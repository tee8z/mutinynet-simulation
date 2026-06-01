# Mutinynet RGB / Ark / LND Simulation

This repo runs a local bridge simulation where RGB assets and Ark assets swap through Lightning settlement and Ark VHTLC contract VTXOs.

- RGB assets can buy Ark assets through an LND hold invoice and Ark VHTLC claim.
- Ark assets can buy RGB assets through an Ark VHTLC and RGB/LN invoice claim.
- Runtime swap actions use LND gRPC plus Rust Ark gRPC/client code.
- Simulation bootstrap uses the RGB Lightning node API for RGB asset issuance and `ark` CLI for local Ark wallet setup plus Ark asset issuance.

## Current Swap Path

Both bridge directions bind the Ark asset leg and the Lightning/RGB leg to the same 32-byte preimage.

```text
RGB asset -> Ark asset

node1
  | RGB asset payment
  v
node4 / rmm
  | BTC Lightning
  v
lnd1
  | BTC Lightning hold invoice
  v
lnd2 / provider
  | Ark VHTLC funded with Ark asset
  v
arktaker claims with the same preimage

Ark asset -> RGB asset

arktaker
  | Ark VHTLC funded with Ark asset
  v
provider / lnd2
  | BTC Lightning payment reveals preimage
  v
lnd1
  | RGB/LN mapped invoice
  v
node4 / rmm
  | RGB asset delivery
  v
node1
```

The swap design and acceptance checks are documented in [docs/ark-vhtlc-swap.md](docs/ark-vhtlc-swap.md).

## Real-World Shape

The local simulation drives both sides so the repo can prove the two swap directions end to end. That is a test harness boundary, not the expected production control model.

In a real wallet flow, the two sides are normally independent wallets controlled by different entities. One wallet creates or discovers an invoice carrying the payment hash, and another wallet accepts the matching quote by either paying the Lightning/RGB invoice or funding the Ark VHTLC. The invoice and its payment hash are the rendezvous point between the participants; no bridge or matching service is assumed to custody both wallets or perform both sides of the swap.

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

## Run The UI

Inside the dev shell:

```bash
nix develop
sim-start all
sim-init-unlock all
sim-bridge-ui
```

Then open:

```text
http://127.0.0.1:8091/
```

Useful UI API calls:

```bash
curl -sS http://127.0.0.1:8091/api/cluster | jq
curl -sS http://127.0.0.1:8091/api/preflight | jq

curl -sS -X POST http://127.0.0.1:8091/api/flows/start/setup-assets \
  -H 'Content-Type: application/json' \
  --data '{"rgb_asset_id":"<rgb_asset_id>","ark_asset_id":"<ark_asset_id>"}' | jq

curl -sS -X POST http://127.0.0.1:8091/api/flows/start/all \
  -H 'Content-Type: application/json' \
  --data '{"rgb_asset_id":"<rgb_asset_id>","ark_asset_id":"<ark_asset_id>"}' | jq

curl -sS http://127.0.0.1:8091/api/flows/<run-id> | jq
```

`setup-assets` funds the provider Ark gRPC wallet and the taker Ark gRPC wallet with BTC liquidity plus Ark asset inventory. The swap run writes proof artifacts under `state/bridge-ui/<run-id>/artifacts/`.

## Voltage Mutinynet Nodes

The simulator can use a Voltage-hosted Mutinynet Bitcoin Core node for RPC, P2P, and optional ZMQ. Configure HTTPS RPC normally, enable the local P2P tunnel, and leave `BITCOIND_P2P_HOST` empty so LND neutrino and NBXplorer use the plaintext localhost tunnel.

```bash
BITCOIND_MODE=external
BITCOIND_RPC_HOST=https://<node>.b.voltageapp.io
BITCOIND_RPC_USER=<rpc-user>
BITCOIND_RPC_PASS=<rpc-password>
BITCOIND_RPC_PROXY_ENABLED=auto
BITCOIND_P2P_TUNNEL_ENABLED=1
BITCOIND_P2P_TUNNEL_LOCAL_HOST=127.0.0.1
BITCOIND_P2P_TUNNEL_LOCAL_PORT=29333
BITCOIND_P2P_TUNNEL_TARGET_HOST=<node>.b.voltageapp.io
BITCOIND_P2P_TUNNEL_TARGET_PORT=38333
```

When the P2P hostname matches `BITCOIND_RPC_HOST`, `BITCOIND_P2P_TUNNEL_TARGET_HOST` and `BITCOIND_P2P_TUNNEL_SERVER_NAME` can be omitted. Use the public Voltage hostname provided for the node.

If the node exposes both TLS/SNI ZMQ rawblock and rawtx ports, the same proxy can provide local endpoints for LND bitcoind mode:

```bash
BITCOIND_ZMQ_TUNNEL_ENABLED=1
BITCOIND_ZMQ_TUNNEL_LOCAL_HOST=127.0.0.1
BITCOIND_ZMQ_TUNNEL_RAW_BLOCK_LOCAL_PORT=28332
BITCOIND_ZMQ_TUNNEL_RAW_TX_LOCAL_PORT=28333
BITCOIND_ZMQ_TUNNEL_TARGET_HOST=<node>.b.voltageapp.io
BITCOIND_ZMQ_TUNNEL_RAW_BLOCK_TARGET_PORT=28332
BITCOIND_ZMQ_TUNNEL_RAW_TX_TARGET_PORT=28333
```

When enabled, the ZMQ tunnel automatically sets `BITCOIND_ZMQ_PUB_RAW_BLOCK=tcp://127.0.0.1:28332` and `BITCOIND_ZMQ_PUB_RAW_TX=tcp://127.0.0.1:28333` unless those values are already set.

`sim-start all` starts enabled tunnels automatically. For focused checks, run:

```bash
sim-start p2p
sim-status p2p
nc -vz -w 5 127.0.0.1 29333
sim-start zmq
sim-status zmq
nc -vz -w 5 127.0.0.1 28332
nc -vz -w 5 127.0.0.1 28333
```

## Runtime Boundary

| Area | Implementation |
| --- | --- |
| RGB side | RGB Lightning node APIs create, prepare, send, deliver, claim, and report asset payment state. |
| LND side | Provider drives hold invoices, invoice payment, settlement, cancellation, and payreq decoding through LND gRPC. |
| Ark side | Provider uses Rust Ark gRPC/client code for receive, balance, VHTLC template, fund, verify, claim, and refund. |
| Bootstrap | RGB Lightning node API issues RGB assets; `ark` CLI initializes local Ark wallets, issues demo Ark assets, and funds local test inventory. |

## Public Proofs

Public proof artifacts live under [docs/proofs/](docs/proofs/). The current Ark VHTLC proof is the single flow README at [docs/proofs/README.md](docs/proofs/README.md), with screenshots linked from that page.

The proof records both directions with `contract_funded`, `contract_claimed`, `preimage_verified`, `ln_or_rgb_settled`, and `no_preimage_before_claim` set to `true`.

## Repo Map

| Path | Purpose |
| --- | --- |
| [USAGE.md](USAGE.md) | setup, flake commands, configuration |
| [docs/ark-vhtlc-swap.md](docs/ark-vhtlc-swap.md) | Ark VHTLC swap implementation |
| [docs/proofs/](docs/proofs/) | public proof artifacts |
| [scripts/](scripts/) | local service lifecycle and bridge harness |
| [providers/ark-lnd-swap-provider/](providers/ark-lnd-swap-provider/) | Ark/LND coordinator |
| [tools/bridge-ui/](tools/bridge-ui/) | Maud-rendered control plane for running bridge flows |
| [.env.example](.env.example) | documented runtime knobs |
| [LICENSE](LICENSE) | MIT license |

## Future Work

The current swap path does not require a bridge service that owns both sides of a swap. A quote service can still be useful as an optional wallet UX layer for price discovery, route hints, fees, expiries, and limits while each wallet continues to settle its own BTC/Lightning/RGB or Ark side.

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

- Exercise Ark VHTLC refund and timeout paths and publish proof artifacts for those branches.
- Add a [Taproot Assets](https://github.com/lightninglabs/taproot-assets) example that pays to and from Ark and RGB assets.
- Add optional quoting for inventory, rates, routes, fees, expiries, and min/max amounts.
- Extend the bridge UI into a small payment view.
- Add cleanup helpers for stale channels and RGB/LDK state.
