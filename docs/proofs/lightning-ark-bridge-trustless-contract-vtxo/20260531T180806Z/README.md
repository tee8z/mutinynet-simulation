# Trustless Ark Contract VTXO Proof, 2026-05-31

Run mode: `trustless-all`

UI run id: `1780250859-6acb27f1-c0c7-445a-8a43-c56792c82a88`

Setup run id: `1780250843-69448fea-47cd-49ca-b487-ca9013b05534`

Source artifacts:
`state/bridge-ui/1780250859-6acb27f1-c0c7-445a-8a43-c56792c82a88/artifacts/`

Code state: branch `feat/trustless-ark-grpc-ui` at base commit `2a32932`,
with the trustless Ark gRPC, UI setup, and proof-summary working tree changes
from this run.

The run was executed through the bridge UI against the local simulation connected
to the Voltage staging Bitcoin node port-forward. The setup flow funded the
provider and taker Ark gRPC wallets with BTC liquidity and Ark asset inventory.

## Commands

```bash
curl -sS -X POST http://127.0.0.1:8091/api/flows/start/setup-assets \
  -H 'Content-Type: application/json' \
  --data '{"rgb_asset_id":"rgb:kTfTjn7s-0ug2sAV-IgXsI3P-dDTXQJv-8~lPBYI-99onR_Y","ark_asset_id":"1d59ba84c9c5777ead350a803a6bf9d04bade50d4c249cea1aefd60d822dca5d0100"}'

curl -sS -X POST http://127.0.0.1:8091/api/flows/start/trustless-all \
  -H 'Content-Type: application/json' \
  --data '{"rgb_asset_id":"rgb:kTfTjn7s-0ug2sAV-IgXsI3P-dDTXQJv-8~lPBYI-99onR_Y","ark_asset_id":"1d59ba84c9c5777ead350a803a6bf9d04bade50d4c249cea1aefd60d822dca5d0100"}'
```

## Evidence

Both directions completed:

- `rgb-asset-to-ark-asset`: swap
  `13fe72ba-8ee6-4cef-8ee6-b0e33316a90b`
- `ark-asset-to-rgb-asset`: swap
  `2bef25fe-c314-463b-943d-39b0c90e687f`

Both proof summaries report:

- `contract_funded: true`
- `contract_claimed: true`
- `preimage_verified: true`
- `ln_or_rgb_settled: true`
- `no_preimage_before_claim: true`

`status-snippets.json` contains the public-safe proof fields. It omits
preimages, wallet private keys, local wallet directories, macaroons, full
invoices, and local database paths.
