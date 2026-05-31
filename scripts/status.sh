#!/usr/bin/env bash

set -euo pipefail

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

print_pid() {
  local service="$1" pid
  pid="$(pid_file "$service")"
  if [ -f "$pid" ] && kill -0 "$(cat "$pid")" >/dev/null 2>&1; then
    echo "  pid: $(cat "$pid")"
  else
    echo "  pid: not running"
  fi
}

print_port() {
  local host="$1" port="$2"
  if (echo >"/dev/tcp/$host/$port") >/dev/null 2>&1; then
    echo "  port: $host:$port open"
  else
    echo "  port: $host:$port closed"
  fi
}

status_bitcoind() {
  echo "[bitcoind]"
  echo "  mode: $BITCOIND_MODE"
  if bitcoind_managed; then
    echo "  binary: $BITCOIND_BINARY"
    echo "  data: $BITCOIND_DIR"
    echo "  conf: $BITCOIND_CONF"
    echo "  rpc: 127.0.0.1:$BITCOIND_RPC_PORT"
    echo "  p2p: 127.0.0.1:$BITCOIND_P2P_PORT"
    echo "  zmq rawblock: tcp://127.0.0.1:$BITCOIND_ZMQ_RAW_BLOCK_PORT"
    echo "  zmq rawtx: tcp://127.0.0.1:$BITCOIND_ZMQ_RAW_TX_PORT"
    echo "  log: $(log_file bitcoind)"
    print_pid bitcoind
    print_port "$(bitcoind_rpc_wait_host "$BITCOIND_RPC_BIND")" "$BITCOIND_RPC_PORT"
    print_port "$(bitcoind_rpc_wait_host "$BITCOIND_BIND")" "$BITCOIND_P2P_PORT"
    local info
    info="$(bitcoin_cli getblockchaininfo 2>/dev/null || true)"
    if [ -n "$info" ]; then
      printf '%s\n' "$info" | jq -r '"  chain: \(.chain)\n  blocks: \(.blocks)\n  headers: \(.headers)\n  ibd: \(.initialblockdownload)"' 2>/dev/null || true
    fi
  else
    echo "  target: ${BITCOIND_RPC_HOST:-missing BITCOIND_RPC_HOST}"
    if [ -n "${BITCOIND_P2P_HOST:-}" ]; then
      echo "  p2p: $(bitcoind_p2p_endpoint)"
    fi
  fi
}

status_bitcoind_rpc_proxy() {
  echo "[bitcoind-rpc-proxy]"
  echo "  mode: $BITCOIND_RPC_PROXY_ENABLED"
  if [ -n "${BITCOIND_RPC_HOST:-}" ]; then
    echo "  target: $(bitcoind_rpc_target_url)"
  else
    echo "  target: missing BITCOIND_RPC_HOST"
  fi
  echo "  listen: $(bitcoind_rpc_proxy_url)"
  echo "  effective rpc: $(bitcoind_rpc_service_url)"
  if [ -n "${BITCOIND_P2P_HOST:-}" ] || [ "$BITCOIND_P2P_PORT_FORWARD_ENABLED" = "1" ]; then
    echo "  p2p: $(bitcoind_p2p_endpoint)"
  fi
  echo "  log: $(log_file bitcoind-rpc-proxy)"
  print_pid bitcoind-rpc-proxy
  print_port "$BITCOIND_RPC_PROXY_HOST" "$BITCOIND_RPC_PROXY_PORT"
}

status_nbxplorer_postgres() {
  echo "[nbxplorer-postgres]"
  if [ -n "$NBXPLORER_POSTGRES" ] || [ "$NBXPLORER_POSTGRES_MANAGED" != "1" ]; then
    echo "  mode: external"
  else
    echo "  mode: managed"
  fi
  echo "  listen: ${NBXPLORER_POSTGRES_HOST}:${NBXPLORER_POSTGRES_PORT}"
  echo "  database: $NBXPLORER_POSTGRES_DB"
  echo "  data: $NBXPLORER_POSTGRES_DIR"
  echo "  log: $(log_file nbxplorer-postgres)"
  print_pid nbxplorer-postgres
  if [ "$NBXPLORER_POSTGRES_MANAGED" = "1" ] && [ -z "$NBXPLORER_POSTGRES" ]; then
    print_port "$NBXPLORER_POSTGRES_HOST" "$NBXPLORER_POSTGRES_PORT"
  fi
}

status_nbxplorer() {
  echo "[nbxplorer]"
  echo "  enabled: $NBXPLORER_ENABLED"
  echo "  url: $(nbxplorer_url)"
  echo "  network: $NBXPLORER_NETWORK"
  echo "  postgres: ${NBXPLORER_POSTGRES_HOST}:${NBXPLORER_POSTGRES_PORT}/${NBXPLORER_POSTGRES_DB}"
  echo "  data: $NBXPLORER_DIR"
  echo "  log: $(log_file nbxplorer)"
  print_pid nbxplorer
  print_port "$NBXPLORER_BIND" "$NBXPLORER_PORT"

  local status
  status="$(curl -sS "$(nbxplorer_url)/v1/cryptos/BTC/status" 2>/dev/null || true)"
  if [ -n "$status" ]; then
    printf '%s\n' "$status" | jq -r '"  chain: \(.networkType // .chain // "-")\n  blocks: \(.bitcoinStatus.blocks // .status.blocks // "-")\n  synced: \(.isFullySynched // .status.isSynced // .bitcoinStatus.isSynched // "-")"' 2>/dev/null || true
  fi
}

status_esplora() {
  echo "[esplora]"
  echo "  mode: $RLN_INDEXER_MODE"
  echo "  RGB indexer URL: $RLN_INDEXER_URL"
  echo "  url: $(esplora_url)"
  echo "  network: $ESPLORA_NETWORK"
  echo "  db: $ESPLORA_DB_DIR"
  echo "  log: $(log_file esplora)"
  print_pid esplora
  print_port "$(listen_wait_host "$ESPLORA_HTTP_HOST")" "$ESPLORA_HTTP_PORT"

  local tip
  tip="$(curl --max-time 3 -sS "$RLN_INDEXER_URL/blocks/tip/height" 2>/dev/null || true)"
  if [ -n "$tip" ]; then
    echo "  tip height: $tip"
  fi
}

status_rgb_proxy() {
  echo "[rgb-proxy]"
  echo "  enabled: $RGB_PROXY_ENABLED"
  echo "  endpoint: $RGB_PROXY_ENDPOINT"
  echo "  data: $RGB_PROXY_DATA_DIR"
  echo "  log: $(log_file rgb-proxy)"
  print_pid rgb-proxy
  print_port 127.0.0.1 "$RGB_PROXY_PORT"
}

status_rln_node() {
  local node state network
  node="$(node_label "$1")"
  echo "[$node]"
  echo "  api: $(node_url "$node")"
  echo "  peer: 127.0.0.1:$(node_peer_port "$node")"
  echo "  data: $(node_dir "$node")"
  echo "  log: $(log_file "$node")"
  print_pid "$node"
  print_port 127.0.0.1 "$(node_daemon_port "$node")"

  state="$(api "$node" GET /nodeinfo 2>/dev/null || true)"
  if [ -z "$state" ]; then
    echo "  state: offline, locked, or still starting"
    return 0
  fi
  network="$(api "$node" GET /networkinfo 2>/dev/null || true)"
  echo "$state" | jq -r '"  pubkey: \(.pubkey)\n  channels: \(.num_channels) total / \(.num_usable_channels) usable\n  peers: \(.num_peers)\n  local sats: \(.local_balance_sat)"'
  if [ -n "$network" ]; then
    echo "$network" | jq -r '"  network: \(.network) height=\(.height)"'
  fi
}

status_lnd_node() {
  local label="$1" state info balance
  echo "[$label]"
  echo "  rpc: 127.0.0.1:$(lnd_rpc_port "$label")"
  echo "  rest: 127.0.0.1:$(lnd_rest_port "$label")"
  echo "  peer: 127.0.0.1:$(lnd_peer_port "$label")"
  echo "  db: $LND_DB_BACKEND"
  echo "  backend: $LND_CHAIN_BACKEND"
  if lnd_uses_neutrino; then
    if lnd_neutrino_has_connect_endpoint; then
      echo "  neutrino: $(lnd_neutrino_connect_endpoint)"
      if [ -n "$LND_SIGNET_BLOCK_TIME" ]; then
        echo "  signet block time: $LND_SIGNET_BLOCK_TIME"
      fi
    else
      echo "  neutrino: missing LND_NEUTRINO_CONNECT or BITCOIND_P2P_HOST"
    fi
  elif lnd_zmq_enabled; then
    echo "  zmq rawblock: $LND_ZMQ_PUB_RAW_BLOCK"
    echo "  zmq rawtx: $LND_ZMQ_PUB_RAW_TX"
  else
    echo "  bitcoind: $(bitcoind_rpc_effective_host):$(bitcoind_rpc_effective_port) polling=true"
  fi
  echo "  data: $(lnd_dir "$label")"
  echo "  log: $(log_file "$label")"
  print_pid "$label"
  print_port 127.0.0.1 "$(lnd_rpc_port "$label")"

  state="$(lnd_cli "$label" state 2>/dev/null || true)"
  if [ -n "$state" ]; then
    echo "$state" | jq -r '"  wallet state: \(.state // "-")"'
  fi

  info="$(lnd_cli "$label" getinfo 2>/dev/null || true)"
  if [ -z "$info" ]; then
    echo "  state: offline, locked, or still syncing"
    return 0
  fi
  echo "$info" | jq -r '"  alias: \(.alias // "-")\n  pubkey: \(.identity_pubkey)\n  network: \(.chains[0].network // "-") height=\(.block_height)\n  synced_to_chain: \(.synced_to_chain)\n  peers: \(.num_peers)\n  channels: \((.num_active_channels // 0) + (.num_inactive_channels // 0)) total / \(.num_active_channels // 0) active"'
  balance="$(lnd_cli "$label" walletbalance 2>/dev/null || true)"
  if [ -n "$balance" ]; then
    echo "$balance" | jq -r '"  wallet confirmed sats: \(.confirmed_balance // .total_balance // .account_balance.default.confirmed_balance // 0)\n  wallet total sats: \(.total_balance // 0)"'
  fi
}

status_arkd_wallet() {
  echo "[arkd-wallet]"
  echo "  grpc: 127.0.0.1:${ARKD_WALLET_PORT}"
  echo "  network: $ARK_NETWORK"
  echo "  nbxplorer: ${ARKD_WALLET_NBXPLORER_URL:-$(nbxplorer_url)}"
  echo "  data: $ARKD_WALLET_DIR"
  echo "  log: $(log_file arkd-wallet)"
  print_pid arkd-wallet
  print_port 127.0.0.1 "$ARKD_WALLET_PORT"
}

status_arkd() {
  echo "[arkd]"
  echo "  public: $(arkd_url)"
  echo "  admin: http://127.0.0.1:${ARKD_ADMIN_PORT}"
  echo "  explorer: $ARK_EXPLORER_URL"
  echo "  data: $ARKD_DIR"
  echo "  log: $(log_file arkd)"
  print_pid arkd
  print_port 127.0.0.1 "$ARKD_PORT"
  print_port 127.0.0.1 "$ARKD_ADMIN_PORT"

  if command -v arkd >/dev/null 2>&1; then
    arkd --url "http://127.0.0.1:${ARKD_ADMIN_PORT}" --datadir "$ARKD_DIR" wallet status 2>/dev/null | sed 's/^/  /' || true
    arkd --url "http://127.0.0.1:${ARKD_ADMIN_PORT}" --datadir "$ARKD_DIR" wallet balance 2>/dev/null | sed 's/^/  /' || true
  fi
}

status_ark_lnd_provider() {
  echo "[ark-lnd-provider]"
  echo "  enabled: $ARK_LND_PROVIDER_ENABLED"
  echo "  url: $(ark_lnd_provider_url)"
  echo "  lnd node: $ARK_LND_PROVIDER_LND_NODE"
  echo "  ark server: $ARK_LND_PROVIDER_ARK_SERVER_URL"
  echo "  database: $ARK_LND_PROVIDER_DB"
  echo "  log: $(log_file ark-lnd-provider)"
  print_pid ark-lnd-provider
  print_port "$ARK_LND_PROVIDER_HOST" "$ARK_LND_PROVIDER_PORT"

  local health
  health="$(curl -sS "$(ark_lnd_provider_url)/health" 2>/dev/null || true)"
  if [ -n "$health" ]; then
    printf '%s\n' "$health" | jq -r '"  health: ok=\(.ok) database=\(.database)\n  lnd: \(.lnd_rpcserver)\n  ark server: \(.ark_server_url)\n  ark key configured: \(.ark_wallet_key_configured)"' 2>/dev/null || true
  fi
}

while read -r service; do
  case "$service" in
    bitcoind) status_bitcoind ;;
    bitcoind-rpc-proxy) status_bitcoind_rpc_proxy ;;
    esplora) status_esplora ;;
    nbxplorer-postgres) status_nbxplorer_postgres ;;
    nbxplorer) status_nbxplorer ;;
    rgb-proxy) status_rgb_proxy ;;
    node1|node2|node3|node4) status_rln_node "$service" ;;
    lnd1|lnd2) status_lnd_node "$service" ;;
    arkd-wallet) status_arkd_wallet ;;
    arkd) status_arkd ;;
    ark-lnd-provider) status_ark_lnd_provider ;;
  esac
done < <(services_from_args "$@")
