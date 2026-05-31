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

- `ln-to-ark` creates a hold invoice from a caller-supplied payment hash,
  returns an Ark VHTLC template, funds that VHTLC after the RGB/LN leg is
  locked, and settles the invoice from the observed Ark claim preimage.
- `ark-to-ln` creates an Ark VHTLC template for the RGB/LN invoice hash,
  requires a funded Ark contract before paying the Lightning invoice, and claims
  the Ark VHTLC with the payment preimage.

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
POST /v1/ark/balance
POST /v1/ark/contract/pubkey
```

Example:

```bash
curl -sS http://127.0.0.1:8090/v1/swaps/ln-to-ark \
  -H 'Content-Type: application/json' \
  --data '{"contract":true,"amount_sat":1000,"preimage_hash":"<sha256_preimage_hash_hex>","asset_id":"<asset_id>","asset_amount":"100","ark_claim_pubkey":"<xonly_pubkey>","ark_refund_time":<unix_time>,"ln_expiry":<unix_time>}'
```

Ark VHTLC harness modes:

```bash
scripts/test-lightning-ark-bridge.sh rgb-asset-to-ark-asset
scripts/test-lightning-ark-bridge.sh ark-asset-to-rgb-asset
scripts/test-lightning-ark-bridge.sh all
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
