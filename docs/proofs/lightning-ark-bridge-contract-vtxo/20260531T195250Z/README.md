# Ark VHTLC Contract VTXO Proof, 2026-05-31

Run mode: `all`

UI run id: `1780257136-743967ac-caee-4021-877e-ada558470f6e`

Setup run id: `1780257123-6301cdac-3174-4fe3-b76f-9b29295e2490`

Source artifacts: `state/bridge-ui/1780257136-743967ac-caee-4021-877e-ada558470f6e/artifacts/`

Code state: base commit `d2b63fa`, with the current working tree changes for the normal Ark VHTLC swap path, restart idempotency, setup top-ups, LND liquidity rebalance, and proof timing fields.

The run was executed through the bridge UI backend against the local simulation connected to the Voltage staging Bitcoin node port-forward. The setup flow confirmed existing RGB and Ark asset ids, verified provider and taker Ark gRPC wallet BTC liquidity and Ark asset inventory, and confirmed enough `lnd1 -> lnd2` outbound liquidity for the RGB-to-Ark hold-invoice leg.

## Commands

These are the same endpoints used by the UI buttons:

```bash
curl -sS -X POST http://127.0.0.1:8091/api/flows/start/setup-assets \
  -H 'Content-Type: application/json' \
  --data '{}'

curl -sS -X POST http://127.0.0.1:8091/api/flows/start/all \
  -H 'Content-Type: application/json' \
  --data '{}'
```

## Timing

The setup flow completed in 1 second. The full two-direction swap run completed in 34 seconds.

- `rgb-asset-to-ark-asset`: payment completed in 14 seconds. Ark contract claim and Lightning settlement were observed after 11 seconds; RGB payment success was observed after 14 seconds.
- `ark-asset-to-rgb-asset`: payment completed in 16 seconds. Ark contract funding was verified after 1 second; provider Lightning payment completed after 15 seconds; RGB invoice claim completed after 13 seconds.

## Evidence

Both directions completed:

- `rgb-asset-to-ark-asset`: swap `8dfc2fc9-87cb-4565-aba3-54cd47508e02`
- `ark-asset-to-rgb-asset`: swap `198f3ec5-eca8-42f9-8829-399064712f02`

Both proof summaries report:

- `contract_funded: true`
- `contract_claimed: true`
- `preimage_verified: true`
- `ln_or_rgb_settled: true`
- `no_direct_ark_send: true`
- `no_preimage_before_claim: true`

`status-snippets.json` includes payment preimages and the wallet private key material used by the local proof run. The proof omits only local filesystem paths that are not portable across machines.

## Screenshots

The UI screenshot sequence for this run lives under `screenshots/`.

- `01-overview-preflight.png`: cluster health and preflight.
- `02-setup-and-run-controls.png`: setup inputs and run controls.
- `03-setup-timeline.png`: setup flow timeline.
- `04-setup-summary.png`: setup summary.
- `05-setup-json.png`: setup JSON details.
- `06-all-run-start.png`: full swap run start.
- `07-rgb-to-ark-template.png`: RGB-to-Ark VHTLC template and funding path.
- `08-rgb-to-ark-payment.png`: RGB-to-Ark payment state.
- `09-rgb-to-ark-proof-summary.png`: RGB-to-Ark proof summary.
- `10-rgb-to-ark-complete.png`: RGB-to-Ark completed leg.
- `11-ark-to-rgb-start.png`: Ark-to-RGB leg start.
- `12-ark-to-rgb-template.png`: Ark-to-RGB VHTLC template.
- `13-provider-verifies-vhtlc.png`: provider verifies the funded VHTLC.
- `14-provider-pays-rgb-invoice.png`: provider pays the RGB/LN invoice.
- `15-provider-claims-vhtlc.png`: provider claims the Ark VHTLC.
- `16-ark-to-rgb-complete-json.png`: Ark-to-RGB completion JSON.
- `17-both-legs-complete.png`: both swap legs completed.
- `18-run-artifact-summary.png`: run artifact summary.
- `19-proof-summary-complete.png`: proof summary after completion.
- `20-log-tail.png`: final log tail.
