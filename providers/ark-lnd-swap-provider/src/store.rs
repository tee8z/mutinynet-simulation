use std::{
    fmt,
    path::Path,
    str::FromStr,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use anyhow::Context;
use serde::Serialize;
use serde_json::Value;
use sqlx::{
    sqlite::{SqliteConnectOptions, SqliteJournalMode, SqlitePoolOptions, SqliteSynchronous},
    SqlitePool,
};
use tokio::sync::{mpsc, oneshot};

use crate::{
    config::DatabaseSettings,
    models::{CommandResult, ListSwapsQuery, SwapRow},
};

static MIGRATOR: sqlx::migrate::Migrator = sqlx::migrate!("./migrations");

#[derive(Clone)]
pub struct SwapStore {
    read_pool: SqlitePool,
    writer: mpsc::Sender<WriteCommand>,
}

pub struct NewLnToArkSwap {
    pub id: String,
    pub amount_sat: i64,
    pub preimage_hash: String,
    pub preimage_hash_sha256: Option<String>,
    pub preimage_hash_hash160: Option<String>,
    pub preimage: Option<String>,
    pub preimage_source: Option<String>,
    pub bolt11: String,
    pub asset_id: Option<String>,
    pub asset_amount: Option<String>,
    pub ark_wallet_dir: Option<String>,
    pub ark_recipient: Option<String>,
    pub ark_contract_address: Option<String>,
    pub ark_contract_script: Option<String>,
    pub ark_tap_tree: Option<String>,
    pub ark_vtxo_outpoint: Option<String>,
    pub ark_claim_pubkey: Option<String>,
    pub ark_refund_pubkey: Option<String>,
    pub ark_refund_time: Option<i64>,
    pub ln_expiry: Option<i64>,
    pub ark_contract_result: Option<CommandResult>,
    pub ln_result: CommandResult,
    pub metadata: Option<Value>,
}

pub struct NewArkToLnSwap {
    pub id: String,
    pub amount_sat: Option<i64>,
    pub preimage_hash: Option<String>,
    pub preimage_hash_sha256: Option<String>,
    pub preimage_hash_hash160: Option<String>,
    pub preimage_source: Option<String>,
    pub bolt11: String,
    pub asset_id: Option<String>,
    pub asset_amount: Option<String>,
    pub ark_wallet_dir: Option<String>,
    pub ark_contract_address: Option<String>,
    pub ark_contract_script: Option<String>,
    pub ark_tap_tree: Option<String>,
    pub ark_vtxo_outpoint: Option<String>,
    pub ark_claim_pubkey: Option<String>,
    pub ark_refund_pubkey: Option<String>,
    pub ark_refund_time: Option<i64>,
    pub ln_expiry: Option<i64>,
    pub ark_contract_result: Option<CommandResult>,
    pub ln_result: CommandResult,
    pub metadata: Option<Value>,
}

pub type StoreResult<T> = Result<T, StoreError>;

#[derive(Debug)]
pub enum StoreError {
    NotFound(String),
    Internal(anyhow::Error),
    WriterClosed,
}

impl fmt::Display for StoreError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::NotFound(id) => write!(f, "swap not found: {id}"),
            Self::Internal(error) => write!(f, "{error}"),
            Self::WriterClosed => write!(f, "store writer task is closed"),
        }
    }
}

impl std::error::Error for StoreError {}

impl From<anyhow::Error> for StoreError {
    fn from(error: anyhow::Error) -> Self {
        Self::Internal(error)
    }
}

impl From<sqlx::Error> for StoreError {
    fn from(error: sqlx::Error) -> Self {
        Self::Internal(error.into())
    }
}

impl From<serde_json::Error> for StoreError {
    fn from(error: serde_json::Error) -> Self {
        Self::Internal(error.into())
    }
}

enum WriteCommand {
    CreateLnToArk {
        record: NewLnToArkSwap,
        respond_to: oneshot::Sender<StoreResult<SwapRow>>,
    },
    CreateArkToLn {
        record: NewArkToLnSwap,
        respond_to: oneshot::Sender<StoreResult<SwapRow>>,
    },
    UpdateLnState {
        id: String,
        status: String,
        result: CommandResult,
        respond_to: oneshot::Sender<StoreResult<SwapRow>>,
    },
    UpdateArkState {
        id: String,
        status: String,
        result: CommandResult,
        respond_to: oneshot::Sender<StoreResult<SwapRow>>,
    },
    UpdateContractState {
        id: String,
        status: String,
        result: CommandResult,
        respond_to: oneshot::Sender<StoreResult<SwapRow>>,
    },
    UpdatePreimage {
        id: String,
        preimage: String,
        source: String,
        respond_to: oneshot::Sender<StoreResult<SwapRow>>,
    },
}

impl SwapStore {
    pub async fn connect(settings: &DatabaseSettings) -> anyhow::Result<Self> {
        if let Some(path) = &settings.path {
            create_parent_dir(path).await?;
        }

        let writer_pool = open_pool(settings, 1).await?;
        migrate(&writer_pool).await?;

        let read_pool = if settings.url == "sqlite::memory:" {
            writer_pool.clone()
        } else {
            open_pool(settings, 8).await?
        };
        let (writer, receiver) = mpsc::channel(128);
        tokio::spawn(write_loop(writer_pool, receiver));

        Ok(Self { read_pool, writer })
    }

    pub async fn health_check(&self) -> bool {
        sqlx::query_scalar::<_, i64>("SELECT 1")
            .fetch_one(&self.read_pool)
            .await
            .is_ok()
    }

    pub async fn list_swaps(&self, query: &ListSwapsQuery) -> StoreResult<Vec<SwapRow>> {
        let limit = query.limit.unwrap_or(50).clamp(1, 500);
        let rows = sqlx::query_as::<_, SwapRow>(
            r#"
            SELECT *
            FROM swaps
            WHERE (? IS NULL OR kind = ?)
              AND (? IS NULL OR status = ?)
            ORDER BY created_at DESC
            LIMIT ?
            "#,
        )
        .bind(query.kind.as_deref())
        .bind(query.kind.as_deref())
        .bind(query.status.as_deref())
        .bind(query.status.as_deref())
        .bind(limit)
        .fetch_all(&self.read_pool)
        .await?;

        Ok(rows)
    }

    pub async fn load_swap(&self, id: &str) -> StoreResult<SwapRow> {
        load_swap(&self.read_pool, id).await
    }

    pub async fn create_ln_to_ark(&self, record: NewLnToArkSwap) -> StoreResult<SwapRow> {
        self.send_write(|respond_to| WriteCommand::CreateLnToArk { record, respond_to })
            .await
    }

    pub async fn create_ark_to_ln(&self, record: NewArkToLnSwap) -> StoreResult<SwapRow> {
        self.send_write(|respond_to| WriteCommand::CreateArkToLn { record, respond_to })
            .await
    }

    pub async fn update_ln_state(
        &self,
        id: String,
        status: impl Into<String>,
        result: CommandResult,
    ) -> StoreResult<SwapRow> {
        let status = status.into();
        self.send_write(|respond_to| WriteCommand::UpdateLnState {
            id,
            status,
            result,
            respond_to,
        })
        .await
    }

    pub async fn update_ark_state(
        &self,
        id: String,
        status: impl Into<String>,
        result: CommandResult,
    ) -> StoreResult<SwapRow> {
        let status = status.into();
        self.send_write(|respond_to| WriteCommand::UpdateArkState {
            id,
            status,
            result,
            respond_to,
        })
        .await
    }

    pub async fn update_contract_state(
        &self,
        id: String,
        status: impl Into<String>,
        result: CommandResult,
    ) -> StoreResult<SwapRow> {
        let status = status.into();
        self.send_write(|respond_to| WriteCommand::UpdateContractState {
            id,
            status,
            result,
            respond_to,
        })
        .await
    }

    pub async fn update_preimage(
        &self,
        id: String,
        preimage: String,
        source: impl Into<String>,
    ) -> StoreResult<SwapRow> {
        let source = source.into();
        self.send_write(|respond_to| WriteCommand::UpdatePreimage {
            id,
            preimage,
            source,
            respond_to,
        })
        .await
    }

    async fn send_write(
        &self,
        build: impl FnOnce(oneshot::Sender<StoreResult<SwapRow>>) -> WriteCommand,
    ) -> StoreResult<SwapRow> {
        let (respond_to, response) = oneshot::channel();
        self.writer
            .send(build(respond_to))
            .await
            .map_err(|_| StoreError::WriterClosed)?;
        response.await.map_err(|_| StoreError::WriterClosed)?
    }
}

async fn write_loop(pool: SqlitePool, mut receiver: mpsc::Receiver<WriteCommand>) {
    while let Some(command) = receiver.recv().await {
        match command {
            WriteCommand::CreateLnToArk { record, respond_to } => {
                let _ = respond_to.send(insert_ln_to_ark(&pool, record).await);
            }
            WriteCommand::CreateArkToLn { record, respond_to } => {
                let _ = respond_to.send(insert_ark_to_ln(&pool, record).await);
            }
            WriteCommand::UpdateLnState {
                id,
                status,
                result,
                respond_to,
            } => {
                let _ =
                    respond_to.send(update_state(&pool, &id, &status, "ln_result", &result).await);
            }
            WriteCommand::UpdateArkState {
                id,
                status,
                result,
                respond_to,
            } => {
                let _ =
                    respond_to.send(update_state(&pool, &id, &status, "ark_result", &result).await);
            }
            WriteCommand::UpdateContractState {
                id,
                status,
                result,
                respond_to,
            } => {
                let _ = respond_to.send(update_contract_state(&pool, &id, &status, &result).await);
            }
            WriteCommand::UpdatePreimage {
                id,
                preimage,
                source,
                respond_to,
            } => {
                let _ = respond_to.send(update_preimage(&pool, &id, &preimage, &source).await);
            }
        }
    }
}

async fn insert_ln_to_ark(pool: &SqlitePool, record: NewLnToArkSwap) -> StoreResult<SwapRow> {
    let now = now_unix();
    let ln_result = serde_json::to_string(&record.ln_result)?;
    let ark_contract_result = record
        .ark_contract_result
        .as_ref()
        .map(serde_json::to_string)
        .transpose()?;
    let metadata = record.metadata.map(|value| value.to_string());

    sqlx::query(
        r#"
        INSERT INTO swaps (
            id, kind, status, amount_sat, preimage_hash, preimage_hash_sha256,
            preimage_hash_hash160, preimage, preimage_source, bolt11,
            asset_id, asset_amount, ark_wallet_dir, ark_recipient,
            ark_contract_address, ark_contract_script, ark_tap_tree,
            ark_vtxo_outpoint, ark_claim_pubkey, ark_refund_pubkey,
            ark_refund_time, ln_expiry, ark_contract_result,
            ln_result, metadata, created_at, updated_at
        )
        VALUES (
            ?, 'ln_to_ark', 'ln_hold_invoice_created', ?, ?, ?, ?, ?, ?, ?,
            ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
        )
        "#,
    )
    .bind(&record.id)
    .bind(record.amount_sat)
    .bind(&record.preimage_hash)
    .bind(record.preimage_hash_sha256.as_deref())
    .bind(record.preimage_hash_hash160.as_deref())
    .bind(record.preimage.as_deref())
    .bind(record.preimage_source.as_deref())
    .bind(&record.bolt11)
    .bind(record.asset_id.as_deref())
    .bind(record.asset_amount.as_deref())
    .bind(record.ark_wallet_dir.as_deref())
    .bind(record.ark_recipient.as_deref())
    .bind(record.ark_contract_address.as_deref())
    .bind(record.ark_contract_script.as_deref())
    .bind(record.ark_tap_tree.as_deref())
    .bind(record.ark_vtxo_outpoint.as_deref())
    .bind(record.ark_claim_pubkey.as_deref())
    .bind(record.ark_refund_pubkey.as_deref())
    .bind(record.ark_refund_time)
    .bind(record.ln_expiry)
    .bind(ark_contract_result.as_deref())
    .bind(&ln_result)
    .bind(metadata.as_deref())
    .bind(now)
    .bind(now)
    .execute(pool)
    .await?;

    record_event(
        pool,
        &record.id,
        "ln_hold_invoice_created",
        &record.ln_result,
    )
    .await?;
    load_swap(pool, &record.id).await
}

async fn insert_ark_to_ln(pool: &SqlitePool, record: NewArkToLnSwap) -> StoreResult<SwapRow> {
    let now = now_unix();
    let ln_result = serde_json::to_string(&record.ln_result)?;
    let ark_contract_result = record
        .ark_contract_result
        .as_ref()
        .map(serde_json::to_string)
        .transpose()?;
    let metadata = record.metadata.map(|value| value.to_string());
    let status = if record.ark_contract_address.is_some() {
        "ark_contract_template_created"
    } else {
        "ln_invoice_registered"
    };

    sqlx::query(
        r#"
        INSERT INTO swaps (
            id, kind, status, amount_sat, preimage_hash, preimage_hash_sha256,
            preimage_hash_hash160, preimage_source, bolt11,
            asset_id, asset_amount, ark_wallet_dir,
            ark_contract_address, ark_contract_script, ark_tap_tree,
            ark_vtxo_outpoint, ark_claim_pubkey, ark_refund_pubkey,
            ark_refund_time, ln_expiry, ark_contract_result,
            ln_result, metadata,
            created_at, updated_at
        )
        VALUES (
            ?, 'ark_to_ln', ?, ?, ?, ?, ?, ?, ?,
            ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
        )
        "#,
    )
    .bind(&record.id)
    .bind(status)
    .bind(record.amount_sat)
    .bind(record.preimage_hash.as_deref())
    .bind(record.preimage_hash_sha256.as_deref())
    .bind(record.preimage_hash_hash160.as_deref())
    .bind(record.preimage_source.as_deref())
    .bind(&record.bolt11)
    .bind(record.asset_id.as_deref())
    .bind(record.asset_amount.as_deref())
    .bind(record.ark_wallet_dir.as_deref())
    .bind(record.ark_contract_address.as_deref())
    .bind(record.ark_contract_script.as_deref())
    .bind(record.ark_tap_tree.as_deref())
    .bind(record.ark_vtxo_outpoint.as_deref())
    .bind(record.ark_claim_pubkey.as_deref())
    .bind(record.ark_refund_pubkey.as_deref())
    .bind(record.ark_refund_time)
    .bind(record.ln_expiry)
    .bind(ark_contract_result.as_deref())
    .bind(&ln_result)
    .bind(metadata.as_deref())
    .bind(now)
    .bind(now)
    .execute(pool)
    .await?;

    record_event(pool, &record.id, status, &record.ln_result).await?;
    load_swap(pool, &record.id).await
}

async fn update_state(
    pool: &SqlitePool,
    id: &str,
    status: &str,
    result_column: &str,
    result: &CommandResult,
) -> StoreResult<SwapRow> {
    let result_json = serde_json::to_string(result)?;
    let rows = match result_column {
        "ln_result" => {
            sqlx::query(
                "UPDATE swaps SET status = ?, ln_result = ?, last_error = NULL, updated_at = ? WHERE id = ?",
            )
            .bind(status)
            .bind(&result_json)
            .bind(now_unix())
            .bind(id)
            .execute(pool)
            .await?
            .rows_affected()
        }
        "ark_result" => {
            sqlx::query(
                "UPDATE swaps SET status = ?, ark_result = ?, last_error = NULL, updated_at = ? WHERE id = ?",
            )
            .bind(status)
            .bind(&result_json)
            .bind(now_unix())
            .bind(id)
            .execute(pool)
            .await?
            .rows_affected()
        }
        _ => return Err(StoreError::Internal(anyhow::anyhow!("invalid result column"))),
    };

    if rows == 0 {
        return Err(StoreError::NotFound(id.to_string()));
    }

    record_event(pool, id, status, result).await?;
    load_swap(pool, id).await
}

async fn update_contract_state(
    pool: &SqlitePool,
    id: &str,
    status: &str,
    result: &CommandResult,
) -> StoreResult<SwapRow> {
    let result_json = serde_json::to_string(result)?;
    let stdout = &result.stdout;
    let rows = sqlx::query(
        r#"
        UPDATE swaps
        SET status = ?,
            ark_contract_result = ?,
            ark_contract_address = COALESCE(?, ark_contract_address),
            ark_contract_script = COALESCE(?, ark_contract_script),
            ark_tap_tree = COALESCE(?, ark_tap_tree),
            ark_vtxo_outpoint = COALESCE(?, ark_vtxo_outpoint),
            ark_claim_pubkey = COALESCE(?, ark_claim_pubkey),
            ark_refund_pubkey = COALESCE(?, ark_refund_pubkey),
            ark_refund_time = COALESCE(?, ark_refund_time),
            ark_claim_txid = COALESCE(?, ark_claim_txid),
            ark_refund_txid = COALESCE(?, ark_refund_txid),
            preimage_hash_sha256 = COALESCE(?, preimage_hash_sha256),
            last_error = NULL,
            updated_at = ?
        WHERE id = ?
        "#,
    )
    .bind(status)
    .bind(&result_json)
    .bind(json_str(stdout, "ark_contract_address"))
    .bind(json_str(stdout, "ark_contract_script"))
    .bind(json_str(stdout, "ark_tap_tree"))
    .bind(json_str(stdout, "ark_vtxo_outpoint"))
    .bind(json_str(stdout, "ark_claim_pubkey"))
    .bind(json_str(stdout, "ark_refund_pubkey"))
    .bind(json_i64(stdout, "ark_refund_time"))
    .bind(json_str(stdout, "ark_claim_txid"))
    .bind(json_str(stdout, "ark_refund_txid"))
    .bind(json_str(stdout, "preimage_hash_sha256"))
    .bind(now_unix())
    .bind(id)
    .execute(pool)
    .await?
    .rows_affected();

    if rows == 0 {
        return Err(StoreError::NotFound(id.to_string()));
    }

    record_event(pool, id, status, result).await?;
    load_swap(pool, id).await
}

async fn update_preimage(
    pool: &SqlitePool,
    id: &str,
    preimage: &str,
    source: &str,
) -> StoreResult<SwapRow> {
    let rows = sqlx::query(
        "UPDATE swaps SET preimage = ?, preimage_source = ?, last_error = NULL, updated_at = ? WHERE id = ?",
    )
    .bind(preimage)
    .bind(source)
    .bind(now_unix())
    .bind(id)
    .execute(pool)
    .await?
    .rows_affected();

    if rows == 0 {
        return Err(StoreError::NotFound(id.to_string()));
    }

    record_event(
        pool,
        id,
        "preimage_learned",
        &serde_json::json!({ "stored": true, "source": source }),
    )
    .await?;
    load_swap(pool, id).await
}

async fn load_swap(pool: &SqlitePool, id: &str) -> StoreResult<SwapRow> {
    sqlx::query_as::<_, SwapRow>("SELECT * FROM swaps WHERE id = ?")
        .bind(id)
        .fetch_optional(pool)
        .await?
        .ok_or_else(|| StoreError::NotFound(id.to_string()))
}

async fn record_event<T: Serialize>(
    pool: &SqlitePool,
    swap_id: &str,
    event_type: &str,
    details: &T,
) -> StoreResult<()> {
    sqlx::query(
        "INSERT INTO swap_events (swap_id, event_type, details, created_at) VALUES (?, ?, ?, ?)",
    )
    .bind(swap_id)
    .bind(event_type)
    .bind(serde_json::to_string(details)?)
    .bind(now_unix())
    .execute(pool)
    .await?;
    Ok(())
}

async fn create_parent_dir(path: &Path) -> anyhow::Result<()> {
    if let Some(parent) = path.parent() {
        tokio::fs::create_dir_all(parent)
            .await
            .with_context(|| format!("creating sqlite database directory {}", parent.display()))?;
    }
    Ok(())
}

async fn open_pool(
    settings: &DatabaseSettings,
    max_connections: u32,
) -> anyhow::Result<SqlitePool> {
    let options = SqliteConnectOptions::from_str(&settings.url)?
        .create_if_missing(true)
        .journal_mode(SqliteJournalMode::Wal)
        .synchronous(SqliteSynchronous::Normal)
        .busy_timeout(Duration::from_secs(30));

    SqlitePoolOptions::new()
        .max_connections(max_connections)
        .connect_with(options)
        .await
        .context("opening sqlite database")
}

async fn migrate(pool: &SqlitePool) -> anyhow::Result<()> {
    sqlx::query("PRAGMA journal_mode=WAL").execute(pool).await?;
    sqlx::query("PRAGMA synchronous=NORMAL")
        .execute(pool)
        .await?;
    MIGRATOR
        .run(pool)
        .await
        .context("running sqlite migrations")?;
    Ok(())
}

fn now_unix() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64
}

fn json_str(value: &Value, key: &str) -> Option<String> {
    value
        .get(key)
        .and_then(Value::as_str)
        .filter(|text| !text.is_empty())
        .map(ToOwned::to_owned)
}

fn json_i64(value: &Value, key: &str) -> Option<i64> {
    value
        .get(key)
        .and_then(|inner| inner.as_i64().or_else(|| inner.as_str()?.parse().ok()))
}
