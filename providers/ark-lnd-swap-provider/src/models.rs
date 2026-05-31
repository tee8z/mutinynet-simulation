use serde::{Deserialize, Serialize};
use serde_json::Value;
use sqlx::FromRow;

#[derive(Serialize)]
pub struct HealthResponse {
    pub ok: bool,
    pub database: bool,
    pub lnd_rpcserver: String,
    pub ark_server_url: String,
    pub ark_wallet_key_configured: bool,
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
    pub preimage_hash_sha256: Option<String>,
    pub preimage_hash_hash160: Option<String>,
    pub preimage: Option<String>,
    pub preimage_source: Option<String>,
    pub bolt11: Option<String>,
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
    pub ark_claim_txid: Option<String>,
    pub ark_refund_txid: Option<String>,
    pub ark_contract_result: Option<String>,
    pub proof: Option<String>,
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
    preimage_hash_sha256: Option<String>,
    preimage_hash_hash160: Option<String>,
    preimage: Option<String>,
    preimage_source: Option<String>,
    bolt11: Option<String>,
    asset_id: Option<String>,
    asset_amount: Option<String>,
    ark_wallet_dir: Option<String>,
    ark_recipient: Option<String>,
    ark_contract_address: Option<String>,
    ark_contract_script: Option<String>,
    ark_tap_tree: Option<String>,
    ark_vtxo_outpoint: Option<String>,
    ark_claim_pubkey: Option<String>,
    ark_refund_pubkey: Option<String>,
    ark_refund_time: Option<i64>,
    ln_expiry: Option<i64>,
    ark_claim_txid: Option<String>,
    ark_refund_txid: Option<String>,
    ark_contract_result: Option<Value>,
    proof: Option<Value>,
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
            preimage_hash_sha256: row.preimage_hash_sha256,
            preimage_hash_hash160: row.preimage_hash_hash160,
            preimage: row.preimage,
            preimage_source: row.preimage_source,
            bolt11: row.bolt11,
            asset_id: row.asset_id,
            asset_amount: row.asset_amount,
            ark_wallet_dir: row.ark_wallet_dir,
            ark_recipient: row.ark_recipient,
            ark_contract_address: row.ark_contract_address,
            ark_contract_script: row.ark_contract_script,
            ark_tap_tree: row.ark_tap_tree,
            ark_vtxo_outpoint: row.ark_vtxo_outpoint,
            ark_claim_pubkey: row.ark_claim_pubkey,
            ark_refund_pubkey: row.ark_refund_pubkey,
            ark_refund_time: row.ark_refund_time,
            ln_expiry: row.ln_expiry,
            ark_claim_txid: row.ark_claim_txid,
            ark_refund_txid: row.ark_refund_txid,
            ark_contract_result: parse_jsonish(row.ark_contract_result),
            proof: parse_jsonish(row.proof),
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
    pub trustless: Option<bool>,
    pub asset_id: Option<String>,
    pub asset_amount: Option<String>,
    pub ark_recipient: Option<String>,
    pub ark_wallet_dir: Option<String>,
    pub ark_claim_pubkey: Option<String>,
    pub ark_refund_pubkey: Option<String>,
    pub ark_refund_time: Option<i64>,
    pub ln_expiry: Option<i64>,
    pub vtxo_sats: Option<i64>,
    pub metadata: Option<Value>,
}

#[derive(Debug, Deserialize)]
pub struct CreateArkToLnRequest {
    pub bolt11: String,
    pub amount_sat: Option<i64>,
    pub asset_id: Option<String>,
    pub asset_amount: Option<String>,
    pub ark_wallet_dir: Option<String>,
    pub trustless: Option<bool>,
    pub ark_claim_pubkey: Option<String>,
    pub ark_refund_pubkey: Option<String>,
    pub ark_refund_time: Option<i64>,
    pub ln_expiry: Option<i64>,
    pub vtxo_sats: Option<i64>,
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
    pub wallet_private_key_hex: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct ArkReceiveRequest {
    pub wallet_dir: Option<String>,
    pub wallet_private_key_hex: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct ArkContractPubkeyRequest {
    pub wallet_dir: Option<String>,
    pub wallet_password: Option<String>,
    pub wallet_private_key_hex: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct ArkContractActionRequest {
    pub preimage_hash_sha256: Option<String>,
    pub preimage: Option<String>,
    pub asset_id: Option<String>,
    pub asset_amount: Option<String>,
    pub ark_claim_pubkey: Option<String>,
    pub ark_refund_pubkey: Option<String>,
    pub ark_refund_time: Option<i64>,
    pub ark_vtxo_outpoint: Option<String>,
    pub ark_claim_txid: Option<String>,
    pub destination_address: Option<String>,
    pub wallet_dir: Option<String>,
    pub wallet_password: Option<String>,
    pub wallet_private_key_hex: Option<String>,
    pub vtxo_sats: Option<i64>,
    pub settle_ln: Option<bool>,
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
