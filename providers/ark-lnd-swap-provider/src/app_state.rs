use crate::{ark::ArkClient, lnd::LndClient, store::SwapStore};

#[derive(Clone)]
pub struct AppState {
    pub ark: ArkClient,
    pub lnd: LndClient,
    pub store: SwapStore,
}
