#!/usr/bin/env bash

export MUTINY_SIM_DIR="${MUTINY_SIM_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

if [ -f "$MUTINY_SIM_DIR/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  source "$MUTINY_SIM_DIR/.env"
  set +a
fi

export NODE1_DAEMON_PORT="${NODE1_DAEMON_PORT:-3101}"
export NODE2_DAEMON_PORT="${NODE2_DAEMON_PORT:-3102}"
export NODE3_DAEMON_PORT="${NODE3_DAEMON_PORT:-3103}"
export NODE4_DAEMON_PORT="${NODE4_DAEMON_PORT:-3104}"
export DATA_DIR="${DATA_DIR:-$MUTINY_SIM_DIR/data}"
export LND_NETWORK="${LND_NETWORK:-signet}"
export LND_NO_MACAROONS="${LND_NO_MACAROONS:-1}"
export LNCLI_BINARY="${LNCLI_BINARY:-lncli}"
export LND1_DIR="${LND1_DIR:-$DATA_DIR/lnd1}"
export LND1_RPC_PORT="${LND1_RPC_PORT:-11041}"
export LND2_DIR="${LND2_DIR:-$DATA_DIR/lnd2}"
export LND2_RPC_PORT="${LND2_RPC_PORT:-11042}"
export ARK_CLI_DIR="${ARK_CLI_DIR:-$DATA_DIR/ark-cli}"
export ARK_CLI_PASSWORD="${ARK_CLI_PASSWORD:-mutinynet-ark-cli-password}"
export ARKD_DIR="${ARKD_DIR:-$DATA_DIR/arkd}"
export ARKD_ADMIN_PORT="${ARKD_ADMIN_PORT:-7071}"
export ARK_LND_PROVIDER_HOST="${ARK_LND_PROVIDER_HOST:-127.0.0.1}"
export ARK_LND_PROVIDER_PORT="${ARK_LND_PROVIDER_PORT:-8090}"

rln-url() {
  case "$1" in
    node1|r1) printf 'http://127.0.0.1:%s' "$NODE1_DAEMON_PORT" ;;
    node2|r2) printf 'http://127.0.0.1:%s' "$NODE2_DAEMON_PORT" ;;
    node3|r3) printf 'http://127.0.0.1:%s' "$NODE3_DAEMON_PORT" ;;
    node4|r4|rmm|rgb-mm|market-maker) printf 'http://127.0.0.1:%s' "$NODE4_DAEMON_PORT" ;;
    *) echo "unknown RGB node: $1" >&2; return 2 ;;
  esac
}

rln-call() {
  local node="$1" method="$2" path="$3" body="${4:-}" url
  url="$(rln-url "$node")$path"
  if [ -n "$body" ]; then
    curl -sS --fail-with-body -H 'Content-Type: application/json' -X "$method" --data "$body" "$url" | jq .
  else
    curl -sS --fail-with-body -H 'Content-Type: application/json' -X "$method" "$url" | jq .
  fi
}

r1() { rln-call node1 "$@"; }
r2() { rln-call node2 "$@"; }
r3() { rln-call node3 "$@"; }
r4() { rln-call node4 "$@"; }
rmm() { rln-call node4 "$@"; }

lnd-sim() {
  local label="$1"
  shift
  local dir port
  case "$label" in
    lnd1|lnda|rgb) dir="$LND1_DIR"; port="$LND1_RPC_PORT" ;;
    lnd2|lndb|ark) dir="$LND2_DIR"; port="$LND2_RPC_PORT" ;;
    *) echo "unknown lnd node: $label" >&2; return 2 ;;
  esac
  local -a args=(--lnddir "$dir" --rpcserver "127.0.0.1:$port" --network "$LND_NETWORK" --tlscertpath "$dir/tls.cert")
  if [ "$LND_NO_MACAROONS" = "1" ]; then
    args+=(--no-macaroons)
  elif [ -f "$dir/data/chain/bitcoin/$LND_NETWORK/admin.macaroon" ]; then
    args+=(--macaroonpath "$dir/data/chain/bitcoin/$LND_NETWORK/admin.macaroon")
  fi
  "$LNCLI_BINARY" "${args[@]}" "$@"
}

lnd1() { lnd-sim lnd1 "$@"; }
lnd2() { lnd-sim lnd2 "$@"; }

arkwallet() {
  local wallet="$1"
  shift
  ARK_WALLET_DATADIR="$ARK_CLI_DIR/$wallet" ark "$@"
}

arkmaker() { arkwallet maker "$@"; }
arktaker() { arkwallet taker "$@"; }

arkadmin() {
  arkd --url "http://127.0.0.1:$ARKD_ADMIN_PORT" --datadir "$ARKD_DIR" "$@"
}

ark-lnd-provider-url() {
  printf 'http://%s:%s' "$ARK_LND_PROVIDER_HOST" "$ARK_LND_PROVIDER_PORT"
}

ark-lnd-provider() {
  local method="$1" path="$2" body="${3:-}" url
  url="$(ark-lnd-provider-url)$path"
  if [ -n "$body" ]; then
    curl -sS --fail-with-body -H 'Content-Type: application/json' -X "$method" --data "$body" "$url" | jq .
  else
    curl -sS --fail-with-body -H 'Content-Type: application/json' -X "$method" "$url" | jq .
  fi
}

provider() { ark-lnd-provider "$@"; }

sim-build-rln() { "$MUTINY_SIM_DIR/scripts/build-rln.sh" "$@"; }
sim-init-local() { "$MUTINY_SIM_DIR/scripts/init-local.sh" "$@"; }
sim-start() { "$MUTINY_SIM_DIR/scripts/start.sh" "$@"; }
sim-stop() { "$MUTINY_SIM_DIR/scripts/stop.sh" "$@"; }
sim-init-unlock() { "$MUTINY_SIM_DIR/scripts/init-unlock.sh" "$@"; }
sim-status() { "$MUTINY_SIM_DIR/scripts/status.sh" "$@"; }
sim-faucet-auth() { "$MUTINY_SIM_DIR/scripts/faucet-auth.sh" "$@"; }
sim-faucet-fund() { "$MUTINY_SIM_DIR/scripts/faucet-fund.sh" "$@"; }
sim-bitcoind-p2p-port-forward() { "$MUTINY_SIM_DIR/scripts/bitcoind-p2p-port-forward.sh" "$@"; }
sim-bridge-ui() { "$MUTINY_SIM_DIR/scripts/bridge-ui.sh" "$@"; }
sim-bridge-plan() { "$MUTINY_SIM_DIR/scripts/bridge-plan.sh" "$@"; }
sim-setup-bridge-assets() { "$MUTINY_SIM_DIR/scripts/setup-bridge-assets.sh" "$@"; }
sim-setup-market-maker() { "$MUTINY_SIM_DIR/scripts/setup-market-maker.sh" "$@"; }
sim-test-lightning-ark-bridge() { "$MUTINY_SIM_DIR/scripts/test-lightning-ark-bridge.sh" "$@"; }
sim-rgb-asset-to-ark-asset() { "$MUTINY_SIM_DIR/scripts/rgb-asset-to-ark-asset.sh" "$@"; }
sim-ark-asset-to-rgb-asset() { "$MUTINY_SIM_DIR/scripts/ark-asset-to-rgb-asset.sh" "$@"; }

sim-logs() {
  tail -f "$@" "$MUTINY_SIM_DIR"/logs/*.log
}
