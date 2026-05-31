use anyhow::{anyhow, Context};
use serde_json::json;
use tokio::time::timeout;
use voltage_tonic_lnd::{invoicesrpc, lnrpc, routerrpc, Client};

use crate::{config::LndSettings, models::CommandResult};

#[derive(Clone)]
pub struct LndClient {
    settings: LndSettings,
}

impl LndClient {
    pub fn new(settings: LndSettings) -> Self {
        Self { settings }
    }

    pub fn rpcserver(&self) -> &str {
        &self.settings.rpcserver
    }

    pub async fn add_hold_invoice(
        &self,
        preimage_hash: &str,
        amount_sat: i64,
        memo: &str,
        expiry_sec: Option<i64>,
    ) -> anyhow::Result<CommandResult> {
        let hash = decode_hex32("preimage_hash", preimage_hash)?;
        let mut client = self.connect().await?;
        let response = self
            .call(
                client
                    .invoices()
                    .add_hold_invoice(invoicesrpc::AddHoldInvoiceRequest {
                        memo: memo.to_string(),
                        hash,
                        value: amount_sat,
                        expiry: expiry_sec.unwrap_or_default(),
                        ..Default::default()
                    }),
            )
            .await?
            .into_inner();

        Ok(CommandResult {
            stdout: json!({
                "payment_request": response.payment_request,
                "add_index": response.add_index.to_string(),
                "payment_addr": hex::encode(response.payment_addr),
            }),
            stderr: String::new(),
        })
    }

    pub async fn decode_payreq(&self, bolt11: &str) -> anyhow::Result<CommandResult> {
        let mut client = self.connect().await?;
        let decoded = self
            .call(client.lightning().decode_pay_req(lnrpc::PayReqString {
                pay_req: bolt11.to_string(),
            }))
            .await?
            .into_inner();

        Ok(CommandResult {
            stdout: json!({
                "destination": decoded.destination,
                "payment_hash": decoded.payment_hash,
                "num_satoshis": decoded.num_satoshis,
                "timestamp": decoded.timestamp,
                "expiry": decoded.expiry,
                "description": decoded.description,
                "description_hash": decoded.description_hash,
                "fallback_addr": decoded.fallback_addr,
                "cltv_expiry": decoded.cltv_expiry,
                "num_msat": decoded.num_msat,
                "payment_addr": hex::encode(decoded.payment_addr),
            }),
            stderr: String::new(),
        })
    }

    pub async fn lookup_invoice(&self, payment_hash: &str) -> anyhow::Result<CommandResult> {
        let hash = decode_hex32("payment_hash", payment_hash)?;
        let mut client = self.connect().await?;
        let invoice = self
            .call(client.lightning().lookup_invoice(lnrpc::PaymentHash {
                r_hash_str: String::new(),
                r_hash: hash,
            }))
            .await?
            .into_inner();

        Ok(CommandResult {
            stdout: json!({
                "memo": invoice.memo,
                "payment_request": invoice.payment_request,
                "r_hash": hex::encode(invoice.r_hash),
                "value": invoice.value,
                "settled": invoice.settled,
                "creation_date": invoice.creation_date,
                "settle_date": invoice.settle_date,
                "state": invoice_state_label(invoice.state),
                "state_code": invoice.state,
                "amt_paid_sat": invoice.amt_paid_sat,
                "amt_paid_msat": invoice.amt_paid_msat,
            }),
            stderr: String::new(),
        })
    }

    pub async fn settle_invoice(&self, preimage: &str) -> anyhow::Result<CommandResult> {
        let preimage = decode_hex32("preimage", preimage)?;
        let mut client = self.connect().await?;
        self.call(
            client
                .invoices()
                .settle_invoice(invoicesrpc::SettleInvoiceMsg { preimage }),
        )
        .await?;

        Ok(CommandResult {
            stdout: json!({ "status": "ok", "action": "settle_invoice" }),
            stderr: String::new(),
        })
    }

    pub async fn cancel_invoice(&self, payment_hash: &str) -> anyhow::Result<CommandResult> {
        let payment_hash = decode_hex32("payment_hash", payment_hash)?;
        let mut client = self.connect().await?;
        self.call(
            client
                .invoices()
                .cancel_invoice(invoicesrpc::CancelInvoiceMsg { payment_hash }),
        )
        .await?;

        Ok(CommandResult {
            stdout: json!({ "status": "ok", "action": "cancel_invoice" }),
            stderr: String::new(),
        })
    }

    pub async fn pay_invoice(
        &self,
        bolt11: &str,
        fee_limit_sat: Option<i64>,
    ) -> anyhow::Result<CommandResult> {
        let mut client = self.connect().await?;
        let response = self
            .call(
                client
                    .router()
                    .send_payment_v2(routerrpc::SendPaymentRequest {
                        payment_request: bolt11.to_string(),
                        fee_limit_sat: fee_limit_sat.unwrap_or(i64::MAX),
                        timeout_seconds: self
                            .settings
                            .command_timeout
                            .as_secs()
                            .min(i32::MAX as u64) as i32,
                        no_inflight_updates: true,
                        ..Default::default()
                    }),
            )
            .await?;
        let mut stream = response.into_inner();

        while let Some(payment) = self.call(stream.message()).await? {
            match payment.status {
                2 => {
                    return Ok(CommandResult {
                        stdout: json!({
                            "status": payment_status_label(payment.status),
                            "payment_hash": payment.payment_hash,
                            "payment_preimage": payment.payment_preimage,
                            "value_sat": payment.value_sat,
                            "value_msat": payment.value_msat,
                            "fee_sat": payment.fee_sat,
                            "fee_msat": payment.fee_msat,
                            "payment_request": payment.payment_request,
                            "raw": format!(
                                "status: {}\npayment_hash: {}\npreimage: {}\nfee_sat: {}",
                                payment_status_label(payment.status),
                                payment.payment_hash,
                                payment.payment_preimage,
                                payment.fee_sat
                            ),
                        }),
                        stderr: String::new(),
                    });
                }
                3 => {
                    return Err(anyhow!(
                        "LND payment failed: hash={} failure_reason={} status={}",
                        payment.payment_hash,
                        payment.failure_reason,
                        payment_status_label(payment.status)
                    ));
                }
                _ => {}
            }
        }

        Err(anyhow!("LND payment stream ended before payment succeeded"))
    }

    async fn connect(&self) -> anyhow::Result<Client> {
        let mut builder = Client::builder()
            .address(grpc_address(&self.settings.rpcserver))
            .cert_path(self.settings.tls_cert.clone())
            .timeout(self.settings.command_timeout)
            .connect_timeout(self.settings.command_timeout);

        builder = if self.settings.no_macaroons {
            builder.macaroon_contents("00")
        } else if let Some(macaroon) = &self.settings.macaroon {
            builder.macaroon_path(macaroon.clone())
        } else {
            return Err(anyhow!(
                "ARK_LND_PROVIDER_LND_MACAROON is required when LND macaroons are enabled"
            ));
        };

        timeout(self.settings.command_timeout, builder.build())
            .await
            .map_err(|_| anyhow!("timed out connecting to LND gRPC"))?
            .context("connecting to LND gRPC")
    }

    async fn call<T, F>(&self, fut: F) -> anyhow::Result<T>
    where
        F: std::future::Future<Output = Result<T, voltage_tonic_lnd::tonic::Status>>,
    {
        timeout(self.settings.command_timeout, fut)
            .await
            .map_err(|_| anyhow!("timed out waiting for LND gRPC response"))?
            .context("LND gRPC request failed")
    }
}

fn grpc_address(rpcserver: &str) -> String {
    if rpcserver.starts_with("http://") || rpcserver.starts_with("https://") {
        rpcserver.to_string()
    } else {
        format!("https://{rpcserver}")
    }
}

fn decode_hex32(label: &str, value: &str) -> anyhow::Result<Vec<u8>> {
    let bytes = hex::decode(value).with_context(|| format!("{label} must be hex"))?;
    if bytes.len() != 32 {
        return Err(anyhow!("{label} must be 32 bytes"));
    }
    Ok(bytes)
}

fn invoice_state_label(state: i32) -> &'static str {
    match state {
        0 => "OPEN",
        1 => "SETTLED",
        2 => "CANCELED",
        3 => "ACCEPTED",
        _ => "UNKNOWN",
    }
}

fn payment_status_label(status: i32) -> &'static str {
    match status {
        1 => "IN_FLIGHT",
        2 => "SUCCEEDED",
        3 => "FAILED",
        4 => "INITIATED",
        _ => "UNKNOWN",
    }
}
