use std::path::{Path, PathBuf};

use crate::{command::run_command, config::ArkSettings, models::CommandResult};

#[derive(Clone)]
pub struct ArkClient {
    settings: ArkSettings,
}

impl ArkClient {
    pub fn new(settings: ArkSettings) -> Self {
        Self { settings }
    }

    pub fn default_wallet_dir(&self) -> &Path {
        &self.settings.wallet_dir
    }

    pub fn default_password(&self) -> Option<String> {
        self.settings.password.clone()
    }

    pub async fn receive(&self, wallet_dir: Option<PathBuf>) -> anyhow::Result<CommandResult> {
        self.run(wallet_dir, vec!["receive".to_string()]).await
    }

    pub async fn balance(&self, wallet_dir: Option<PathBuf>) -> anyhow::Result<CommandResult> {
        self.run(wallet_dir, vec!["balance".to_string()]).await
    }

    pub async fn send_asset(
        &self,
        wallet_dir: PathBuf,
        to: String,
        asset_id: String,
        amount: String,
        password: Option<String>,
    ) -> anyhow::Result<CommandResult> {
        let mut args = vec![
            "send".to_string(),
            "--to".to_string(),
            to,
            "--asset-id".to_string(),
            asset_id,
            "--amount".to_string(),
            amount,
        ];
        if let Some(password) = password {
            args.push("--password".to_string());
            args.push(password);
        }
        self.run(Some(wallet_dir), args).await
    }

    async fn run(
        &self,
        wallet_dir: Option<PathBuf>,
        args: Vec<String>,
    ) -> anyhow::Result<CommandResult> {
        let wallet_dir = wallet_dir.unwrap_or_else(|| self.settings.wallet_dir.clone());
        run_command(
            &self.settings.ark_bin,
            args,
            &[(
                "ARK_WALLET_DATADIR".to_string(),
                wallet_dir.display().to_string(),
            )],
            self.settings.command_timeout,
        )
        .await
    }
}
