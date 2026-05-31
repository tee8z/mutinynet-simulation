use std::{path::PathBuf, str::FromStr, sync::Arc, time::Duration};

use anyhow::{anyhow, Context};
use ark_client::{
    wallet::{Balance, BoardingWallet, OnchainWallet},
    Blockchain, Client as ArkSdkClient, Error as ArkSdkError, InMemorySwapStorage, OfflineClient,
    SpendStatus, StaticKeyProvider, TxStatus,
};
use ark_core::{
    asset::AssetId,
    script::tr_script_pubkey,
    send::{
        build_asset_send_transactions, sign_ark_transaction, sign_checkpoint_transaction,
        SendReceiver, VtxoInput,
    },
    server::{Asset, GetVtxosRequest, Info, VirtualTxOutPoint},
    ArkAddress, BoardingOutput, ExplorerUtxo, UtxoCoinSelection, UNSPENDABLE_KEY,
    VTXO_CONDITION_KEY,
};
use bitcoin::{
    absolute,
    consensus::Encodable,
    hex::DisplayHex,
    key::{Keypair, Secp256k1},
    opcodes::all::*,
    psbt,
    secp256k1::{schnorr::Signature, Message, PublicKey as SecpPublicKey, SecretKey},
    taproot::{LeafVersion, TaprootBuilder, TaprootSpendInfo},
    Address, Amount, FeeRate, Network, OutPoint, Psbt, ScriptBuf, Sequence, Transaction, Txid,
    VarInt, XOnlyPublicKey,
};
use serde_json::{json, Value};
use tokio::time::{sleep, timeout};

use crate::{
    config::ArkContractSettings,
    models::{ArkContractActionRequest, CommandResult, SwapRow},
};

type StaticArkClient =
    ArkSdkClient<NoopBlockchain, NoopWallet, InMemorySwapStorage, StaticKeyProvider>;

#[derive(Clone)]
pub struct ArkContractClient {
    settings: ArkContractSettings,
}

impl ArkContractClient {
    pub fn new(settings: ArkContractSettings) -> Self {
        Self { settings }
    }

    pub async fn wallet_pubkey(
        &self,
        _wallet_dir: PathBuf,
        _password: Option<String>,
        private_key: Option<String>,
    ) -> anyhow::Result<CommandResult> {
        let keypair = keypair_from_hex(&self.private_key(private_key)?)?;
        let (x_only, _) = keypair.x_only_public_key();
        let compressed = SecpPublicKey::from_keypair(&keypair);

        Ok(CommandResult {
            stdout: json!({
                "status": "ok",
                "ark_claim_pubkey": x_only.to_string(),
                "ark_refund_pubkey": x_only.to_string(),
                "compressed_pubkey": compressed.to_string(),
            }),
            stderr: String::new(),
        })
    }

    pub async fn template(
        &self,
        row: &SwapRow,
        request: &ArkContractActionRequest,
    ) -> anyhow::Result<CommandResult> {
        let context = self.build_context(row, request).await?;
        Ok(CommandResult {
            stdout: self.template_fields(&context),
            stderr: String::new(),
        })
    }

    pub async fn fund(
        &self,
        row: &SwapRow,
        request: &ArkContractActionRequest,
        _wallet_dir: PathBuf,
        _password: Option<String>,
    ) -> anyhow::Result<CommandResult> {
        let context = self.build_context(row, request).await?;
        let client = self
            .connect_static_client(request.wallet_private_key_hex.clone())
            .await?;
        let asset_id = AssetId::from_str(&context.spec.asset_id).context("parsing asset_id")?;
        let asset_amount = parse_u64("asset_amount", &context.spec.asset_amount)?;
        let requested_vtxo_sats = u64::try_from(context.spec.vtxo_sats)
            .map_err(|_| anyhow!("vtxo_sats must be non-negative"))?;
        let vtxo_sats = requested_vtxo_sats.max(context.info.dust.to_sat());

        let funding_txid = client
            .send(vec![SendReceiver {
                address: context.address,
                amount: Amount::from_sat(vtxo_sats),
                assets: vec![Asset {
                    asset_id,
                    amount: asset_amount,
                }],
            }])
            .await
            .map_err(anyhow::Error::from)
            .context("funding Ark contract VTXO over gRPC")?;

        let vtxo = self
            .wait_for_contract_vtxo(
                &context,
                Some(&funding_txid),
                request.ark_vtxo_outpoint.as_deref(),
            )
            .await?;

        let mut stdout = self.template_fields(&context);
        stdout["funding_txid"] = Value::String(funding_txid.to_string());
        stdout["ark_vtxo_outpoint"] = Value::String(vtxo.outpoint.to_string());
        stdout["contract_funded"] = Value::Bool(true);
        stdout["asset_id"] = Value::String(context.spec.asset_id);
        stdout["asset_amount"] = Value::String(context.spec.asset_amount);
        stdout["vtxo"] = public_vtxo(&vtxo);

        Ok(CommandResult {
            stdout,
            stderr: String::new(),
        })
    }

    pub async fn verify_funded(
        &self,
        row: &SwapRow,
        request: &ArkContractActionRequest,
    ) -> anyhow::Result<CommandResult> {
        let context = self.build_context(row, request).await?;
        let vtxo = self
            .find_contract_vtxo(&context, request.ark_vtxo_outpoint.as_deref())
            .await?;

        let mut stdout = self.template_fields(&context);
        stdout["contract_funded"] = Value::Bool(vtxo.is_some());
        stdout["ark_vtxo_outpoint"] = vtxo
            .as_ref()
            .map(|v| Value::String(v.outpoint.to_string()))
            .unwrap_or(Value::Null);
        stdout["asset_id"] = Value::String(context.spec.asset_id);
        stdout["asset_amount"] = Value::String(context.spec.asset_amount);
        stdout["vtxo"] = vtxo.as_ref().map(public_vtxo).unwrap_or(Value::Null);

        Ok(CommandResult {
            stdout,
            stderr: String::new(),
        })
    }

    pub async fn claim(
        &self,
        row: &SwapRow,
        request: &ArkContractActionRequest,
        _wallet_dir: PathBuf,
        _password: Option<String>,
    ) -> anyhow::Result<CommandResult> {
        self.claim_or_refund(row, request, ContractSpendPath::Claim)
            .await
    }

    pub async fn refund(
        &self,
        row: &SwapRow,
        request: &ArkContractActionRequest,
        _wallet_dir: PathBuf,
        _password: Option<String>,
    ) -> anyhow::Result<CommandResult> {
        self.claim_or_refund(row, request, ContractSpendPath::Refund)
            .await
    }

    async fn claim_or_refund(
        &self,
        row: &SwapRow,
        request: &ArkContractActionRequest,
        path: ContractSpendPath,
    ) -> anyhow::Result<CommandResult> {
        let context = self.build_context(row, request).await?;
        let destination = request
            .destination_address
            .as_deref()
            .ok_or_else(|| anyhow!("destination_address is required"))?;
        let destination =
            ArkAddress::from_str(destination).context("parsing destination_address")?;
        let outpoint = request
            .ark_vtxo_outpoint
            .as_deref()
            .or(row.ark_vtxo_outpoint.as_deref())
            .ok_or_else(|| anyhow!("ark_vtxo_outpoint is required"))?;
        let vtxo = self
            .find_contract_vtxo(&context, Some(outpoint))
            .await?
            .ok_or_else(|| anyhow!("contract vtxo not found or asset proof did not match"))?;
        let keypair = keypair_from_hex(&self.private_key(request.wallet_private_key_hex.clone())?)?;
        let preimage = match path {
            ContractSpendPath::Claim => Some(decode_hex32(
                "preimage",
                request
                    .preimage
                    .as_deref()
                    .or(row.preimage.as_deref())
                    .ok_or_else(|| anyhow!("preimage is required"))?,
            )?),
            ContractSpendPath::Refund => None,
        };

        let (spend_script, locktime) = match path {
            ContractSpendPath::Claim => (context.claim_script.clone(), None),
            ContractSpendPath::Refund => (
                context.refund_script.clone(),
                Some(absolute::LockTime::from_consensus(
                    context.spec.refund_time as u32,
                )),
            ),
        };
        let script_ver = (spend_script.clone(), LeafVersion::TapScript);
        let control_block = context
            .spend_info
            .control_block(&script_ver)
            .ok_or_else(|| anyhow!("control block not found for contract script"))?;

        let input = VtxoInput::new(
            spend_script,
            locktime,
            control_block,
            context.tapscripts.clone(),
            context.script_pubkey.clone(),
            vtxo.amount,
            vtxo.outpoint,
            vtxo.assets.clone(),
        );
        let receiver = SendReceiver {
            address: destination,
            amount: vtxo.amount,
            assets: vtxo.assets.clone(),
        };

        let ark = self.connected_ark_grpc().await?;
        let offchain = build_asset_send_transactions(
            &[receiver],
            &destination,
            std::slice::from_ref(&input),
            &context.info,
        )
        .map_err(anyhow::Error::from)
        .context("building Ark contract spend transaction")?;
        let mut ark_tx = offchain.ark_tx;

        let signer = |input: &mut psbt::Input,
                      msg: bitcoin::secp256k1::Message|
         -> Result<Vec<(Signature, XOnlyPublicKey)>, ark_core::Error> {
            if let Some(preimage) = preimage.as_ref() {
                input.unknown.insert(
                    psbt::raw::Key {
                        type_value: 222,
                        key: VTXO_CONDITION_KEY.to_vec(),
                    },
                    condition_witness(preimage),
                );
            }

            let sig = Secp256k1::new().sign_schnorr_no_aux_rand(&msg, &keypair);
            Ok(vec![(sig, keypair.x_only_public_key().0)])
        };

        sign_ark_transaction(signer, &mut ark_tx, 0)
            .map_err(anyhow::Error::from)
            .context("signing Ark contract spend transaction")?;
        let ark_txid = ark_tx.unsigned_tx.compute_txid();
        let response = ark
            .submit_offchain_transaction_request(ark_tx, offchain.checkpoint_txs)
            .await
            .map_err(anyhow::Error::from)
            .context("submitting Ark contract spend transaction")?;

        let mut signed_checkpoints = Vec::new();
        for mut checkpoint in response.signed_checkpoint_txs {
            let signer = |_: &mut psbt::Input,
                          msg: bitcoin::secp256k1::Message|
             -> Result<Vec<(Signature, XOnlyPublicKey)>, ark_core::Error> {
                let sig = Secp256k1::new().sign_schnorr_no_aux_rand(&msg, &keypair);
                Ok(vec![(sig, keypair.x_only_public_key().0)])
            };
            sign_checkpoint_transaction(signer, &mut checkpoint)
                .map_err(anyhow::Error::from)
                .context("signing Ark contract checkpoint transaction")?;
            signed_checkpoints.push(checkpoint);
        }

        ark.finalize_offchain_transaction(ark_txid, signed_checkpoints)
            .await
            .map_err(anyhow::Error::from)
            .context("finalizing Ark contract spend transaction")?;

        let mut stdout = self.template_fields(&context);
        stdout["ark_vtxo_outpoint"] = Value::String(vtxo.outpoint.to_string());
        stdout["asset_id"] = Value::String(context.spec.asset_id);
        stdout["asset_amount"] = Value::String(context.spec.asset_amount);
        stdout["path"] = Value::String(path.as_str().to_string());
        stdout["ark_claim_txid"] = if matches!(path, ContractSpendPath::Claim) {
            Value::String(ark_txid.to_string())
        } else {
            Value::Null
        };
        stdout["ark_refund_txid"] = if matches!(path, ContractSpendPath::Refund) {
            Value::String(ark_txid.to_string())
        } else {
            Value::Null
        };
        stdout["decoded_witness_preimage"] = request
            .preimage
            .clone()
            .or(row.preimage.clone())
            .filter(|_| matches!(path, ContractSpendPath::Claim))
            .map(Value::String)
            .unwrap_or(Value::Null);

        Ok(CommandResult {
            stdout,
            stderr: String::new(),
        })
    }

    async fn build_context(
        &self,
        row: &SwapRow,
        request: &ArkContractActionRequest,
    ) -> anyhow::Result<ContractContext> {
        let spec = self.contract_spec(row, request)?;
        let mut ark = self.connected_ark_grpc().await?;
        let info = ark
            .get_info()
            .await
            .map_err(anyhow::Error::from)
            .context("fetching Ark server info")?;
        let server_pubkey = info.signer_pk.x_only_public_key().0;
        let vhtlc = Sha256Vhtlc::new(
            spec.claim_pubkey,
            spec.refund_pubkey,
            server_pubkey,
            spec.preimage_hash,
            spec.refund_time,
            Sequence::from_height(delay_to_u16(self.settings.unilateral_claim_delay_blocks)?),
            Sequence::from_height(delay_to_u16(self.settings.unilateral_refund_delay_blocks)?),
        )?;
        let spend_info = vhtlc.spend_info()?;
        let script_pubkey = tr_script_pubkey(&spend_info);
        let address = ArkAddress::new(info.network, server_pubkey, spend_info.output_key());
        let tapscripts = vhtlc.scripts();

        Ok(ContractContext {
            info,
            spec,
            address,
            script_pubkey,
            spend_info,
            claim_script: vhtlc.claim_script(),
            refund_script: vhtlc.refund_script(),
            unilateral_claim_script: vhtlc.unilateral_claim_script(),
            unilateral_refund_script: vhtlc.unilateral_refund_script(),
            tapscripts,
        })
    }

    fn contract_spec(
        &self,
        row: &SwapRow,
        request: &ArkContractActionRequest,
    ) -> anyhow::Result<ContractSpec> {
        let preimage_hash = request
            .preimage_hash_sha256
            .clone()
            .or(row.preimage_hash_sha256.clone())
            .or(row.preimage_hash.clone())
            .ok_or_else(|| anyhow!("preimage_hash_sha256 is required"))?;
        let claim_pubkey = request
            .ark_claim_pubkey
            .clone()
            .or(row.ark_claim_pubkey.clone())
            .ok_or_else(|| anyhow!("ark_claim_pubkey is required"))?;
        let refund_pubkey = request
            .ark_refund_pubkey
            .clone()
            .or(row.ark_refund_pubkey.clone())
            .ok_or_else(|| anyhow!("ark_refund_pubkey is required"))?;
        let refund_time = request
            .ark_refund_time
            .or(row.ark_refund_time)
            .ok_or_else(|| anyhow!("ark_refund_time is required"))?;
        let asset_id = request
            .asset_id
            .clone()
            .or(row.asset_id.clone())
            .ok_or_else(|| anyhow!("asset_id is required"))?;
        let asset_amount = request
            .asset_amount
            .clone()
            .or(row.asset_amount.clone())
            .ok_or_else(|| anyhow!("asset_amount is required"))?;

        Ok(ContractSpec {
            preimage_hash_hex: preimage_hash.clone(),
            preimage_hash: decode_hex32_array("preimage_hash_sha256", &preimage_hash)?,
            claim_pubkey_hex: normalize_pubkey_hex(&claim_pubkey)?,
            claim_pubkey: parse_xonly_pubkey(&claim_pubkey, "ark_claim_pubkey")?,
            refund_pubkey_hex: normalize_pubkey_hex(&refund_pubkey)?,
            refund_pubkey: parse_xonly_pubkey(&refund_pubkey, "ark_refund_pubkey")?,
            refund_time,
            asset_id,
            asset_amount,
            vtxo_sats: request.vtxo_sats.unwrap_or(self.settings.vtxo_sats),
        })
    }

    fn template_fields(&self, context: &ContractContext) -> Value {
        let leaves = context
            .tapscripts
            .iter()
            .map(|script| script.as_bytes().to_lower_hex_string())
            .collect::<Vec<_>>();

        json!({
            "status": "ok",
            "adapter": "rust-ark-grpc",
            "ark_contract_address": context.address.to_string(),
            "ark_contract_script": context.script_pubkey.as_bytes().to_lower_hex_string(),
            "ark_tap_tree": serde_json::to_string(&leaves).unwrap_or_default(),
            "ark_claim_pubkey": context.spec.claim_pubkey_hex,
            "ark_refund_pubkey": context.spec.refund_pubkey_hex,
            "ark_refund_time": context.spec.refund_time,
            "claim_tapleaf_script": context.claim_script.as_bytes().to_lower_hex_string(),
            "refund_tapleaf_script": context.refund_script.as_bytes().to_lower_hex_string(),
            "unilateral_claim_tapleaf_script": context.unilateral_claim_script.as_bytes().to_lower_hex_string(),
            "unilateral_refund_tapleaf_script": context.unilateral_refund_script.as_bytes().to_lower_hex_string(),
            "hash_op": "OP_SHA256",
            "network": self.settings.network,
            "preimage_hash_sha256": context.spec.preimage_hash_hex,
            "server_pubkey": context.info.signer_pk.x_only_public_key().0.to_string(),
            "arkd_version": context.info.version,
        })
    }

    async fn wait_for_contract_vtxo(
        &self,
        context: &ContractContext,
        funding_txid: Option<&Txid>,
        outpoint: Option<&str>,
    ) -> anyhow::Result<VirtualTxOutPoint> {
        let attempts = self.settings.command_timeout.as_secs().clamp(1, 30);
        for _ in 0..attempts {
            if let Some(vtxo) = self.find_contract_vtxo(context, outpoint).await? {
                if funding_txid
                    .map(|txid| vtxo.outpoint.txid == *txid || vtxo.ark_txid == Some(*txid))
                    .unwrap_or(true)
                {
                    return Ok(vtxo);
                }
            }
            sleep(Duration::from_secs(1)).await;
        }

        Err(anyhow!("contract vtxo was not indexed before timeout"))
    }

    async fn find_contract_vtxo(
        &self,
        context: &ContractContext,
        outpoint: Option<&str>,
    ) -> anyhow::Result<Option<VirtualTxOutPoint>> {
        let outpoint = outpoint
            .map(OutPoint::from_str)
            .transpose()
            .context("parsing ark_vtxo_outpoint")?;
        let asset_id = AssetId::from_str(&context.spec.asset_id).context("parsing asset_id")?;
        let asset_amount = parse_u64("asset_amount", &context.spec.asset_amount)?;

        let ark = self.connected_ark_grpc().await?;
        let request = GetVtxosRequest::new_for_addresses(std::iter::once(context.address))
            .spendable_only()
            .map_err(anyhow::Error::from)?;
        let response = ark
            .list_vtxos(request)
            .await
            .map_err(anyhow::Error::from)
            .context("listing Ark contract VTXOs")?;

        Ok(response.vtxos.into_iter().find(|vtxo| {
            if outpoint
                .map(|expected| vtxo.outpoint != expected)
                .unwrap_or(false)
            {
                return false;
            }
            vtxo.script == context.script_pubkey
                && vtxo
                    .assets
                    .iter()
                    .any(|asset| asset.asset_id == asset_id && asset.amount == asset_amount)
        }))
    }

    async fn connected_ark_grpc(&self) -> anyhow::Result<ark_grpc::Client> {
        let mut ark = ark_grpc::Client::new(self.settings.ark_server_url.clone());
        timeout(self.settings.command_timeout, ark.connect())
            .await
            .map_err(|_| anyhow!("timed out connecting to Ark gRPC"))?
            .map_err(anyhow::Error::from)
            .context("connecting to Ark gRPC")?;
        Ok(ark)
    }

    async fn connect_static_client(
        &self,
        private_key: Option<String>,
    ) -> anyhow::Result<StaticArkClient> {
        let keypair = keypair_from_hex(&self.private_key(private_key)?)?;
        let offline = OfflineClient::<
            NoopBlockchain,
            NoopWallet,
            InMemorySwapStorage,
            StaticKeyProvider,
        >::new_with_keypair(
            "ark-lnd-swap-provider-contract".to_string(),
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
            .context("connecting static Ark client")
    }

    fn private_key(&self, private_key: Option<String>) -> anyhow::Result<String> {
        private_key
            .or_else(|| self.settings.private_key_hex.clone())
            .ok_or_else(|| {
                anyhow!(
                    "wallet_private_key_hex or ARK_LND_PROVIDER_ARK_PRIVATE_KEY_HEX is required for Ark contract wallet operations"
                )
            })
    }
}

#[derive(Clone)]
struct ContractSpec {
    preimage_hash_hex: String,
    preimage_hash: [u8; 32],
    claim_pubkey_hex: String,
    claim_pubkey: XOnlyPublicKey,
    refund_pubkey_hex: String,
    refund_pubkey: XOnlyPublicKey,
    refund_time: i64,
    asset_id: String,
    asset_amount: String,
    vtxo_sats: i64,
}

struct ContractContext {
    info: Info,
    spec: ContractSpec,
    address: ArkAddress,
    script_pubkey: ScriptBuf,
    spend_info: TaprootSpendInfo,
    claim_script: ScriptBuf,
    refund_script: ScriptBuf,
    unilateral_claim_script: ScriptBuf,
    unilateral_refund_script: ScriptBuf,
    tapscripts: Vec<ScriptBuf>,
}

#[derive(Clone, Copy)]
enum ContractSpendPath {
    Claim,
    Refund,
}

impl ContractSpendPath {
    fn as_str(self) -> &'static str {
        match self {
            Self::Claim => "claim",
            Self::Refund => "refund",
        }
    }
}

struct Sha256Vhtlc {
    claim_pubkey: XOnlyPublicKey,
    refund_pubkey: XOnlyPublicKey,
    server_pubkey: XOnlyPublicKey,
    preimage_hash: [u8; 32],
    refund_time: i64,
    claim_delay: Sequence,
    refund_delay: Sequence,
}

impl Sha256Vhtlc {
    fn new(
        claim_pubkey: XOnlyPublicKey,
        refund_pubkey: XOnlyPublicKey,
        server_pubkey: XOnlyPublicKey,
        preimage_hash: [u8; 32],
        refund_time: i64,
        claim_delay: Sequence,
        refund_delay: Sequence,
    ) -> anyhow::Result<Self> {
        if refund_time <= 0 {
            return Err(anyhow!("ark_refund_time must be positive"));
        }
        Ok(Self {
            claim_pubkey,
            refund_pubkey,
            server_pubkey,
            preimage_hash,
            refund_time,
            claim_delay,
            refund_delay,
        })
    }

    fn claim_script(&self) -> ScriptBuf {
        ScriptBuf::builder()
            .push_opcode(OP_SHA256)
            .push_slice(self.preimage_hash)
            .push_opcode(OP_EQUALVERIFY)
            .push_x_only_key(&self.claim_pubkey)
            .push_opcode(OP_CHECKSIGVERIFY)
            .push_x_only_key(&self.server_pubkey)
            .push_opcode(OP_CHECKSIG)
            .into_script()
    }

    fn refund_script(&self) -> ScriptBuf {
        ScriptBuf::builder()
            .push_int(self.refund_time)
            .push_opcode(OP_CLTV)
            .push_opcode(OP_DROP)
            .push_x_only_key(&self.refund_pubkey)
            .push_opcode(OP_CHECKSIGVERIFY)
            .push_x_only_key(&self.server_pubkey)
            .push_opcode(OP_CHECKSIG)
            .into_script()
    }

    fn unilateral_claim_script(&self) -> ScriptBuf {
        ScriptBuf::builder()
            .push_opcode(OP_SHA256)
            .push_slice(self.preimage_hash)
            .push_opcode(OP_EQUALVERIFY)
            .push_int(self.claim_delay.to_consensus_u32() as i64)
            .push_opcode(OP_CSV)
            .push_opcode(OP_DROP)
            .push_x_only_key(&self.claim_pubkey)
            .push_opcode(OP_CHECKSIG)
            .into_script()
    }

    fn unilateral_refund_script(&self) -> ScriptBuf {
        ScriptBuf::builder()
            .push_int(self.refund_time)
            .push_opcode(OP_CLTV)
            .push_opcode(OP_DROP)
            .push_int(self.refund_delay.to_consensus_u32() as i64)
            .push_opcode(OP_CSV)
            .push_opcode(OP_DROP)
            .push_x_only_key(&self.refund_pubkey)
            .push_opcode(OP_CHECKSIG)
            .into_script()
    }

    fn scripts(&self) -> Vec<ScriptBuf> {
        vec![
            self.claim_script(),
            self.refund_script(),
            self.unilateral_claim_script(),
            self.unilateral_refund_script(),
        ]
    }

    fn spend_info(&self) -> anyhow::Result<TaprootSpendInfo> {
        let internal_key = SecpPublicKey::from_str(UNSPENDABLE_KEY)
            .context("parsing Ark unspendable taproot key")?
            .x_only_public_key()
            .0;
        let secp = Secp256k1::new();
        let mut builder = TaprootBuilder::new();
        for script in self.scripts() {
            builder = builder
                .add_leaf(2, script)
                .map_err(|err| anyhow!("adding VHTLC taproot leaf: {err}"))?;
        }

        builder
            .finalize(&secp, internal_key)
            .map_err(|_| anyhow!("failed to finalize VHTLC taproot tree"))
    }
}

fn keypair_from_hex(private_key_hex: &str) -> anyhow::Result<Keypair> {
    let bytes = hex::decode(private_key_hex).context("wallet_private_key_hex must be hex")?;
    if bytes.len() != 32 {
        return Err(anyhow!("wallet_private_key_hex must be 32 bytes"));
    }
    let secret = SecretKey::from_slice(&bytes).context("invalid wallet private key")?;
    let secp = Secp256k1::new();
    Ok(Keypair::from_secret_key(&secp, &secret))
}

fn parse_xonly_pubkey(value: &str, label: &str) -> anyhow::Result<XOnlyPublicKey> {
    let value = value.trim();
    if value.len() == 64 {
        let bytes = hex::decode(value).with_context(|| format!("{label} must be hex"))?;
        return XOnlyPublicKey::from_slice(&bytes).with_context(|| format!("invalid {label}"));
    }
    if value.len() == 66 {
        return SecpPublicKey::from_str(value)
            .with_context(|| format!("invalid compressed {label}"))
            .map(|pk| pk.x_only_public_key().0);
    }
    Err(anyhow!("{label} must be a compressed or x-only public key"))
}

fn normalize_pubkey_hex(value: &str) -> anyhow::Result<String> {
    Ok(parse_xonly_pubkey(value, "ark pubkey")?.to_string())
}

fn decode_hex32(label: &str, value: &str) -> anyhow::Result<Vec<u8>> {
    let bytes = hex::decode(value).with_context(|| format!("{label} must be hex"))?;
    if bytes.len() != 32 {
        return Err(anyhow!("{label} must be 32 bytes"));
    }
    Ok(bytes)
}

fn decode_hex32_array(label: &str, value: &str) -> anyhow::Result<[u8; 32]> {
    let bytes = decode_hex32(label, value)?;
    bytes
        .try_into()
        .map_err(|_| anyhow!("{label} must be 32 bytes"))
}

fn parse_u64(label: &str, value: &str) -> anyhow::Result<u64> {
    value
        .parse::<u64>()
        .with_context(|| format!("{label} must be an unsigned integer"))
}

fn delay_to_u16(value: i64) -> anyhow::Result<u16> {
    if !(1..=u16::MAX as i64).contains(&value) {
        return Err(anyhow!("contract delay must be between 1 and {}", u16::MAX));
    }
    Ok(value as u16)
}

fn condition_witness(preimage: &[u8]) -> Vec<u8> {
    let mut bytes = vec![1];
    VarInt(preimage.len() as u64)
        .consensus_encode(&mut bytes)
        .expect("vec writes cannot fail");
    bytes.extend_from_slice(preimage);
    bytes
}

fn public_vtxo(vtxo: &VirtualTxOutPoint) -> Value {
    json!({
        "outpoint": vtxo.outpoint.to_string(),
        "txid": vtxo.outpoint.txid.to_string(),
        "vout": vtxo.outpoint.vout,
        "value": vtxo.amount.to_sat(),
        "assets": vtxo.assets.iter().map(|asset| {
            json!({ "asset_id": asset.asset_id.to_string(), "amount": asset.amount })
        }).collect::<Vec<_>>(),
        "ark_txid": vtxo.ark_txid.map(|txid| txid.to_string()),
        "spent_by": vtxo.spent_by.map(|txid| txid.to_string()),
        "is_spent": vtxo.is_spent,
        "is_unrolled": vtxo.is_unrolled,
    })
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
        _exit_delay: Sequence,
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
