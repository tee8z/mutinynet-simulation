# Ark VHTLC Contract VTXO Proof

This directory is the public proof package for the Ark VHTLC contract VTXO swap flow. It has one README for the whole proof, one machine-readable status file, and one screenshot directory:

```text
docs/proofs/
  README.md
  status-snippets.json
  screenshots/
```

The proof omits only local filesystem paths that are not portable across machines. Protocol identifiers stay visible when they help prove the run: asset ids, payment hashes, pubkeys, Ark addresses, BOLT11 invoices, swap ids, contract ids, completed-test preimages, and wallet private key material used by the local proof run.

## Run

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

## Flow

The proof covers both swap directions.

`rgb-asset-to-ark-asset`: the RGB payer pays a preimage-hash hold invoice with RGB asset liquidity. The provider funds an Ark VHTLC using the same payment hash. The taker claims the Ark VHTLC, revealing the preimage. The provider observes the Ark claim preimage and settles the Lightning/RGB invoice.

`ark-asset-to-rgb-asset`: the Ark payer funds an Ark VHTLC for a provider-registered RGB/LN invoice. The provider verifies the funded VHTLC before paying the RGB invoice. After the RGB invoice is claimable, the provider uses the revealed preimage to claim the Ark VHTLC.

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

Detailed proof fields are in [status-snippets.json](status-snippets.json).

## Screenshot Walkthrough

| Step | Screenshot | What It Shows |
| --- | --- | --- |
| 1 | [Overview preflight](screenshots/01-overview-preflight.png) | Cluster health and preflight state before the run. |
| 2 | [Setup and run controls](screenshots/02-setup-and-run-controls.png) | Setup inputs and run controls. |
| 3 | [Setup timeline](screenshots/03-setup-timeline.png) | Setup flow timeline. |
| 4 | [Setup summary](screenshots/04-setup-summary.png) | Setup completed and asset/liquidity state summarized. |
| 5 | [Setup JSON](screenshots/05-setup-json.png) | Setup JSON details. |
| 6 | [All run start](screenshots/06-all-run-start.png) | Full two-direction swap run starting. |
| 7 | [RGB-to-Ark template](screenshots/07-rgb-to-ark-template.png) | RGB-to-Ark VHTLC template and funding path. |
| 8 | [RGB-to-Ark payment](screenshots/08-rgb-to-ark-payment.png) | RGB-to-Ark payment state while the hold invoice and Ark VHTLC coordinate on the same payment hash. |
| 9 | [RGB-to-Ark proof summary](screenshots/09-rgb-to-ark-proof-summary.png) | RGB-to-Ark proof summary. |
| 10 | [RGB-to-Ark complete](screenshots/10-rgb-to-ark-complete.png) | RGB-to-Ark completed leg. |
| 11 | [Ark-to-RGB start](screenshots/11-ark-to-rgb-start.png) | Ark-to-RGB leg start. |
| 12 | [Ark-to-RGB template](screenshots/12-ark-to-rgb-template.png) | Ark-to-RGB VHTLC template. |
| 13 | [Provider verifies VHTLC](screenshots/13-provider-verifies-vhtlc.png) | Provider verifies the funded VHTLC before paying the RGB/LN invoice. |
| 14 | [Provider pays RGB invoice](screenshots/14-provider-pays-rgb-invoice.png) | Provider pays the RGB/LN invoice. |
| 15 | [Provider claims VHTLC](screenshots/15-provider-claims-vhtlc.png) | Provider claims the Ark VHTLC after the preimage is available. |
| 16 | [Ark-to-RGB completion JSON](screenshots/16-ark-to-rgb-complete-json.png) | Ark-to-RGB completion JSON. |
| 17 | [Both legs complete](screenshots/17-both-legs-complete.png) | Both swap legs completed. |
| 18 | [Run artifact summary](screenshots/18-run-artifact-summary.png) | Run artifact summary. |
| 19 | [Proof summary complete](screenshots/19-proof-summary-complete.png) | Proof summary after completion. |
| 20 | [Final log tail](screenshots/20-log-tail.png) | Final log tail. |

## Acceptance Criteria

A proof artifact can be treated as the public headline proof only if it shows:

1. The test used the Ark contract VTXO implementation, not only provider-coordinated release steps.
2. Both swap directions completed with the expected final statuses.
3. The transcript demonstrates how the contract binding protects settlement ordering without relying on local filesystem paths or operator-only runtime files.
4. Refund timeout coverage is either exercised or explicitly marked as not part of the fast-path proof.
