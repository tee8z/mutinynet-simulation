use std::{future::IntoFuture, sync::Arc};

use axum::{serve::Serve, Router};
use tokio::{net::TcpListener, signal};
use tower_http::trace::TraceLayer;
use tracing::{error, info};

use crate::{
    app_state::AppState, ark::ArkClient, config::Settings, lnd::LndClient, routes, store::SwapStore,
};

pub struct Application {
    server: Serve<TcpListener, Router, Router>,
}

impl Application {
    pub async fn build(settings: Settings) -> anyhow::Result<Self> {
        let store = SwapStore::connect(&settings.database).await?;
        let state = AppState {
            ark: ArkClient::new(settings.ark),
            lnd: LndClient::new(settings.lnd),
            store,
        };

        let listener = TcpListener::bind(settings.bind).await?;
        let server = axum::serve(listener, app(Arc::new(state)));
        info!(
            "ark-lnd swap provider listening on http://{}",
            settings.bind
        );
        Ok(Self { server })
    }

    pub async fn run_until_stopped(self) -> anyhow::Result<()> {
        self.server
            .with_graceful_shutdown(shutdown_signal())
            .into_future()
            .await?;
        Ok(())
    }
}

fn app(state: Arc<AppState>) -> Router {
    routes::router()
        .layer(TraceLayer::new_for_http())
        .with_state(state)
}

async fn shutdown_signal() {
    let ctrl_c = async {
        if let Err(err) = signal::ctrl_c().await {
            error!(?err, "failed to install ctrl+c handler");
        }
    };

    #[cfg(unix)]
    let terminate = async {
        match signal::unix::signal(signal::unix::SignalKind::terminate()) {
            Ok(mut signal) => {
                signal.recv().await;
            }
            Err(err) => error!(?err, "failed to install terminate handler"),
        }
    };

    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();

    tokio::select! {
        _ = ctrl_c => {},
        _ = terminate => {},
    }
}
