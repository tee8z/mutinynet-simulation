# Trustless Ark VTXO Swap Design

Status: design target for the next implementation. This is not production-ready
and should not be used to update proof claims until the acceptance criteria below
pass with fresh artifacts.

## Goal

Replace the current CLI-coordinated Ark asset send with a contract-bound VTXO
flow so the repo can truthfully prove both directions:

- RGB assets can buy Ark assets without trusting the Ark-side coordinator to send
  after receiving the RGB/LN payment.
- Ark assets can pay RGB assets without trusting the coordinator to pay the
  RGB/LN invoice after receiving Ark assets.

The trustless claim is scoped to an Arkade VTXO contract plus the normal Arkade
operator/signer assumptions. It is not a claim of production readiness, audited
contracts, or operator-free instant settlement.

## Current Baseline

The provider currently coordinates state and shells out to CLIs:

- `ln-to-ark` creates an LND hold invoice and stores a generated preimage.
- `ark-send` performs `ark send --to <recipient> --asset-id <id> --amount <n>`.
- `settle-ln` later settles the hold invoice with the stored preimage.
- `ark-to-ln` assumes the payer has already moved Ark assets to the provider,
  then the provider pays the RGB/LN invoice.

The test harness reflects that model:

- `rgb-asset-to-ark-asset` waits for the LND invoice to be `ACCEPTED`, calls
  `/ark-send`, then calls `/settle-ln`.
- `ark-asset-to-rgb-asset` first sends Ark assets from the taker wallet to the
  provider wallet, then asks the provider to pay the RGB/LN invoice.

That proves coordinated exchange, not atomic exchange. The provider can settle
or withhold actions according to local policy; Ark asset ownership is not bound
to the same secret that controls the RGB/LN leg.

## Ark Primitive To Use

Use an Arkade VTXO whose output script is a VHTLC carrying the Ark asset packet.
Public Arkade docs support the required building blocks:

- VTXOs are programmable Taproot outputs backed by presigned Bitcoin
  transactions, with collaborative and unilateral paths.
- Custom VTXO scripts can be built from Tapscript leaves and spent via
  `buildOffchainTx`, `SubmitTx`, and `FinalizeTx`.
- ArkService exposes `GetInfo`, `SubmitTx`, `FinalizeTx`, transaction streams,
  and related coordination RPCs.
- Arkade assets live on VTXOs and are transferred through standard Arkade
  transactions.

The contract must carry both the Ark asset id and amount and enough sats to be a
valid Arkade output. It must not be a normal wallet receive address owned by the
provider.

## Shared Secret

Each swap uses one 32-byte preimage `P`.

- Lightning/RGB BOLT11 uses `H = SHA256(P)` as the payment hash.
- The Ark VHTLC must require the same `P` on the claim path.
- Prefer an Ark script that checks `OP_SHA256 <H> OP_EQUALVERIFY` so the VTXO is
  bound directly to the BOLT11 payment hash.
- If the available Ark SDK VHTLC helper only supports `HASH160(P)`, the
  implementation must store both `SHA256(P)` and `HASH160(P)` and the harness
  must prove the revealed Ark witness preimage is byte-for-byte the same `P`
  that settles or completes the Lightning/RGB payment.

The provider must not know `P` before the party entitled to the Ark contract
claim reveals it. For `rgb-to-ark`, the buyer generates `P`. For `ark-to-rgb`,
the RGB invoice creator generates `P`.

## Contract Paths

The VHTLC needs explicit claim and refund branches.

Claim path:

- claimant signature
- Ark server/signer signature for the fast collaborative path
- hashlock check against `P`
- records the preimage in the Ark transaction witness so the other side can
  complete the RGB/LN leg

Claim fallback path:

- claimant signature
- hashlock check against `P`
- CSV exit delay from `GetInfo`
- no server signature

Refund path:

- refunder signature
- Ark server/signer signature for the fast collaborative path
- CLTV absolute refund time
- no preimage

Refund fallback path:

- refunder signature
- CLTV absolute refund time
- CSV exit delay from `GetInfo`
- no server signature

The public hashlock example documents claim paths but not a complete asset
VHTLC with sender refund. The implementation must either build this script
directly with SDK Tapscript primitives or add a reviewed SDK helper before the
proof can be called trustless.

## RGB Assets Buy Ark Assets

Roles:

- buyer: owns RGB asset, wants Ark asset, controls final Ark recipient key
- provider: owns Ark asset, receives the RGB/LN payment

Flow:

1. Buyer generates `P` and sends only `H = SHA256(P)` to the provider.
2. Provider creates an LND hold invoice using `H`. The provider does not store
   `P`.
3. Buyer pays that invoice through the RGB asset route. The invoice reaches
   `ACCEPTED`, so the RGB/LN value is locked but not settled.
4. Provider funds an Ark asset VHTLC:
   - claim key: buyer Ark key
   - refund key: provider Ark key
   - asset id and amount: quoted Ark asset
   - hashlock: `P`
5. Buyer verifies the contract script, asset id, amount, outpoint, and timeout.
6. Buyer claims the Ark VHTLC with `P`.
7. Provider watches the Ark claim, extracts `P`, verifies `SHA256(P) == H`, and
   settles the LND hold invoice.
8. If the buyer never claims, the provider refunds the Ark VHTLC after the Ark
   refund time and cancels or lets the LND hold invoice fail. The buyer's RGB/LN
   payment must not settle.

Timeout ordering:

```text
now < ark_refund_time < ln_htlc_final_expiry
```

Set `ark_refund_time` early enough that any Ark claim accepted before the refund
time leaves the provider a settlement margin before the Lightning/RGB HTLC
expires. The harness should reject claims observed after the refund time.

## Ark Assets Pay RGB Assets

Roles:

- payer: owns Ark asset, wants RGB asset
- provider/RGB maker: can deliver RGB asset and receives Ark asset if it reveals
  the RGB/LN preimage

Flow:

1. RGB maker creates the RGB/LN mapped invoice and owns `P`; the invoice exposes
   `H = SHA256(P)`.
2. Provider gives the Ark payer a VHTLC template:
   - claim key: provider Ark key
   - refund key: payer Ark key
   - asset id and amount: quoted Ark asset
   - hashlock: `P`
3. Payer funds the Ark asset VHTLC. The provider must verify it through
   ArkService/Indexer before paying the RGB/LN invoice.
4. Provider pays the RGB/LN invoice.
5. RGB maker delivers the RGB asset and claims the mapped invoice, revealing
   `P` through the Lightning payment result.
6. Provider verifies `SHA256(P) == H` and claims the Ark VHTLC with `P`.
7. If the RGB/LN invoice is not claimed and no `P` appears, the Ark payer refunds
   the Ark VHTLC after the refund time.

Timeout ordering:

```text
now < ln_invoice_expiry < ark_refund_time
```

Set `ark_refund_time` late enough that the provider has a claim margin after the
RGB/LN invoice can reveal `P`, but not so late that the payer is exposed to an
unbounded lock if no preimage appears.

## Required Provider Changes

The current provider API can stay as the outer shape, but the state machine must
change.

Required state:

- `preimage_hash_sha256`
- optional `preimage_hash_hash160`
- `preimage`, only after learned from Ark claim or Lightning payment result
- `ark_contract_address`
- `ark_contract_script`
- `ark_tap_tree`
- `ark_vtxo_outpoint`
- `ark_claim_pubkey`
- `ark_refund_pubkey`
- `ark_refund_time`
- `ln_expiry`
- `ark_claim_txid`
- `ark_refund_txid`
- proof fields for asset id, asset amount, and decoded witness preimage

Required API behavior:

- `ln-to-ark` must accept a caller-supplied payment hash and must not generate or
  return the preimage.
- `ark-to-ln` must return a VHTLC funding template instead of assuming the payer
  sends to the provider wallet.
- `ark-send` must be replaced by contract funding, claim, and refund actions.
- `pay-ln` must only run after the Ark VHTLC is verified for `ark-to-ln`.
- `settle-ln` for `ln-to-ark` must be driven by the observed Ark claim preimage,
  not by a stored provider preimage.
- Background watchers must subscribe to Ark transactions or poll the indexer for
  the contract script/outpoint, extract claim/refund outcomes, and advance swap
  state idempotently.

## Required Ark Capabilities

The implementation needs one of these integration paths:

- Direct Rust gRPC client generated from the Ark protobufs plus local script and
  PSBT construction, or
- a narrow Ark contract sidecar using the TypeScript SDK, called by the Rust
  provider, until equivalent Rust helpers exist.

Minimum Ark/SDK capabilities:

- `GetInfo` for server pubkey, exit delay, network, fee and amount limits, and
  checkpoint script data.
- Build a custom VHTLC `VtxoScript` with claim and refund paths.
- Transfer an Ark asset packet to the custom VHTLC address/script.
- Query contract VTXOs by script and prove `asset_id`, `asset_amount`, outpoint,
  status, and expiry.
- Spend the contract through the claim path with `P`.
- Spend the contract through the refund path after CLTV.
- Return raw or decoded Ark transaction data sufficient for the test harness to
  verify which path was used and which preimage was revealed.
- Finalize offchain spends through `SubmitTx` and `FinalizeTx`.

## Missing Or Unproven Support

Public docs are enough to define the design, but not enough to implement this in
the current Rust provider without a spike.

Missing or unproven items:

- A documented asset-bearing VHTLC template with both claim and refund paths.
- A documented SHA256 VHTLC helper compatible with BOLT11 payment hashes. The
  public hashlock example uses `HASH160(P)`.
- A documented SDK call that sends Ark assets to a custom VTXO script and then
  spends that same asset VTXO through claim and refund paths.
- A stable Rust SDK for custom script construction, signing, and witness
  decoding. The repo currently has only an `ark` CLI adapter.
- A provider-level protobuf/API method for "fund asset VHTLC", "claim asset
  VHTLC", and "refund asset VHTLC". ArkService exposes lower-level
  transaction submission, but not this swap-specific workflow.
- A documented way to extract the Ark claim preimage from finalized offchain
  transaction events without hand-decoding raw transactions.

If any of these are not available in the pinned `arkd`/SDK version, the next
implementation must either add the missing support upstream/local-sidecar or
keep the proof labeled as coordinated, not trustless.

## Test Harness Changes

Add separate trustless modes instead of replacing the existing coordinated proof
in place:

- `trustless-rgb-asset-to-ark-asset`
- `trustless-ark-asset-to-rgb-asset`
- `trustless-all`

The trustless harness must fail if:

- it calls `ark_cli send` directly to a provider or taker wallet as the Ark swap
  leg;
- the provider response contains the preimage before it is learned from the
  claim side;
- the Ark asset is not locked in the expected VHTLC script before the dependent
  payment action runs;
- the revealed preimage does not satisfy the Lightning payment hash;
- the Ark claim/refund path cannot be decoded from artifacts;
- timeout ordering is absent or unsafe.

The harness should include accelerated timeout/refund fixtures so both refund
paths can be exercised without waiting for production-length expiries.

## Fresh Proof Acceptance Criteria

Create new artifacts under a path like:

```text
state/tests/trustless-ark-swap-all-<timestamp>/
```

Do not reuse the existing `lightning-ark-bridge-*` artifacts for trustless
claims.

Required common artifacts:

- `config.json` with git commit, arkd version, provider binary version, network,
  asset ids, asset amounts, timeout margins, and mode.
- `proof-summary.json` with one entry per flow and booleans for
  `contract_funded`, `contract_claimed`, `preimage_verified`,
  `ln_or_rgb_settled`, `refund_test_passed`, and `no_direct_ark_send`.
- raw provider request/response JSON for each state transition.
- Ark indexer or transaction stream snapshots proving contract funding,
  spending, and final VTXO ownership.

For `trustless-rgb-asset-to-ark-asset` success:

- buyer-supplied `preimage_hash_sha256` appears in the LND/RGB invoice.
- provider has no preimage before the Ark claim artifact.
- Ark VHTLC funding artifact shows the expected asset id, amount, claim key,
  refund key, script hash, outpoint, and refund time.
- Ark claim artifact contains or decodes to preimage `P`.
- harness verifies `SHA256(P)` equals the BOLT11 payment hash.
- provider settles the hold invoice only after the Ark claim.
- final Ark recipient balance includes the purchased asset amount.
- RGB/LN payment reaches the settled/succeeded state.

For `trustless-rgb-asset-to-ark-asset` refund:

- RGB/LN payment is held or pending but never settled.
- buyer never claims the Ark VHTLC.
- provider refunds the Ark VHTLC after `ark_refund_time`.
- RGB/LN payment is canceled, expired, or otherwise returned to the payer.
- no preimage is revealed.

For `trustless-ark-asset-to-rgb-asset` success:

- RGB/LN invoice payment hash is recorded before Ark funding.
- payer funds an Ark VHTLC, not the provider wallet.
- provider verifies the funded VHTLC before paying the RGB/LN invoice.
- RGB asset delivery succeeds.
- Lightning payment result or RGB claim artifact reveals preimage `P`.
- harness verifies `SHA256(P)` equals the invoice payment hash.
- provider claims the Ark VHTLC before `ark_refund_time`.
- final provider Ark balance includes the paid Ark asset amount.

For `trustless-ark-asset-to-rgb-asset` refund:

- payer funds the Ark VHTLC.
- provider does not obtain a valid preimage because the RGB/LN invoice is not
  claimed.
- payer refunds the Ark VHTLC after `ark_refund_time`.
- final payer Ark balance recovers the locked Ark asset amount.
- no RGB asset success is recorded.

Only after all success and refund criteria pass should the README proof wording
change from "mapped-asset simulation" to a trustless Ark VTXO swap claim. The
wording should still state the Arkade operator, signer, expiry, fee, and
watcher assumptions.

## Minimal Implementation Plan

1. Add an Ark contract adapter behind the provider. Start with a sidecar if the
   TypeScript SDK is the only practical way to build and spend custom VHTLCs.
2. Extend the swap schema with contract, timeout, preimage-source, and proof
   fields.
3. Implement `rgb-to-ark` with buyer-supplied payment hash, Ark VHTLC funding,
   claim watcher, and invoice settlement from observed preimage.
4. Implement `ark-to-rgb` with payer-funded Ark VHTLC verification, RGB/LN
   payment, preimage extraction from the payment result, and Ark claim.
5. Add claim/refund harness modes and proof summary validation.
6. Rerun tests from a clean artifact directory and update README proof language
   only if every acceptance criterion passes.

## References

- Arkade VTXOs and ownership:
  https://docs.arkadeos.com/learn/core-concepts/vtxos-and-ownership
- Arkade contract deep dive:
  https://docs.arkadeos.com/contracts/deep-dive
- Arkade hashlock example:
  https://docs.arkadeos.com/contracts/hashlock
- Arkade Lightning swaps:
  https://docs.arkadeos.com/contracts/lightning-swaps
- Arkade asset sends:
  https://docs.arkadeos.com/wallets/operations/assets/send-assets
- ArkService docs:
  https://docs.arkadeos.com/arkd/core-services/ark-service
- Ark protobuf Go reference:
  https://pkg.go.dev/github.com/arkade-os/arkd/api-spec/protobuf/gen/ark/v1
