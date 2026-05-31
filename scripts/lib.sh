#!/usr/bin/env bash

set -euo pipefail

SIM_DIR="${MUTINY_SIM_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

if [ -f "$SIM_DIR/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  source "$SIM_DIR/.env"
  set +a
fi

DATA_DIR="${DATA_DIR:-$SIM_DIR/data}"
LOG_DIR="${LOG_DIR:-$SIM_DIR/logs}"
STATE_DIR="${STATE_DIR:-$SIM_DIR/state}"
RUN_DIR="${RUN_DIR:-$SIM_DIR/run}"

DEFAULT_SIGNET_CHALLENGE="512102f7561d208dd9ae99bf497273e16f389bdbd6c4742ddb8e6b216e64fa2928ad8f51ae"
SIGNET_CHALLENGE="${SIGNET_CHALLENGE:-$DEFAULT_SIGNET_CHALLENGE}"

BITCOIND_MODE="${BITCOIND_MODE:-external}"
BITCOIND_BINARY="${BITCOIND_BINARY:-bitcoind}"
BITCOIN_CLI_BINARY="${BITCOIN_CLI_BINARY:-bitcoin-cli}"
BITCOIND_DIR="${BITCOIND_DIR:-$DATA_DIR/bitcoind}"
BITCOIND_CONF="${BITCOIND_CONF:-$BITCOIND_DIR/bitcoin.conf}"
BITCOIND_RPC_PORT="${BITCOIND_RPC_PORT:-38332}"
BITCOIND_P2P_PORT="${BITCOIND_P2P_PORT:-38333}"
BITCOIND_P2P_HOST="${BITCOIND_P2P_HOST:-}"
BITCOIND_RPC_BIND="${BITCOIND_RPC_BIND:-127.0.0.1}"
BITCOIND_RPC_ALLOW_IP="${BITCOIND_RPC_ALLOW_IP:-127.0.0.1}"
BITCOIND_BIND="${BITCOIND_BIND:-127.0.0.1}"
BITCOIND_ZMQ_RAW_BLOCK_PORT="${BITCOIND_ZMQ_RAW_BLOCK_PORT:-28332}"
BITCOIND_ZMQ_RAW_TX_PORT="${BITCOIND_ZMQ_RAW_TX_PORT:-28333}"
BITCOIND_BLOCKFILTERINDEX="${BITCOIND_BLOCKFILTERINDEX:-0}"
BITCOIND_PEERBLOCKFILTERS="${BITCOIND_PEERBLOCKFILTERS:-0}"
BITCOIND_TXINDEX="${BITCOIND_TXINDEX:-0}"
BITCOIND_DNSSEED="${BITCOIND_DNSSEED:-0}"
BITCOIND_ADDNODE="${BITCOIND_ADDNODE:-45.79.52.207:38333}"
BITCOIND_SIGNET_BLOCK_TIME="${BITCOIND_SIGNET_BLOCK_TIME:-30}"
BITCOIND_DBCACHE="${BITCOIND_DBCACHE:-2048}"
BITCOIND_BLOCKSONLY="${BITCOIND_BLOCKSONLY:-1}"
BITCOIND_MAXCONNECTIONS="${BITCOIND_MAXCONNECTIONS:-32}"
BITCOIND_ASSUMEVALID="${BITCOIND_ASSUMEVALID:-}"
BITCOIND_RPC_PROXY_ENABLED="${BITCOIND_RPC_PROXY_ENABLED:-auto}"
BITCOIND_RPC_PROXY_HOST="${BITCOIND_RPC_PROXY_HOST:-127.0.0.1}"
BITCOIND_RPC_PROXY_PORT="${BITCOIND_RPC_PROXY_PORT:-$BITCOIND_RPC_PORT}"
BITCOIND_RPC_PROXY_TIMEOUT="${BITCOIND_RPC_PROXY_TIMEOUT:-60}"
BITCOIND_ZMQ_PUB_RAW_BLOCK="${BITCOIND_ZMQ_PUB_RAW_BLOCK:-${BITCOIND_ZMQPUBRAWBLOCK:-}}"
BITCOIND_ZMQ_PUB_RAW_TX="${BITCOIND_ZMQ_PUB_RAW_TX:-${BITCOIND_ZMQPUBRAWTX:-}}"
BITCOIND_P2P_PORT_FORWARD_ENABLED="${BITCOIND_P2P_PORT_FORWARD_ENABLED:-0}"
BITCOIND_P2P_PORT_FORWARD_NAMESPACE="${BITCOIND_P2P_PORT_FORWARD_NAMESPACE:-}"
BITCOIND_P2P_PORT_FORWARD_SERVICE="${BITCOIND_P2P_PORT_FORWARD_SERVICE:-}"
BITCOIND_P2P_PORT_FORWARD_LOCAL_HOST="${BITCOIND_P2P_PORT_FORWARD_LOCAL_HOST:-127.0.0.1}"
BITCOIND_P2P_PORT_FORWARD_LOCAL_PORT="${BITCOIND_P2P_PORT_FORWARD_LOCAL_PORT:-29333}"
BITCOIND_P2P_PORT_FORWARD_REMOTE_PORT="${BITCOIND_P2P_PORT_FORWARD_REMOTE_PORT:-38333}"
BITCOIND_P2P_PORT_FORWARD_AWS_PROFILE="${BITCOIND_P2P_PORT_FORWARD_AWS_PROFILE:-${AWS_PROFILE:-}}"

if [ "$BITCOIND_MODE" = "local" ]; then
  BITCOIND_RPC_HOST="http://127.0.0.1:$BITCOIND_RPC_PORT"
  BITCOIND_RPC_USER="${BITCOIND_RPC_USER:-mutinynet}"
  BITCOIND_RPC_PASS="${BITCOIND_RPC_PASS:-mutinynet}"
  BITCOIND_P2P_HOST="127.0.0.1"
  BITCOIND_ZMQ_PUB_RAW_BLOCK="${BITCOIND_ZMQ_PUB_RAW_BLOCK:-tcp://127.0.0.1:$BITCOIND_ZMQ_RAW_BLOCK_PORT}"
  BITCOIND_ZMQ_PUB_RAW_TX="${BITCOIND_ZMQ_PUB_RAW_TX:-tcp://127.0.0.1:$BITCOIND_ZMQ_RAW_TX_PORT}"
fi

NBXPLORER_ENABLED="${NBXPLORER_ENABLED:-1}"
NBXPLORER_DIR="${NBXPLORER_DIR:-$DATA_DIR/nbxplorer}"
NBXPLORER_NETWORK="${NBXPLORER_NETWORK:-mutinynet}"
NBXPLORER_BIND="${NBXPLORER_BIND:-127.0.0.1}"
NBXPLORER_PORT="${NBXPLORER_PORT:-32838}"
NBXPLORER_BTCNODEENDPOINT="${NBXPLORER_BTCNODEENDPOINT:-}"
NBXPLORER_POSTGRES="${NBXPLORER_POSTGRES:-}"
NBXPLORER_POSTGRES_MANAGED="${NBXPLORER_POSTGRES_MANAGED:-1}"
NBXPLORER_POSTGRES_DIR="${NBXPLORER_POSTGRES_DIR:-$DATA_DIR/nbxplorer-postgres}"
NBXPLORER_POSTGRES_HOST="${NBXPLORER_POSTGRES_HOST:-127.0.0.1}"
NBXPLORER_POSTGRES_PORT="${NBXPLORER_POSTGRES_PORT:-15432}"
NBXPLORER_POSTGRES_DB="${NBXPLORER_POSTGRES_DB:-nbxplorer}"
NBXPLORER_POSTGRES_USER="${NBXPLORER_POSTGRES_USER:-${USER:-$(id -un)}}"
NBXPLORER_POSTGRES_SOCKET_DIR="${NBXPLORER_POSTGRES_SOCKET_DIR:-/tmp/mutinynet-simulation-nbxplorer-postgres-${UID:-$(id -u)}}"

RLN_INDEXER_MODE="${RLN_INDEXER_MODE:-external}"
ESPLORA_BINARY="${ESPLORA_BINARY:-electrs}"
ESPLORA_DIR="${ESPLORA_DIR:-$DATA_DIR/esplora}"
ESPLORA_DB_DIR="${ESPLORA_DB_DIR:-$ESPLORA_DIR/db}"
ESPLORA_NETWORK="${ESPLORA_NETWORK:-signet}"
ESPLORA_HTTP_HOST="${ESPLORA_HTTP_HOST:-127.0.0.1}"
ESPLORA_HTTP_PORT="${ESPLORA_HTTP_PORT:-3003}"
ESPLORA_ELECTRUM_HOST="${ESPLORA_ELECTRUM_HOST:-127.0.0.1}"
ESPLORA_ELECTRUM_PORT="${ESPLORA_ELECTRUM_PORT:-60601}"
ESPLORA_MONITORING_HOST="${ESPLORA_MONITORING_HOST:-127.0.0.1}"
ESPLORA_MONITORING_PORT="${ESPLORA_MONITORING_PORT:-54224}"
ESPLORA_LIGHTMODE="${ESPLORA_LIGHTMODE:-1}"
ESPLORA_JSONRPC_IMPORT="${ESPLORA_JSONRPC_IMPORT:-1}"
ESPLORA_INDEX_UNSPENDABLES="${ESPLORA_INDEX_UNSPENDABLES:-1}"
ESPLORA_ADDRESS_SEARCH="${ESPLORA_ADDRESS_SEARCH:-0}"
ESPLORA_CORS="${ESPLORA_CORS:-*}"
ESPLORA_EXTRA_ARGS="${ESPLORA_EXTRA_ARGS:-}"
ESPLORA_START_WAIT_FOR_HTTP="${ESPLORA_START_WAIT_FOR_HTTP:-0}"
ESPLORA_HTTP_WAIT_TIMEOUT_SEC="${ESPLORA_HTTP_WAIT_TIMEOUT_SEC:-180}"

INIT_LOCAL_POLL_SEC="${INIT_LOCAL_POLL_SEC:-30}"
INIT_LOCAL_TIMEOUT_SEC="${INIT_LOCAL_TIMEOUT_SEC:-0}"

RLN_REPO="${RLN_REPO:-$HOME/repos/rgb-lightning-node}"
RLN_GIT_URL="${RLN_GIT_URL:-https://github.com/tee8z/rgb-lightning-node.git}"
RLN_GIT_REF="${RLN_GIT_REF:-feat/regular-lightning-channels}"
RLN_DATA_DIR="${RLN_DATA_DIR:-$DATA_DIR/rln}"
RLN_NETWORK="${RLN_NETWORK:-signetcustom}"
RLN_NODE_PASSWORD="${RLN_NODE_PASSWORD:-mutinynet-rln-password}"
case "$RLN_INDEXER_MODE" in
  local|managed|1|true|TRUE|yes|YES|on|ON)
    if [ -z "${RLN_INDEXER_URL:-}" ] || [ "${RLN_INDEXER_URL:-}" = "https://mutinynet.com/api" ]; then
      RLN_INDEXER_URL="http://$ESPLORA_HTTP_HOST:$ESPLORA_HTTP_PORT"
    fi
    ;;
  *)
    RLN_INDEXER_URL="${RLN_INDEXER_URL:-https://mutinynet.com/api}"
    ;;
esac
RLN_SKIP_CONSISTENCY_CHECK="${RLN_SKIP_CONSISTENCY_CHECK:-1}"
RGB_PROXY_ENABLED="${RGB_PROXY_ENABLED:-1}"
RGB_PROXY_PORT="${RGB_PROXY_PORT:-3000}"
RGB_PROXY_DATA_DIR="${RGB_PROXY_DATA_DIR:-$DATA_DIR/rgb-proxy}"
RGB_PROXY_ENDPOINT="${RGB_PROXY_ENDPOINT:-rpc://127.0.0.1:${RGB_PROXY_PORT}/json-rpc}"
NODE1_DAEMON_PORT="${NODE1_DAEMON_PORT:-3101}"
NODE1_PEER_PORT="${NODE1_PEER_PORT:-19735}"
NODE2_DAEMON_PORT="${NODE2_DAEMON_PORT:-3102}"
NODE2_PEER_PORT="${NODE2_PEER_PORT:-19736}"
NODE3_DAEMON_PORT="${NODE3_DAEMON_PORT:-3103}"
NODE3_PEER_PORT="${NODE3_PEER_PORT:-19737}"
NODE4_DAEMON_PORT="${NODE4_DAEMON_PORT:-3104}"
NODE4_PEER_PORT="${NODE4_PEER_PORT:-19738}"

LND_NETWORK="${LND_NETWORK:-signet}"
LND_SIGNET_CHALLENGE="${LND_SIGNET_CHALLENGE:-$SIGNET_CHALLENGE}"
LND_SIGNET_BLOCK_TIME="${LND_SIGNET_BLOCK_TIME:-}"
LND_BINARY="${LND_BINARY:-lnd}"
LNCLI_BINARY="${LNCLI_BINARY:-lncli}"
LND_ADD_PEERS="${LND_ADD_PEERS:-}"
LND_WALLET_PASSWORD="${LND_WALLET_PASSWORD:-mutinynet-lnd-password}"
LND_NO_MACAROONS="${LND_NO_MACAROONS:-1}"
LND_NO_SEED_BACKUP="${LND_NO_SEED_BACKUP:-1}"
LND_NO_ANCHORS="${LND_NO_ANCHORS:-1}"
LND_LOG_LEVEL="${LND_LOG_LEVEL:-info}"
LND_DB_BACKEND="${LND_DB_BACKEND:-sqlite}"
LND_DB_SQLITE_TIMEOUT="${LND_DB_SQLITE_TIMEOUT:-30s}"
LND_DB_SQLITE_BUSY_TIMEOUT="${LND_DB_SQLITE_BUSY_TIMEOUT:-30s}"
LND_DB_SQLITE_MAX_CONNECTIONS="${LND_DB_SQLITE_MAX_CONNECTIONS:-8}"
LND_CHAIN_BACKEND="${LND_CHAIN_BACKEND:-bitcoind}"
LND_NEUTRINO_CONNECT="${LND_NEUTRINO_CONNECT:-}"
LND_NEUTRINO_ADD_PEER="${LND_NEUTRINO_ADD_PEER:-}"
LND_NEUTRINO_MAX_PEERS="${LND_NEUTRINO_MAX_PEERS:-1}"
LND_NEUTRINO_PERSIST_FILTERS="${LND_NEUTRINO_PERSIST_FILTERS:-1}"
LND_ZMQ_PUB_RAW_BLOCK="${LND_ZMQ_PUB_RAW_BLOCK:-${LND_ZMQPUBRAWBLOCK:-$BITCOIND_ZMQ_PUB_RAW_BLOCK}}"
LND_ZMQ_PUB_RAW_TX="${LND_ZMQ_PUB_RAW_TX:-${LND_ZMQPUBRAWTX:-$BITCOIND_ZMQ_PUB_RAW_TX}}"
LND_ZMQ_READ_DEADLINE="${LND_ZMQ_READ_DEADLINE:-${BITCOIND_ZMQ_READ_DEADLINE:-5s}}"
LND1_DIR="${LND1_DIR:-$DATA_DIR/lnd1}"
LND1_RPC_PORT="${LND1_RPC_PORT:-11041}"
LND1_REST_PORT="${LND1_REST_PORT:-18081}"
LND1_PEER_PORT="${LND1_PEER_PORT:-20841}"
LND1_ALIAS="${LND1_ALIAS:-mut-sim-lnd-rgb-side}"
LND2_DIR="${LND2_DIR:-$DATA_DIR/lnd2}"
LND2_RPC_PORT="${LND2_RPC_PORT:-11042}"
LND2_REST_PORT="${LND2_REST_PORT:-18082}"
LND2_PEER_PORT="${LND2_PEER_PORT:-20842}"
LND2_ALIAS="${LND2_ALIAS:-mut-sim-lnd-ark-side}"

ARK_NETWORK="${ARK_NETWORK:-mutinynet}"
ARK_EXPLORER_URL="${ARK_EXPLORER_URL:-https://mempool.mutinynet.arkade.sh/api}"
ARKD_WALLET_DIR="${ARKD_WALLET_DIR:-$DATA_DIR/arkd-wallet}"
ARKD_WALLET_PORT="${ARKD_WALLET_PORT:-6060}"
ARKD_WALLET_SIGNER_KEY="${ARKD_WALLET_SIGNER_KEY:-19422b10efd05403820ff6a3365422be2fc5f07f34a6d1603f7298328f0f80f6}"
ARKD_DIR="${ARKD_DIR:-$DATA_DIR/arkd}"
ARKD_PORT="${ARKD_PORT:-7070}"
ARKD_ADMIN_PORT="${ARKD_ADMIN_PORT:-7071}"
ARKD_PASSWORD="${ARKD_PASSWORD:-mutinynet-arkd-password}"
ARK_CLI_DIR="${ARK_CLI_DIR:-$DATA_DIR/ark-cli}"
ARK_CLI_PASSWORD="${ARK_CLI_PASSWORD:-mutinynet-ark-cli-password}"

ARK_LND_PROVIDER_ENABLED="${ARK_LND_PROVIDER_ENABLED:-1}"
ARK_LND_PROVIDER_DIR="${ARK_LND_PROVIDER_DIR:-$DATA_DIR/ark-lnd-provider}"
ARK_LND_PROVIDER_HOST="${ARK_LND_PROVIDER_HOST:-127.0.0.1}"
ARK_LND_PROVIDER_PORT="${ARK_LND_PROVIDER_PORT:-8090}"
ARK_LND_PROVIDER_BIND="${ARK_LND_PROVIDER_BIND:-$ARK_LND_PROVIDER_HOST:$ARK_LND_PROVIDER_PORT}"
ARK_LND_PROVIDER_DB="${ARK_LND_PROVIDER_DB:-$ARK_LND_PROVIDER_DIR/provider.sqlite}"
ARK_LND_PROVIDER_LND_NODE="${ARK_LND_PROVIDER_LND_NODE:-lnd2}"
ARK_LND_PROVIDER_ARK_WALLET="${ARK_LND_PROVIDER_ARK_WALLET:-maker}"
ARK_LND_PROVIDER_ARK_WALLET_DIR="${ARK_LND_PROVIDER_ARK_WALLET_DIR:-$ARK_CLI_DIR/$ARK_LND_PROVIDER_ARK_WALLET}"
ARK_LND_PROVIDER_COMMAND_TIMEOUT_SEC="${ARK_LND_PROVIDER_COMMAND_TIMEOUT_SEC:-120}"
ARK_LND_PROVIDER_ARK_SERVER_URL="${ARK_LND_PROVIDER_ARK_SERVER_URL:-http://127.0.0.1:$ARKD_PORT}"
ARK_LND_PROVIDER_ARK_NETWORK="${ARK_LND_PROVIDER_ARK_NETWORK:-$ARK_NETWORK}"
ARK_LND_PROVIDER_ARK_PRIVATE_KEY_HEX="${ARK_LND_PROVIDER_ARK_PRIVATE_KEY_HEX:-}"
ARK_LND_PROVIDER_ARK_CONTRACT_VTXO_SATS="${ARK_LND_PROVIDER_ARK_CONTRACT_VTXO_SATS:-1000}"
ARK_LND_PROVIDER_ARK_CONTRACT_CLAIM_DELAY_BLOCKS="${ARK_LND_PROVIDER_ARK_CONTRACT_CLAIM_DELAY_BLOCKS:-1}"
ARK_LND_PROVIDER_ARK_CONTRACT_REFUND_DELAY_BLOCKS="${ARK_LND_PROVIDER_ARK_CONTRACT_REFUND_DELAY_BLOCKS:-1}"

FAUCET_PROVIDER="${FAUCET_PROVIDER:-ben}"
FAUCET_AMOUNT="${FAUCET_AMOUNT:-100000}"
MUTINYNET_FAUCET_URL="${MUTINYNET_FAUCET_URL:-https://faucet.mutinynet.com}"
MUTINYNET_FAUCET_TOKEN_FILE="${MUTINYNET_FAUCET_TOKEN_FILE:-$HOME/.mutinynet/token}"
MUTINYNET_GITHUB_TOKEN_FILE="${MUTINYNET_GITHUB_TOKEN_FILE:-}"
VOLTAGE_AUTH_SERVICE_URL="${VOLTAGE_AUTH_SERVICE_URL:-https://auth.voltage.cloud}"
VOLTAGE_FAUCET_URL="${VOLTAGE_FAUCET_URL:-https://faucet.voltage.cloud/dispense}"
VOLTAGE_AUTH_USERNAME="${VOLTAGE_AUTH_USERNAME:-${AUTH_USERNAME:-}}"
VOLTAGE_AUTH_PASSWORD="${VOLTAGE_AUTH_PASSWORD:-${AUTH_PASSWORD:-}}"
VOLTAGE_AUTH_MFA_CODE="${VOLTAGE_AUTH_MFA_CODE:-${AUTH_MFA_CODE:-}}"
WAIT_TIMEOUT_SEC="${WAIT_TIMEOUT_SEC:-900}"

mkdir -p "$DATA_DIR" "$LOG_DIR" "$STATE_DIR" "$RUN_DIR"

require_env() {
  local missing=0 key
  for key in "$@"; do
    if [ -z "${!key:-}" ]; then
      echo "missing required env var: $key" >&2
      missing=1
    fi
  done
  if [ "$missing" -ne 0 ]; then
    echo "copy .env.example to .env and fill the missing values" >&2
    exit 2
  fi
}

require_cmd() {
  local missing=0 cmd
  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "missing required command: $cmd" >&2
      missing=1
    fi
  done
  if [ "$missing" -ne 0 ]; then
    exit 2
  fi
}

json_bool() {
  case "$1" in
    1|true|TRUE|yes|YES) printf 'true' ;;
    *) printf 'false' ;;
  esac
}

wait_for_tcp() {
  local host="$1" port="$2" label="$3" timeout="${4:-90}" start
  start="$(date +%s)"
  while true; do
    if (echo >"/dev/tcp/$host/$port") >/dev/null 2>&1; then
      return 0
    fi
    if [ $(( "$(date +%s)" - start )) -ge "$timeout" ]; then
      echo "$label did not open $host:$port" >&2
      return 1
    fi
    sleep 1
  done
}

pid_file() {
  case "$1" in
    bitcoind) printf '%s/bitcoind.pid' "$RUN_DIR" ;;
    bitcoind-rpc-proxy) printf '%s/bitcoind-rpc-proxy.pid' "$RUN_DIR" ;;
    esplora) printf '%s/esplora.pid' "$RUN_DIR" ;;
    nbxplorer-postgres) printf '%s/nbxplorer-postgres.pid' "$RUN_DIR" ;;
    nbxplorer) printf '%s/nbxplorer.pid' "$RUN_DIR" ;;
    rgb-proxy) printf '%s/rgb-proxy.pid' "$RUN_DIR" ;;
    arkd-wallet) printf '%s/arkd-wallet.pid' "$RUN_DIR" ;;
    arkd) printf '%s/arkd.pid' "$RUN_DIR" ;;
    ark-lnd-provider) printf '%s/ark-lnd-provider.pid' "$RUN_DIR" ;;
    lnd1|lnd2) printf '%s/%s.pid' "$RUN_DIR" "$1" ;;
    node1|node2|node3|node4) printf '%s/%s.pid' "$RUN_DIR" "$1" ;;
    *) echo "unknown service: $1" >&2; return 2 ;;
  esac
}

log_file() {
  case "$1" in
    bitcoind) printf '%s/bitcoind.log' "$LOG_DIR" ;;
    bitcoind-rpc-proxy) printf '%s/bitcoind-rpc-proxy.log' "$LOG_DIR" ;;
    esplora) printf '%s/esplora.log' "$LOG_DIR" ;;
    nbxplorer-postgres) printf '%s/nbxplorer-postgres.log' "$LOG_DIR" ;;
    nbxplorer) printf '%s/nbxplorer.log' "$LOG_DIR" ;;
    rgb-proxy) printf '%s/rgb-proxy.log' "$LOG_DIR" ;;
    arkd-wallet) printf '%s/arkd-wallet.log' "$LOG_DIR" ;;
    arkd) printf '%s/arkd.log' "$LOG_DIR" ;;
    ark-lnd-provider) printf '%s/ark-lnd-provider.log' "$LOG_DIR" ;;
    lnd1|lnd2) printf '%s/%s.log' "$LOG_DIR" "$1" ;;
    node1|node2|node3|node4) printf '%s/%s.log' "$LOG_DIR" "$1" ;;
    *) echo "unknown service: $1" >&2; return 2 ;;
  esac
}

services_from_args() {
  if [ "$#" -eq 0 ] || [ "${1:-}" = "all" ]; then
    printf '%s\n' bitcoind bitcoind-rpc-proxy esplora nbxplorer-postgres nbxplorer arkd-wallet arkd rgb-proxy node1 node2 node3 node4 lnd1 lnd2 ark-lnd-provider
    return 0
  fi

  local arg
  for arg in "$@"; do
    case "$arg" in
      bitcoin|bitcoin-core|core|bitcoind) printf 'bitcoind\n' ;;
      bitcoind-rpc|rpc|bitcoind-rpc-proxy) printf 'bitcoind-rpc-proxy\n' ;;
      esplora|electrs|indexer|rgb-indexer|rln-indexer) printf 'esplora\n' ;;
      nbx-postgres|nbxplorer-postgres|nbxplorer-db) printf 'nbxplorer-postgres\n' ;;
      nbx|nbxplorer|explorer) printf 'nbxplorer\n' ;;
      rgb-proxy|rgbproxy|proxy) printf 'rgb-proxy\n' ;;
      ark-wallet|arkd-wallet) printf 'arkd-wallet\n' ;;
      ark|arkd) printf 'arkd\n' ;;
      ark-lnd|ark-lnd-provider|provider|swap-provider) printf 'ark-lnd-provider\n' ;;
      lnd1|lnda|lnd-rgb) printf 'lnd1\n' ;;
      lnd2|lndb|lnd-ark) printf 'lnd2\n' ;;
      r1|node1) printf 'node1\n' ;;
      r2|node2) printf 'node2\n' ;;
      r3|node3) printf 'node3\n' ;;
      r4|node4|rmm|rgb-mm|market-maker) printf 'node4\n' ;;
      *) echo "unknown service: $arg" >&2; return 2 ;;
    esac
  done
}

node_label() {
  case "$1" in
    r1|node1) printf 'node1' ;;
    r2|node2) printf 'node2' ;;
    r3|node3) printf 'node3' ;;
    r4|node4|rmm|rgb-mm|market-maker) printf 'node4' ;;
    *) echo "unknown RGB node: $1" >&2; return 2 ;;
  esac
}

node_alias() {
  case "$(node_label "$1")" in
    node1) printf 'mut-sim-rgb-issuer' ;;
    node2) printf 'mut-sim-rgb-middle' ;;
    node3) printf 'mut-sim-rgb-receiver' ;;
    node4) printf 'mut-sim-rgb-market-maker' ;;
  esac
}

node_daemon_port() {
  case "$(node_label "$1")" in
    node1) printf '%s' "$NODE1_DAEMON_PORT" ;;
    node2) printf '%s' "$NODE2_DAEMON_PORT" ;;
    node3) printf '%s' "$NODE3_DAEMON_PORT" ;;
    node4) printf '%s' "$NODE4_DAEMON_PORT" ;;
  esac
}

node_peer_port() {
  case "$(node_label "$1")" in
    node1) printf '%s' "$NODE1_PEER_PORT" ;;
    node2) printf '%s' "$NODE2_PEER_PORT" ;;
    node3) printf '%s' "$NODE3_PEER_PORT" ;;
    node4) printf '%s' "$NODE4_PEER_PORT" ;;
  esac
}

node_dir() {
  printf '%s/%s' "$RLN_DATA_DIR" "$(node_label "$1")"
}

node_url() {
  printf 'http://127.0.0.1:%s' "$(node_daemon_port "$1")"
}

api() {
  local node="$1" method="$2" path="$3" body="${4:-}" url
  url="$(node_url "$node")$path"
  if [ -n "$body" ]; then
    curl -sS --fail-with-body -H 'Content-Type: application/json' -X "$method" --data "$body" "$url"
  else
    curl -sS --fail-with-body -H 'Content-Type: application/json' -X "$method" "$url"
  fi
}

lnd_dir() {
  case "$1" in
    lnd1) printf '%s' "$LND1_DIR" ;;
    lnd2) printf '%s' "$LND2_DIR" ;;
    *) echo "unknown lnd node: $1" >&2; return 2 ;;
  esac
}

lnd_rpc_port() {
  case "$1" in
    lnd1) printf '%s' "$LND1_RPC_PORT" ;;
    lnd2) printf '%s' "$LND2_RPC_PORT" ;;
    *) echo "unknown lnd node: $1" >&2; return 2 ;;
  esac
}

lnd_rest_port() {
  case "$1" in
    lnd1) printf '%s' "$LND1_REST_PORT" ;;
    lnd2) printf '%s' "$LND2_REST_PORT" ;;
    *) echo "unknown lnd node: $1" >&2; return 2 ;;
  esac
}

lnd_peer_port() {
  case "$1" in
    lnd1) printf '%s' "$LND1_PEER_PORT" ;;
    lnd2) printf '%s' "$LND2_PEER_PORT" ;;
    *) echo "unknown lnd node: $1" >&2; return 2 ;;
  esac
}

lnd_alias() {
  case "$1" in
    lnd1) printf '%s' "$LND1_ALIAS" ;;
    lnd2) printf '%s' "$LND2_ALIAS" ;;
    *) echo "unknown lnd node: $1" >&2; return 2 ;;
  esac
}

lnd_tls_cert_file() {
  printf '%s/tls.cert' "$(lnd_dir "$1")"
}

lnd_config_file() {
  printf '%s/lnd.conf' "$(lnd_dir "$1")"
}

lnd_admin_macaroon_file() {
  printf '%s/data/chain/bitcoin/%s/admin.macaroon' "$(lnd_dir "$1")" "$LND_NETWORK"
}

lnd_wallet_file() {
  if [ "$LND_DB_BACKEND" = "sqlite" ]; then
    printf '%s/data/chain/bitcoin/%s/chain.sqlite' "$(lnd_dir "$1")" "$LND_NETWORK"
  else
    printf '%s/data/chain/bitcoin/%s/wallet.db' "$(lnd_dir "$1")" "$LND_NETWORK"
  fi
}

lnd_cli() {
  local label="$1"
  shift
  local -a args
  args=(
    --lnddir "$(lnd_dir "$label")"
    --rpcserver "127.0.0.1:$(lnd_rpc_port "$label")"
    --network "$LND_NETWORK"
    --tlscertpath "$(lnd_tls_cert_file "$label")"
  )
  if [ "$LND_NO_MACAROONS" = "1" ]; then
    args+=(--no-macaroons)
  elif [ -f "$(lnd_admin_macaroon_file "$label")" ]; then
    args+=(--macaroonpath "$(lnd_admin_macaroon_file "$label")")
  fi
  "$LNCLI_BINARY" "${args[@]}" "$@"
}

ark_cli() {
  local wallet="${1:-maker}"
  shift || true
  mkdir -p "$ARK_CLI_DIR/$wallet"
  ARK_WALLET_DATADIR="$ARK_CLI_DIR/$wallet" ark "$@"
}

bitcoind_managed() {
  [ "$BITCOIND_MODE" = "local" ]
}

rln_indexer_uses_local() {
  case "$RLN_INDEXER_MODE" in
    local|managed|1|true|TRUE|yes|YES|on|ON) return 0 ;;
    external|remote|0|false|FALSE|no|NO|off|OFF) return 1 ;;
    *)
      echo "unknown RLN_INDEXER_MODE: $RLN_INDEXER_MODE" >&2
      return 2
      ;;
  esac
}

bitcoin_cli() {
  "$BITCOIN_CLI_BINARY" -conf="$BITCOIND_CONF" "$@"
}

bitcoind_rpc_target_is_proxy() {
  [ "$(bitcoind_rpc_configured_host)" = "$BITCOIND_RPC_PROXY_HOST" ] &&
    [ "$(bitcoind_rpc_configured_port)" = "$BITCOIND_RPC_PROXY_PORT" ] &&
    [[ "${BITCOIND_RPC_HOST:-}" != https://* ]]
}

bitcoind_rpc_needs_local_proxy() {
  case "${BITCOIND_RPC_HOST:-}" in
    https://*) return 0 ;;
    *) return 1 ;;
  esac
}

bitcoind_rpc_uses_proxy() {
  case "$BITCOIND_RPC_PROXY_ENABLED" in
    0|false|FALSE|no|NO|off|OFF|never)
      return 1
      ;;
    1|true|TRUE|yes|YES|on|ON|always)
      if bitcoind_rpc_target_is_proxy; then
        return 1
      fi
      return 0
      ;;
    auto|"")
      bitcoind_rpc_needs_local_proxy
      ;;
    *)
      echo "unknown BITCOIND_RPC_PROXY_ENABLED: $BITCOIND_RPC_PROXY_ENABLED" >&2
      return 2
      ;;
  esac
}

bitcoind_rpc_url_rest() {
  local value="$1"
  value="${value#http://}"
  value="${value#https://}"
  printf '%s' "$value"
}

bitcoind_rpc_hostport() {
  local rest
  rest="$(bitcoind_rpc_url_rest "${BITCOIND_RPC_HOST:-}")"
  rest="${rest%%/*}"
  printf '%s' "$rest"
}

bitcoind_rpc_configured_host() {
  local hostport
  hostport="$(bitcoind_rpc_hostport)"
  if [[ "$hostport" == *:* ]]; then
    printf '%s' "${hostport%:*}"
  else
    printf '%s' "$hostport"
  fi
}

bitcoind_rpc_configured_port() {
  local hostport
  hostport="$(bitcoind_rpc_hostport)"
  if [[ "$hostport" == *:* ]]; then
    printf '%s' "${hostport##*:}"
  else
    printf '%s' "$BITCOIND_RPC_PORT"
  fi
}

bitcoind_rpc_configured_hostport() {
  printf '%s:%s' "$(bitcoind_rpc_configured_host)" "$(bitcoind_rpc_configured_port)"
}

bitcoind_rpc_target_url() {
  local scheme rest hostport path
  case "$BITCOIND_RPC_HOST" in
    https://*) scheme="https"; rest="${BITCOIND_RPC_HOST#https://}" ;;
    http://*) scheme="http"; rest="${BITCOIND_RPC_HOST#http://}" ;;
    *) scheme="http"; rest="$BITCOIND_RPC_HOST" ;;
  esac
  if [[ "$rest" == */* ]]; then
    hostport="${rest%%/*}"
    path="/${rest#*/}"
  else
    hostport="$rest"
    path="/"
  fi
  if [[ "$hostport" != *:* ]]; then
    hostport="${hostport}:$BITCOIND_RPC_PORT"
  fi
  printf '%s://%s%s' "$scheme" "$hostport" "$path"
}

bitcoind_rpc_proxy_url() {
  printf 'http://%s:%s' "$BITCOIND_RPC_PROXY_HOST" "$BITCOIND_RPC_PROXY_PORT"
}

bitcoind_rpc_service_url() {
  if bitcoind_rpc_uses_proxy; then
    bitcoind_rpc_proxy_url
  else
    bitcoind_rpc_target_url
  fi
}

bitcoind_rpc_wait_host() {
  local host="$1"
  case "$host" in
    ""|0.0.0.0|::) printf '127.0.0.1' ;;
    *) printf '%s' "$host" ;;
  esac
}

listen_wait_host() {
  bitcoind_rpc_wait_host "$1"
}

nbxplorer_postgres_connection_string() {
  if [ -n "$NBXPLORER_POSTGRES" ]; then
    printf '%s' "$NBXPLORER_POSTGRES"
  else
    printf 'User ID=%s;Host=%s;Port=%s;Application Name=nbxplorer;Database=%s' \
      "$NBXPLORER_POSTGRES_USER" \
      "$NBXPLORER_POSTGRES_HOST" \
      "$NBXPLORER_POSTGRES_PORT" \
      "$NBXPLORER_POSTGRES_DB"
  fi
}

bitcoind_rpc_effective_host() {
  if bitcoind_rpc_uses_proxy; then
    printf '%s' "$BITCOIND_RPC_PROXY_HOST"
  else
    bitcoind_rpc_configured_host
  fi
}

bitcoind_rpc_effective_port() {
  if bitcoind_rpc_uses_proxy; then
    printf '%s' "$BITCOIND_RPC_PROXY_PORT"
  else
    bitcoind_rpc_configured_port
  fi
}

bitcoind_p2p_host() {
  if [ "$BITCOIND_P2P_PORT_FORWARD_ENABLED" = "1" ] && [ -z "$BITCOIND_P2P_HOST" ]; then
    printf '%s' "$BITCOIND_P2P_PORT_FORWARD_LOCAL_HOST"
    return 0
  fi
  if [ -n "$BITCOIND_P2P_HOST" ]; then
    printf '%s' "$BITCOIND_P2P_HOST"
  else
    bitcoind_rpc_configured_host
  fi
}

bitcoind_p2p_port() {
  if [ "$BITCOIND_P2P_PORT_FORWARD_ENABLED" = "1" ] && [ -z "$BITCOIND_P2P_HOST" ]; then
    printf '%s' "$BITCOIND_P2P_PORT_FORWARD_LOCAL_PORT"
  else
    printf '%s' "$BITCOIND_P2P_PORT"
  fi
}

bitcoind_p2p_endpoint() {
  printf '%s:%s' "$(bitcoind_p2p_host)" "$(bitcoind_p2p_port)"
}

lnd_neutrino_has_connect_endpoint() {
  [ -n "$LND_NEUTRINO_CONNECT" ] || [ -n "$BITCOIND_P2P_HOST" ] || [ -n "${BITCOIND_RPC_HOST:-}" ]
}

lnd_neutrino_connect_endpoint() {
  if [ -n "$LND_NEUTRINO_CONNECT" ]; then
    printf '%s' "$LND_NEUTRINO_CONNECT"
  else
    bitcoind_p2p_endpoint
  fi
}

require_lnd_neutrino_connect() {
  if lnd_neutrino_has_connect_endpoint; then
    return 0
  fi

  echo "missing neutrino peer: set LND_NEUTRINO_CONNECT or BITCOIND_P2P_HOST" >&2
  echo "BITCOIND_RPC_HOST can also be used when the P2P host matches the RPC host" >&2
  return 2
}

lnd_uses_bitcoind() {
  [ "$LND_CHAIN_BACKEND" = "bitcoind" ]
}

lnd_uses_neutrino() {
  [ "$LND_CHAIN_BACKEND" = "neutrino" ]
}

lnd_zmq_enabled() {
  [ -n "$LND_ZMQ_PUB_RAW_BLOCK" ] && [ -n "$LND_ZMQ_PUB_RAW_TX" ]
}

validate_lnd_zmq_config() {
  if [ -z "$LND_ZMQ_PUB_RAW_BLOCK" ] && [ -z "$LND_ZMQ_PUB_RAW_TX" ]; then
    return 0
  fi
  if [ -z "$LND_ZMQ_PUB_RAW_BLOCK" ] || [ -z "$LND_ZMQ_PUB_RAW_TX" ]; then
    echo "set both LND_ZMQ_PUB_RAW_BLOCK and LND_ZMQ_PUB_RAW_TX, or leave both empty for RPC polling" >&2
    return 2
  fi
  if [ "$LND_ZMQ_PUB_RAW_BLOCK" = "$LND_ZMQ_PUB_RAW_TX" ]; then
    echo "LND requires LND_ZMQ_PUB_RAW_BLOCK and LND_ZMQ_PUB_RAW_TX to be different addresses" >&2
    return 2
  fi
  case "$LND_ZMQ_PUB_RAW_BLOCK $LND_ZMQ_PUB_RAW_TX" in
    *'tcp://0.0.0.0:'*)
      echo "LND ZMQ endpoints must be reachable client addresses, not bitcoind bind address 0.0.0.0" >&2
      return 2
      ;;
  esac
}

nbxplorer_url() {
  printf 'http://%s:%s' "$NBXPLORER_BIND" "$NBXPLORER_PORT"
}

esplora_url() {
  printf 'http://%s:%s' "$ESPLORA_HTTP_HOST" "$ESPLORA_HTTP_PORT"
}

arkd_url() {
  printf 'http://127.0.0.1:%s' "$ARKD_PORT"
}

ark_lnd_provider_url() {
  printf 'http://%s:%s' "$ARK_LND_PROVIDER_HOST" "$ARK_LND_PROVIDER_PORT"
}

wait_for_bitcoind_rpc_proxy() {
  wait_for_tcp "$BITCOIND_RPC_PROXY_HOST" "$BITCOIND_RPC_PROXY_PORT" bitcoind-rpc-proxy 60
}

wait_for_bitcoind() {
  wait_for_tcp "$(bitcoind_rpc_wait_host "$BITCOIND_RPC_BIND")" "$BITCOIND_RPC_PORT" bitcoind-rpc 120
}

wait_for_bitcoind_p2p() {
  wait_for_tcp "$(bitcoind_rpc_wait_host "$BITCOIND_BIND")" "$BITCOIND_P2P_PORT" bitcoind-p2p 120
}

wait_for_nbxplorer_postgres() {
  wait_for_tcp "$NBXPLORER_POSTGRES_HOST" "$NBXPLORER_POSTGRES_PORT" nbxplorer-postgres 60
}

wait_for_nbxplorer() {
  wait_for_tcp "$NBXPLORER_BIND" "$NBXPLORER_PORT" nbxplorer 180
}

wait_for_esplora_http() {
  wait_for_tcp "$(listen_wait_host "$ESPLORA_HTTP_HOST")" "$ESPLORA_HTTP_PORT" esplora "$ESPLORA_HTTP_WAIT_TIMEOUT_SEC"
}

wait_for_esplora_process() {
  local pid start
  pid="$(pid_file esplora)"
  start="$(date +%s)"
  while true; do
    if [ -f "$pid" ] && kill -0 "$(cat "$pid")" >/dev/null 2>&1; then
      return 0
    fi
    if [ $(( "$(date +%s)" - start )) -ge 30 ]; then
      echo "timed out waiting for esplora process" >&2
      return 1
    fi
    sleep 1
  done
}

wait_for_esplora() {
  case "$ESPLORA_START_WAIT_FOR_HTTP" in
    1|true|TRUE|yes|YES|on|ON) wait_for_esplora_http ;;
    *) wait_for_esplora_process ;;
  esac
}

wait_for_bitcoind_synced() {
  local start info blocks headers ibd progress timeout poll
  timeout="$INIT_LOCAL_TIMEOUT_SEC"
  poll="$INIT_LOCAL_POLL_SEC"
  start="$(date +%s)"

  while true; do
    info="$(bitcoin_cli getblockchaininfo 2>/dev/null || true)"
    if [ -n "$info" ]; then
      blocks="$(printf '%s' "$info" | jq -r '.blocks // 0')"
      headers="$(printf '%s' "$info" | jq -r '.headers // 0')"
      ibd="$(printf '%s' "$info" | jq -r '.initialblockdownload // true')"
      progress="$(printf '%s' "$info" | jq -r '((.verificationprogress // 0) * 100 | floor / 100)')"

      if [ "$ibd" = "false" ]; then
        echo "bitcoind synced: blocks=$blocks headers=$headers progress=${progress}%"
        return 0
      fi

      echo "waiting for bitcoind sync: blocks=$blocks headers=$headers ibd=$ibd progress=${progress}%"
    else
      echo "waiting for bitcoind RPC"
    fi

    if [ "$timeout" != "0" ] && [ $(( "$(date +%s)" - start )) -ge "$timeout" ]; then
      echo "timed out waiting for bitcoind sync after ${timeout}s" >&2
      return 1
    fi
    sleep "$poll"
  done
}

wait_for_lnd_chain_synced() {
  local label="$1" start info synced block_height timeout poll
  timeout="$INIT_LOCAL_TIMEOUT_SEC"
  poll="${INIT_LOCAL_LND_POLL_SEC:-5}"
  start="$(date +%s)"

  wait_for_lnd_unlocked "$label"
  while true; do
    info="$(lnd_cli "$label" getinfo 2>/dev/null || true)"
    if [ -n "$info" ]; then
      synced="$(printf '%s' "$info" | jq -r '.synced_to_chain // false')"
      block_height="$(printf '%s' "$info" | jq -r '.block_height // 0')"
      if [ "$synced" = "true" ]; then
        echo "$label synced_to_chain=true height=$block_height"
        return 0
      fi
      echo "waiting for $label chain sync: synced_to_chain=$synced height=$block_height"
    fi

    if [ "$timeout" != "0" ] && [ $(( "$(date +%s)" - start )) -ge "$timeout" ]; then
      echo "timed out waiting for $label chain sync after ${timeout}s" >&2
      return 1
    fi
    sleep "$poll"
  done
}

wait_for_rgb_proxy() {
  wait_for_tcp 127.0.0.1 "$RGB_PROXY_PORT" rgb-proxy 90
}

wait_for_rln_node() {
  wait_for_tcp 127.0.0.1 "$(node_daemon_port "$1")" "$(node_label "$1")" 120
}

wait_for_lnd() {
  wait_for_tcp 127.0.0.1 "$(lnd_rpc_port "$1")" "$1" 180
}

wait_for_lnd_unlocked() {
  local label="$1" start info
  wait_for_lnd "$label"
  start="$(date +%s)"
  while true; do
    info="$(lnd_cli "$label" getinfo 2>/dev/null || true)"
    if [ -n "$info" ]; then
      return 0
    fi
    if [ $(( "$(date +%s)" - start )) -ge 180 ]; then
      echo "$label RPC opened but wallet never became ready" >&2
      return 1
    fi
    sleep 2
  done
}

wait_for_arkd_wallet() {
  wait_for_tcp 127.0.0.1 "$ARKD_WALLET_PORT" arkd-wallet 120
}

wait_for_arkd() {
  wait_for_tcp 127.0.0.1 "$ARKD_PORT" arkd 120
}

wait_for_ark_lnd_provider() {
  wait_for_tcp "$ARK_LND_PROVIDER_HOST" "$ARK_LND_PROVIDER_PORT" ark-lnd-provider 90
}

rln_binary() {
  if [ -n "${RLN_BINARY:-}" ]; then
    printf '%s' "$RLN_BINARY"
  elif [ -x "$RLN_REPO/target/release/rgb-lightning-node" ]; then
    printf '%s' "$RLN_REPO/target/release/rgb-lightning-node"
  elif [ -x "$RLN_REPO/target/debug/rgb-lightning-node" ]; then
    printf '%s' "$RLN_REPO/target/debug/rgb-lightning-node"
  elif command -v rgb-lightning-node >/dev/null 2>&1; then
    command -v rgb-lightning-node
  else
    return 1
  fi
}

toml_string() {
  jq -Rn --arg value "$1" '$value'
}

load_faucet_token_file() {
  if [ -z "${MUTINYNET_FAUCET_TOKEN:-}" ] && [ -f "$MUTINYNET_FAUCET_TOKEN_FILE" ]; then
    MUTINYNET_FAUCET_TOKEN="$(tr -d '\n\r' <"$MUTINYNET_FAUCET_TOKEN_FILE")"
    export MUTINYNET_FAUCET_TOKEN
  fi
}

github_token_for_faucet() {
  if [ -n "${MUTINYNET_GITHUB_TOKEN:-}" ]; then
    printf '%s' "$MUTINYNET_GITHUB_TOKEN"
    return 0
  fi

  if [ -n "$MUTINYNET_GITHUB_TOKEN_FILE" ] && [ -f "$MUTINYNET_GITHUB_TOKEN_FILE" ]; then
    tr -d '\n\r' <"$MUTINYNET_GITHUB_TOKEN_FILE"
    return 0
  fi

  if command -v gh >/dev/null 2>&1; then
    gh auth token 2>/dev/null || true
  fi
}

exchange_github_token_for_faucet_token() {
  local github_token="$1" response token
  response="$(curl -sS --fail-with-body \
    -H 'Content-Type: application/json' \
    -X POST \
    --data "$(jq -nc --arg code "$github_token" '{code:$code}')" \
    "${MUTINYNET_FAUCET_URL%/}/auth/github/device")"
  token="$(printf '%s' "$response" | jq -r '.token // empty')"
  if [ -z "$token" ]; then
    printf '%s\n' "$response" >&2
    echo "faucet auth did not return a token" >&2
    return 1
  fi
  mkdir -p "$(dirname "$MUTINYNET_FAUCET_TOKEN_FILE")"
  (
    umask 077
    printf '%s\n' "$token" >"$MUTINYNET_FAUCET_TOKEN_FILE"
  )
  MUTINYNET_FAUCET_TOKEN="$token"
  export MUTINYNET_FAUCET_TOKEN
}

ensure_faucet_auth() {
  require_cmd curl jq

  case "$FAUCET_PROVIDER" in
    ben|mutinynet|public) ;;
    voltage) require_env VOLTAGE_AUTH_USERNAME VOLTAGE_AUTH_PASSWORD; return 0 ;;
    *) echo "unknown FAUCET_PROVIDER=$FAUCET_PROVIDER; expected ben or voltage" >&2; return 2 ;;
  esac

  require_cmd mutinynet-cli
  load_faucet_token_file

  if mutinynet-cli limits >/dev/null 2>&1; then
    return 0
  fi

  local github_token
  github_token="$(github_token_for_faucet | tr -d '\n\r')"
  if [ -n "$github_token" ]; then
    echo "deriving Mutinynet faucet token from GitHub credentials"
    if exchange_github_token_for_faucet_token "$github_token" &&
      mutinynet-cli limits >/dev/null 2>&1; then
      echo "saved Mutinynet faucet token to $MUTINYNET_FAUCET_TOKEN_FILE"
      return 0
    fi
  fi

  echo "starting interactive Mutinynet faucet login"
  mutinynet-cli login
  load_faucet_token_file
}

voltage_auth_token() {
  require_env VOLTAGE_AUTH_USERNAME VOLTAGE_AUTH_PASSWORD
  require_cmd curl jq

  local login_url response token session mfa_response
  login_url="${VOLTAGE_AUTH_SERVICE_URL%/}/api/v1/auth/login"
  response="$(curl -sS --fail-with-body \
    -H 'Content-Type: application/json' \
    -X POST \
    --data "$(jq -nc \
      --arg email "$VOLTAGE_AUTH_USERNAME" \
      --arg password "$VOLTAGE_AUTH_PASSWORD" \
      '{email:$email,password:$password}')" \
    "$login_url")"

  token="$(printf '%s' "$response" | jq -r '.auth.access_token // .access_token // empty')"
  if [ -n "$token" ]; then
    printf '%s\n' "$token"
    return 0
  fi

  session="$(printf '%s' "$response" | jq -r '.session.token // .session // empty')"
  if [ -n "$session" ]; then
    if [ -z "$VOLTAGE_AUTH_MFA_CODE" ]; then
      echo "Voltage auth requested MFA; set VOLTAGE_AUTH_MFA_CODE and retry" >&2
      return 2
    fi
    mfa_response="$(curl -sS --fail-with-body \
      -H 'Content-Type: application/json' \
      -X POST \
      --data "$(jq -nc \
        --arg email "$VOLTAGE_AUTH_USERNAME" \
        --arg session "$session" \
        --arg code "$VOLTAGE_AUTH_MFA_CODE" \
        '{email:$email,session:$session,code:$code}')" \
      "${VOLTAGE_AUTH_SERVICE_URL%/}/api/v1/auth/mfa_challenge")"
    token="$(printf '%s' "$mfa_response" | jq -r '.auth.access_token // .access_token // empty')"
    if [ -n "$token" ]; then
      printf '%s\n' "$token"
      return 0
    fi
    printf '%s\n' "$mfa_response" >&2
  else
    printf '%s\n' "$response" >&2
  fi

  echo "Voltage auth service did not return an access token" >&2
  return 1
}

post_voltage_faucet() {
  local address="$1"
  local amount="${2:-$FAUCET_AMOUNT}"
  local token
  token="$(voltage_auth_token)"
  curl -sS --fail-with-body \
    -H 'Content-Type: application/json' \
    -H "Authorization: Bearer $token" \
    -X POST \
    --data "$(jq -nc --arg address "$address" --argjson amount "$amount" \
      '{address:$address,amount:$amount}')" \
    "$VOLTAGE_FAUCET_URL"
}

post_ben_faucet() {
  local address="$1"
  local amount="${2:-$FAUCET_AMOUNT}"
  ensure_faucet_auth
  mutinynet-cli onchain "$address" "$amount"
}

post_faucet_address() {
  local address="$1"
  local amount="${2:-$FAUCET_AMOUNT}"
  case "$FAUCET_PROVIDER" in
    ben|mutinynet|public) post_ben_faucet "$address" "$amount" ;;
    voltage) post_voltage_faucet "$address" "$amount" ;;
    *) echo "unknown FAUCET_PROVIDER=$FAUCET_PROVIDER; expected ben or voltage" >&2; return 2 ;;
  esac
}
