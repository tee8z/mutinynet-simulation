use std::{
    path::PathBuf,
    sync::Arc,
    time::{SystemTime, UNIX_EPOCH},
};

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
        ArkContractActionRequest, ArkContractPubkeyRequest, ArkReceiveRequest, ArkSendRequest,
        CommandResult, CreateArkToLnRequest, CreateLnToArkRequest, HealthResponse, ListSwapsQuery,
        PayLnRequest, SettleLnRequest, SwapResponse, SwapRow,
    },
    preimage::{preimage_and_hash, sha256_hex_from_hex32, validate_hex32},
    store::{NewArkToLnSwap, NewLnToArkSwap},
};

pub fn router() -> Router<Arc<AppState>> {
    Router::new()
        .route("/health", get(health))
        .route("/v1/ark/receive", post(ark_receive))
        .route("/v1/ark/contract/pubkey", post(ark_contract_pubkey))
        .route("/v1/swaps", get(list_swaps))
        .route("/v1/swaps/ln-to-ark", post(create_ln_to_ark))
        .route("/v1/swaps/ark-to-ln", post(create_ark_to_ln))
        .route("/v1/swaps/{id}", get(get_swap))
        .route("/v1/swaps/{id}/settle-ln", post(settle_ln))
        .route("/v1/swaps/{id}/cancel-ln", post(cancel_ln))
        .route("/v1/swaps/{id}/pay-ln", post(pay_ln))
        .route("/v1/swaps/{id}/ark-send", post(ark_send))
        .route(
            "/v1/swaps/{id}/ark-contract/template",
            post(ark_contract_template),
        )
        .route("/v1/swaps/{id}/ark-contract/fund", post(ark_contract_fund))
        .route(
            "/v1/swaps/{id}/ark-contract/verify-funded",
            post(ark_contract_verify_funded),
        )
        .route(
            "/v1/swaps/{id}/ark-contract/claim",
            post(ark_contract_claim),
        )
        .route(
            "/v1/swaps/{id}/ark-contract/refund",
            post(ark_contract_refund),
        )
        .route(
            "/v1/swaps/{id}/ark-contract/observe-claim",
            post(ark_contract_observe_claim),
        )
}

async fn health(State(state): State<Arc<AppState>>) -> Result<Json<HealthResponse>, ApiError> {
    let database = state.store.health_check().await;
    Ok(Json(HealthResponse {
        ok: database,
        database,
        lnd_rpcserver: state.lnd.rpcserver().to_string(),
        ark_server_url: state.ark.ark_server_url().to_string(),
        ark_wallet_key_configured: state.ark.default_private_key_hex().is_some(),
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
    let trustless = request.trustless.unwrap_or(false);
    if trustless {
        if request.preimage.is_some() {
            return Err(ApiError::bad_request(
                "trustless ln-to-ark must not supply a preimage to the provider",
            ));
        }
        if request.preimage_hash.is_none() {
            return Err(ApiError::bad_request(
                "trustless ln-to-ark requires caller-supplied preimage_hash",
            ));
        }
        if request.ark_claim_pubkey.is_none() {
            return Err(ApiError::bad_request(
                "trustless ln-to-ark requires ark_claim_pubkey",
            ));
        }
        if request.ark_refund_time.is_none() || request.ln_expiry.is_none() {
            return Err(ApiError::bad_request(
                "trustless ln-to-ark requires ark_refund_time and ln_expiry",
            ));
        }
        let now = now_unix();
        let ark_refund_time = request.ark_refund_time.unwrap_or_default();
        let ln_expiry = request.ln_expiry.unwrap_or_default();
        if !(now < ark_refund_time && ark_refund_time < ln_expiry) {
            return Err(ApiError::bad_request(
                "trustless ln-to-ark timeout ordering must be now < ark_refund_time < ln_expiry",
            ));
        }
    }

    let (preimage, preimage_hash) = preimage_and_hash(
        request.preimage.as_deref(),
        request.preimage_hash.as_deref(),
    )?;
    let memo = request
        .memo
        .unwrap_or_else(|| "ark-lnd ln-to-ark swap".to_string());
    let invoice_expiry_sec = request
        .ln_expiry
        .map(|expiry| expiry.saturating_sub(now_unix()).max(1));
    let ln_result = state
        .lnd
        .add_hold_invoice(
            &preimage_hash,
            request.amount_sat,
            &memo,
            invoice_expiry_sec,
        )
        .await?;
    let bolt11 = payment_request(&ln_result)?;
    let id = Uuid::new_v4().to_string();
    let ark_refund_pubkey = if trustless {
        Some(match request.ark_refund_pubkey.clone() {
            Some(value) => value,
            None => provider_contract_pubkey(&state).await?,
        })
    } else {
        request.ark_refund_pubkey.clone()
    };
    let template_request = ArkContractActionRequest {
        preimage_hash_sha256: Some(preimage_hash.clone()),
        preimage: None,
        asset_id: request.asset_id.clone(),
        asset_amount: request.asset_amount.clone(),
        ark_claim_pubkey: request.ark_claim_pubkey.clone(),
        ark_refund_pubkey: ark_refund_pubkey.clone(),
        ark_refund_time: request.ark_refund_time,
        ark_vtxo_outpoint: None,
        ark_claim_txid: None,
        destination_address: None,
        wallet_dir: request.ark_wallet_dir.clone(),
        wallet_password: None,
        wallet_private_key_hex: None,
        vtxo_sats: request.vtxo_sats,
        settle_ln: None,
    };

    let mut row = state
        .store
        .create_ln_to_ark(NewLnToArkSwap {
            id,
            amount_sat: request.amount_sat,
            preimage_hash: preimage_hash.clone(),
            preimage_hash_sha256: Some(preimage_hash),
            preimage_hash_hash160: None,
            preimage,
            preimage_source: None,
            bolt11,
            asset_id: request.asset_id,
            asset_amount: request.asset_amount,
            ark_wallet_dir: request.ark_wallet_dir,
            ark_recipient: request.ark_recipient,
            ark_contract_address: None,
            ark_contract_script: None,
            ark_tap_tree: None,
            ark_vtxo_outpoint: None,
            ark_claim_pubkey: request.ark_claim_pubkey,
            ark_refund_pubkey,
            ark_refund_time: request.ark_refund_time,
            ln_expiry: request.ln_expiry,
            ark_contract_result: None,
            ln_result,
            metadata: request.metadata,
        })
        .await?;
    if trustless {
        let result = state.ark_contract.template(&row, &template_request).await?;
        row = state
            .store
            .update_contract_state(row.id.clone(), "ark_contract_template_created", result)
            .await?;
    }

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
    let trustless = request.trustless.unwrap_or(false);
    if trustless {
        if request.ark_refund_pubkey.is_none() {
            return Err(ApiError::bad_request(
                "trustless ark-to-ln requires payer ark_refund_pubkey",
            ));
        }
        if request.ark_refund_time.is_none() || request.ln_expiry.is_none() {
            return Err(ApiError::bad_request(
                "trustless ark-to-ln requires ark_refund_time and ln_expiry",
            ));
        }
        let now = now_unix();
        let ark_refund_time = request.ark_refund_time.unwrap_or_default();
        let ln_expiry = request.ln_expiry.unwrap_or_default();
        if !(now < ln_expiry && ln_expiry < ark_refund_time) {
            return Err(ApiError::bad_request(
                "trustless ark-to-ln timeout ordering must be now < ln_expiry < ark_refund_time",
            ));
        }
    }

    let decode = state.lnd.decode_payreq(&request.bolt11).await?;
    if trustless {
        if let (Some(requested), Some(decoded)) =
            (request.ln_expiry, decoded_invoice_expiry(&decode))
        {
            if (requested - decoded).abs() > 5 {
                return Err(ApiError::bad_request(
                    "trustless ark-to-ln ln_expiry must match the decoded invoice expiry",
                ));
            }
        }
    }
    let payment_hash = decode
        .stdout
        .get("payment_hash")
        .and_then(Value::as_str)
        .map(ToOwned::to_owned);
    let id = Uuid::new_v4().to_string();
    let ark_claim_pubkey = if trustless {
        Some(match request.ark_claim_pubkey.clone() {
            Some(value) => value,
            None => provider_contract_pubkey(&state).await?,
        })
    } else {
        request.ark_claim_pubkey.clone()
    };
    let template_request = ArkContractActionRequest {
        preimage_hash_sha256: payment_hash.clone(),
        preimage: None,
        asset_id: request.asset_id.clone(),
        asset_amount: request.asset_amount.clone(),
        ark_claim_pubkey: ark_claim_pubkey.clone(),
        ark_refund_pubkey: request.ark_refund_pubkey.clone(),
        ark_refund_time: request.ark_refund_time,
        ark_vtxo_outpoint: None,
        ark_claim_txid: None,
        destination_address: None,
        wallet_dir: request.ark_wallet_dir.clone(),
        wallet_password: None,
        wallet_private_key_hex: None,
        vtxo_sats: request.vtxo_sats,
        settle_ln: None,
    };

    let mut row = state
        .store
        .create_ark_to_ln(NewArkToLnSwap {
            id: id.clone(),
            amount_sat: request.amount_sat,
            preimage_hash: payment_hash.clone(),
            preimage_hash_sha256: payment_hash,
            preimage_hash_hash160: None,
            preimage_source: None,
            bolt11: request.bolt11,
            asset_id: request.asset_id,
            asset_amount: request.asset_amount,
            ark_wallet_dir: request.ark_wallet_dir,
            ark_contract_address: None,
            ark_contract_script: None,
            ark_tap_tree: None,
            ark_vtxo_outpoint: None,
            ark_claim_pubkey,
            ark_refund_pubkey: request.ark_refund_pubkey,
            ark_refund_time: request.ark_refund_time,
            ln_expiry: request.ln_expiry,
            ark_contract_result: None,
            ln_result: decode,
            metadata: request.metadata,
        })
        .await?;
    if trustless {
        let result = state.ark_contract.template(&row, &template_request).await?;
        row = state
            .store
            .update_contract_state(id.clone(), "ark_contract_template_created", result)
            .await?;
    }

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
    if is_contract_swap(&row) && row.kind == "ln_to_ark" && request.preimage.is_some() {
        return Err(ApiError::bad_request(
            "trustless ln-to-ark settlement must use the observed Ark claim preimage",
        ));
    }
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
    let password = request.password;

    let result = state
        .ark
        .send_asset(
            wallet_dir,
            to,
            asset_id,
            amount,
            password,
            request.wallet_private_key_hex,
        )
        .await?;
    let row = state.store.update_ark_state(id, "ark_sent", result).await?;
    Ok(Json(row.into()))
}

async fn ark_receive(
    State(state): State<Arc<AppState>>,
    Json(request): Json<ArkReceiveRequest>,
) -> Result<Json<CommandResult>, ApiError> {
    let wallet_dir = request.wallet_dir.map(PathBuf::from);
    Ok(Json(
        state
            .ark
            .receive(wallet_dir, request.wallet_private_key_hex)
            .await?,
    ))
}

async fn ark_contract_pubkey(
    State(state): State<Arc<AppState>>,
    Json(request): Json<ArkContractPubkeyRequest>,
) -> Result<Json<CommandResult>, ApiError> {
    let wallet_dir = request
        .wallet_dir
        .map(PathBuf::from)
        .unwrap_or_else(|| state.ark.default_wallet_dir().to_path_buf());
    Ok(Json(
        state
            .ark_contract
            .wallet_pubkey(wallet_dir, None, request.wallet_private_key_hex)
            .await?,
    ))
}

async fn ark_contract_template(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    Json(request): Json<ArkContractActionRequest>,
) -> Result<Json<SwapResponse>, ApiError> {
    let row = state.store.load_swap(&id).await?;
    let result = state.ark_contract.template(&row, &request).await?;
    let row = state
        .store
        .update_contract_state(id, "ark_contract_template_created", result)
        .await?;
    Ok(Json(row.into()))
}

async fn ark_contract_fund(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    Json(request): Json<ArkContractActionRequest>,
) -> Result<Json<SwapResponse>, ApiError> {
    let row = state.store.load_swap(&id).await?;
    let wallet_dir = request
        .wallet_dir
        .as_ref()
        .map(PathBuf::from)
        .or_else(|| row.ark_wallet_dir.as_ref().map(PathBuf::from))
        .unwrap_or_else(|| state.ark.default_wallet_dir().to_path_buf());
    let password = request.wallet_password.clone();
    let result = state
        .ark_contract
        .fund(&row, &request, wallet_dir, password)
        .await?;
    let row = state
        .store
        .update_contract_state(id, "ark_contract_funded", result)
        .await?;
    Ok(Json(row.into()))
}

async fn ark_contract_verify_funded(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    Json(request): Json<ArkContractActionRequest>,
) -> Result<Json<SwapResponse>, ApiError> {
    let row = state.store.load_swap(&id).await?;
    let result = state.ark_contract.verify_funded(&row, &request).await?;
    let funded = result
        .stdout
        .get("contract_funded")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let status = if funded {
        "ark_contract_funded"
    } else {
        "ark_contract_template_created"
    };
    let row = state
        .store
        .update_contract_state(id, status, result)
        .await?;
    Ok(Json(row.into()))
}

async fn ark_contract_claim(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    Json(request): Json<ArkContractActionRequest>,
) -> Result<Json<SwapResponse>, ApiError> {
    let row = state.store.load_swap(&id).await?;
    let preimage = request
        .preimage
        .clone()
        .or(row.preimage.clone())
        .ok_or_else(|| ApiError::bad_request("preimage is required for contract claim"))?;
    verify_preimage_matches_swap(&row, &preimage)?;
    let wallet_dir = request
        .wallet_dir
        .as_ref()
        .map(PathBuf::from)
        .or_else(|| row.ark_wallet_dir.as_ref().map(PathBuf::from))
        .unwrap_or_else(|| state.ark.default_wallet_dir().to_path_buf());
    let password = request.wallet_password.clone();
    let result = state
        .ark_contract
        .claim(&row, &request, wallet_dir, password)
        .await?;
    let row = state
        .store
        .update_contract_state(id.clone(), "ark_contract_claimed", result)
        .await?;
    let row = state
        .store
        .update_preimage(id, preimage, "ark_claim_witness")
        .await
        .unwrap_or(row);
    Ok(Json(row.into()))
}

async fn ark_contract_refund(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    Json(request): Json<ArkContractActionRequest>,
) -> Result<Json<SwapResponse>, ApiError> {
    let row = state.store.load_swap(&id).await?;
    let wallet_dir = request
        .wallet_dir
        .as_ref()
        .map(PathBuf::from)
        .or_else(|| row.ark_wallet_dir.as_ref().map(PathBuf::from))
        .unwrap_or_else(|| state.ark.default_wallet_dir().to_path_buf());
    let password = request.wallet_password.clone();
    let result = state
        .ark_contract
        .refund(&row, &request, wallet_dir, password)
        .await?;
    let row = state
        .store
        .update_contract_state(id, "ark_contract_refunded", result)
        .await?;
    Ok(Json(row.into()))
}

async fn ark_contract_observe_claim(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    Json(request): Json<ArkContractActionRequest>,
) -> Result<Json<SwapResponse>, ApiError> {
    let row = state.store.load_swap(&id).await?;
    let preimage = request
        .preimage
        .clone()
        .ok_or_else(|| ApiError::bad_request("preimage is required"))?;
    verify_preimage_matches_swap(&row, &preimage)?;

    let result = CommandResult {
        stdout: serde_json::json!({
            "status": "ok",
            "path": "claim",
            "ark_claim_txid": request.ark_claim_txid,
            "decoded_witness_preimage": preimage,
            "preimage_hash_sha256": row.preimage_hash_sha256.or(row.preimage_hash),
        }),
        stderr: String::new(),
    };
    let row = state
        .store
        .update_contract_state(id.clone(), "ark_contract_claimed", result)
        .await?;
    let row = state
        .store
        .update_preimage(id.clone(), preimage.clone(), "ark_claim_witness")
        .await
        .unwrap_or(row);

    if row.kind == "ln_to_ark" && request.settle_ln.unwrap_or(true) {
        let result = state.lnd.settle_invoice(&preimage).await?;
        let row = state
            .store
            .update_ln_state(id, "ln_settled", result)
            .await?;
        return Ok(Json(row.into()));
    }

    Ok(Json(row.into()))
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
    if row.kind == "ark_to_ln" && is_contract_swap(&row) && row.ark_vtxo_outpoint.is_none() {
        return Err(ApiError::bad_request(
            "Ark VHTLC must be verified as funded before paying the Lightning invoice",
        ));
    }
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
                "LND AddHoldInvoice did not return payment_request: {}",
                result.stdout
            ))
        })
}

async fn provider_contract_pubkey(state: &AppState) -> Result<String, ApiError> {
    let result = state
        .ark_contract
        .wallet_pubkey(
            state.ark.default_wallet_dir().to_path_buf(),
            None,
            state.ark.default_private_key_hex(),
        )
        .await?;
    result
        .stdout
        .get("ark_claim_pubkey")
        .or_else(|| result.stdout.get("ark_refund_pubkey"))
        .and_then(Value::as_str)
        .map(ToOwned::to_owned)
        .ok_or_else(|| {
            ApiError::internal(anyhow!(
                "Ark contract adapter did not return a wallet pubkey: {}",
                result.stdout
            ))
        })
}

fn verify_preimage_matches_swap(row: &SwapRow, preimage: &str) -> Result<(), ApiError> {
    validate_hex32("preimage", preimage)?;
    let expected = row
        .preimage_hash_sha256
        .as_ref()
        .or(row.preimage_hash.as_ref())
        .ok_or_else(|| ApiError::bad_request("swap does not have a preimage hash"))?;
    let actual = sha256_hex_from_hex32("preimage", preimage)?;
    if &actual != expected {
        return Err(ApiError::bad_request(
            "preimage does not match swap payment hash",
        ));
    }
    Ok(())
}

fn is_contract_swap(row: &SwapRow) -> bool {
    row.ark_contract_address.is_some() || row.ark_contract_script.is_some()
}

fn now_unix() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64
}

fn decoded_invoice_expiry(result: &CommandResult) -> Option<i64> {
    let timestamp = json_i64(result.stdout.get("timestamp")?)?;
    let expiry = json_i64(result.stdout.get("expiry")?)?;
    Some(timestamp + expiry)
}

fn json_i64(value: &Value) -> Option<i64> {
    value
        .as_i64()
        .or_else(|| value.as_str().and_then(|text| text.parse::<i64>().ok()))
}
