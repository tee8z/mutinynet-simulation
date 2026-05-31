use std::{path::PathBuf, sync::Arc};

use anyhow::anyhow;
use axum::{
    extract::{Path, Query, State},
    routing::{get, post},
    Json, Router,
};
use serde_json::Value;
use uuid::Uuid;

use crate::{
    app_state::AppState,
    error::ApiError,
    models::{
        ArkReceiveRequest, ArkSendRequest, CommandResult, CreateArkToLnRequest,
        CreateLnToArkRequest, HealthResponse, ListSwapsQuery, PayLnRequest, SettleLnRequest,
        SwapResponse, SwapRow,
    },
    preimage::{preimage_and_hash, validate_hex32},
    store::{NewArkToLnSwap, NewLnToArkSwap},
};

pub fn router() -> Router<Arc<AppState>> {
    Router::new()
        .route("/health", get(health))
        .route("/v1/ark/receive", post(ark_receive))
        .route("/v1/swaps", get(list_swaps))
        .route("/v1/swaps/ln-to-ark", post(create_ln_to_ark))
        .route("/v1/swaps/ark-to-ln", post(create_ark_to_ln))
        .route("/v1/swaps/{id}", get(get_swap))
        .route("/v1/swaps/{id}/settle-ln", post(settle_ln))
        .route("/v1/swaps/{id}/cancel-ln", post(cancel_ln))
        .route("/v1/swaps/{id}/pay-ln", post(pay_ln))
        .route("/v1/swaps/{id}/ark-send", post(ark_send))
}

async fn health(State(state): State<Arc<AppState>>) -> Result<Json<HealthResponse>, ApiError> {
    let database = state.store.health_check().await;
    Ok(Json(HealthResponse {
        ok: database,
        database,
        lnd_rpcserver: state.lnd.rpcserver().to_string(),
        ark_wallet_dir: state.ark.default_wallet_dir().display().to_string(),
    }))
}

async fn list_swaps(
    State(state): State<Arc<AppState>>,
    Query(query): Query<ListSwapsQuery>,
) -> Result<Json<Vec<SwapResponse>>, ApiError> {
    let rows = state.store.list_swaps(&query).await?;
    Ok(Json(rows.into_iter().map(SwapResponse::from).collect()))
}

async fn get_swap(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
) -> Result<Json<SwapResponse>, ApiError> {
    Ok(Json(state.store.load_swap(&id).await?.into()))
}

async fn create_ln_to_ark(
    State(state): State<Arc<AppState>>,
    Json(request): Json<CreateLnToArkRequest>,
) -> Result<Json<SwapResponse>, ApiError> {
    if request.amount_sat <= 0 {
        return Err(ApiError::bad_request(
            "amount_sat must be greater than zero",
        ));
    }

    let (preimage, preimage_hash) = preimage_and_hash(
        request.preimage.as_deref(),
        request.preimage_hash.as_deref(),
    )?;
    let memo = request
        .memo
        .unwrap_or_else(|| "ark-lnd ln-to-ark swap".to_string());
    let ln_result = state
        .lnd
        .add_hold_invoice(&preimage_hash, request.amount_sat, &memo)
        .await?;
    let bolt11 = payment_request(&ln_result)?;
    let id = Uuid::new_v4().to_string();

    let row = state
        .store
        .create_ln_to_ark(NewLnToArkSwap {
            id,
            amount_sat: request.amount_sat,
            preimage_hash,
            preimage,
            bolt11,
            asset_id: request.asset_id,
            asset_amount: request.asset_amount,
            ark_wallet_dir: request.ark_wallet_dir,
            ark_recipient: request.ark_recipient,
            ln_result,
            metadata: request.metadata,
        })
        .await?;

    Ok(Json(row.into()))
}

async fn create_ark_to_ln(
    State(state): State<Arc<AppState>>,
    Json(request): Json<CreateArkToLnRequest>,
) -> Result<Json<SwapResponse>, ApiError> {
    if request.bolt11.trim().is_empty() {
        return Err(ApiError::bad_request("bolt11 is required"));
    }
    if request.amount_sat.unwrap_or(1) <= 0 {
        return Err(ApiError::bad_request(
            "amount_sat must be greater than zero when set",
        ));
    }

    let decode = state.lnd.decode_payreq(&request.bolt11).await?;
    let payment_hash = decode
        .stdout
        .get("payment_hash")
        .and_then(Value::as_str)
        .map(ToOwned::to_owned);
    let id = Uuid::new_v4().to_string();

    let mut row = state
        .store
        .create_ark_to_ln(NewArkToLnSwap {
            id: id.clone(),
            amount_sat: request.amount_sat,
            preimage_hash: payment_hash,
            bolt11: request.bolt11,
            asset_id: request.asset_id,
            asset_amount: request.asset_amount,
            ark_wallet_dir: request.ark_wallet_dir,
            ln_result: decode,
            metadata: request.metadata,
        })
        .await?;

    if request.execute.unwrap_or(false) {
        row = pay_ln_by_id(&state, &id, request.fee_limit_sat).await?;
    }

    Ok(Json(row.into()))
}

async fn settle_ln(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    Json(request): Json<SettleLnRequest>,
) -> Result<Json<SwapResponse>, ApiError> {
    let row = state.store.load_swap(&id).await?;
    let preimage = request
        .preimage
        .or(row.preimage)
        .ok_or_else(|| ApiError::bad_request("preimage is required for this swap"))?;
    validate_hex32("preimage", &preimage)?;

    let result = state.lnd.settle_invoice(&preimage).await?;
    let row = state
        .store
        .update_ln_state(id, "ln_settled", result)
        .await?;
    Ok(Json(row.into()))
}

async fn cancel_ln(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
) -> Result<Json<SwapResponse>, ApiError> {
    let row = state.store.load_swap(&id).await?;
    let preimage_hash = row
        .preimage_hash
        .ok_or_else(|| ApiError::bad_request("swap does not have a preimage_hash"))?;
    validate_hex32("preimage_hash", &preimage_hash)?;

    let result = state.lnd.cancel_invoice(&preimage_hash).await?;
    let row = state
        .store
        .update_ln_state(id, "ln_canceled", result)
        .await?;
    Ok(Json(row.into()))
}

async fn pay_ln(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    Json(request): Json<PayLnRequest>,
) -> Result<Json<SwapResponse>, ApiError> {
    let row = pay_ln_by_id(&state, &id, request.fee_limit_sat).await?;
    Ok(Json(row.into()))
}

async fn ark_send(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    Json(request): Json<ArkSendRequest>,
) -> Result<Json<SwapResponse>, ApiError> {
    let row = state.store.load_swap(&id).await?;
    let to = request
        .to
        .or(row.ark_recipient)
        .ok_or_else(|| ApiError::bad_request("ark recipient address is required"))?;
    let asset_id = request
        .asset_id
        .or(row.asset_id)
        .ok_or_else(|| ApiError::bad_request("asset_id is required"))?;
    let amount = request
        .amount
        .or(row.asset_amount)
        .ok_or_else(|| ApiError::bad_request("asset amount is required"))?;
    let wallet_dir = request
        .wallet_dir
        .or(row.ark_wallet_dir)
        .map(PathBuf::from)
        .unwrap_or_else(|| state.ark.default_wallet_dir().to_path_buf());
    let password = request.password.or_else(|| state.ark.default_password());

    let result = state
        .ark
        .send_asset(wallet_dir, to, asset_id, amount, password)
        .await?;
    let row = state.store.update_ark_state(id, "ark_sent", result).await?;
    Ok(Json(row.into()))
}

async fn ark_receive(
    State(state): State<Arc<AppState>>,
    Json(request): Json<ArkReceiveRequest>,
) -> Result<Json<CommandResult>, ApiError> {
    let wallet_dir = request.wallet_dir.map(PathBuf::from);
    Ok(Json(state.ark.receive(wallet_dir).await?))
}

async fn pay_ln_by_id(
    state: &AppState,
    id: &str,
    fee_limit_sat: Option<i64>,
) -> Result<SwapRow, ApiError> {
    if let Some(fee_limit_sat) = fee_limit_sat {
        if fee_limit_sat < 0 {
            return Err(ApiError::bad_request("fee_limit_sat cannot be negative"));
        }
    }

    let row = state.store.load_swap(id).await?;
    let bolt11 = row
        .bolt11
        .ok_or_else(|| ApiError::bad_request("swap does not have a bolt11 invoice"))?;
    let result = state.lnd.pay_invoice(&bolt11, fee_limit_sat).await?;
    Ok(state
        .store
        .update_ln_state(id.to_string(), "ln_paid", result)
        .await?)
}

fn payment_request(result: &CommandResult) -> Result<String, ApiError> {
    result
        .stdout
        .get("payment_request")
        .and_then(Value::as_str)
        .map(ToOwned::to_owned)
        .ok_or_else(|| {
            ApiError::internal(anyhow!(
                "lncli addholdinvoice did not return payment_request: {}",
                result.stdout
            ))
        })
}
