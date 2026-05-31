# Mutinynet RGB / Ark / LND Simulation

This repo runs a Mutinynet RGB / Ark / LND bridge simulation:

- RGB assets can buy Ark assets through Lightning settlement.
- Ark assets can buy RGB assets through Lightning settlement.
- RGB, Ark, and LND stay behind their protocol APIs.
- Provider runtime actions use LND gRPC plus Rust Ark gRPC/client code.
- Simulation bootstrap uses the RGB Lightning node API for RGB asset issuance
  and `ark` CLI for local Ark wallet setup plus Ark asset issuance.

BTC Lightning is the settlement rail. The committed public transcript records a
completed mapped-asset run. Trustless Ark VTXO modes write local artifacts under
`state/tests/trustless-ark-swap-*`.

## Public Transcript

Public transcript:
[2026-05-30 mapped bridge run](docs/proofs/lightning-ark-bridge-baseline-20260530T223914Z/)

Source run:
`state/tests/lightning-ark-bridge-all-20260530T223914Z/`

State paths stay ignored with local runtime state. The committed proof keeps the
protocol identifiers needed to audit the run: command shapes, statuses, amounts,
asset ids, payment hashes, pubkeys, swap ids, invoices, and completed-test
preimages. Local filesystem paths and passwords stay out.

```text
RGB asset -> Ark asset

node1
  | RGB asset
  v
node4 / rmm
  | BTC Lightning
  v
lnd1
  | BTC Lightning
  v
lnd2 / provider
  | Ark asset
  v
arktaker

Ark asset -> RGB asset

arktaker
  | Ark asset
  v
provider / lnd2
  | BTC Lightning
  v
lnd1
  | BTC Lightning
  v
node4 / rmm
  | RGB asset
  v
node1
```

UI example:

```text
run id:   1780188385-3327b727-9e6a-435c-969c-f4416a797b73
window:   2026-05-31T00:46:25Z -> 2026-05-31T00:46:42Z
artifacts: state/bridge-ui/1780188385-3327b727-9e6a-435c-969c-f4416a797b73/artifacts/

preflight:
  RGB asset  rgb:j~dKPS...-v95~MTY        source rgb_channel
  Ark asset  0c9109c8ab...c0b10100        source ark_balance
```

Ark asset used in the public transcript and UI example:
`0c9109c8ab004368a8c87f7fe88540b6335cb637eb36be5e1e9203d6858ec0b10100`

The table below is compact. The linked proof transcript keeps full identifiers.

| Flow | Swap | Input | Output | Final state |
| --- | --- | --- | --- | --- |
| RGB -> Ark | `371ba5cb...89e1` | 10 RGB units, 6000 sat hold invoice | 100 Ark units | payment hash `c255c73461...8a8e306`; RGB `Succeeded`; LND `SETTLED`; provider `ln_settled` |
| Ark -> RGB | `15699c56...0081` | 100 Ark units, 1000 sat invoice | 10 RGB units | payment hash `86961b4c5c...6446bb83`; provider `ln_paid`; RGB delivery `Succeeded`; mapped invoice `ln_claimed` |

Screenshot transcript from the same run:

| Cluster / Run | RGB -> Ark |
| --- | --- |
| <img src="images/proof-01-overview-preflight.png" alt="Cluster and preflight ready" width="430"> | <img src="images/proof-03-rgb-to-ark-start.png" alt="RGB to Ark timeline start" width="430"> |
| <img src="images/proof-02-run-form.png" alt="Run form and succeeded all run" width="430"> | <img src="images/proof-04-rgb-to-ark-inventory-recipient.png" alt="Ark inventory and recipient" width="430"> |
| <img src="images/proof-14-run-log-json.png" alt="Run log and JSON payload" width="430"> | <img src="images/proof-05-rgb-to-ark-payment.png" alt="Hold invoice and RGB payment" width="430"> |
|  | <img src="images/proof-06-rgb-to-ark-invoice-accepted.png" alt="Provider LND invoice accepted" width="430"> |
|  | <img src="images/proof-07-rgb-to-ark-settlement.png" alt="Ark asset send and hold invoice settlement" width="430"> |
|  | <img src="images/proof-08-rgb-to-ark-complete.png" alt="RGB payment succeeded and Ark balance updated" width="430"> |

| Ark -> RGB | Completion |
| --- | --- |
| <img src="images/proof-09-ark-to-rgb-start.png" alt="Ark to RGB timeline start" width="430"> | <img src="images/proof-12-ark-to-rgb-provider-pay.png" alt="Provider pays Lightning invoice" width="430"> |
| <img src="images/proof-10-ark-to-rgb-invoice-recipient.png" alt="Mapped RGB invoice and Ark recipient" width="430"> | <img src="images/proof-13-ark-to-rgb-complete.png" alt="RGB delivery succeeded and invoice claimed" width="430"> |
| <img src="images/proof-11-ark-to-rgb-provider-register.png" alt="Provider registers mapped RGB invoice" width="430"> |  |

## Topology

```text
                         Mutinynet Bitcoin Core
                     RPC / P2P / ZMQ / indexers
                                  |
                                  v

node1  <===== RGB asset channel =====>  node4 / rmm
 RGB wallet                              RGB market maker
                                             |
                                             | BTC Lightning
                                             v
                                           lnd1
                                             |
                                             | BTC Lightning
                                             v
                                           lnd2
                                             |
                                             v
                                      ark-lnd-provider
                                      Ark + LND2 only
                                             |
                                             v
                                      arkd / Ark wallets
```

## Mechanics

| RGB -> Ark | What moves |
| --- | --- |
| `hold invoice` | provider locks the Lightning leg |
| `RGB asset payment` | node1 pays through node4/rmm |
| `LND invoice accepted` | provider sees the held BTC invoice |
| `Ark asset send` | provider sends Ark asset to taker |
| `hold invoice settled` | preimage completes the Lightning leg |

| Ark -> RGB | What moves |
| --- | --- |
| `Ark asset send` | taker sends Ark asset to provider |
| `mapped RGB invoice` | node4 creates the RGB-side BTC invoice |
| `provider pays LND invoice` | provider starts the Lightning leg |
| `RGB asset delivery` | node4 sends RGB asset to node1 |
| `mapped invoice claimed` | node4 claims the BTC invoice |

The provider maps Ark-side asset movement to Lightning invoices controlled by
`lnd2`. RGB asset preparation, delivery, and claiming stay in the RGB Lightning
node APIs.

| Piece | Runtime behavior |
| --- | --- |
| RGB side | RGB Lightning node APIs create, prepare, send, deliver, claim, and report asset payment state. |
| LND side | Provider drives hold invoices, invoice payment, and settlement through LND gRPC. |
| Ark side | Provider uses Rust Ark gRPC/client code for Ark sends and contract VTXOs; simulation bootstrap uses `ark` CLI for local Ark wallet setup and Ark asset issuance. |

## Run The UI

Inside the dev shell:

```bash
nix develop
sim-bridge-ui
```

From a plain shell:

```bash
nix run .#bridge-ui
```

If `sim-bridge-ui` is not on `PATH` in an existing shell:

```bash
source ./alias.sh
sim-bridge-ui
```

Then open the UI. The JSON API is available for scripts:

```bash
xdg-open http://127.0.0.1:8091/
curl -sS http://127.0.0.1:8091/api/cluster | jq
curl -sS -X POST http://127.0.0.1:8091/api/flows/start/setup-assets | jq
curl -sS -X POST http://127.0.0.1:8091/api/flows/start/rgb-asset-to-ark-asset | jq
curl -sS -X POST http://127.0.0.1:8091/api/flows/start/ark-asset-to-rgb-asset | jq
curl -sS -X POST http://127.0.0.1:8091/api/flows/start/trustless-all | jq
curl -sS http://127.0.0.1:8091/api/flows/<run-id> | jq
```

For screenshots, run `all` and capture cluster health, preflight, the succeeded
run row, the timeline, and the run JSON panel. The UI keeps protocol
identifiers visible and scrubs local filesystem paths.

Repeated local runs move Lightning liquidity. If RGB -> Ark fails with
`insufficient bandwidth`, pay a normal invoice from `lnd2` to `lnd1`, then run
`all` again.

## Runtime Boundary

| Area | Implementation |
| --- | --- |
| LND access | Direct LND gRPC client. |
| Ark provider access | Rust Ark gRPC/client provider path. |
| Simulation bootstrap | RGB Lightning node API issues RGB assets; `ark` CLI initializes local Ark wallets, issues demo Ark assets, and funds local test inventory. |
| Swap modes | Mapped-asset flows and Ark VHTLC contract flows are available from the harness. |
| Proof artifacts | Public mapped-asset and trustless VTXO transcripts under `docs/proofs/`; UI run artifacts under `state/bridge-ui/`. |

The Ark VTXO flow is documented in
[docs/trustless-ark-swap.md](docs/trustless-ark-swap.md). The local harness
supports `trustless-rgb-asset-to-ark-asset`,
`trustless-ark-asset-to-rgb-asset`, and `trustless-all`.

## Repo Map

| Path | Purpose |
| --- | --- |
| [USAGE.md](USAGE.md) | setup, flake commands, configuration |
| [docs/proofs/](docs/proofs/) | public proof artifacts |
| [docs/trustless-ark-swap.md](docs/trustless-ark-swap.md) | Ark contract-bound swap implementation |
| [scripts/](scripts/) | cluster lifecycle and bridge harness |
| [providers/ark-lnd-swap-provider/](providers/ark-lnd-swap-provider/) | Ark/LND coordinator |
| [tools/bridge-ui/](tools/bridge-ui/) | Maud-rendered control plane for running bridge flows |
| [.env.example](.env.example) | documented runtime knobs |
| [LICENSE](LICENSE) | MIT license |

## Future Work

```text
              quote service
        price / route / fee / expiry
                    |
   +----------------+----------------+
   |                |                |
 RGB assets     Ark assets     Taproot Assets
   |                |                |
   +----------------+----------------+
                    |
              small payment UI
        choose in -> quote -> pay -> receipt
```

- Add timeout/refund proof coverage for the Ark contract-bound VTXO path.
- Add a [Taproot Assets](https://github.com/lightninglabs/taproot-assets)
  example that pays to and from Ark and RGB assets.
- Add quoting for inventory, rates, routes, fees, expiries, and min/max amounts.
- Extend the bridge UI into a small payment view.
- Add cleanup helpers for stale channels and RGB/LDK state.
