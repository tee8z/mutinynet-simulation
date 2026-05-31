# Ark LND Swap Provider

Small Axum service for coordinating Ark/LND swap experiments inside the
Mutinynet simulation.

It keeps durable swap state in SQLite through SQLx `0.9.0`, uses `lncli` for
LND hold invoices, invoice payment, settlement, and cancellation, and uses the
`ark` CLI as the first Ark-side integration layer.

## Role In The Validated Bridge

The provider is the Ark-side coordinator in the validated Ark asset <-> RGB
asset simulation:

- `ln-to-ark` creates a hold invoice. The RGB side pays that invoice with an RGB
  asset, then the provider sends the mapped Ark asset and settles the invoice.
- `ark-to-ln` records the Ark-side asset movement, pays a mapped RGB invoice
  through `lnd2`, and lets the RGB node deliver the mapped RGB asset before the
  held Lightning invoice is claimed.

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
POST /v1/ark/receive
```

Example:

```bash
curl -sS http://127.0.0.1:8090/v1/swaps/ln-to-ark \
  -H 'Content-Type: application/json' \
  --data '{"amount_sat":1000,"asset_id":"<asset_id>","asset_amount":"100","ark_recipient":"<ark_address>"}'
```

This is a coordinator, not yet a full Ark VTXO atomic swap implementation. The
simulation intentionally uses CLI adapters for both Lightning (`lncli`) and Ark
(`ark`) today. For a service integration, replace both adapters with direct gRPC
clients while keeping the same provider API and swap state model.
