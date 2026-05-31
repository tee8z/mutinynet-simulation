use axum::{
    extract::{Path, State},
    http::StatusCode,
    response::{IntoResponse, Response},
    routing::{get, post},
    Json, Router,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use std::{
    collections::{HashMap, VecDeque},
    env, fs,
    path::{Path as FsPath, PathBuf},
    process::Stdio,
    sync::Arc,
    time::{SystemTime, UNIX_EPOCH},
};
use tokio::{
    io::{AsyncBufReadExt, BufReader},
    net::TcpListener,
    process::Command,
    sync::Mutex,
    time::{timeout, Duration},
};
use tower_http::trace::TraceLayer;
use tracing::{error, info};
use uuid::Uuid;

mod dashboard;

const TAIL_LIMIT: usize = 200;

#[derive(Clone)]
struct AppState {
    sim_dir: PathBuf,
    state_dir: PathBuf,
    runs: Arc<Mutex<HashMap<String, RunRuntime>>>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "snake_case")]
enum RunStatus {
    Running,
    Succeeded,
    Failed,
}

#[derive(Clone, Debug)]
struct RunRuntime {
    id: String,
    mode: String,
    status: RunStatus,
    output_dir: PathBuf,
    started_at_unix: u64,
    completed_at_unix: Option<u64>,
    exit_code: Option<i32>,
    stdout_tail: VecDeque<String>,
    stderr_tail: VecDeque<String>,
    error: Option<String>,
}

#[derive(Debug, Deserialize, Default)]
struct StartFlowRequest {
    rgb_asset_id: Option<String>,
    ark_asset_id: Option<String>,
    rgb_asset_amount: Option<u64>,
    ark_asset_amount: Option<String>,
    ln_to_ark_sats: Option<u64>,
    ark_to_rgb_sats: Option<u64>,
    rgb_asset_keysend_msat: Option<u64>,
    fee_limit_sat: Option<u64>,
    wait_timeout_sec: Option<u64>,
}

#[derive(Debug, Serialize)]
struct FlowResponse {
    id: String,
    mode: String,
    status: RunStatus,
    output_dir: String,
    started_at_unix: u64,
    completed_at_unix: Option<u64>,
    exit_code: Option<i32>,
    error: Option<String>,
    stdout_tail: Vec<String>,
    stderr_tail: Vec<String>,
    timeline: Vec<TimelineStep>,
    artifacts: Vec<String>,
}

#[derive(Debug, Serialize)]
struct TimelineStep {
    flow: &'static str,
    step: &'static str,
    label: &'static str,
    file: &'static str,
    observed: bool,
    state: &'static str,
    data: Option<Value>,
}

#[derive(Debug, Serialize)]
struct ClusterSnapshot {
    generated_at_unix: u64,
    checks: Vec<CommandSnapshot>,
}

#[derive(Debug, Serialize)]
struct CommandSnapshot {
    name: &'static str,
    ok: bool,
    exit_code: Option<i32>,
    stdout: Value,
    stderr: Option<String>,
}

struct ApiError {
    status: StatusCode,
    message: String,
}

impl ApiError {
    fn bad_request(message: impl Into<String>) -> Self {
        Self {
            status: StatusCode::BAD_REQUEST,
            message: message.into(),
        }
    }

    fn not_found(message: impl Into<String>) -> Self {
        Self {
            status: StatusCode::NOT_FOUND,
            message: message.into(),
        }
    }

    fn internal(error: impl std::fmt::Display) -> Self {
        Self {
            status: StatusCode::INTERNAL_SERVER_ERROR,
            message: error.to_string(),
        }
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        (self.status, Json(json!({ "error": self.message }))).into_response()
    }
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "mutinynet_bridge_ui=info,tower_http=info".into()),
        )
        .init();

    let sim_dir = env::var("MUTINY_SIM_DIR")
        .map(PathBuf::from)
        .unwrap_or(env::current_dir()?);
    let state_dir = env::var("BRIDGE_UI_STATE_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|_| sim_dir.join("state").join("bridge-ui"));
    fs::create_dir_all(&state_dir)?;

    let bind = env::var("BRIDGE_UI_BIND").unwrap_or_else(|_| "127.0.0.1:8091".to_string());
    let state = AppState {
        sim_dir,
        state_dir,
        runs: Arc::new(Mutex::new(HashMap::new())),
    };

    let app = Router::new()
        .merge(dashboard::dashboard_routes())
        .route("/health", get(health))
        .route("/api/cluster", get(cluster))
        .route("/api/p2p", get(p2p_status))
        .route("/api/p2p/start", post(p2p_start))
        .route("/api/p2p/stop", post(p2p_stop))
        .route("/api/preflight", get(preflight))
        .route("/api/flows", get(list_flows))
        .route("/api/flows/start/{mode}", post(start_flow))
        .route("/api/flows/{id}", get(get_flow))
        .layer(TraceLayer::new_for_http())
        .with_state(state);

    let listener = TcpListener::bind(&bind).await?;
    info!("bridge UI listening on http://{}", bind);
    axum::serve(listener, app)
        .with_graceful_shutdown(shutdown_signal())
        .await?;
    Ok(())
}

async fn shutdown_signal() {
    let _ = tokio::signal::ctrl_c().await;
}

async fn health(State(state): State<AppState>) -> Json<Value> {
    Json(json!({
        "ok": true,
        "sim_dir": state.sim_dir,
        "state_dir": state.state_dir,
    }))
}

async fn preflight(State(state): State<AppState>) -> Json<Value> {
    let rgb = resolve_rgb_asset_id(&state).await;
    let ark = resolve_ark_asset_id(&state, "all", "100").await;
    let mut missing = Vec::new();
    if rgb.is_err() {
        missing.push("rgb_asset_id");
    }
    if ark.is_err() {
        missing.push("ark_asset_id");
    }

    Json(json!({
        "generated_at_unix": now_unix(),
        "ready": missing.is_empty(),
        "missing": missing,
        "rgb_asset_id": resolution_json(rgb),
        "ark_asset_id": resolution_json(ark),
    }))
}

async fn list_flows(State(state): State<AppState>) -> Json<Value> {
    let runs = state.runs.lock().await;
    let flows = runs
        .values()
        .map(|run| {
            json!({
                "id": run.id,
                "mode": run.mode,
                "status": run.status,
                "output_dir": run.output_dir,
                "started_at_unix": run.started_at_unix,
                "completed_at_unix": run.completed_at_unix,
                "exit_code": run.exit_code,
                "error": run.error,
            })
        })
        .collect::<Vec<_>>();
    Json(json!({ "flows": flows }))
}

async fn get_flow(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<Json<FlowResponse>, ApiError> {
    Ok(Json(flow_response(&state, &id).await?))
}

async fn start_flow(
    State(state): State<AppState>,
    Path(mode): Path<String>,
    request: Option<Json<StartFlowRequest>>,
) -> Result<Json<FlowResponse>, ApiError> {
    let mut request = request.map(|Json(request)| request).unwrap_or_default();
    let mode = normalize_mode(&mode)?;
    reject_if_flow_running(&state).await?;
    apply_default_assets(&state, &mode, &mut request)
        .await
        .map_err(|err| ApiError::bad_request(err.to_string()))?;
    let run_id = format!("{}-{}", now_unix(), Uuid::new_v4());
    let output_dir = state.state_dir.join(&run_id).join("artifacts");
    fs::create_dir_all(&output_dir).map_err(ApiError::internal)?;

    let runtime = RunRuntime {
        id: run_id.clone(),
        mode: mode.clone(),
        status: RunStatus::Running,
        output_dir: output_dir.clone(),
        started_at_unix: now_unix(),
        completed_at_unix: None,
        exit_code: None,
        stdout_tail: VecDeque::new(),
        stderr_tail: VecDeque::new(),
        error: None,
    };
    state.runs.lock().await.insert(run_id.clone(), runtime);

    let task_state = state.clone();
    let task_run_id = run_id.clone();
    tokio::spawn(async move {
        if let Err(err) = run_harness(task_state.clone(), task_run_id.clone(), request).await {
            error!(run_id = %task_run_id, "bridge harness failed to start: {err}");
            let mut runs = task_state.runs.lock().await;
            if let Some(run) = runs.get_mut(&task_run_id) {
                run.status = RunStatus::Failed;
                run.completed_at_unix = Some(now_unix());
                run.error = Some(err.to_string());
            }
        }
    });

    Ok(Json(flow_response(&state, &run_id).await?))
}

async fn run_harness(
    state: AppState,
    run_id: String,
    request: StartFlowRequest,
) -> anyhow::Result<()> {
    let run = state
        .runs
        .lock()
        .await
        .get(&run_id)
        .cloned()
        .ok_or_else(|| anyhow::anyhow!("run not found"))?;

    let script_name = if run.mode == "setup-assets" {
        "setup-bridge-assets.sh"
    } else {
        "test-lightning-ark-bridge.sh"
    };
    let script = state.sim_dir.join("scripts").join(script_name);
    let mut command = Command::new(script);
    command
        .current_dir(&state.sim_dir)
        .env("MUTINY_SIM_DIR", &state.sim_dir)
        .env("BRIDGE_TEST_OUTPUT_DIR", &run.output_dir)
        .env("BRIDGE_SETUP_OUTPUT_DIR", &run.output_dir)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    if run.mode != "setup-assets" {
        command.arg(&run.mode);
    }

    if let Some(value) = request.rgb_asset_id {
        command.env("BRIDGE_TEST_RGB_ASSET_ID", value);
    }
    if let Some(value) = request.ark_asset_id {
        command.env("BRIDGE_TEST_ARK_ASSET_ID", value);
    }
    if let Some(value) = request.rgb_asset_amount {
        command.env("BRIDGE_TEST_RGB_ASSET_AMOUNT", value.to_string());
    }
    if let Some(value) = request.ark_asset_amount {
        command.env("BRIDGE_TEST_ARK_ASSET_AMOUNT", value);
    }
    if let Some(value) = request.ln_to_ark_sats {
        command.env("BRIDGE_TEST_LN_TO_ARK_SATS", value.to_string());
    }
    if let Some(value) = request.ark_to_rgb_sats {
        command.env("BRIDGE_TEST_ARK_TO_RGB_SATS", value.to_string());
    }
    if let Some(value) = request.rgb_asset_keysend_msat {
        command.env("BRIDGE_TEST_RGB_ASSET_KEYSEND_MSAT", value.to_string());
    }
    if let Some(value) = request.fee_limit_sat {
        command.env("BRIDGE_TEST_FEE_LIMIT_SAT", value.to_string());
    }
    if let Some(value) = request.wait_timeout_sec {
        command.env("BRIDGE_TEST_WAIT_TIMEOUT_SEC", value.to_string());
    }
    if (run.mode == "setup-assets" || is_bridge_mode(&run.mode))
        && env::var("BRIDGE_TEST_ARK_TAKER_PRIVATE_KEY_HEX")
            .ok()
            .filter(|value| !value.trim().is_empty())
            .is_none()
    {
        command.env(
            "BRIDGE_TEST_ARK_TAKER_PRIVATE_KEY_HEX",
            derive_taker_private_key(&state).await?,
        );
    }

    let mut child = command.spawn()?;
    let stdout = child.stdout.take();
    let stderr = child.stderr.take();

    let stdout_task = stdout.map(|stream| {
        tokio::spawn(read_tail(
            state.clone(),
            run_id.clone(),
            StreamKind::Stdout,
            stream,
        ))
    });
    let stderr_task = stderr.map(|stream| {
        tokio::spawn(read_tail(
            state.clone(),
            run_id.clone(),
            StreamKind::Stderr,
            stream,
        ))
    });

    let status = child.wait().await?;

    if let Some(task) = stdout_task {
        let _ = task.await;
    }
    if let Some(task) = stderr_task {
        let _ = task.await;
    }

    let mut runs = state.runs.lock().await;
    if let Some(run) = runs.get_mut(&run_id) {
        run.completed_at_unix = Some(now_unix());
        run.exit_code = status.code();
        run.status = if status.success() {
            RunStatus::Succeeded
        } else {
            RunStatus::Failed
        };
        if !status.success() {
            run.error = Some(format!("harness exited with status {status}"));
        }
    }

    Ok(())
}

enum StreamKind {
    Stdout,
    Stderr,
}

async fn read_tail<R>(state: AppState, run_id: String, kind: StreamKind, stream: R)
where
    R: tokio::io::AsyncRead + Unpin,
{
    let mut lines = BufReader::new(stream).lines();
    while let Ok(Some(line)) = lines.next_line().await {
        let mut runs = state.runs.lock().await;
        let Some(run) = runs.get_mut(&run_id) else {
            return;
        };
        let tail = match kind {
            StreamKind::Stdout => &mut run.stdout_tail,
            StreamKind::Stderr => &mut run.stderr_tail,
        };
        tail.push_back(line);
        while tail.len() > TAIL_LIMIT {
            tail.pop_front();
        }
    }
}

async fn cluster(State(state): State<AppState>) -> Json<ClusterSnapshot> {
    let checks = vec![
        run_cluster_command(
            &state.sim_dir,
            "provider",
            "curl -sS --fail-with-body \"$(ark_lnd_provider_url)/health\"",
        )
        .await,
        run_cluster_command(&state.sim_dir, "rgb_node1", "api node1 GET /nodeinfo").await,
        run_cluster_command(&state.sim_dir, "rgb_node4", "api node4 GET /nodeinfo").await,
        run_cluster_command(&state.sim_dir, "lnd1", "lnd_cli lnd1 getinfo").await,
        run_cluster_command(&state.sim_dir, "lnd2", "lnd_cli lnd2 getinfo").await,
        run_cluster_command(&state.sim_dir, "ark_maker", "ark_cli maker balance").await,
        run_cluster_command(&state.sim_dir, "ark_taker", "ark_cli taker balance").await,
    ];

    Json(ClusterSnapshot {
        generated_at_unix: now_unix(),
        checks,
    })
}

async fn p2p_status(State(state): State<AppState>) -> Json<CommandSnapshot> {
    let mut snapshot = run_cluster_command_timeout(
        &state.sim_dir,
        "bitcoind_p2p",
        "scripts/bitcoind-p2p-port-forward.sh status",
        Duration::from_secs(10),
    )
    .await;
    if snapshot
        .stdout
        .as_str()
        .is_some_and(|text| text.contains(" closed"))
    {
        snapshot.ok = false;
    }
    Json(snapshot)
}

async fn p2p_start(State(state): State<AppState>) -> Json<CommandSnapshot> {
    Json(
        run_cluster_command_timeout(
            &state.sim_dir,
            "bitcoind_p2p_start",
            "scripts/bitcoind-p2p-port-forward.sh start",
            Duration::from_secs(45),
        )
        .await,
    )
}

async fn p2p_stop(State(state): State<AppState>) -> Json<CommandSnapshot> {
    Json(
        run_cluster_command_timeout(
            &state.sim_dir,
            "bitcoind_p2p_stop",
            "scripts/bitcoind-p2p-port-forward.sh stop",
            Duration::from_secs(15),
        )
        .await,
    )
}

async fn run_cluster_command(
    sim_dir: &FsPath,
    name: &'static str,
    shell_command: &'static str,
) -> CommandSnapshot {
    run_cluster_command_timeout(sim_dir, name, shell_command, Duration::from_secs(10)).await
}

async fn run_cluster_command_timeout(
    sim_dir: &FsPath,
    name: &'static str,
    shell_command: &'static str,
    command_timeout: Duration,
) -> CommandSnapshot {
    let script = format!(
        "source scripts/lib.sh >/dev/null; export PATH=\"$SIM_DIR/result/bin:$PATH\"; {shell_command}"
    );
    let output = timeout(
        command_timeout,
        Command::new("bash")
            .arg("-lc")
            .arg(script)
            .current_dir(sim_dir)
            .output(),
    )
    .await;

    match output {
        Ok(Ok(output)) => {
            let stdout_text = String::from_utf8_lossy(&output.stdout).trim().to_string();
            let stderr_text = String::from_utf8_lossy(&output.stderr).trim().to_string();
            CommandSnapshot {
                name,
                ok: output.status.success(),
                exit_code: output.status.code(),
                stdout: parse_and_redact(&stdout_text),
                stderr: if stderr_text.is_empty() {
                    None
                } else {
                    Some(stderr_text)
                },
            }
        }
        Ok(Err(err)) => CommandSnapshot {
            name,
            ok: false,
            exit_code: None,
            stdout: Value::Null,
            stderr: Some(err.to_string()),
        },
        Err(_) => CommandSnapshot {
            name,
            ok: false,
            exit_code: None,
            stdout: Value::Null,
            stderr: Some("command timed out".to_string()),
        },
    }
}

async fn apply_default_assets(
    state: &AppState,
    mode: &str,
    request: &mut StartFlowRequest,
) -> anyhow::Result<()> {
    if request
        .rgb_asset_id
        .as_deref()
        .unwrap_or_default()
        .is_empty()
    {
        match resolve_rgb_asset_id(state).await {
            Ok(resolved) => request.rgb_asset_id = Some(resolved.value),
            Err(err) if mode == "setup-assets" => {
                info!("setup-assets will issue RGB asset because no default resolved: {err}");
            }
            Err(err) => return Err(err),
        }
    }

    if request
        .ark_asset_id
        .as_deref()
        .unwrap_or_default()
        .is_empty()
    {
        let amount = request.ark_asset_amount.as_deref().unwrap_or("100");
        match resolve_ark_asset_id(state, mode, amount).await {
            Ok(resolved) => request.ark_asset_id = Some(resolved.value),
            Err(err) if mode == "setup-assets" => {
                info!("setup-assets will issue Ark asset because no default resolved: {err}");
            }
            Err(err) => return Err(err),
        }
    }

    Ok(())
}

async fn reject_if_flow_running(state: &AppState) -> Result<(), ApiError> {
    let runs = state.runs.lock().await;
    if let Some(run) = runs
        .values()
        .find(|run| matches!(run.status, RunStatus::Running))
    {
        return Err(ApiError::bad_request(format!(
            "{} is still running as {}; wait for it to finish before starting another flow",
            run.mode, run.id
        )));
    }
    Ok(())
}

#[derive(Debug)]
struct ResolvedValue {
    value: String,
    source: &'static str,
}

fn resolution_json(result: anyhow::Result<ResolvedValue>) -> Value {
    match result {
        Ok(resolved) => {
            let fingerprint = fingerprint(&resolved.value);
            json!({
                "ok": true,
                "source": resolved.source,
                "value": resolved.value,
                "fingerprint": fingerprint,
            })
        }
        Err(err) => json!({
            "ok": false,
            "error": err.to_string(),
        }),
    }
}

async fn resolve_rgb_asset_id(state: &AppState) -> anyhow::Result<ResolvedValue> {
    if let Some(value) = first_env_value(&["BRIDGE_TEST_RGB_ASSET_ID", "RGB_MM_ASSET_ID"]) {
        return Ok(ResolvedValue {
            value,
            source: "env",
        });
    }

    for node in ["node1", "node4"] {
        let output = run_raw_shell_json(
            &state.sim_dir,
            &format!("api {node} GET /listchannels"),
            Duration::from_secs(10),
        )
        .await?;
        if let Some(asset_id) =
            output
                .get("channels")
                .and_then(Value::as_array)
                .and_then(|channels| {
                    channels.iter().find_map(|channel| {
                        let asset_id = channel.get("asset_id").and_then(Value::as_str)?;
                        if asset_id.is_empty() {
                            return None;
                        }
                        if channel
                            .get("is_usable")
                            .and_then(Value::as_bool)
                            .unwrap_or(false)
                        {
                            Some(asset_id.to_string())
                        } else {
                            None
                        }
                    })
                })
        {
            return Ok(ResolvedValue {
                value: asset_id,
                source: "rgb_channel",
            });
        }
    }

    anyhow::bail!(
        "set BRIDGE_TEST_RGB_ASSET_ID/RGB_MM_ASSET_ID or create a usable RGB asset channel"
    )
}

async fn resolve_ark_asset_id(
    state: &AppState,
    mode: &str,
    amount: &str,
) -> anyhow::Result<ResolvedValue> {
    if let Some(value) = first_env_value(&["BRIDGE_TEST_ARK_ASSET_ID", "ARK_TEST_ASSET_ID"]) {
        return Ok(ResolvedValue {
            value,
            source: "env",
        });
    }

    let wallet = if mode == "ark-asset-to-rgb-asset" {
        "taker"
    } else {
        "maker"
    };
    let output = run_raw_shell_json(
        &state.sim_dir,
        &format!("ark_cli {wallet} balance"),
        Duration::from_secs(10),
    )
    .await?;
    let needed = amount.parse::<u64>().unwrap_or(1);
    let balances = output
        .get("asset_balances")
        .and_then(Value::as_object)
        .ok_or_else(|| anyhow::anyhow!("ark {wallet} balance did not include asset_balances"))?;

    balances
        .iter()
        .find_map(|(asset_id, balance)| {
            let balance = value_as_u64(balance)?;
            (balance >= needed).then(|| ResolvedValue {
                value: asset_id.to_string(),
                source: "ark_balance",
            })
        })
        .ok_or_else(|| anyhow::anyhow!("ark {wallet} has no asset balance >= {needed}"))
}

fn first_env_value(keys: &[&str]) -> Option<String> {
    keys.iter()
        .find_map(|key| env::var(key).ok().filter(|value| !value.trim().is_empty()))
}

async fn run_raw_shell_json(
    sim_dir: &FsPath,
    shell_command: &str,
    command_timeout: Duration,
) -> anyhow::Result<Value> {
    let script = format!(
        "source scripts/lib.sh >/dev/null; export PATH=\"$SIM_DIR/result/bin:$PATH\"; {shell_command}"
    );
    let output = timeout(
        command_timeout,
        Command::new("bash")
            .arg("-lc")
            .arg(script)
            .current_dir(sim_dir)
            .output(),
    )
    .await
    .map_err(|_| anyhow::anyhow!("command timed out: {shell_command}"))??;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        anyhow::bail!("{shell_command} failed: {stderr}");
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    Ok(serde_json::from_str(stdout.trim())?)
}

async fn run_raw_shell_text(
    sim_dir: &FsPath,
    shell_command: &str,
    command_timeout: Duration,
) -> anyhow::Result<String> {
    let script = format!(
        "source scripts/lib.sh >/dev/null; export PATH=\"$SIM_DIR/result/bin:$PATH\"; {shell_command}"
    );
    let output = timeout(
        command_timeout,
        Command::new("bash")
            .arg("-lc")
            .arg(script)
            .current_dir(sim_dir)
            .output(),
    )
    .await
    .map_err(|_| anyhow::anyhow!("command timed out: {shell_command}"))??;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        anyhow::bail!("{shell_command} failed: {stderr}");
    }

    Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
}

async fn derive_taker_private_key(state: &AppState) -> anyhow::Result<String> {
    let key = run_raw_shell_text(
        &state.sim_dir,
        "wallet=\"${BRIDGE_TEST_ARK_TAKER_WALLET:-taker}\"; ark_cli \"$wallet\" dump-privkey --password \"$ARK_CLI_PASSWORD\" | grep -Eo '[0-9a-fA-F]{64}' | head -n 1",
        Duration::from_secs(10),
    )
    .await?;
    if key.len() == 64 && key.chars().all(|ch| ch.is_ascii_hexdigit()) {
        Ok(key)
    } else {
        anyhow::bail!("could not derive taker wallet private key")
    }
}

fn value_as_u64(value: &Value) -> Option<u64> {
    value
        .as_u64()
        .or_else(|| value.as_str().and_then(|text| text.parse::<u64>().ok()))
}

async fn flow_response(state: &AppState, id: &str) -> Result<FlowResponse, ApiError> {
    let run = state
        .runs
        .lock()
        .await
        .get(id)
        .cloned()
        .ok_or_else(|| ApiError::not_found("flow run not found"))?;
    let artifacts = artifact_files(&run.output_dir);
    let timeline = build_timeline(&run.mode, &run.output_dir);

    Ok(FlowResponse {
        id: run.id,
        mode: run.mode,
        status: run.status,
        output_dir: redact_local_paths(&run.output_dir.display().to_string()),
        started_at_unix: run.started_at_unix,
        completed_at_unix: run.completed_at_unix,
        exit_code: run.exit_code,
        error: run.error.map(|text| redact_local_paths(&text)),
        stdout_tail: run
            .stdout_tail
            .into_iter()
            .map(|text| redact_local_paths(&text))
            .collect(),
        stderr_tail: run
            .stderr_tail
            .into_iter()
            .map(|text| redact_local_paths(&text))
            .collect(),
        timeline,
        artifacts,
    })
}

fn artifact_files(output_dir: &FsPath) -> Vec<String> {
    let Ok(entries) = fs::read_dir(output_dir) else {
        return Vec::new();
    };
    let mut files = entries
        .filter_map(Result::ok)
        .filter_map(|entry| {
            let path = entry.path();
            if path.extension().and_then(|ext| ext.to_str()) != Some("json") {
                return None;
            }
            path.file_name()
                .and_then(|name| name.to_str())
                .map(ToOwned::to_owned)
        })
        .collect::<Vec<_>>();
    files.sort();
    files
}

#[derive(Clone, Copy)]
struct StepDef {
    flow: &'static str,
    step: &'static str,
    label: &'static str,
    file: &'static str,
}

fn build_timeline(mode: &str, output_dir: &FsPath) -> Vec<TimelineStep> {
    let mut defs: Vec<StepDef> = Vec::new();
    if mode == "setup-assets" {
        defs.extend_from_slice(SETUP_STEPS);
    }
    if mode == "all" || mode == "rgb-asset-to-ark-asset" {
        defs.extend_from_slice(RGB_TO_ARK_STEPS);
    }
    if mode == "all" || mode == "ark-asset-to-rgb-asset" {
        defs.extend_from_slice(ARK_TO_RGB_STEPS);
    }

    defs.into_iter()
        .map(|def| {
            let path = output_dir.join(def.file);
            let data = fs::read_to_string(&path).ok().map(|text| {
                serde_json::from_str::<Value>(&text)
                    .map(|value| redact_value(&value))
                    .unwrap_or_else(|_| Value::String(redact_local_paths(&text)))
            });
            let state = match data.as_ref() {
                Some(value) if timeline_value_failed(value) => "failed",
                Some(_) => "done",
                None => "pending",
            };
            TimelineStep {
                flow: def.flow,
                step: def.step,
                label: def.label,
                file: def.file,
                observed: data.is_some(),
                state,
                data,
            }
        })
        .collect()
}

fn timeline_value_failed(value: &Value) -> bool {
    value
        .pointer("/payment/status")
        .and_then(Value::as_str)
        .is_some_and(|status| status == "Failed")
        || value
            .get("status")
            .and_then(Value::as_str)
            .is_some_and(|status| status == "Failed" || status == "failed")
        || value
            .get("last_error")
            .and_then(Value::as_str)
            .is_some_and(|error| !error.is_empty())
}

const RGB_TO_ARK_STEPS: &[StepDef] = &[
    StepDef {
        flow: "rgb_asset_to_ark_asset",
        step: "provider_health",
        label: "provider is reachable",
        file: "provider-health.json",
    },
    StepDef {
        flow: "rgb_asset_to_ark_asset",
        step: "contract_template",
        label: "provider creates hold invoice and Ark VHTLC template",
        file: "rgb-asset-to-ark-asset-swap-created.json",
    },
    StepDef {
        flow: "rgb_asset_to_ark_asset",
        step: "rgb_payment_sent",
        label: "RGB asset payment locks the Lightning leg",
        file: "rgb-asset-to-ark-asset-rgb-sendpayment.json",
    },
    StepDef {
        flow: "rgb_asset_to_ark_asset",
        step: "contract_funded",
        label: "provider funds Ark VHTLC",
        file: "rgb-asset-to-ark-asset-contract-fund.json",
    },
    StepDef {
        flow: "rgb_asset_to_ark_asset",
        step: "contract_claimed",
        label: "taker claims Ark VHTLC",
        file: "rgb-asset-to-ark-asset-contract-claim.json",
    },
    StepDef {
        flow: "rgb_asset_to_ark_asset",
        step: "claim_observed",
        label: "provider settles from observed claim preimage",
        file: "rgb-asset-to-ark-asset-observe-claim.json",
    },
    StepDef {
        flow: "rgb_asset_to_ark_asset",
        step: "summary",
        label: "proof summary recorded",
        file: "rgb-asset-to-ark-asset-proof-summary.json",
    },
];

const ARK_TO_RGB_STEPS: &[StepDef] = &[
    StepDef {
        flow: "ark_asset_to_rgb_asset",
        step: "rgb_invoice",
        label: "RGB mapped invoice is created",
        file: "ark-asset-to-rgb-asset-rgb-invoice.json",
    },
    StepDef {
        flow: "ark_asset_to_rgb_asset",
        step: "contract_template",
        label: "provider creates Ark VHTLC template",
        file: "ark-asset-to-rgb-asset-swap-created.json",
    },
    StepDef {
        flow: "ark_asset_to_rgb_asset",
        step: "contract_funded",
        label: "payer funds Ark VHTLC",
        file: "ark-asset-to-rgb-asset-contract-fund.json",
    },
    StepDef {
        flow: "ark_asset_to_rgb_asset",
        step: "contract_verified",
        label: "provider verifies funded VHTLC",
        file: "ark-asset-to-rgb-asset-contract-verify-funded.json",
    },
    StepDef {
        flow: "ark_asset_to_rgb_asset",
        step: "ln_payment",
        label: "provider pays RGB/LN invoice",
        file: "ark-asset-to-rgb-asset-provider-pay.json",
    },
    StepDef {
        flow: "ark_asset_to_rgb_asset",
        step: "rgb_claim",
        label: "RGB maker claims mapped invoice",
        file: "ark-asset-to-rgb-asset-rgb-claim.json",
    },
    StepDef {
        flow: "ark_asset_to_rgb_asset",
        step: "contract_claimed",
        label: "provider claims Ark VHTLC",
        file: "ark-asset-to-rgb-asset-contract-claim.json",
    },
    StepDef {
        flow: "ark_asset_to_rgb_asset",
        step: "summary",
        label: "proof summary recorded",
        file: "ark-asset-to-rgb-asset-proof-summary.json",
    },
];

const SETUP_STEPS: &[StepDef] = &[
    StepDef {
        flow: "setup",
        step: "rgb_issue",
        label: "RGB asset is available",
        file: "rgb-issue.json",
    },
    StepDef {
        flow: "setup",
        step: "market_maker_channels",
        label: "RGB market-maker channels are created",
        file: "market-maker-setup.log",
    },
    StepDef {
        flow: "setup",
        step: "ark_issue",
        label: "Ark asset is available",
        file: "ark-issue.json",
    },
    StepDef {
        flow: "setup",
        step: "ark_maker_balance",
        label: "Ark maker wallet has inventory",
        file: "ark-maker-balance.json",
    },
    StepDef {
        flow: "setup",
        step: "ark_taker_balance",
        label: "Ark taker wallet has inventory",
        file: "ark-taker-balance.json",
    },
    StepDef {
        flow: "setup",
        step: "summary",
        label: "Setup summary is written",
        file: "setup-summary.json",
    },
];

fn normalize_mode(mode: &str) -> Result<String, ApiError> {
    match mode {
        "setup-assets" => Ok("setup-assets".to_string()),
        "all" => Ok("all".to_string()),
        "rgb-asset-to-ark-asset" | "ln-to-ark" => Ok("rgb-asset-to-ark-asset".to_string()),
        "ark-asset-to-rgb-asset" | "ark-to-ln" => Ok("ark-asset-to-rgb-asset".to_string()),
        _ => Err(ApiError::bad_request(
            "mode must be setup-assets, all, rgb-asset-to-ark-asset, or ark-asset-to-rgb-asset",
        )),
    }
}

fn is_bridge_mode(mode: &str) -> bool {
    matches!(
        mode,
        "all" | "rgb-asset-to-ark-asset" | "ark-asset-to-rgb-asset"
    )
}

fn now_unix() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

fn parse_and_redact(text: &str) -> Value {
    if text.is_empty() {
        return Value::Null;
    }
    match serde_json::from_str::<Value>(text) {
        Ok(value) => redact_value(&value),
        Err(_) => Value::String(redact_local_paths(text)),
    }
}

fn redact_value(value: &Value) -> Value {
    redact_value_with_key("", value)
}

fn redact_value_with_key(key: &str, value: &Value) -> Value {
    if is_secret_key(key) {
        return Value::String("<redacted>".to_string());
    }

    match value {
        Value::Object(map) => Value::Object(
            map.iter()
                .map(|(child_key, child_value)| {
                    (
                        redact_object_key(key, child_key),
                        redact_value_with_key(child_key, child_value),
                    )
                })
                .collect::<Map<_, _>>(),
        ),
        Value::Array(values) => Value::Array(
            values
                .iter()
                .map(|child| redact_value_with_key(key, child))
                .collect(),
        ),
        Value::String(text) => Value::String(redact_string(key, text)),
        _ => value.clone(),
    }
}

fn redact_object_key(_parent_key: &str, key: &str) -> String {
    key.to_string()
}

fn redact_string(key: &str, text: &str) -> String {
    let lower = key.to_ascii_lowercase();

    if is_secret_key(&lower) {
        return "<redacted>".to_string();
    }

    if lower.contains("wallet_dir") || lower.contains("output_dir") || looks_like_local_path(text) {
        return redact_local_paths(text);
    }

    redact_local_paths(text)
}

fn is_secret_key(key: &str) -> bool {
    let lower = key.to_ascii_lowercase();
    lower == "preimage"
        || lower.contains("wallet_private_key")
        || lower.contains("private_key")
        || lower.contains("privatekey")
        || lower.contains("privkey")
        || lower.contains("password")
        || lower.contains("macaroon")
        || lower.contains("secret")
}

fn redact_local_paths(text: &str) -> String {
    let mut redacted = String::with_capacity(text.len());
    let mut cursor = 0;

    while cursor < text.len() {
        let rest = &text[cursor..];

        if rest.starts_with("/home/") || rest.starts_with("/tmp/") {
            let token_len = rest
                .find(|ch: char| ch.is_whitespace() || matches!(ch, '"' | '\'' | ',' | ')' | ']'))
                .unwrap_or(rest.len());
            redacted.push_str(&scrub_path_token(&rest[..token_len]));
            cursor += token_len;
            continue;
        }

        let ch = rest.chars().next().expect("non-empty string slice");
        redacted.push(ch);
        cursor += ch.len_utf8();
    }

    redacted
}

fn looks_like_local_path(text: &str) -> bool {
    text.starts_with("/home/") || text.starts_with("/tmp/") || text.contains(" /home/")
}

fn scrub_path_token(path: &str) -> String {
    if let Some((_, relative)) = path.split_once("/mutinynet-simulation/") {
        format!("./{relative}")
    } else {
        "<local-path>".to_string()
    }
}

fn fingerprint(text: &str) -> String {
    let chars = text.chars().collect::<Vec<_>>();
    if chars.len() <= 20 {
        return "<redacted>".to_string();
    }
    let head = chars.iter().take(10).collect::<String>();
    let tail = chars
        .iter()
        .rev()
        .take(8)
        .collect::<Vec<_>>()
        .into_iter()
        .rev()
        .collect::<String>();
    format!("{head}...{tail}")
}
