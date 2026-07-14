use std::{
    env, fs,
    path::{Path, PathBuf},
    str::FromStr,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use anyhow::{anyhow, Context};
use ark_core::{script::tr_script_pubkey, ArkAddress, UNSPENDABLE_KEY};
use bitcoin::{
    hex::DisplayHex,
    key::Secp256k1,
    opcodes::all::*,
    secp256k1::{PublicKey as SecpPublicKey, SecretKey},
    taproot::{TaprootBuilder, TaprootSpendInfo},
    Network, ScriptBuf, XOnlyPublicKey,
};
use rand::{rngs::OsRng, RngCore};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use tokio::time::timeout;

const DEFAULT_ARK_SERVER_URL: &str = "http://127.0.0.1:7070";
const DEFAULT_RGB_NODE_URL: &str = "http://127.0.0.1:3104";
const DEFAULT_RGB_AMOUNT: u64 = 10;
const DEFAULT_RGB_MSAT: u64 = 3_000_000;
const DEFAULT_EXPIRY_SEC: u64 = 900;
const DEFAULT_REFUND_SEC: i64 = 600;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let args = Args::parse()?;
    let now = unix_now()?;
    let output_dir = args
        .output_dir
        .clone()
        .unwrap_or_else(|| PathBuf::from(format!("state/tests/rgb-ark-contract-swap-{}", now)));
    fs::create_dir_all(&output_dir).context("creating output directory")?;

    let preimage = args.preimage.clone().unwrap_or_else(random_hex32);
    let preimage_hash = args
        .preimage_hash
        .clone()
        .unwrap_or_else(|| sha256_hex(&hex::decode(&preimage).expect("generated preimage is hex")));

    if sha256_hex(&hex::decode(&preimage).context("preimage must be hex")?) != preimage_hash {
        return Err(anyhow!("preimage does not hash to preimage_hash"));
    }

    let ark_info = ark_info(&args).await?;
    let claim_pubkey = args
        .ark_claim_pubkey
        .as_deref()
        .map(|value| parse_xonly_pubkey(value, "ark_claim_pubkey"))
        .transpose()?
        .unwrap_or_else(generated_xonly_pubkey);
    let refund_pubkey = args
        .ark_refund_pubkey
        .as_deref()
        .map(|value| parse_xonly_pubkey(value, "ark_refund_pubkey"))
        .transpose()?
        .unwrap_or_else(generated_xonly_pubkey);
    let refund_time = args
        .ark_refund_time
        .unwrap_or(now as i64 + DEFAULT_REFUND_SEC);

    let vhtlc = Sha256Vhtlc::new(
        claim_pubkey,
        refund_pubkey,
        ark_info.server_pubkey,
        decode_hex32_array("preimage_hash", &preimage_hash)?,
        refund_time,
    )?;
    let spend_info = vhtlc.spend_info()?;
    let script_pubkey = tr_script_pubkey(&spend_info);
    let ark_address = ArkAddress::new(
        ark_info.network,
        ark_info.server_pubkey,
        spend_info.output_key(),
    );
    let tapscripts = vhtlc.scripts();
    let tap_tree = tapscripts
        .iter()
        .map(|script| script.as_bytes().to_lower_hex_string())
        .collect::<Vec<_>>();

    let rgb_invoice_request = json!({
        "amt_msat": args.rgb_amt_msat,
        "expiry_sec": args.rgb_expiry_sec,
        "asset_id": args.rgb_asset_id.clone(),
        "asset_amount": args.rgb_asset_amount,
        "payment_hash": preimage_hash.clone(),
    });
    write_json(
        &output_dir.join("rgb-node-hodl-invoice-request.json"),
        &rgb_invoice_request,
    )?;

    let rgb_live_invoice = if args.live_rgb_invoice {
        Some(create_rgb_hodl_invoice(&args, &rgb_invoice_request, &output_dir).await?)
    } else {
        None
    };

    let contractum = contractum_draft(&args, &preimage_hash, refund_time);
    fs::write(output_dir.join("rgb-htlc-draft.contractum"), &contractum)
        .context("writing RGB Contractum draft")?;

    let ark_vhtlc = json!({
        "kind": "ark_sha256_vhtlc",
        "status": if ark_info.generated_demo_key { "template_demo_server_key" } else { "real_ark_server_key" },
        "ark_server_url": args.ark_server_url.clone(),
        "arkd_version": ark_info.version,
        "network": ark_info.network.to_string(),
        "server_pubkey": ark_info.server_pubkey.to_string(),
        "server_pubkey_source": ark_info.source,
        "ark_contract_address": ark_address.to_string(),
        "ark_contract_script": script_pubkey.as_bytes().to_lower_hex_string(),
        "ark_tap_tree": tap_tree,
        "claim_tapleaf_script": vhtlc.claim_script().as_bytes().to_lower_hex_string(),
        "refund_tapleaf_script": vhtlc.refund_script().as_bytes().to_lower_hex_string(),
        "hash_op": "OP_SHA256",
        "preimage_hash_sha256": preimage_hash.clone(),
        "ark_claim_pubkey": claim_pubkey.to_string(),
        "ark_refund_pubkey": refund_pubkey.to_string(),
        "ark_refund_time": refund_time,
        "asset_id": args.ark_asset_id.clone(),
        "asset_amount": args.ark_asset_amount.clone(),
        "vtxo_sats": args.ark_vtxo_sats,
    });
    write_json(&output_dir.join("ark-vhtlc.json"), &ark_vhtlc)?;

    let pack = json!({
        "status": "ok",
        "generated_at_unix": now,
        "direction": args.direction.as_str(),
        "summary": "Two native locks share one SHA256 preimage hash. The Ark side is a concrete Taproot VHTLC. The RGB side is shown as the current RGB-node hodl-invoice lock plus a direct RGB contract sketch.",
        "middle_lightning_removed": true,
        "current_rgb_caveat": "The live RGB-node path still uses RGB Lightning channel state. The direct RGB contract target requires a custom RGB schema/interface or future Contractum compiler support.",
        "shared_secret": {
            "preimage": preimage.clone(),
            "preimage_hash_sha256": preimage_hash.clone(),
            "hash": "SHA256"
        },
        "timeouts": timeout_ordering(&args.direction, refund_time, args.rgb_expiry_sec, now),
        "ark_side": ark_vhtlc,
        "rgb_side": {
            "current_node_lock": {
                "primitive": "rgb-lightning-node hodl invoice",
                "rgb_node_url": args.rgb_node_url.clone(),
                "request_file": "rgb-node-hodl-invoice-request.json",
                "live_response_file": if args.live_rgb_invoice { Value::String("rgb-node-hodl-invoice-response.json".to_string()) } else { Value::Null },
                "live_response": rgb_live_invoice,
                "claim_endpoint": "POST /claimhodlinvoice",
                "claim_body": {
                    "payment_hash": preimage_hash.clone(),
                    "payment_preimage": preimage.clone()
                }
            },
            "direct_contract_target": {
                "status": "design_sketch_not_compiled",
                "contractum_file": "rgb-htlc-draft.contractum",
                "needed_work": [
                    "custom RGB schema/interface with Lock, Claim, and Refund operations",
                    "client-side validation rules for SHA256(preimage) and timeout/refund branch",
                    "consignment exchange and acceptance flow for the RGB HTLC state transition"
                ],
                "reason": "RGB20 transfers support asset movement, but hashlock/timelock enforcement needs schema logic or RGB Lightning channel HTLC logic."
            }
        },
        "flow": flow_steps(&args.direction),
        "references": [
            "https://rgb.tech/program/",
            "https://rgb.tech/program/contractum/#basics",
            "https://rgb.tech/power-user/#contract",
            "https://rgb.tech/docs/#api"
        ],
        "files": [
            "contract-pack.json",
            "ark-vhtlc.json",
            "rgb-node-hodl-invoice-request.json",
            "rgb-htlc-draft.contractum",
            "README.md"
        ]
    });

    write_json(&output_dir.join("contract-pack.json"), &pack)?;
    fs::write(output_dir.join("README.md"), readme(&args, &pack))
        .context("writing artifact README")?;

    println!("{}", output_dir.display());
    Ok(())
}

#[derive(Debug)]
struct Args {
    direction: Direction,
    output_dir: Option<PathBuf>,
    preimage: Option<String>,
    preimage_hash: Option<String>,
    ark_server_url: String,
    ark_network: Network,
    ark_server_pubkey: Option<String>,
    ark_claim_pubkey: Option<String>,
    ark_refund_pubkey: Option<String>,
    ark_refund_time: Option<i64>,
    ark_asset_id: String,
    ark_asset_amount: String,
    ark_vtxo_sats: u64,
    rgb_node_url: String,
    rgb_asset_id: String,
    rgb_asset_amount: u64,
    rgb_amt_msat: u64,
    rgb_expiry_sec: u64,
    live_rgb_invoice: bool,
    require_ark: bool,
}

impl Args {
    fn parse() -> anyhow::Result<Self> {
        let mut args = Self {
            direction: Direction::RgbToArk,
            output_dir: None,
            preimage: None,
            preimage_hash: None,
            ark_server_url: env_string("ARK_LND_PROVIDER_ARK_SERVER_URL", DEFAULT_ARK_SERVER_URL),
            ark_network: parse_network(&env_string("ARK_LND_PROVIDER_ARK_NETWORK", "mutinynet"))?,
            ark_server_pubkey: env::var("RGB_ARK_SWAP_ARK_SERVER_PUBKEY").ok(),
            ark_claim_pubkey: env::var("RGB_ARK_SWAP_ARK_CLAIM_PUBKEY").ok(),
            ark_refund_pubkey: env::var("RGB_ARK_SWAP_ARK_REFUND_PUBKEY").ok(),
            ark_refund_time: env_i64("RGB_ARK_SWAP_ARK_REFUND_TIME"),
            ark_asset_id: env_string("BRIDGE_TEST_ARK_ASSET_ID", "<ark_asset_id>"),
            ark_asset_amount: env_string("BRIDGE_TEST_ARK_ASSET_AMOUNT", "100"),
            ark_vtxo_sats: env_u64("RGB_ARK_SWAP_ARK_VTXO_SATS", 1000),
            rgb_node_url: env_string("RGB_ARK_SWAP_RGB_NODE_URL", DEFAULT_RGB_NODE_URL),
            rgb_asset_id: env_string("BRIDGE_TEST_RGB_ASSET_ID", "<rgb_asset_id>"),
            rgb_asset_amount: env_u64("BRIDGE_TEST_RGB_ASSET_AMOUNT", DEFAULT_RGB_AMOUNT),
            rgb_amt_msat: env_u64("RGB_ARK_SWAP_RGB_AMT_MSAT", DEFAULT_RGB_MSAT),
            rgb_expiry_sec: env_u64("RGB_ARK_SWAP_RGB_EXPIRY_SEC", DEFAULT_EXPIRY_SEC),
            live_rgb_invoice: false,
            require_ark: false,
        };

        let mut iter = env::args().skip(1);
        while let Some(arg) = iter.next() {
            match arg.as_str() {
                "-h" | "--help" => {
                    print_help();
                    std::process::exit(0);
                }
                "--direction" => args.direction = Direction::parse(&next_arg(&mut iter, &arg)?)?,
                "--output-dir" => args.output_dir = Some(PathBuf::from(next_arg(&mut iter, &arg)?)),
                "--preimage" => {
                    args.preimage = Some(normalize_hex32("preimage", &next_arg(&mut iter, &arg)?)?)
                }
                "--preimage-hash" => {
                    args.preimage_hash = Some(normalize_hex32(
                        "preimage_hash",
                        &next_arg(&mut iter, &arg)?,
                    )?)
                }
                "--ark-server-url" => args.ark_server_url = next_arg(&mut iter, &arg)?,
                "--ark-network" => args.ark_network = parse_network(&next_arg(&mut iter, &arg)?)?,
                "--ark-server-pubkey" => args.ark_server_pubkey = Some(next_arg(&mut iter, &arg)?),
                "--ark-claim-pubkey" => args.ark_claim_pubkey = Some(next_arg(&mut iter, &arg)?),
                "--ark-refund-pubkey" => args.ark_refund_pubkey = Some(next_arg(&mut iter, &arg)?),
                "--ark-refund-time" => {
                    args.ark_refund_time = Some(
                        next_arg(&mut iter, &arg)?
                            .parse()
                            .context("parsing --ark-refund-time")?,
                    )
                }
                "--ark-asset-id" => args.ark_asset_id = next_arg(&mut iter, &arg)?,
                "--ark-asset-amount" => args.ark_asset_amount = next_arg(&mut iter, &arg)?,
                "--ark-vtxo-sats" => {
                    args.ark_vtxo_sats = next_arg(&mut iter, &arg)?
                        .parse()
                        .context("parsing --ark-vtxo-sats")?
                }
                "--rgb-node-url" => args.rgb_node_url = next_arg(&mut iter, &arg)?,
                "--rgb-asset-id" => args.rgb_asset_id = next_arg(&mut iter, &arg)?,
                "--rgb-asset-amount" => {
                    args.rgb_asset_amount = next_arg(&mut iter, &arg)?
                        .parse()
                        .context("parsing --rgb-asset-amount")?
                }
                "--rgb-amt-msat" => {
                    args.rgb_amt_msat = next_arg(&mut iter, &arg)?
                        .parse()
                        .context("parsing --rgb-amt-msat")?
                }
                "--rgb-expiry-sec" => {
                    args.rgb_expiry_sec = next_arg(&mut iter, &arg)?
                        .parse()
                        .context("parsing --rgb-expiry-sec")?
                }
                "--live-rgb-invoice" => args.live_rgb_invoice = true,
                "--require-ark" => args.require_ark = true,
                _ => return Err(anyhow!("unknown argument: {arg}")),
            }
        }

        Ok(args)
    }
}

#[derive(Clone, Copy, Debug)]
enum Direction {
    RgbToArk,
    ArkToRgb,
}

impl Direction {
    fn parse(value: &str) -> anyhow::Result<Self> {
        match value {
            "rgb-to-ark" | "rgb-asset-to-ark-asset" => Ok(Self::RgbToArk),
            "ark-to-rgb" | "ark-asset-to-rgb-asset" => Ok(Self::ArkToRgb),
            _ => Err(anyhow!("direction must be rgb-to-ark or ark-to-rgb")),
        }
    }

    fn as_str(self) -> &'static str {
        match self {
            Self::RgbToArk => "rgb-to-ark",
            Self::ArkToRgb => "ark-to-rgb",
        }
    }
}

#[derive(Debug)]
struct ArkInfo {
    version: Option<String>,
    network: Network,
    server_pubkey: XOnlyPublicKey,
    source: String,
    generated_demo_key: bool,
}

async fn ark_info(args: &Args) -> anyhow::Result<ArkInfo> {
    if let Some(pubkey) = args.ark_server_pubkey.as_deref() {
        return Ok(ArkInfo {
            version: None,
            network: args.ark_network,
            server_pubkey: parse_xonly_pubkey(pubkey, "ark_server_pubkey")?,
            source: "argument_or_environment".to_string(),
            generated_demo_key: false,
        });
    }

    match fetch_ark_info(&args.ark_server_url).await {
        Ok(info) => Ok(info),
        Err(err) if args.require_ark => Err(err),
        Err(_) => Ok(ArkInfo {
            version: None,
            network: args.ark_network,
            server_pubkey: generated_xonly_pubkey(),
            source: "generated_demo_key_arkd_not_reached".to_string(),
            generated_demo_key: true,
        }),
    }
}

async fn fetch_ark_info(url: &str) -> anyhow::Result<ArkInfo> {
    let mut ark = ark_grpc::Client::new(url.to_string());
    timeout(Duration::from_secs(5), ark.connect())
        .await
        .context("timed out connecting to Ark gRPC")?
        .map_err(anyhow::Error::from)
        .context("connecting to Ark gRPC")?;
    let info = timeout(Duration::from_secs(5), ark.get_info())
        .await
        .context("timed out fetching Ark info")?
        .map_err(anyhow::Error::from)
        .context("fetching Ark info")?;

    Ok(ArkInfo {
        version: Some(info.version),
        network: info.network,
        server_pubkey: info.signer_pk.x_only_public_key().0,
        source: "arkd_get_info".to_string(),
        generated_demo_key: false,
    })
}

async fn create_rgb_hodl_invoice(
    args: &Args,
    request: &Value,
    output_dir: &Path,
) -> anyhow::Result<Value> {
    let url = format!("{}/lninvoice", args.rgb_node_url.trim_end_matches('/'));
    let response = reqwest::Client::new()
        .post(&url)
        .json(request)
        .send()
        .await
        .context("creating RGB hodl invoice")?;
    let status = response.status();
    let text = response.text().await.context("reading RGB response body")?;
    let body = serde_json::from_str::<Value>(&text).unwrap_or_else(|_| json!({ "raw": text }));
    let wrapped = json!({
        "url": url,
        "status": status.as_u16(),
        "body": body,
    });
    write_json(
        &output_dir.join("rgb-node-hodl-invoice-response.json"),
        &wrapped,
    )?;
    if !status.is_success() {
        return Err(anyhow!("RGB node returned HTTP {}", status));
    }
    Ok(wrapped)
}

struct Sha256Vhtlc {
    claim_pubkey: XOnlyPublicKey,
    refund_pubkey: XOnlyPublicKey,
    server_pubkey: XOnlyPublicKey,
    preimage_hash: [u8; 32],
    refund_time: i64,
}

impl Sha256Vhtlc {
    fn new(
        claim_pubkey: XOnlyPublicKey,
        refund_pubkey: XOnlyPublicKey,
        server_pubkey: XOnlyPublicKey,
        preimage_hash: [u8; 32],
        refund_time: i64,
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
        })
    }

    fn claim_script(&self) -> ScriptBuf {
        ScriptBuf::builder()
            .push_opcode(OP_SHA256)
            .push_slice(self.preimage_hash)
            .push_opcode(OP_EQUAL)
            .push_opcode(OP_VERIFY)
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

    fn scripts(&self) -> Vec<ScriptBuf> {
        vec![self.claim_script(), self.refund_script()]
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
                .add_leaf(1, script)
                .map_err(|err| anyhow!("adding VHTLC taproot leaf: {err}"))?;
        }

        builder
            .finalize(&secp, internal_key)
            .map_err(|_| anyhow!("failed to finalize VHTLC taproot tree"))
    }
}

fn flow_steps(direction: &Direction) -> Vec<Value> {
    match direction {
        Direction::RgbToArk => vec![
            json!("RGB asset holder and Ark asset holder agree on H = SHA256(P)."),
            json!("RGB side locks asset movement to H through the RGB node hodl invoice, or through the direct RGB HTLC schema target."),
            json!("Ark side funds the Taproot VHTLC carrying the Ark asset with the same H."),
            json!("Ark claimant spends the Ark VHTLC claim path with P."),
            json!("The revealed P claims the RGB hodl invoice or RGB direct-contract claim branch."),
        ],
        Direction::ArkToRgb => vec![
            json!("RGB asset side publishes H = SHA256(P) for the requested RGB asset transfer."),
            json!("Ark asset holder funds the Ark VHTLC with the same H."),
            json!("RGB side completes the asset transfer only after the Ark VHTLC is verified."),
            json!("RGB claim reveals P."),
            json!("The revealed P claims the Ark VHTLC claim path."),
        ],
    }
}

fn timeout_ordering(
    direction: &Direction,
    ark_refund_time: i64,
    rgb_expiry_sec: u64,
    now: u64,
) -> Value {
    let rgb_expiry = now + rgb_expiry_sec;
    match direction {
        Direction::RgbToArk => json!({
            "rule": "now < ark_refund_time < rgb_expiry",
            "now": now,
            "ark_refund_time": ark_refund_time,
            "rgb_expiry": rgb_expiry,
            "valid_with_current_inputs": now < ark_refund_time as u64 && (ark_refund_time as u64) < rgb_expiry,
        }),
        Direction::ArkToRgb => json!({
            "rule": "now < rgb_expiry < ark_refund_time",
            "now": now,
            "rgb_expiry": rgb_expiry,
            "ark_refund_time": ark_refund_time,
            "valid_with_current_inputs": now < rgb_expiry && rgb_expiry < ark_refund_time as u64,
        }),
    }
}

fn contractum_draft(args: &Args, preimage_hash: &str, refund_time: i64) -> String {
    format!(
        r#"-- RGB HTLC draft for review. This is not compiled by this binary.
-- Contractum is documented as work-in-progress; this file is a shareable target shape.
-- Shared hash: {preimage_hash}
-- RGB asset: {rgb_asset_id}
-- RGB amount: {rgb_asset_amount}
-- Refund time: {refund_time}

types Swap
   data Sha256 :: bytes [Byte^32]
   data UnixTime :: seconds U64
   data XonlyPk :: bytes [Byte^32]

schema RgbArkHtlc
   owned Asset :: Zk64
   owned LockedAsset :: Zk64

   global PaymentHash :: Swap.Sha256
   global RefundTime :: Swap.UnixTime
   global ClaimKey :: Swap.XonlyPk
   global RefundKey :: Swap.XonlyPk

   genesis :: PaymentHash, RefundTime, ClaimKey, RefundKey

   -- Move spendable RGB state into a hashlocked state.
   op Lock :: spent {{Asset}} -> locked [LockedAsset]
      assert sum spent == sum locked

   -- Release the locked state when the SHA256 preimage is revealed.
   op Claim :: spent {{LockedAsset}}, proof preimage Bytes -> received [Asset]
      assert Hash.sha256 preimage == PaymentHash
      assert sum spent == sum received

   -- Return the locked state after the timeout.
   op Refund :: spent {{LockedAsset}} -> returned [Asset]
      assert Time.now >= RefundTime
      assert sum spent == sum returned

interface HtlcFungibleSwap:
   global PaymentHash -> Sha256
   global RefundTime -> UnixTime
   owned Asset :: Zk64
   owned LockedAsset :: Zk64
   op Lock :: {{Asset}} -> [LockedAsset]
   op Claim :: {{LockedAsset}} -> [Asset]
   op Refund :: {{LockedAsset}} -> [Asset]
"#,
        rgb_asset_id = args.rgb_asset_id,
        rgb_asset_amount = args.rgb_asset_amount,
    )
}

fn readme(args: &Args, pack: &Value) -> String {
    let hash = pack["shared_secret"]["preimage_hash_sha256"]
        .as_str()
        .unwrap_or("");
    format!(
        r#"# RGB/Ark Contract Swap Artifact

This folder is a small, shareable contract pack for a same-hash RGB/Ark swap.

- Shared hash: `{hash}`
- Direction: `{}`
- Ark contract: `ark-vhtlc.json`
- RGB current lock request: `rgb-node-hodl-invoice-request.json`
- RGB direct-contract sketch: `rgb-htlc-draft.contractum`

The Ark side is an actual Taproot VHTLC script set. The RGB side is split into
two views: the current RGB node hodl-invoice path, and the direct RGB contract
target that would require custom schema/interface work.

Useful inspection fields:

- `ark_contract_address`
- `claim_tapleaf_script`
- `refund_tapleaf_script`
- `preimage_hash_sha256`
- `rgb_side.direct_contract_target`

References:

- https://rgb.tech/program/
- https://rgb.tech/program/contractum/#basics
- https://rgb.tech/power-user/#contract
- https://rgb.tech/docs/#api
"#,
        args.direction.as_str()
    )
}

fn write_json(path: &Path, value: &Value) -> anyhow::Result<()> {
    let text = serde_json::to_string_pretty(value).context("serializing json")?;
    fs::write(path, format!("{text}\n")).with_context(|| format!("writing {}", path.display()))
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

fn decode_hex32_array(label: &str, value: &str) -> anyhow::Result<[u8; 32]> {
    let bytes = hex::decode(value).with_context(|| format!("{label} must be hex"))?;
    if bytes.len() != 32 {
        return Err(anyhow!("{label} must be 32 bytes"));
    }
    bytes
        .try_into()
        .map_err(|_| anyhow!("{label} must be 32 bytes"))
}

fn normalize_hex32(label: &str, value: &str) -> anyhow::Result<String> {
    let bytes = decode_hex32_array(label, value)?;
    Ok(bytes.as_slice().to_lower_hex_string())
}

fn sha256_hex(bytes: &[u8]) -> String {
    let digest = Sha256::digest(bytes);
    digest[..].to_lower_hex_string()
}

fn random_hex32() -> String {
    let mut bytes = [0u8; 32];
    OsRng.fill_bytes(&mut bytes);
    bytes.as_slice().to_lower_hex_string()
}

fn generated_xonly_pubkey() -> XOnlyPublicKey {
    let secp = Secp256k1::new();
    loop {
        let mut bytes = [0u8; 32];
        OsRng.fill_bytes(&mut bytes);
        if let Ok(secret) = SecretKey::from_slice(&bytes) {
            return SecpPublicKey::from_secret_key(&secp, &secret)
                .x_only_public_key()
                .0;
        }
    }
}

fn unix_now() -> anyhow::Result<u64> {
    Ok(SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .context("system clock is before unix epoch")?
        .as_secs())
}

fn parse_network(value: &str) -> anyhow::Result<Network> {
    match value {
        "bitcoin" | "mainnet" => Ok(Network::Bitcoin),
        "testnet" => Ok(Network::Testnet),
        "testnet4" => Ok(Network::Testnet4),
        "signet" | "mutinynet" => Ok(Network::Signet),
        "regtest" => Ok(Network::Regtest),
        _ => Err(anyhow!("unsupported network: {value}")),
    }
}

fn env_string(key: &str, default: &str) -> String {
    env::var(key).unwrap_or_else(|_| default.to_string())
}

fn env_u64(key: &str, default: u64) -> u64 {
    env::var(key)
        .ok()
        .and_then(|value| value.parse().ok())
        .unwrap_or(default)
}

fn env_i64(key: &str) -> Option<i64> {
    env::var(key).ok().and_then(|value| value.parse().ok())
}

fn next_arg(iter: &mut impl Iterator<Item = String>, flag: &str) -> anyhow::Result<String> {
    iter.next()
        .ok_or_else(|| anyhow!("{flag} requires a value"))
}

fn print_help() {
    println!(
        r#"rgb-ark-contract-swap

Generate a shareable RGB/Ark same-hash contract pack.

Options:
  --direction rgb-to-ark|ark-to-rgb
  --output-dir <path>
  --preimage <32-byte-hex>
  --preimage-hash <32-byte-hex>
  --ark-server-url <url>
  --ark-network bitcoin|testnet|testnet4|signet|mutinynet|regtest
  --ark-server-pubkey <xonly-or-compressed-pubkey>
  --ark-claim-pubkey <xonly-or-compressed-pubkey>
  --ark-refund-pubkey <xonly-or-compressed-pubkey>
  --ark-refund-time <unix-seconds>
  --ark-asset-id <id>
  --ark-asset-amount <amount>
  --ark-vtxo-sats <sats>
  --rgb-node-url <url>
  --rgb-asset-id <id>
  --rgb-asset-amount <amount>
  --rgb-amt-msat <msat>
  --rgb-expiry-sec <seconds>
  --live-rgb-invoice
  --require-ark
"#
    );
}
