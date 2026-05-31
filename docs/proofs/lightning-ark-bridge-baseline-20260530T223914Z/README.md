# Lightning/Ark Bridge Baseline Proof

Status: baseline only, non-trustless.

Source run:

- Ignored local artifact directory:
  `state/tests/lightning-ark-bridge-all-20260530T223914Z/`
- Test driver: `scripts/test-lightning-ark-bridge.sh`
- Run mode: `all`
- Observed UTC window: `2026-05-30T22:39:16Z` to
  `2026-05-30T22:39:28Z`

This proof is useful as a mapped-asset bridge regression transcript. It must not
be presented as the final public proof of trustless swapping because this run
did not exercise the Ark contract-bound VTXO logic. The flow was coordinated by
local CLI/API calls against the provider, Ark CLI, LND CLI, and RGB Lightning
nodes.

In this baseline, the RGB asset legs are handled by RGB Lightning node APIs. The
Ark asset legs are coordinated by the provider and test harness through `ark`
CLI sends.

## Reproduction command shape

The test script supports the command shape below. The exact source run was
captured from the output directory named above.

```bash
BRIDGE_TEST_OUTPUT_DIR=state/tests/lightning-ark-bridge-all-20260530T223914Z \
  scripts/test-lightning-ark-bridge.sh all
```

The script usage also exposes the equivalent mode name:

```bash
sim-test-lightning-ark-bridge all
```

## Public configuration

- RGB payer node: `node1`
- RGB maker node: `node4`
- RGB receiver node: `node1`
- RGB-side LND node: `lnd1`
- Provider-side LND node: `lnd2`
- Ark taker wallet label: `taker`
- RGB asset amount: `10`
- Ark asset amount: `100`
- RGB asset id:
  `rgb:j~dKPSFu-NIzm2WJ-CPzFKfO-ZnEk_3d-Rbq7fnY-v95~MTY`
- Ark asset id:
  `0c9109c8ab004368a8c87f7fe88540b6335cb637eb36be5e1e9203d6858ec0b10100`
- LN-to-Ark amount: `6000` sat
- Ark-to-RGB amount: `1000` sat
- RGB asset keysend amount: `3000000` msat
- Fee limit: `10` sat

Provider readiness was confirmed with `ok: true` and `database: true`. Local
wallet paths stay omitted from the public proof.

## Direction 1: RGB Asset To Ark Asset

Path progression:

1. Ark taker wallet created an offchain recipient.
2. Provider created an `ln_to_ark` hold invoice for `6000` sat and Ark asset
   amount `100`.
3. `node1` prepared an RGB asset payment using asset amount `10`.
4. `node4` registered the swapstring as the RGB-side maker.
5. `node1` paid the provider hold invoice with the RGB asset through `node4`.
6. Provider-side LND invoice reached `ACCEPTED`.
7. Provider sent the Ark asset from the maker wallet to the Ark taker
   recipient.
8. Provider settled the hold invoice.
9. RGB payment reached `Succeeded`; provider-side LND invoice reached
   `SETTLED`.

CLI/API transcript:

```bash
ark_cli taker receive

provider_post_file /v1/swaps/ln-to-ark \
  rgb-asset-to-ark-asset-request.json

api node1 POST /prepareassetpayment \
  '{"invoice":"lntbs60u1p4pkec5pp54uktzntvu64e453csxcgqhs60ysh2h7rschyqzre9l55klqfx8ksdzcd46hg6tw09hx2apdwd5k6atvv96xjmmwypexwc3dv9ehxet5946x7ttpwf4j6ctnwdjhggrzwf5kgem9yp6x2um5cqzzsxqyz5vqsp565e7kl9eca4zzzrj0z9mrdaylcsysvyyufw2fkgun206569z7j0q9qxpqysgqalvml0swx3rrhmqqwjvmlqvfha490ksl77gxwr7g80a5fqvvkhvrhtvkn2fsechcjcs6mzegfwufys5xdxvm263rgawlag4q6e6j0vgq3ux8ty","asset_id":"rgb:j~dKPSFu-NIzm2WJ-CPzFKfO-ZnEk_3d-Rbq7fnY-v95~MTY","asset_amount":10}'

api node4 POST /taker \
  '{"swapstring":"3000000/btc/10/rgb:j~dKPSFu-NIzm2WJ-CPzFKfO-ZnEk_3d-Rbq7fnY-v95~MTY/1780267156/af2cb14d6ce6ab9ad23881b0805e1a7921755fc3862e4008792fe94b7c0931ed"}'

api node1 POST /sendassetpayment \
  '{"invoice":"lntbs60u1p4pkec5pp54uktzntvu64e453csxcgqhs60ysh2h7rschyqzre9l55klqfx8ksdzcd46hg6tw09hx2apdwd5k6atvv96xjmmwypexwc3dv9ehxet5946x7ttpwf4j6ctnwdjhggrzwf5kgem9yp6x2um5cqzzsxqyz5vqsp565e7kl9eca4zzzrj0z9mrdaylcsysvyyufw2fkgun206569z7j0q9qxpqysgqalvml0swx3rrhmqqwjvmlqvfha490ksl77gxwr7g80a5fqvvkhvrhtvkn2fsechcjcs6mzegfwufys5xdxvm263rgawlag4q6e6j0vgq3ux8ty","asset_id":"rgb:j~dKPSFu-NIzm2WJ-CPzFKfO-ZnEk_3d-Rbq7fnY-v95~MTY","asset_amount":10,"swap_provider_pubkey":"026c4180b10e3c2e4ce214f8e52ad2620a8ac16de6fb3849cdf4dcdd50b1fdf076"}'

lnd_cli lnd2 lookupinvoice \
  af2cb14d6ce6ab9ad23881b0805e1a7921755fc3862e4008792fe94b7c0931ed

provider_post /v1/swaps/3e67e5b4-7f27-449a-bcfe-2d6b45d1690b/ark-send '{}'

provider_post /v1/swaps/3e67e5b4-7f27-449a-bcfe-2d6b45d1690b/settle-ln \
  '{"preimage":"deca1573e3b7539b7bdc1f860e09a8d64da84e737cc6a044d9c11e70223b73a7"}'

api node1 POST /getpayment \
  '{"payment_hash":"af2cb14d6ce6ab9ad23881b0805e1a7921755fc3862e4008792fe94b7c0931ed"}'
```

Observed statuses:

- Swap id: `3e67e5b4-7f27-449a-bcfe-2d6b45d1690b`
- Provider swap status: `ln_hold_invoice_created` -> `ln_settled`
- LND invoice state: `ACCEPTED` -> `SETTLED`
- RGB payment status: `Succeeded`
- Payment hash:
  `af2cb14d6ce6ab9ad23881b0805e1a7921755fc3862e4008792fe94b7c0931ed`

## Direction 2: Ark Asset To RGB Asset

Path progression:

1. `node4` created a mapped RGB asset invoice for `1000` sat and RGB asset
   amount `10`, addressed to `node1`.
2. Ark taker wallet sent Ark asset amount `100` to the provider wallet.
3. Provider registered the RGB-side invoice as an `ark_to_ln` swap.
4. Provider started the Lightning payment.
5. RGB asset invoice reached `ln_accepted`.
6. `node4` sent RGB asset amount `10` to `node1` with keysend.
7. Receiver-side RGB payment reached `Succeeded`.
8. `node4` claimed the mapped RGB asset invoice.
9. Provider Lightning payment reached `ln_paid`; mapped RGB asset invoice
   reached `ln_claimed`.

CLI/API transcript:

```bash
api node4 POST /assetinvoice \
  '{"amt_msat":1000000,"asset_id":"rgb:j~dKPSFu-NIzm2WJ-CPzFKfO-ZnEk_3d-Rbq7fnY-v95~MTY","asset_amount":10,"recipient_pubkey":"027d53844319cfccbd35ee22b7295d944a3943946cf2ee0bc391ab9299ac0bbf53"}'

ark_cli <provider-maker-wallet> receive

ark_cli taker send \
  --to 'tark1qpt0syx7j0jspe69kldtljet0x9jz6ns4xw70m0w0xl30yfhn0mz6ak3n2y6rn57q2fj4593fgwxcnjc6pfnlrgq3mfprlmdjt4kl7sk7ggqu6' \
  --asset-id '0c9109c8ab004368a8c87f7fe88540b6335cb637eb36be5e1e9203d6858ec0b10100' \
  --amount 100 \
  --password '<password-redacted>'

provider_post_file /v1/swaps/ark-to-ln \
  ark-asset-to-rgb-asset-request.json

provider_post /v1/swaps/9b3a2ab7-c373-4b78-878a-dc3d3cb5f362/pay-ln \
  '{"fee_limit_sat":10}'

api node4 POST /getassetinvoice \
  '{"payment_hash":"6c66b62b3288883954f5a2f1ec426171b000d958fcf6e8900f487b107e607b47"}'

api node4 POST /keysend \
  '{"dest_pubkey":"027d53844319cfccbd35ee22b7295d944a3943946cf2ee0bc391ab9299ac0bbf53","amt_msat":3000000,"asset_id":"rgb:j~dKPSFu-NIzm2WJ-CPzFKfO-ZnEk_3d-Rbq7fnY-v95~MTY","asset_amount":10}'

api node1 POST /getpayment \
  '{"payment_hash":"5ee5fe80b76728284c3694e49c684bf0332ba778f43577765c3a60c41f646309"}'

api node4 POST /claimassetinvoice \
  '{"payment_hash":"6c66b62b3288883954f5a2f1ec426171b000d958fcf6e8900f487b107e607b47"}'
```

Observed statuses:

- Swap id: `9b3a2ab7-c373-4b78-878a-dc3d3cb5f362`
- Provider swap status: `ln_invoice_registered` -> `ln_paid`
- Mapped RGB invoice status: `invoice_created` -> `ln_accepted` -> `ln_claimed`
- RGB delivery payment status: `Succeeded`
- Payment hash:
  `6c66b62b3288883954f5a2f1ec426171b000d958fcf6e8900f487b107e607b47`
- RGB delivery payment hash:
  `5ee5fe80b76728284c3694e49c684bf0332ba778f43577765c3a60c41f646309`

## Publication Notes

The raw ignored run also contains local wallet paths, passwords, route details,
and raw provider/LND command output. This public artifact keeps protocol
identifiers visible:

- command shapes;
- asset ids, payment hashes, pubkeys, Ark addresses, BOLT11 invoices, swap IDs,
  swapstrings, and completed-test preimages;
- non-secret statuses and amounts;
- high-level topology labels.

Local wallet paths and passwords remain omitted.

No files from `state/`, `data/`, `logs/`, or provider target directories are
intended to be committed.
