# Usage

This file is the runbook. The proof summary is in [README.md](README.md).

## Requirements

- Nix with flakes enabled.
- Linux `x86_64` or `aarch64`.
- A synced Mutinynet Bitcoin Core RPC endpoint, or time to sync the local Core
  packaged by this flake.

Runtime data stays under ignored local directories: `data/`, `logs/`, `run/`,
and `state/`.

## Project Links

The flake pins or packages these external projects:

| Project | Used for |
| --- | --- |
| [nixpkgs](https://github.com/NixOS/nixpkgs) | package set and dev shell |
| [tee8z/lnd](https://github.com/tee8z/lnd/tree/feat/custom-signet-block-time) | Mutinynet-aware LND fork |
| [tee8z/rgb-lightning-node](https://github.com/tee8z/rgb-lightning-node/tree/feat/regular-lightning-channels) | RGB Lightning node fork |
| [arkade-os/arkd](https://github.com/arkade-os/arkd) | Ark server, wallet, and CLI |
| [benthecarman/bitcoin](https://github.com/benthecarman/bitcoin/releases/tag/mutinynet-inq-template-hash) | local Mutinynet Bitcoin Core |
| [Blockstream/electrs](https://github.com/Blockstream/electrs/tree/new-index) | optional local Esplora backend |
| [RGB-Tools/rgb-proxy-server](https://github.com/RGB-Tools/rgb-proxy-server) | RGB consignment proxy |
| [NBXplorer](https://github.com/dgarage/NBXplorer) | Bitcoin indexer for Ark server wallet |
| [mutinynet-cli](https://github.com/benthecarman/mutinynet-cli) | Mutinynet faucet helper |

## Shell

```bash
cp .env.example .env
$EDITOR .env
nix develop
```

The shell loads aliases such as `sim-start`, `sim-status`, `lnd1`, `rmm`,
`arkmaker`, and `provider`.

## Bitcoin Backend

Default mode uses an existing synced Mutinynet Core:

```bash
BITCOIND_MODE=external
BITCOIND_RPC_HOST=http://bitcoin.local:38332
BITCOIND_RPC_USER=your-rpc-user
BITCOIND_RPC_PASS=your-rpc-password
```

HTTPS RPC endpoints work through the local proxy when
`BITCOIND_RPC_PROXY_ENABLED=auto`.

Local Core is available, but first sync is slow:

```bash
BITCOIND_MODE=local
BITCOIND_ASSUMEVALID=$(curl -sS https://mutinynet.com/api/blocks/tip/hash)
```

## RGB Indexer

Default:

```bash
RLN_INDEXER_MODE=external
RLN_INDEXER_URL=https://mutinynet.com/api
```

Local Esplora:

```bash
RLN_INDEXER_MODE=local
ESPLORA_HTTP_HOST=127.0.0.1
ESPLORA_HTTP_PORT=3003
ESPLORA_LIGHTMODE=1
ESPLORA_JSONRPC_IMPORT=1
```

Local Esplora will not serve HTTP until local Core leaves initial block
download.

## Build RGB Node

```bash
sim-build-rln
```

The helper uses `RLN_REPO`, `RLN_GIT_URL`, and `RLN_GIT_REF` from `.env`.

## Start

```bash
sim-start all
sim-init-unlock all
sim-status
```

Stop:

```bash
sim-stop all
```

## Funding

Default faucet:

```bash
FAUCET_PROVIDER=ben
sim-faucet-auth
sim-faucet-fund all
```

Voltage faucet:

```bash
FAUCET_PROVIDER=voltage
VOLTAGE_AUTH_USERNAME=you@example.com
VOLTAGE_AUTH_PASSWORD=...
VOLTAGE_AUTH_MFA_CODE=... # only when required
```

## LND Notes

Default LND mode:

```bash
LND_DB_BACKEND=sqlite
LND_CHAIN_BACKEND=bitcoind
```

Neutrino mode needs a reachable Bitcoin P2P endpoint:

```bash
LND_CHAIN_BACKEND=neutrino
BITCOIND_P2P_HOST=bitcoin.local
BITCOIND_P2P_PORT=38333
LND_SIGNET_BLOCK_TIME=30s
```

For local Core neutrino tests, enable compact filters before first sync:

```bash
BITCOIND_BLOCKFILTERINDEX=1
BITCOIND_PEERBLOCKFILTERS=1
```

## P2P Tunnel

For a Core P2P service reachable only through Kubernetes:

```bash
BITCOIND_P2P_PORT_FORWARD_ENABLED=1
BITCOIND_P2P_PORT_FORWARD_NAMESPACE=<namespace>
BITCOIND_P2P_PORT_FORWARD_SERVICE=<service>
BITCOIND_P2P_PORT_FORWARD_LOCAL_PORT=29333
BITCOIND_P2P_PORT_FORWARD_REMOTE_PORT=38333
```

`sim-start all` starts the tunnel when it is enabled.

## Market Maker

After issuing an RGB asset:

```bash
RGB_MM_ASSET_ID=<rgb_asset_id> sim-setup-market-maker
```

This opens:

```text
node1 <== RGB asset channel ==> node4/rmm
node4/rmm <== BTC Lightning ==> lnd1
```

## Bridge Harness

Run both directions:

```bash
sim-init-local
RGB_MM_ASSET_ID=<rgb_asset_id> sim-setup-market-maker

BRIDGE_TEST_RGB_ASSET_ID=<rgb_asset_id> \
BRIDGE_TEST_ARK_ASSET_ID=<ark_asset_id> \
sim-rgb-asset-to-ark-asset

BRIDGE_TEST_RGB_ASSET_ID=<rgb_asset_id> \
BRIDGE_TEST_ARK_ASSET_ID=<ark_asset_id> \
sim-ark-asset-to-rgb-asset
```

Combined harness:

```bash
BRIDGE_TEST_RGB_ASSET_ID=<rgb_asset_id> \
BRIDGE_TEST_ARK_ASSET_ID=<ark_asset_id> \
sim-test-lightning-ark-bridge all
```

Artifacts are written under:

```text
state/tests/lightning-ark-bridge-<mode>-<timestamp>/
```

Public-safe proof transcripts live under [docs/proofs/](docs/proofs/).
The contract-bound VTXO harness is specified in
[docs/trustless-ark-swap.md](docs/trustless-ark-swap.md). Script artifacts use
`state/tests/trustless-ark-swap-<mode>-<timestamp>/`; UI artifacts use
`state/bridge-ui/<run-id>/artifacts/`.

## Bridge UI

Start the local UI:

```bash
sim-bridge-ui
```

Default URL:

```text
http://127.0.0.1:8091
```

Useful calls:

```bash
xdg-open http://127.0.0.1:8091/

curl -sS http://127.0.0.1:8091/api/cluster | jq

curl -sS -X POST http://127.0.0.1:8091/api/flows/start/setup-assets \
  -H 'Content-Type: application/json' \
  --data '{}' | jq

curl -sS -X POST http://127.0.0.1:8091/api/flows/start/rgb-asset-to-ark-asset \
  -H 'Content-Type: application/json' \
  --data '{}' | jq

curl -sS -X POST http://127.0.0.1:8091/api/flows/start/ark-asset-to-rgb-asset \
  -H 'Content-Type: application/json' \
  --data '{}' | jq

curl -sS -X POST http://127.0.0.1:8091/api/flows/start/trustless-all \
  -H 'Content-Type: application/json' \
  --data '{}' | jq

curl -sS http://127.0.0.1:8091/api/flows/<run-id> | jq
```

The UI wraps the existing bridge harness, writes artifacts under
`state/bridge-ui/`, and redacts invoices, preimages, addresses, wallet paths,
pubkeys, route details, and passwords from UI and JSON responses.

Run `setup-assets` before `trustless-all`. It funds the provider and taker Ark
gRPC wallets with BTC liquidity and Ark asset inventory for the contract VTXO
flows.

## Useful Commands

```bash
r1 GET /nodeinfo
rmm GET /listchannels
lnd1 getinfo
lnd2 getinfo
arkadmin wallet status
arkmaker receive
arktaker balance
provider GET /health
provider GET /v1/swaps
```

Nix apps are also exposed:

```bash
nix run .#status
nix run .#start -- all
nix run .#bridge-ui
nix run .#test-lightning-ark-bridge -- all
```
