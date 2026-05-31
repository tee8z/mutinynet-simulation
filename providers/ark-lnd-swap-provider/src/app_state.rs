use crate::{ark::ArkClient, contract::ArkContractClient, lnd::LndClient, store::SwapStore};

#[derive(Clone)]
pub struct AppState {
    pub ark: ArkClient,
    pub ark_contract: ArkContractClient,
    pub lnd: LndClient,
    pub store: SwapStore,
}
