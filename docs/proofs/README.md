# Ark VHTLC Contract VTXO Proof

This README is the public proof package for the Ark VHTLC contract VTXO swap flow. It embeds the UI snapshots directly in the flow order so the proof can be read as a single walkthrough.

The proof omits only local filesystem paths that are not portable across machines. Protocol identifiers stay visible when they help prove the run: asset ids, payment hashes, pubkeys, Ark addresses, BOLT11 invoices, swap ids, contract ids, completed-test preimages, and wallet private key material used by the local proof run.

## What This Proves

The run proves both asset-swap directions use an Ark contract VTXO, not a direct provider release:

- `rgb-asset-to-ark-asset`: the RGB payer pays a preimage-hash hold invoice. The provider funds an Ark VHTLC using the same payment hash. The taker claims the Ark VHTLC, revealing the preimage. The provider observes that Ark claim preimage and settles the Lightning/RGB invoice.
- `ark-asset-to-rgb-asset`: the Ark payer funds an Ark VHTLC for a provider-registered RGB/LN invoice. The provider verifies the funded VHTLC before paying the RGB invoice. After the RGB invoice is claimable, the provider uses the revealed preimage to claim the Ark VHTLC.

Both directions completed with:

- `contract_funded: true`
- `contract_claimed: true`
- `preimage_verified: true`
- `ln_or_rgb_settled: true`
- `no_direct_ark_send: true`
- `no_preimage_before_claim: true`

Detailed proof fields are in [status-snippets.json](status-snippets.json).

## Run Context

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

## 1. Preflight And Setup

The UI starts with the cluster health checks, Bitcoin P2P tunnel status, and proof inventory visible. This verifies the local coordinator can see the RGB nodes, LND nodes, Ark wallets, provider service, and external Bitcoin/indexer dependencies before the run starts.

![Cluster health and preflight](screenshots/01-overview-preflight.png)

The setup and run controls show the active assets and the available setup/run actions.

![Setup and run controls](screenshots/02-setup-and-run-controls.png)

The setup run prepares the inventory required for both swap directions.

![Setup timeline](screenshots/03-setup-timeline.png)

The setup summary confirms the local RGB and Ark asset ids, provider and taker Ark gRPC wallet funding, and Lightning liquidity checks.

![Setup summary](screenshots/04-setup-summary.png)

The setup JSON keeps the machine-readable setup record alongside the visual state.

![Setup JSON details](screenshots/05-setup-json.png)

## 2. Full Swap Run Starts

The `all` run starts both swap directions in one proof run.

![Full run start](screenshots/06-all-run-start.png)

## 3. RGB Asset To Ark Asset

The first leg creates the preimage-hash hold invoice and Ark VHTLC template. The important binding is that the Ark contract and the Lightning/RGB invoice share the same payment hash.

![RGB-to-Ark VHTLC template](screenshots/07-rgb-to-ark-template.png)

The RGB payer pays the provider hold invoice with RGB asset liquidity while the provider funds the Ark VHTLC from its maker wallet.

![RGB-to-Ark payment state](screenshots/08-rgb-to-ark-payment.png)

The proof summary records that the Ark VHTLC was funded and claimed, the preimage was verified, and settlement happened only after the claim revealed the preimage.

![RGB-to-Ark proof summary](screenshots/09-rgb-to-ark-proof-summary.png)

The first leg completes with no direct Ark send and no preimage before claim.

![RGB-to-Ark complete](screenshots/10-rgb-to-ark-complete.png)

## 4. Ark Asset To RGB Asset

The second leg starts from the opposite direction: the Ark payer wants RGB asset delivery and funds the Ark VHTLC first.

![Ark-to-RGB start](screenshots/11-ark-to-rgb-start.png)

The provider creates the Ark VHTLC template for the registered RGB/LN invoice.

![Ark-to-RGB VHTLC template](screenshots/12-ark-to-rgb-template.png)

Before making the Lightning/RGB payment, the provider verifies the Ark VHTLC is funded and matches the expected asset, amount, payment hash, and claim/refund keys.

![Provider verifies funded VHTLC](screenshots/13-provider-verifies-vhtlc.png)

After verification, the provider pays the RGB/LN invoice.

![Provider pays RGB invoice](screenshots/14-provider-pays-rgb-invoice.png)

Once the RGB/LN side reveals the preimage, the provider claims the Ark VHTLC.

![Provider claims Ark VHTLC](screenshots/15-provider-claims-vhtlc.png)

The completion JSON records the final Ark-to-RGB proof fields.

![Ark-to-RGB completion JSON](screenshots/16-ark-to-rgb-complete-json.png)

## 5. Final Evidence

Both swap legs are complete in the same run.

![Both legs complete](screenshots/17-both-legs-complete.png)

The artifact summary shows the proof outputs generated by the run.

![Run artifact summary](screenshots/18-run-artifact-summary.png)

The final proof summary shows both legs with the expected contract, preimage, settlement, and no-direct-send flags.

![Final proof summary](screenshots/19-proof-summary-complete.png)

The final log tail shows the run ended cleanly.

![Final log tail](screenshots/20-log-tail.png)

## Timing

The setup flow completed in 1 second. The full two-direction swap run completed in 34 seconds.

- `rgb-asset-to-ark-asset`: payment completed in 14 seconds. Ark contract claim and Lightning settlement were observed after 11 seconds; RGB payment success was observed after 14 seconds.
- `ark-asset-to-rgb-asset`: payment completed in 16 seconds. Ark contract funding was verified after 1 second; provider Lightning payment completed after 15 seconds; RGB invoice claim completed after 13 seconds.

## Identifiers

Both directions completed:

- `rgb-asset-to-ark-asset`: swap `8dfc2fc9-87cb-4565-aba3-54cd47508e02`
- `ark-asset-to-rgb-asset`: swap `198f3ec5-eca8-42f9-8829-399064712f02`

## Acceptance Criteria

A proof artifact can be treated as the public headline proof only if it shows:

1. The test used the Ark contract VTXO implementation, not only provider-coordinated release steps.
2. Both swap directions completed with the expected final statuses.
3. The transcript demonstrates how the contract binding protects settlement ordering without relying on local filesystem paths or operator-only runtime files.
4. Refund timeout coverage is either exercised or explicitly marked as not part of the fast-path proof.
