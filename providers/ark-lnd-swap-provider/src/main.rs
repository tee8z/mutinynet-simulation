mod app_state;
mod ark;
mod config;
mod contract;
mod error;
mod lnd;
mod models;
mod preimage;
mod routes;
mod startup;
mod store;

use crate::{config::Settings, startup::Application};

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "ark_lnd_swap_provider=info,tower_http=info".into()),
        )
        .init();

    let settings = Settings::from_env()?;
    Application::build(settings)
        .await?
        .run_until_stopped()
        .await
}
