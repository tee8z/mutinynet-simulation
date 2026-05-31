# Ark LND Swap Provider

Small Axum service for coordinating Ark/LND swap experiments inside the
Mutinynet simulation.

It keeps durable swap state in SQLite through SQLx `0.9.0`, uses LND gRPC for
hold invoices, invoice payment, settlement, and cancellation, and uses Rust Ark
gRPC/client crates for wallet sends and experimental Ark VHTLC contract
operations.

## Role In The Validated Bridge

The provider is the Ark-side coordinator in the validated Ark asset <-> RGB
asset simulation:

- `ln-to-ark` creates a hold invoice. The RGB side pays that invoice with an RGB
  asset, then the provider sends the mapped Ark asset and settles the invoice.
- `ark-to-ln` records the Ark-side asset movement, pays a mapped RGB invoice
  through `lnd2`, and lets the RGB node deliver the mapped RGB asset before the
  held Lightning invoice is claimed.

The experimental trustless modes keep the same outer API but add Ark VHTLC
fields. `ln-to-ark` accepts a caller-supplied payment hash and creates a
contract template without storing a preimage. `ark-to-ln` requires a funded Ark
contract before the provider will pay the Lightning invoice.

## Endpoints

```bash
GET  /health
GET  /v1/swaps
GET  /v1/swaps/{id}
POST /v1/swaps/ln-to-ark
POST /v1/swaps/ark-to-ln
POST /v1/swaps/{id}/settle-ln
POST /v1/swaps/{id}/cancel-ln
POST /v1/swaps/{id}/pay-ln
POST /v1/swaps/{id}/ark-send
POST /v1/swaps/{id}/ark-contract/template
POST /v1/swaps/{id}/ark-contract/fund
POST /v1/swaps/{id}/ark-contract/verify-funded
POST /v1/swaps/{id}/ark-contract/claim
POST /v1/swaps/{id}/ark-contract/refund
POST /v1/swaps/{id}/ark-contract/observe-claim
POST /v1/ark/receive
POST /v1/ark/contract/pubkey
```

Example:

```bash
curl -sS http://127.0.0.1:8090/v1/swaps/ln-to-ark \
  -H 'Content-Type: application/json' \
  --data '{"amount_sat":1000,"asset_id":"<asset_id>","asset_amount":"100","ark_recipient":"<ark_address>"}'
```

Trustless harness modes:

```bash
scripts/test-lightning-ark-bridge.sh trustless-rgb-asset-to-ark-asset
scripts/test-lightning-ark-bridge.sh trustless-ark-asset-to-rgb-asset
scripts/test-lightning-ark-bridge.sh trustless-all
```

The Ark/LND gRPC adapters are configured with:

```bash
ARK_LND_PROVIDER_ARK_SERVER_URL=http://127.0.0.1:7070
ARK_LND_PROVIDER_ARK_NETWORK=mutinynet
ARK_LND_PROVIDER_ARK_PRIVATE_KEY_HEX=<32-byte-hex-static-wallet-key>
ARK_LND_PROVIDER_LND_RPCSERVER=127.0.0.1:10042
ARK_LND_PROVIDER_LND_TLS_CERT=./data/lnd2/tls.cert
```

This is an experimental local service. Ark wallet operations require a static
private key provided by `ARK_LND_PROVIDER_ARK_PRIVATE_KEY_HEX` or per-request
`wallet_private_key_hex`. The simulation startup script can derive the
provider's local test key from the configured Ark CLI wallet and pass it to the
provider through the environment. Runtime swap operations use LND gRPC and Rust
Ark gRPC/client calls.
