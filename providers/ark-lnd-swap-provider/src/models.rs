use serde::{Deserialize, Serialize};
use serde_json::Value;
use sqlx::FromRow;

#[derive(Serialize)]
pub struct HealthResponse {
    pub ok: bool,
    pub database: bool,
    pub lnd_rpcserver: String,
    pub ark_wallet_dir: String,
}

#[derive(Serialize)]
pub struct ErrorResponse {
    pub error: String,
}

#[derive(Debug, FromRow)]
pub struct SwapRow {
    pub id: String,
    pub kind: String,
    pub status: String,
    pub amount_sat: Option<i64>,
    pub preimage_hash: Option<String>,
    pub preimage: Option<String>,
    pub bolt11: Option<String>,
    pub asset_id: Option<String>,
    pub asset_amount: Option<String>,
    pub ark_wallet_dir: Option<String>,
    pub ark_recipient: Option<String>,
    pub ln_result: Option<String>,
    pub ark_result: Option<String>,
    pub metadata: Option<String>,
    pub last_error: Option<String>,
    pub created_at: i64,
    pub updated_at: i64,
}

#[derive(Debug, Serialize)]
pub struct SwapResponse {
    id: String,
    kind: String,
    status: String,
    amount_sat: Option<i64>,
    preimage_hash: Option<String>,
    preimage: Option<String>,
    bolt11: Option<String>,
    asset_id: Option<String>,
    asset_amount: Option<String>,
    ark_wallet_dir: Option<String>,
    ark_recipient: Option<String>,
    ln_result: Option<Value>,
    ark_result: Option<Value>,
    metadata: Option<Value>,
    last_error: Option<String>,
    created_at: i64,
    updated_at: i64,
}

impl From<SwapRow> for SwapResponse {
    fn from(row: SwapRow) -> Self {
        Self {
            id: row.id,
            kind: row.kind,
            status: row.status,
            amount_sat: row.amount_sat,
            preimage_hash: row.preimage_hash,
            preimage: row.preimage,
            bolt11: row.bolt11,
            asset_id: row.asset_id,
            asset_amount: row.asset_amount,
            ark_wallet_dir: row.ark_wallet_dir,
            ark_recipient: row.ark_recipient,
            ln_result: parse_jsonish(row.ln_result),
            ark_result: parse_jsonish(row.ark_result),
            metadata: parse_jsonish(row.metadata),
            last_error: row.last_error,
            created_at: row.created_at,
            updated_at: row.updated_at,
        }
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct CommandResult {
    pub stdout: Value,
    pub stderr: String,
}

#[derive(Debug, Deserialize)]
pub struct CreateLnToArkRequest {
    pub amount_sat: i64,
    pub memo: Option<String>,
    pub preimage: Option<String>,
    pub preimage_hash: Option<String>,
    pub asset_id: Option<String>,
    pub asset_amount: Option<String>,
    pub ark_recipient: Option<String>,
    pub ark_wallet_dir: Option<String>,
    pub metadata: Option<Value>,
}

#[derive(Debug, Deserialize)]
pub struct CreateArkToLnRequest {
    pub bolt11: String,
    pub amount_sat: Option<i64>,
    pub asset_id: Option<String>,
    pub asset_amount: Option<String>,
    pub ark_wallet_dir: Option<String>,
    pub execute: Option<bool>,
    pub fee_limit_sat: Option<i64>,
    pub metadata: Option<Value>,
}

#[derive(Debug, Deserialize)]
pub struct SettleLnRequest {
    pub preimage: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct PayLnRequest {
    pub fee_limit_sat: Option<i64>,
}

#[derive(Debug, Deserialize)]
pub struct ArkSendRequest {
    pub to: Option<String>,
    pub asset_id: Option<String>,
    pub amount: Option<String>,
    pub wallet_dir: Option<String>,
    pub password: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct ArkReceiveRequest {
    pub wallet_dir: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct ListSwapsQuery {
    pub kind: Option<String>,
    pub status: Option<String>,
    pub limit: Option<i64>,
}

fn parse_jsonish(value: Option<String>) -> Option<Value> {
    value.map(|text| serde_json::from_str(&text).unwrap_or_else(|_| Value::String(text)))
}
