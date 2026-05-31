use std::{env, net::SocketAddr, path::PathBuf, time::Duration};

use anyhow::Context;

#[derive(Clone, Debug)]
pub struct Settings {
    pub bind: SocketAddr,
    pub database: DatabaseSettings,
    pub lnd: LndSettings,
    pub ark: ArkSettings,
    pub watcher: WatcherSettings,
}

#[derive(Clone, Debug)]
pub struct DatabaseSettings {
    pub url: String,
    pub path: Option<PathBuf>,
}

#[derive(Clone, Debug)]
pub struct LndSettings {
    pub command_timeout: Duration,
    pub lncli_bin: String,
    pub dir: PathBuf,
    pub rpcserver: String,
    pub network: String,
    pub tls_cert: PathBuf,
    pub no_macaroons: bool,
    pub macaroon: Option<PathBuf>,
}

#[derive(Clone, Debug)]
pub struct ArkSettings {
    pub command_timeout: Duration,
    pub ark_bin: String,
    pub wallet_dir: PathBuf,
    pub password: Option<String>,
}

#[derive(Clone, Debug)]
pub struct WatcherSettings {
    pub enabled: bool,
    pub interval: Duration,
}

impl Settings {
    pub fn from_env() -> anyhow::Result<Self> {
        let bind = env_string("ARK_LND_PROVIDER_BIND", "127.0.0.1:8090")
            .parse()
            .context("parsing ARK_LND_PROVIDER_BIND")?;
        let database_raw = env_string(
            "ARK_LND_PROVIDER_DB",
            "./data/ark-lnd-provider/provider.sqlite",
        );
        let (url, path) = sqlite_url_and_path(&database_raw);
        let command_timeout =
            Duration::from_secs(env_u64("ARK_LND_PROVIDER_COMMAND_TIMEOUT_SEC", 120));

        Ok(Self {
            bind,
            database: DatabaseSettings { url, path },
            lnd: LndSettings {
                command_timeout,
                lncli_bin: env_string("ARK_LND_PROVIDER_LNCLI_BIN", "lncli"),
                dir: env_path("ARK_LND_PROVIDER_LND_DIR", "./data/lnd2"),
                rpcserver: env_string("ARK_LND_PROVIDER_LND_RPCSERVER", "127.0.0.1:10042"),
                network: env_string("ARK_LND_PROVIDER_LND_NETWORK", "signet"),
                tls_cert: env_path("ARK_LND_PROVIDER_LND_TLS_CERT", "./data/lnd2/tls.cert"),
                no_macaroons: env_bool("ARK_LND_PROVIDER_LND_NO_MACAROONS", true),
                macaroon: env::var_os("ARK_LND_PROVIDER_LND_MACAROON").map(PathBuf::from),
            },
            ark: ArkSettings {
                command_timeout,
                ark_bin: env_string("ARK_LND_PROVIDER_ARK_BIN", "ark"),
                wallet_dir: env_path("ARK_LND_PROVIDER_ARK_WALLET_DIR", "./data/ark-cli/maker"),
                password: env::var("ARK_LND_PROVIDER_ARK_PASSWORD").ok(),
            },
            watcher: WatcherSettings {
                enabled: env_bool("ARK_LND_PROVIDER_WATCHER_ENABLED", true),
                interval: Duration::from_secs(env_u64("ARK_LND_PROVIDER_WATCH_INTERVAL_SEC", 2)),
            },
        })
    }
}

fn env_string(key: &str, default: &str) -> String {
    env::var(key).unwrap_or_else(|_| default.to_string())
}

fn env_path(key: &str, default: &str) -> PathBuf {
    env::var_os(key)
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(default))
}

fn env_bool(key: &str, default: bool) -> bool {
    env::var(key)
        .ok()
        .map(|value| {
            matches!(
                value.as_str(),
                "1" | "true" | "TRUE" | "yes" | "YES" | "on" | "ON"
            )
        })
        .unwrap_or(default)
}

fn env_u64(key: &str, default: u64) -> u64 {
    env::var(key)
        .ok()
        .and_then(|value| value.parse().ok())
        .unwrap_or(default)
}

fn sqlite_url_and_path(raw: &str) -> (String, Option<PathBuf>) {
    if raw == "sqlite::memory:" || raw == ":memory:" {
        return ("sqlite::memory:".to_string(), None);
    }
    if let Some(path) = raw.strip_prefix("sqlite://") {
        return (raw.to_string(), Some(PathBuf::from(path)));
    }
    if raw.starts_with("sqlite:") {
        return (raw.to_string(), None);
    }
    let path = PathBuf::from(raw);
    (format!("sqlite://{}", path.display()), Some(path))
}
