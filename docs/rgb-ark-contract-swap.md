# RGB/Ark Contract Swap Demo

This demo generates a small contract pack for a same-hash RGB/Ark swap without
putting LND in the middle.

The direct RGB contract work has moved to the real Rust/Sonic kit in
[docs/rgb-htlc-kit.md](rgb-htlc-kit.md).

The output is intentionally artifact-first:

- `ark-vhtlc.json` contains the concrete Ark Taproot VHTLC address, script
  pubkey, claim leaf, refund leaf, tap tree, pubkeys, asset fields, and shared
  SHA256 hash.
- `rgb-node-hodl-invoice-request.json` is the current runnable RGB-node lock
  request using `/lninvoice` with a caller supplied payment hash.
- `rgb-htlc-draft.contractum` is a historical sketch only. Use
  [docs/rgb-htlc-kit.md](rgb-htlc-kit.md) for the real RGB/Sonic issuer and
  local contract demo.
- `contract-pack.json` ties the pieces together in one shareable file.

Run:

```bash
sim-rgb-ark-contract-swap \
  --ark-asset-id <ark_asset_id> \
  --rgb-asset-id <rgb_asset_id>
```

To also ask the RGB node to create the current hodl invoice:

```bash
sim-rgb-ark-contract-swap \
  --live-rgb-invoice \
  --rgb-node-url http://127.0.0.1:3104 \
  --ark-asset-id <ark_asset_id> \
  --rgb-asset-id <rgb_asset_id>
```

The live RGB path still uses RGB Lightning node channel state. The direct RGB
contract prototype now lives in [docs/rgb-htlc-kit.md](rgb-htlc-kit.md).

References:

- https://rgb.tech/program/
- https://rgb.tech/program/contractum/#basics
- https://rgb.tech/power-user/#contract
- https://rgb.tech/docs/#api
