#[macro_use]
extern crate amplify;
#[macro_use]
extern crate strict_types;
extern crate alloc;

use std::env;
use std::fs;
use std::path::{Path, PathBuf};

use aluvm::{CoreConfig, Lib, LibSite};
use amplify::num::u256;
use anyhow::{anyhow, bail, Context, Result};
use commit_verify::Digest;
use hypersonic::{
    Api, CallState, CellAddr, CellLock, Consensus, Identity, IssueParams, Issuer, OwnedApi,
    Semantics, StateArithm, StateBuilder, StateConvertor, StateValue,
};
use serde::Serialize;
use sha2::Sha256 as StdSha256;
use sonic_persist_fs::LedgerDir;
use strict_types::stl::std_stl;
use strict_types::{LibBuilder, SemId, SymbolicSys, SystemBuilder, TypeLib, TypeSystem};
use ultrasonic::aluvm::FIELD_ORDER_SECP;
use ultrasonic::{fe256, AuthToken, Codex};

const DEFAULT_AMOUNT: u64 = 100;
const DEFAULT_SECRET: u64 = 48;
const DEFAULT_WRONG_SECRET: u64 = 47;
const DEFAULT_OUT_DIR: &str = "state/tests/rgb-htlc-kit";
const HASHLOCK_MODE_WITNESS_EQUALITY: &str = "witness-equality";
const HASHLOCK_MODE_ARK_SHA256_STUB: &str = "ark-sha256-stub";
const CONTRACT_NAME: &str = "RgbArkHtlc";
const ISSUER_FILE: &str = "RgbArkHtlc.issuer";
const METADATA_FILE: &str = "rgb-htlc-kit.json";
const IMPORT_SCRIPT_FILE: &str = "rgb-wallet-import.sh";

fn main() -> Result<()> {
    let args = Args::parse(env::args().skip(1))?;

    if args.help {
        print_help();
        return Ok(());
    }

    fs::create_dir_all(&args.out_dir)
        .with_context(|| format!("creating {}", args.out_dir.display()))?;

    let kit = HtlcKit::new();
    let issuer = kit.issuer()?;
    let issuer_path = args.out_dir.join(ISSUER_FILE);
    issuer
        .save(&issuer_path)
        .with_context(|| format!("saving {}", issuer_path.display()))?;

    let demo = run_demo(&args, &kit, issuer)?;
    write_import_script(&args.out_dir)?;

    let metadata = Metadata {
        summary: "Real RGB/Sonic issuer plus local witness-locked owned-state demo",
        enforced_today: &[
            "The issuer is built with the published Sonic/RGB issuer and codex types.",
            "The contract ledger is created with hypersonic and sonic-persist-fs.",
            "The locked RGB owned state carries a real CellLock script.",
            "A wrong witness is rejected by RGB validation before the correct claim succeeds.",
        ],
        not_enforced_yet: &[
            "The RGB VM used here has no SHA256 instruction, so it cannot yet verify the same SHA256(P) used by an Ark VHTLC.",
            "The timeout/refund branch is documented as protocol work, not enforced by this first artifact.",
            "The stock rgb-wallet transfer helper currently creates owned outputs with lock: None, so locked HTLC operations are driven by this small binary.",
            "The ark-sha256-stub hashlock mode is wired as an explicit handoff point and intentionally errors until the VM hash primitive exists.",
        ],
        rgb_wallet_commands: &[
            "rgb import RgbArkHtlc.issuer",
            "rgb contracts --issuers",
        ],
        hashlock_mode: args.hashlock_mode.as_str(),
        issuer_file: ISSUER_FILE,
        rgb_wallet_import_script: IMPORT_SCRIPT_FILE,
        demo,
    };
    let metadata_path = args.out_dir.join(METADATA_FILE);
    fs::write(&metadata_path, serde_json::to_string_pretty(&metadata)?)
        .with_context(|| format!("writing {}", metadata_path.display()))?;

    println!("wrote {}", issuer_path.display());
    println!("wrote {}", metadata_path.display());
    println!(
        "wrong witness rejected: {}",
        metadata.demo.wrong_witness_rejected
    );
    println!("claim opid: {}", metadata.demo.claim_opid);
    Ok(())
}

fn run_demo(args: &Args, kit: &HtlcKit, issuer: Issuer) -> Result<DemoMetadata> {
    let seed = &[0xCA; 30][..];
    let mut auth_seed = commit_verify::Sha256::digest(seed);
    let mut next_auth = || -> AuthToken {
        auth_seed = commit_verify::Sha256::digest(&*auth_seed);
        let mut buf = [0u8; 30];
        buf.copy_from_slice(&auth_seed[..30]);
        AuthToken::from(buf)
    };

    let mut issue = IssueParams::new_testnet(issuer.codex_id(), CONTRACT_NAME, Consensus::None);
    issue.push_owned_unlocked("amount", next_auth(), svnum!(args.amount));
    let articles = issuer.issue(issue);
    let genesis_opid = articles.genesis_opid();
    let contract_id = articles.contract_id();

    let hashlock_stub = ArkSha256HashlockStub::from_secret(args.secret);
    if matches!(args.hashlock_mode, HashlockMode::ArkSha256Stub) {
        bail!(
            "ark-sha256-stub selected: RGB SHA256 lock execution is intentionally stubbed. \
             Intended Ark hash is {}, produced from preimage {}. Next step: add a VM/runtime \
             primitive that loads CellLock.aux plus the witness bytes and verifies SHA256(preimage) == aux.",
            hashlock_stub.hash_hex,
            hashlock_stub.preimage_hex
        );
    }

    let contract_path = args.out_dir.join(format!("{CONTRACT_NAME}.contract"));
    if contract_path.exists() {
        bail!(
            "{} already exists; remove it or choose a fresh --out directory",
            contract_path.display()
        );
    }
    fs::create_dir_all(&contract_path)
        .with_context(|| format!("creating {}", contract_path.display()))?;

    let mut ledger = LedgerDir::new(articles, contract_path.clone())
        .with_context(|| format!("creating RGB ledger {}", contract_path.display()))?;

    let genesis_addr = only_amount_addr(&ledger)?;
    let lock = witness_equality_cell_lock(kit);
    let locked_auth = AuthToken::from(fe256::from(args.secret));
    let lock_opid = ledger
        .start_deed("lock")
        .using(genesis_addr)
        .assign("amount", locked_auth, svnum!(args.amount), Some(lock))
        .commit()
        .context("locking RGB owned state")?;
    let locked_addr = CellAddr::new(lock_opid, 0);

    let wrong_result = ledger
        .start_deed("claim")
        .satisfying(locked_addr, "amount", svnum!(args.wrong_secret))
        .assign("amount", next_auth(), svnum!(args.amount), None)
        .commit();
    let wrong_witness_rejected = wrong_result.is_err();
    let wrong_witness_error = wrong_result.err().map(|err| err.to_string());
    if !wrong_witness_rejected {
        bail!("wrong witness unexpectedly validated");
    }

    let claim_opid = ledger
        .start_deed("claim")
        .satisfying(locked_addr, "amount", svnum!(args.secret))
        .assign("amount", next_auth(), svnum!(args.amount), None)
        .commit()
        .context("claiming locked RGB owned state with the correct witness")?;

    let mut ark_preimage = [0u8; 32];
    ark_preimage[..8].copy_from_slice(&args.secret.to_le_bytes());
    let ark_sha256 = <StdSha256 as sha2::Digest>::digest(ark_preimage);

    Ok(DemoMetadata {
        contract_dir: path_string(&contract_path),
        contract_id: contract_id.to_string(),
        genesis_opid: genesis_opid.to_string(),
        genesis_addr: genesis_addr.to_string(),
        lock_opid: lock_opid.to_string(),
        locked_addr: locked_addr.to_string(),
        claim_opid: claim_opid.to_string(),
        amount: args.amount,
        witness_secret: args.secret,
        wrong_witness: args.wrong_secret,
        wrong_witness_rejected,
        wrong_witness_error,
        ark_sha256_demo_hash: hex::encode(ark_sha256),
        hashlock_mode: args.hashlock_mode.as_str().to_owned(),
        ark_sha256_hashlock_stub: hashlock_stub,
    })
}

fn witness_equality_cell_lock(kit: &HtlcKit) -> CellLock {
    CellLock {
        aux: StateValue::None,
        script: Some(LibSite::new(kit.validation_lib_id, 1)),
    }
}

fn only_amount_addr(ledger: &LedgerDir) -> Result<CellAddr> {
    let owned = ledger
        .state()
        .main
        .owned
        .get("amount")
        .ok_or_else(|| anyhow!("contract has no amount owned state"))?;
    if owned.len() != 1 {
        bail!("expected one amount owned state, got {}", owned.len());
    }
    owned
        .keys()
        .next()
        .copied()
        .ok_or_else(|| anyhow!("contract has no amount owned state"))
}

fn write_import_script(out_dir: &Path) -> Result<()> {
    let script = r#"#!/usr/bin/env bash
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${RGB:=rgb}"

"$RGB" import "$dir/RgbArkHtlc.issuer"
"$RGB" contracts --issuers
"#;
    let path = out_dir.join(IMPORT_SCRIPT_FILE);
    fs::write(&path, script).with_context(|| format!("writing {}", path.display()))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mut perms = fs::metadata(&path)?.permissions();
        perms.set_mode(0o755);
        fs::set_permissions(&path, perms)?;
    }
    Ok(())
}

fn path_string(path: &Path) -> String {
    path.to_string_lossy().into_owned()
}

struct HtlcKit {
    validation_lib: Lib,
    validation_lib_id: aluvm::LibId,
}

impl HtlcKit {
    fn new() -> Self {
        let validation_lib = validation_lib();
        let validation_lib_id = validation_lib.lib_id();
        Self {
            validation_lib,
            validation_lib_id,
        }
    }

    fn codex(&self) -> Codex {
        Codex {
            name: tiny_s!("RgbArkHtlc"),
            developer: Identity::default(),
            version: default!(),
            timestamp: 1_738_000_000,
            features: none!(),
            field_order: FIELD_ORDER_SECP,
            input_config: CoreConfig::default(),
            verification_config: CoreConfig::default(),
            verifiers: tiny_bmap! {
                0 => LibSite::new(self.validation_lib_id, 0),
                1 => LibSite::new(self.validation_lib_id, 0),
                2 => LibSite::new(self.validation_lib_id, 0),
            },
        }
    }

    fn api(&self) -> Api {
        let types = htlc_types::HtlcTypes::new();
        let codex = self.codex();

        Api {
            codex_id: codex.codex_id(),
            conforms: none!(),
            default_call: Some(CallState::with("transfer", "amount")),
            global: none!(),
            owned: tiny_bmap! {
                vname!("amount") => OwnedApi {
                    sem_id: types.get("RgbHtlc.Amount"),
                    arithmetics: StateArithm::Fungible,
                    convertor: StateConvertor::TypedFieldEncoder(u256::ZERO),
                    builder: StateBuilder::TypedFieldEncoder(u256::ZERO),
                    witness_sem_id: types.get("RgbHtlc.Preimage"),
                    witness_builder: StateBuilder::TypedFieldEncoder(u256::ONE),
                }
            },
            aggregators: none!(),
            verifiers: tiny_bmap! {
                vname!("issue") => 0,
                vname!("lock") => 1,
                vname!("claim") => 2,
                vname!("transfer") => 2,
            },
            errors: Default::default(),
        }
    }

    fn issuer(&self) -> Result<Issuer> {
        let types = htlc_types::HtlcTypes::new();
        let codex = self.codex();
        let semantics = Semantics {
            version: 0,
            default: self.api(),
            custom: none!(),
            codex_libs: small_bset![self.validation_lib.clone()],
            api_libs: none!(),
            types: types.type_system(),
        };
        Issuer::new(codex, semantics).map_err(|err| anyhow!(err.to_string()))
    }
}

fn validation_lib() -> Lib {
    let code = ultrasonic::uasm! {
        stop;

        ldi     auth;
        mov     E1, EA;

        ldi     witness;
        eq      EB, E1;
        put     E8, 1;
        chk     CO;

        test    EC;
        not     CO;
        put     E8, 2;
        chk     CO;

        test    ED;
        not     CO;
        put     E8, 3;
        chk     CO;

        stop;
    };
    Lib::assemble(&code).expect("valid AluVM validation lib")
}

#[derive(Debug)]
struct Args {
    out_dir: PathBuf,
    amount: u64,
    secret: u64,
    wrong_secret: u64,
    hashlock_mode: HashlockMode,
    help: bool,
}

impl Args {
    fn parse(args: impl IntoIterator<Item = String>) -> Result<Self> {
        let mut parsed = Args {
            out_dir: PathBuf::from(DEFAULT_OUT_DIR),
            amount: DEFAULT_AMOUNT,
            secret: DEFAULT_SECRET,
            wrong_secret: DEFAULT_WRONG_SECRET,
            hashlock_mode: HashlockMode::WitnessEquality,
            help: false,
        };

        let mut args = args.into_iter();
        while let Some(arg) = args.next() {
            match arg.as_str() {
                "-h" | "--help" => parsed.help = true,
                "--out" => parsed.out_dir = PathBuf::from(take_value("--out", &mut args)?),
                "--amount" => parsed.amount = parse_u64("--amount", &mut args)?,
                "--secret" => parsed.secret = parse_u64("--secret", &mut args)?,
                "--wrong-secret" => parsed.wrong_secret = parse_u64("--wrong-secret", &mut args)?,
                "--hashlock-mode" => {
                    parsed.hashlock_mode =
                        HashlockMode::parse(&take_value("--hashlock-mode", &mut args)?)?
                }
                other => bail!("unknown argument '{other}'"),
            }
        }
        Ok(parsed)
    }
}

fn take_value(name: &str, args: &mut impl Iterator<Item = String>) -> Result<String> {
    args.next()
        .ok_or_else(|| anyhow!("missing value for {name}"))
}

fn parse_u64(name: &str, args: &mut impl Iterator<Item = String>) -> Result<u64> {
    take_value(name, args)?
        .parse()
        .with_context(|| format!("parsing {name}"))
}

fn print_help() {
    println!(
        "rgb-htlc-kit\n\n\
         Generates a real RGB/Sonic issuer and runs a local witness-locked owned-state demo.\n\n\
         Options:\n\
           --out DIR           Output directory [{DEFAULT_OUT_DIR}]\n\
           --amount SATS       Demo amount [{DEFAULT_AMOUNT}]\n\
           --secret N          Correct witness field value [{DEFAULT_SECRET}]\n\
           --wrong-secret N    Rejected witness field value [{DEFAULT_WRONG_SECRET}]\n\
           --hashlock-mode M   {HASHLOCK_MODE_WITNESS_EQUALITY} or {HASHLOCK_MODE_ARK_SHA256_STUB} [{HASHLOCK_MODE_WITNESS_EQUALITY}]\n\
           -h, --help          Show this help"
    );
}

#[derive(Copy, Clone, Debug)]
enum HashlockMode {
    WitnessEquality,
    ArkSha256Stub,
}

impl HashlockMode {
    fn parse(value: &str) -> Result<Self> {
        match value {
            HASHLOCK_MODE_WITNESS_EQUALITY => Ok(Self::WitnessEquality),
            HASHLOCK_MODE_ARK_SHA256_STUB => Ok(Self::ArkSha256Stub),
            other => bail!(
                "unknown --hashlock-mode '{other}', expected '{HASHLOCK_MODE_WITNESS_EQUALITY}' or '{HASHLOCK_MODE_ARK_SHA256_STUB}'"
            ),
        }
    }

    fn as_str(self) -> &'static str {
        match self {
            Self::WitnessEquality => HASHLOCK_MODE_WITNESS_EQUALITY,
            Self::ArkSha256Stub => HASHLOCK_MODE_ARK_SHA256_STUB,
        }
    }
}

#[derive(Serialize)]
struct Metadata<'a> {
    summary: &'a str,
    enforced_today: &'a [&'a str],
    not_enforced_yet: &'a [&'a str],
    rgb_wallet_commands: &'a [&'a str],
    hashlock_mode: &'a str,
    issuer_file: &'a str,
    rgb_wallet_import_script: &'a str,
    demo: DemoMetadata,
}

#[derive(Serialize)]
struct DemoMetadata {
    contract_dir: String,
    contract_id: String,
    genesis_opid: String,
    genesis_addr: String,
    lock_opid: String,
    locked_addr: String,
    claim_opid: String,
    amount: u64,
    witness_secret: u64,
    wrong_witness: u64,
    wrong_witness_rejected: bool,
    wrong_witness_error: Option<String>,
    ark_sha256_demo_hash: String,
    hashlock_mode: String,
    ark_sha256_hashlock_stub: ArkSha256HashlockStub,
}

#[derive(Clone, Serialize)]
struct ArkSha256HashlockStub {
    preimage_hex: String,
    hash_hex: String,
    intended_cell_lock_aux: String,
    intended_witness: String,
    execution_status: String,
    next_code_path: String,
}

impl ArkSha256HashlockStub {
    fn from_secret(secret: u64) -> Self {
        let mut preimage = [0u8; 32];
        preimage[..8].copy_from_slice(&secret.to_le_bytes());
        let hash = <StdSha256 as sha2::Digest>::digest(preimage);
        let preimage_hex = hex::encode(preimage);
        let hash_hex = hex::encode(hash);
        Self {
            preimage_hex: preimage_hex.clone(),
            hash_hex: hash_hex.clone(),
            intended_cell_lock_aux: format!("32-byte SHA256 hash in CellLock.aux: {hash_hex}"),
            intended_witness: format!("32-byte preimage witness: {preimage_hex}"),
            execution_status: "stubbed; current demo still uses witness-equality CellLock"
                .to_owned(),
            next_code_path:
                "replace witness_equality_cell_lock with SHA256(preimage) == CellLock.aux VM execution"
                    .to_owned(),
        }
    }
}

mod htlc_types {
    use super::*;

    pub const LIB_NAME_HTLC: &str = "RgbHtlc";

    #[derive(Copy, Clone, Ord, PartialOrd, Eq, PartialEq, Hash, Debug, Display, From)]
    #[display(inner)]
    #[derive(StrictType, StrictDumb, StrictEncode, StrictDecode)]
    #[strict_type(lib = LIB_NAME_HTLC)]
    pub struct Amount(u64);

    #[derive(Copy, Clone, Ord, PartialOrd, Eq, PartialEq, Hash, Debug, Display, From)]
    #[display(inner)]
    #[derive(StrictType, StrictDumb, StrictEncode, StrictDecode)]
    #[strict_type(lib = LIB_NAME_HTLC)]
    pub struct Preimage(u64);

    pub fn stl() -> TypeLib {
        LibBuilder::with(libname!(LIB_NAME_HTLC), [std_stl().to_dependency_types()])
            .transpile::<Amount>()
            .transpile::<Preimage>()
            .compile()
            .expect("invalid RGB HTLC type library")
    }

    #[derive(Debug)]
    pub struct HtlcTypes(SymbolicSys);

    impl HtlcTypes {
        pub fn new() -> Self {
            Self(
                SystemBuilder::new()
                    .import(std_stl())
                    .expect("std STL imports")
                    .import(stl())
                    .expect("HTLC STL imports")
                    .finalize()
                    .expect("HTLC type system finalizes"),
            )
        }

        pub fn type_system(&self) -> TypeSystem {
            let types = stl().types;
            let types = types.iter().map(|(tn, ty)| ty.sem_id_named(tn));
            self.0.as_types().extract(types).unwrap()
        }

        pub fn get(&self, name: &'static str) -> SemId {
            *self
                .0
                .resolve(name)
                .unwrap_or_else(|| panic!("type '{name}' is absent in the type library"))
        }
    }
}
