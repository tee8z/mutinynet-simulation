# Ark VHTLC VTXO Swap

Status: implemented and validated in the local Mutinynet simulation. It is not production audited.

The bridge binds the Ark asset leg and the Lightning/RGB leg to the same 32-byte preimage. The Ark side uses a SHA256 Taproot VHTLC carrying the Ark asset packet. The Lightning/RGB side uses the same SHA256 value as the BOLT11 payment hash.

The claim path is scoped to Arkade operator/signer, expiry, fee, and watcher assumptions. RGB asset issuance, RGB delivery, and RGB invoice claiming remain inside the RGB Lightning node APIs.

## Actor Model

The simulation runs the provider, payer, buyer, and RGB maker actions from one harness so the repository can validate the complete message flow. That does not mean the real system is expected to run as one bridge process that owns both wallets.

In the intended wallet-to-wallet shape, each side can be controlled by a different entity. The coordination object is the invoice plus its SHA256 payment hash. A participant that wants the opposite asset can receive or discover the invoice, verify the terms, and satisfy the matching side by paying the Lightning/RGB invoice or funding the Ark VHTLC. No bridge or matching service is assumed to custody both wallets or perform both sides of the swap.

## Runtime Components

| Component | Role |
| --- | --- |
| `ark-lnd-swap-provider` | Axum/SQLite service that owns swap state and exposes the Ark/LND swap API. |
| LND adapter | Direct LND gRPC client for hold invoices, invoice payment, settlement, cancellation, and payreq decoding. |
| Ark wallet adapter | Rust Ark client/gRPC path for Ark receive and asset sends. |
| Ark contract adapter | Rust Ark gRPC/client path for VHTLC template, fund, verify, claim, and refund. |
| Simulation bootstrap | RGB Lightning node API issues RGB assets; `ark` CLI creates local Ark wallets, issues demo Ark assets, and funds local test inventory. |

Ark wallet operations use `ARK_LND_PROVIDER_ARK_PRIVATE_KEY_HEX` or a request field named `wallet_private_key_hex`. `scripts/start.sh` can derive the local provider test key from the configured Ark CLI wallet and pass it into the provider process.

## Shared Secret

Each contract-bound swap uses one 32-byte preimage `P`.

- `H = SHA256(P)` is the BOLT11 payment hash.
- The Ark VHTLC claim path requires a witness preimage with the same SHA256.
- The provider stores `P` only after it is learned from an Ark claim witness or a Lightning payment result.

For `rgb-asset-to-ark-asset`, the buyer generates `P` and gives the provider only `H`. For `ark-asset-to-rgb-asset`, the RGB/LN invoice creator owns `P`, and the provider learns it from the successful Lightning payment.

## Contract Template

The provider builds an Ark VTXO Taproot output with two Ark-compatible closure leaves. Both fast-path leaves require the Ark server signature, which keeps the contract inside the Ark offchain protocol path.

| Leaf | Spend condition |
| --- | --- |
| Claim | `OP_SHA256 <H> OP_EQUAL OP_VERIFY`, claimant key signature, Ark server signature. |
| Refund | `ark_refund_time` CLTV, refund key signature, Ark server signature. |

The template response includes the contract Ark address, script pubkey, taproot tree, claim/refund pubkeys, refund time, SHA256 payment hash, asset id, asset amount, VTXO sats, and the Ark server pubkey returned by `GetInfo`.

The claim preimage is attached as the Ark condition witness on both the Ark transaction and its checkpoint transaction, so arkd can validate the condition before finalizing the offchain spend.

## RGB Assets Buy Ark Assets

Roles:

- buyer: owns RGB asset, wants Ark asset, controls the claim key
- provider: owns Ark asset, receives the Lightning/RGB payment, controls the refund key

Flow:

1. Buyer generates `P` and sends `H = SHA256(P)` plus an Ark claim pubkey to the provider.
2. Provider creates a hold invoice with `H` and returns the BOLT11 invoice plus the Ark VHTLC template.
3. Buyer pays the invoice through the RGB route. The invoice reaches `ACCEPTED`, locking the Lightning/RGB leg.
4. Provider funds the Ark VHTLC with the quoted asset id and asset amount.
5. Buyer verifies the contract fields and claims the Ark VHTLC with `P`.
6. Provider records the observed Ark claim preimage and settles the hold invoice with `P`.
7. Provider refunds the Ark VHTLC after `ark_refund_time` when the buyer does not claim.

Timeout ordering:

```text
now < ark_refund_time < ln_expiry
```

## Ark Assets Pay RGB Assets

Roles:

- payer: owns Ark asset, wants RGB asset, controls the refund key
- provider/RGB maker: pays the RGB/LN invoice and claims the Ark VHTLC with the revealed preimage

Flow:

1. RGB maker creates the RGB/LN mapped invoice. The invoice exposes `H = SHA256(P)`.
2. Provider decodes the invoice and returns an Ark VHTLC template using `H`.
3. Payer funds the Ark VHTLC with the quoted asset id and asset amount.
4. Provider verifies the funded VTXO over Ark gRPC.
5. Provider pays the RGB/LN invoice through LND gRPC.
6. The successful Lightning payment reveals `P`.
7. Provider verifies `SHA256(P) == H` and claims the Ark VHTLC with `P`.
8. Payer refunds the Ark VHTLC after `ark_refund_time` when no valid preimage is revealed.

Timeout ordering:

```text
now < ln_expiry < ark_refund_time
```

## Provider API

Ark VHTLC `ln-to-ark` creation:

```bash
provider POST /v1/swaps/ln-to-ark '{
  "contract": true,
  "amount_sat": 6000,
  "preimage_hash": "<sha256_preimage_hash_hex>",
  "asset_id": "<ark_asset_id>",
  "asset_amount": "100",
  "ark_claim_pubkey": "<buyer_xonly_pubkey>",
  "ark_refund_time": <ark_refund_unix_time>,
  "ln_expiry": <ln_expiry_unix_time>
}'
```

Ark VHTLC `ark-to-ln` creation:

```bash
provider POST /v1/swaps/ark-to-ln '{
  "contract": true,
  "bolt11": "<rgb_mapped_invoice>",
  "asset_id": "<ark_asset_id>",
  "asset_amount": "100",
  "ark_refund_pubkey": "<payer_xonly_pubkey>",
  "ark_refund_time": <ark_refund_unix_time>,
  "ln_expiry": <ln_expiry_unix_time>
}'
```

Contract operations:

```bash
provider POST /v1/swaps/<swap_id>/ark-contract/template '{...}'
provider POST /v1/swaps/<swap_id>/ark-contract/fund '{"wallet_private_key_hex":"<funding_wallet_key>"}'
provider POST /v1/swaps/<swap_id>/ark-contract/verify-funded '{"ark_vtxo_outpoint":"<outpoint>"}'
provider POST /v1/swaps/<swap_id>/ark-contract/claim '{
  "preimage":"<32_byte_hex_preimage>",
  "ark_vtxo_outpoint":"<outpoint>",
  "destination_address":"<ark_address>",
  "wallet_private_key_hex":"<claim_wallet_key>"
}'
provider POST /v1/swaps/<swap_id>/ark-contract/refund '{
  "ark_vtxo_outpoint":"<outpoint>",
  "destination_address":"<ark_address>",
  "wallet_private_key_hex":"<refund_wallet_key>"
}'
provider POST /v1/swaps/<swap_id>/ark-contract/observe-claim '{
  "preimage":"<32_byte_hex_preimage>",
  "ark_claim_txid":"<txid>",
  "settle_ln":true
}'
```

`pay-ln` for a contract-bound `ark-to-ln` swap requires a verified funded Ark VHTLC.
`settle-ln` for a contract-bound `ln-to-ark` swap uses the observed Ark claim preimage, not a caller-supplied settlement preimage.

## Harness Modes

```bash
scripts/test-lightning-ark-bridge.sh rgb-asset-to-ark-asset
scripts/test-lightning-ark-bridge.sh ark-asset-to-rgb-asset
scripts/test-lightning-ark-bridge.sh all
```

For the local simulation, the setup script and swap harness derive the provider and taker Ark private keys from the configured Ark CLI wallets when the env vars are not set. Set `ARK_LND_PROVIDER_ARK_PRIVATE_KEY_HEX` or `BRIDGE_TEST_ARK_TAKER_PRIVATE_KEY_HEX` only when you need to override those local wallet keys.

The bridge UI runs the same harness and uses the same local key derivation for `setup-assets` and swap runs:

```bash
sim-start all
sim-init-unlock all
sim-bridge-ui

curl -sS -X POST http://127.0.0.1:8091/api/flows/start/setup-assets \
  -H 'Content-Type: application/json' \
  --data '{"rgb_asset_id":"<rgb_asset_id>","ark_asset_id":"<ark_asset_id>"}' | jq

curl -sS -X POST http://127.0.0.1:8091/api/flows/start/all \
  -H 'Content-Type: application/json' \
  --data '{"rgb_asset_id":"<rgb_asset_id>","ark_asset_id":"<ark_asset_id>"}' | jq
```

`setup-assets` funds the provider Ark gRPC wallet and the taker Ark gRPC wallet with BTC liquidity plus Ark asset inventory. The CLI taker wallet is also funded for local receive-address checks.

## Artifacts

Script runs write under:

```text
state/tests/lightning-ark-bridge-<mode>-<timestamp>/
```

UI runs write under:

```text
state/bridge-ui/<run-id>/artifacts/
```

Useful review fields:

- `preimage_hash_sha256`
- `preimage_source`
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
- `ark_contract_result`
- `ln_result`

The acceptance signal for a successful run is: the expected Ark asset is funded into the VHTLC, the dependent Lightning/RGB action runs only after the required lock is visible, the revealed preimage hashes to the BOLT11 payment hash, and the final claim or refund path matches the timeout branch being tested.

Latest local proof run:

```text
setup run: 1780257123-6301cdac-3174-4fe3-b76f-9b29295e2490
proof run: 1780257136-743967ac-caee-4021-877e-ada558470f6e
artifact dir: state/bridge-ui/1780257136-743967ac-caee-4021-877e-ada558470f6e/artifacts/
public proof: docs/proofs/README.md
```

Both legs in that run have `contract_funded`, `contract_claimed`, `preimage_verified`, `ln_or_rgb_settled`, and `no_preimage_before_claim` set to `true`.

## Environment

Provider gRPC settings:

```bash
ARK_LND_PROVIDER_ARK_SERVER_URL=http://127.0.0.1:7070
ARK_LND_PROVIDER_ARK_NETWORK=mutinynet
ARK_LND_PROVIDER_ARK_PRIVATE_KEY_HEX=<32-byte-hex-static-wallet-key>
ARK_LND_PROVIDER_ARK_CONTRACT_VTXO_SATS=1000
ARK_LND_PROVIDER_LND_RPCSERVER=127.0.0.1:10042
ARK_LND_PROVIDER_LND_TLS_CERT=./data/lnd2/tls.cert
ARK_LND_PROVIDER_LND_NO_MACAROONS=1
```

Harness settings:

```bash
BRIDGE_TEST_ARK_ASSET_ID=<ark_asset_id>
BRIDGE_TEST_ARK_TAKER_PRIVATE_KEY_HEX=<optional-32-byte-hex-key-override>
```

## Operational Assumptions

- Arkade server/signer cooperation is part of the fast path.
- Refund uses the configured absolute CLTV.
- The harness records claim observation explicitly through provider endpoints and artifact checks.
- Contract code is local experimental code built on the pinned Ark Rust crates.

## References

- Arkade VTXOs and ownership: https://docs.arkadeos.com/learn/core-concepts/vtxos-and-ownership
- Arkade contract deep dive: https://docs.arkadeos.com/contracts/deep-dive
- Arkade hashlock example: https://docs.arkadeos.com/contracts/hashlock
- Arkade Lightning swaps: https://docs.arkadeos.com/contracts/lightning-swaps
- Arkade asset sends: https://docs.arkadeos.com/wallets/operations/assets/send-assets
- ArkService docs: https://docs.arkadeos.com/arkd/core-services/ark-service
- Ark protobuf Go reference: https://pkg.go.dev/github.com/arkade-os/arkd/api-spec/protobuf/gen/ark/v1
