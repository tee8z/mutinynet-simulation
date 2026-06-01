#!/usr/bin/env bash

set -euo pipefail

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

pid="$(pid_file bitcoind-p2p-tunnel)"
log="$(log_file bitcoind-p2p-tunnel)"

usage() {
  cat <<EOF
usage: $(basename "$0") [start|stop|status|foreground]

For hosted Bitcoin Core nodes with a public TLS/SNI P2P endpoint, this starts a
local plaintext P2P tunnel that local services can use as:

  BITCOIND_P2P_HOST=$BITCOIND_P2P_TUNNEL_LOCAL_HOST
  BITCOIND_P2P_PORT=$BITCOIND_P2P_TUNNEL_LOCAL_PORT
  NBXPLORER_BTCNODEENDPOINT=$(bitcoind_p2p_endpoint)
  LND_NEUTRINO_CONNECT=$(bitcoind_p2p_endpoint)

Set BITCOIND_P2P_TUNNEL_TARGET_HOST to the public Bitcoin Core hostname. If it
is omitted, the host portion of BITCOIND_RPC_HOST is used.
EOF
}

tunnel_target_host() {
  if [ -n "$BITCOIND_P2P_TUNNEL_TARGET_HOST" ]; then
    printf '%s' "$BITCOIND_P2P_TUNNEL_TARGET_HOST"
  else
    bitcoind_rpc_configured_host
  fi
}

tunnel_server_name() {
  if [ -n "$BITCOIND_P2P_TUNNEL_SERVER_NAME" ]; then
    printf '%s' "$BITCOIND_P2P_TUNNEL_SERVER_NAME"
  else
    tunnel_target_host
  fi
}

status() {
  echo "[bitcoind-p2p-tunnel]"
  echo "  mode: tls"
  echo "  sni: $(tunnel_server_name)"
  bitcoind_tls_tcp_proxy_status "" \
    "$BITCOIND_P2P_TUNNEL_LOCAL_HOST" \
    "$BITCOIND_P2P_TUNNEL_LOCAL_PORT" \
    "$(tunnel_target_host)" \
    "$BITCOIND_P2P_TUNNEL_TARGET_PORT" \
    "$pid" \
    "$log"
}

start() {
  local target_host server_name
  target_host="$(tunnel_target_host)"
  server_name="$(tunnel_server_name)"
  if [ -z "$target_host" ]; then
    echo "missing BITCOIND_P2P_TUNNEL_TARGET_HOST or BITCOIND_RPC_HOST for TLS P2P tunnel" >&2
    return 2
  fi

  start_bitcoind_tls_tcp_proxy \
    bitcoind-p2p-tunnel \
    "$BITCOIND_P2P_TUNNEL_LOCAL_HOST" \
    "$BITCOIND_P2P_TUNNEL_LOCAL_PORT" \
    "$target_host" \
    "$BITCOIND_P2P_TUNNEL_TARGET_PORT" \
    "$server_name" \
    "$BITCOIND_P2P_TUNNEL_INSECURE_SKIP_VERIFY" \
    "$pid" \
    "$log"
}

stop() {
  stop_bitcoind_tls_tcp_proxy bitcoind-p2p-tunnel "$pid"
}

foreground() {
  local target_host server_name
  target_host="$(tunnel_target_host)"
  server_name="$(tunnel_server_name)"
  if [ -z "$target_host" ]; then
    echo "missing BITCOIND_P2P_TUNNEL_TARGET_HOST or BITCOIND_RPC_HOST for TLS P2P tunnel" >&2
    return 2
  fi

  foreground_bitcoind_tls_tcp_proxy \
    bitcoind-p2p-tunnel \
    "$BITCOIND_P2P_TUNNEL_LOCAL_HOST" \
    "$BITCOIND_P2P_TUNNEL_LOCAL_PORT" \
    "$target_host" \
    "$BITCOIND_P2P_TUNNEL_TARGET_PORT" \
    "$server_name" \
    "$BITCOIND_P2P_TUNNEL_INSECURE_SKIP_VERIFY"
}

case "${1:-start}" in
  start) start ;;
  stop) stop ;;
  status) status ;;
  foreground) foreground ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
