use crate::{command::run_command, config::LndSettings, models::CommandResult};

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
    ) -> anyhow::Result<CommandResult> {
        self.run(vec![
            "addholdinvoice".to_string(),
            "--memo".to_string(),
            memo.to_string(),
            "--amt".to_string(),
            amount_sat.to_string(),
            preimage_hash.to_string(),
        ])
        .await
    }

    pub async fn decode_payreq(&self, bolt11: &str) -> anyhow::Result<CommandResult> {
        self.run(vec!["decodepayreq".to_string(), bolt11.to_string()])
            .await
    }

    pub async fn lookup_invoice(&self, payment_hash: &str) -> anyhow::Result<CommandResult> {
        self.run(vec!["lookupinvoice".to_string(), payment_hash.to_string()])
            .await
    }

    pub async fn settle_invoice(&self, preimage: &str) -> anyhow::Result<CommandResult> {
        self.run(vec!["settleinvoice".to_string(), preimage.to_string()])
            .await
    }

    pub async fn cancel_invoice(&self, payment_hash: &str) -> anyhow::Result<CommandResult> {
        self.run(vec!["cancelinvoice".to_string(), payment_hash.to_string()])
            .await
    }

    pub async fn pay_invoice(
        &self,
        bolt11: &str,
        fee_limit_sat: Option<i64>,
    ) -> anyhow::Result<CommandResult> {
        let mut args = vec!["payinvoice".to_string(), "--force".to_string()];
        if let Some(fee_limit_sat) = fee_limit_sat {
            args.push("--fee_limit".to_string());
            args.push(fee_limit_sat.to_string());
        }
        args.push(bolt11.to_string());
        self.run(args).await
    }

    async fn run(&self, command_args: Vec<String>) -> anyhow::Result<CommandResult> {
        let mut args = self.base_args();
        args.extend(command_args);
        run_command(
            &self.settings.lncli_bin,
            args,
            &[],
            self.settings.command_timeout,
        )
        .await
    }

    fn base_args(&self) -> Vec<String> {
        let mut args = vec![
            "--lnddir".to_string(),
            self.settings.dir.display().to_string(),
            "--rpcserver".to_string(),
            self.settings.rpcserver.clone(),
            "--network".to_string(),
            self.settings.network.clone(),
            "--tlscertpath".to_string(),
            self.settings.tls_cert.display().to_string(),
        ];
        if self.settings.no_macaroons {
            args.push("--no-macaroons".to_string());
        } else if let Some(macaroon) = &self.settings.macaroon {
            args.push("--macaroonpath".to_string());
            args.push(macaroon.display().to_string());
        }
        args
    }
}
