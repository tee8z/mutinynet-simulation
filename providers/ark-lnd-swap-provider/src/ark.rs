use std::{
    path::{Path, PathBuf},
    str::FromStr,
    sync::Arc,
};

use anyhow::{anyhow, Context};
use ark_client::{
    wallet::{Balance, BoardingWallet, OnchainWallet},
    Blockchain, Client as ArkSdkClient, Error as ArkSdkError, InMemorySwapStorage, OfflineClient,
    SpendStatus, StaticKeyProvider, TxStatus,
};
use ark_core::{
    asset::AssetId, send::SendReceiver, server::Asset, ArkAddress, BoardingOutput, ExplorerUtxo,
    UtxoCoinSelection,
};
use bitcoin::{
    key::{Keypair, Secp256k1},
    secp256k1::{schnorr::Signature, Message, SecretKey},
    Address, Amount, FeeRate, Network, Psbt, Transaction, Txid, XOnlyPublicKey,
};
use serde_json::json;

use crate::{config::ArkSettings, models::CommandResult};

type StaticArkClient =
    ArkSdkClient<NoopBlockchain, NoopWallet, InMemorySwapStorage, StaticKeyProvider>;

#[derive(Clone)]
pub struct ArkClient {
    settings: ArkSettings,
}

impl ArkClient {
    pub fn new(settings: ArkSettings) -> Self {
        Self { settings }
    }

    pub fn ark_server_url(&self) -> &str {
        &self.settings.ark_server_url
    }

    pub fn default_wallet_dir(&self) -> &Path {
        &self.settings.wallet_dir
    }

    pub fn default_private_key_hex(&self) -> Option<String> {
        self.settings.private_key_hex.clone()
    }

    pub async fn receive(
        &self,
        _wallet_dir: Option<PathBuf>,
        private_key_hex: Option<String>,
    ) -> anyhow::Result<CommandResult> {
        let client = self.connect(private_key_hex).await?;
        let (address, _) = client
            .get_offchain_address()
            .map_err(anyhow::Error::from)
            .context("building Ark offchain receive address")?;

        Ok(CommandResult {
            stdout: json!({
                "address": address.to_string(),
                "ark_address": address.to_string(),
            }),
            stderr: String::new(),
        })
    }

    pub async fn balance(
        &self,
        _wallet_dir: Option<PathBuf>,
        private_key_hex: Option<String>,
    ) -> anyhow::Result<CommandResult> {
        let client = self.connect(private_key_hex).await?;
        let balance = client
            .offchain_balance()
            .await
            .map_err(anyhow::Error::from)
            .context("fetching Ark offchain balance")?;

        let assets = balance
            .asset_balances()
            .iter()
            .map(|(asset_id, amount)| json!({ "asset_id": asset_id.to_string(), "amount": amount }))
            .collect::<Vec<_>>();

        Ok(CommandResult {
            stdout: json!({
                "pre_confirmed_sat": balance.pre_confirmed().to_sat(),
                "confirmed_sat": balance.confirmed().to_sat(),
                "recoverable_sat": balance.recoverable().to_sat(),
                "total_sat": balance.total().to_sat(),
                "assets": assets,
            }),
            stderr: String::new(),
        })
    }

    pub async fn send_asset(
        &self,
        _wallet_dir: PathBuf,
        to: String,
        asset_id: String,
        amount: String,
        _password: Option<String>,
        private_key_hex: Option<String>,
    ) -> anyhow::Result<CommandResult> {
        let client = self.connect(private_key_hex).await?;
        let address = ArkAddress::from_str(&to).context("parsing Ark recipient address")?;
        let asset_id = AssetId::from_str(&asset_id).context("parsing Ark asset id")?;
        let amount = amount
            .parse::<u64>()
            .context("asset amount must be an unsigned integer")?;

        let txid = client
            .send(vec![SendReceiver {
                address,
                amount: client.server_info.dust,
                assets: vec![Asset { asset_id, amount }],
            }])
            .await
            .map_err(anyhow::Error::from)
            .context("sending Ark asset over gRPC")?;

        Ok(CommandResult {
            stdout: json!({
                "txid": txid.to_string(),
                "ark_txid": txid.to_string(),
            }),
            stderr: String::new(),
        })
    }

    async fn connect(&self, private_key_hex: Option<String>) -> anyhow::Result<StaticArkClient> {
        let key_hex = private_key_hex
            .or_else(|| self.settings.private_key_hex.clone())
            .ok_or_else(|| {
                anyhow!(
                    "wallet_private_key_hex or ARK_LND_PROVIDER_ARK_PRIVATE_KEY_HEX is required for Ark gRPC wallet operations"
                )
            })?;
        let keypair = keypair_from_hex(&key_hex)?;

        let offline = OfflineClient::<
            NoopBlockchain,
            NoopWallet,
            InMemorySwapStorage,
            StaticKeyProvider,
        >::new_with_keypair(
            "ark-lnd-swap-provider".to_string(),
            keypair,
            Arc::new(NoopBlockchain),
            Arc::new(NoopWallet),
            self.settings.ark_server_url.clone(),
            Arc::new(InMemorySwapStorage::default()),
            String::new(),
            None,
            self.settings.command_timeout,
            None,
            vec![],
        );

        offline
            .connect()
            .await
            .map_err(anyhow::Error::from)
            .context("connecting to Ark server over gRPC")
    }
}

pub(crate) fn keypair_from_hex(private_key_hex: &str) -> anyhow::Result<Keypair> {
    let bytes = hex::decode(private_key_hex).context("wallet_private_key_hex must be hex")?;
    if bytes.len() != 32 {
        return Err(anyhow!("wallet_private_key_hex must be 32 bytes"));
    }
    let secret = SecretKey::from_slice(&bytes).context("invalid wallet private key")?;
    let secp = Secp256k1::new();
    Ok(Keypair::from_secret_key(&secp, &secret))
}

#[derive(Clone)]
struct NoopBlockchain;

impl Blockchain for NoopBlockchain {
    async fn find_outpoints(&self, _address: &Address) -> Result<Vec<ExplorerUtxo>, ArkSdkError> {
        Err(ArkSdkError::consumer(
            "on-chain wallet access is not configured",
        ))
    }

    async fn find_tx(&self, _txid: &Txid) -> Result<Option<Transaction>, ArkSdkError> {
        Err(ArkSdkError::consumer(
            "on-chain wallet access is not configured",
        ))
    }

    async fn get_tx_status(&self, _txid: &Txid) -> Result<TxStatus, ArkSdkError> {
        Err(ArkSdkError::consumer(
            "on-chain wallet access is not configured",
        ))
    }

    async fn get_output_status(
        &self,
        _txid: &Txid,
        _vout: u32,
    ) -> Result<SpendStatus, ArkSdkError> {
        Err(ArkSdkError::consumer(
            "on-chain wallet access is not configured",
        ))
    }

    async fn broadcast(&self, _tx: &Transaction) -> Result<(), ArkSdkError> {
        Err(ArkSdkError::consumer(
            "on-chain wallet access is not configured",
        ))
    }

    async fn get_fee_rate(&self) -> Result<f64, ArkSdkError> {
        Err(ArkSdkError::consumer(
            "on-chain wallet access is not configured",
        ))
    }

    async fn broadcast_package(&self, _txs: &[&Transaction]) -> Result<(), ArkSdkError> {
        Err(ArkSdkError::consumer(
            "on-chain wallet access is not configured",
        ))
    }
}

#[derive(Clone)]
struct NoopWallet;

impl BoardingWallet for NoopWallet {
    fn new_boarding_output(
        &self,
        _server_pubkey: XOnlyPublicKey,
        _exit_delay: bitcoin::Sequence,
        _network: Network,
    ) -> Result<BoardingOutput, ArkSdkError> {
        Err(ArkSdkError::consumer(
            "on-chain wallet access is not configured",
        ))
    }

    fn get_boarding_outputs(&self) -> Result<Vec<BoardingOutput>, ArkSdkError> {
        Err(ArkSdkError::consumer(
            "on-chain wallet access is not configured",
        ))
    }

    fn sign_for_pk(&self, _pk: &XOnlyPublicKey, _msg: &Message) -> Result<Signature, ArkSdkError> {
        Err(ArkSdkError::consumer(
            "on-chain wallet access is not configured",
        ))
    }
}

impl OnchainWallet for NoopWallet {
    fn get_onchain_address(&self) -> Result<Address, ArkSdkError> {
        Err(ArkSdkError::consumer(
            "on-chain wallet access is not configured",
        ))
    }

    async fn sync(&self) -> Result<(), ArkSdkError> {
        Err(ArkSdkError::consumer(
            "on-chain wallet access is not configured",
        ))
    }

    fn balance(&self) -> Result<Balance, ArkSdkError> {
        Err(ArkSdkError::consumer(
            "on-chain wallet access is not configured",
        ))
    }

    fn prepare_send_to_address(
        &self,
        _address: Address,
        _amount: Amount,
        _fee_rate: FeeRate,
    ) -> Result<Psbt, ArkSdkError> {
        Err(ArkSdkError::consumer(
            "on-chain wallet access is not configured",
        ))
    }

    fn sign(&self, _psbt: &mut Psbt) -> Result<bool, ArkSdkError> {
        Err(ArkSdkError::consumer(
            "on-chain wallet access is not configured",
        ))
    }

    fn select_coins(&self, _target_amount: Amount) -> Result<UtxoCoinSelection, ArkSdkError> {
        Err(ArkSdkError::consumer(
            "on-chain wallet access is not configured",
        ))
    }
}
