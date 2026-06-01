#!/usr/bin/env bash

set -euo pipefail

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

rawblock_pid="$(pid_file bitcoind-zmq-rawblock-tunnel)"
rawtx_pid="$(pid_file bitcoind-zmq-rawtx-tunnel)"
rawblock_log="$(log_file bitcoind-zmq-rawblock-tunnel)"
rawtx_log="$(log_file bitcoind-zmq-rawtx-tunnel)"

usage() {
  cat <<EOF
usage: $(basename "$0") [start|stop|status|foreground-rawblock|foreground-rawtx]

For hosted Bitcoin Core nodes with public TLS/SNI ZMQ endpoints, this starts
local plaintext rawblock and rawtx tunnels that LND can use as:

  BITCOIND_ZMQ_PUB_RAW_BLOCK=tcp://$BITCOIND_ZMQ_TUNNEL_LOCAL_HOST:$BITCOIND_ZMQ_TUNNEL_RAW_BLOCK_LOCAL_PORT
  BITCOIND_ZMQ_PUB_RAW_TX=tcp://$BITCOIND_ZMQ_TUNNEL_LOCAL_HOST:$BITCOIND_ZMQ_TUNNEL_RAW_TX_LOCAL_PORT

Set BITCOIND_ZMQ_TUNNEL_TARGET_HOST to the public Bitcoin Core hostname. If it
is omitted, BITCOIND_P2P_TUNNEL_TARGET_HOST is used, then BITCOIND_RPC_HOST.
EOF
}

tunnel_target_host() {
  if [ -n "$BITCOIND_ZMQ_TUNNEL_TARGET_HOST" ]; then
    printf '%s' "$BITCOIND_ZMQ_TUNNEL_TARGET_HOST"
  elif [ -n "$BITCOIND_P2P_TUNNEL_TARGET_HOST" ]; then
    printf '%s' "$BITCOIND_P2P_TUNNEL_TARGET_HOST"
  else
    bitcoind_rpc_configured_host
  fi
}

tunnel_server_name() {
  if [ -n "$BITCOIND_ZMQ_TUNNEL_SERVER_NAME" ]; then
    printf '%s' "$BITCOIND_ZMQ_TUNNEL_SERVER_NAME"
  else
    tunnel_target_host
  fi
}

status_one() {
  local label="$1" local_port="$2" target_port="$3" pid="$4" log="$5"
  bitcoind_tls_tcp_proxy_status "$label" \
    "$BITCOIND_ZMQ_TUNNEL_LOCAL_HOST" \
    "$local_port" \
    "$(tunnel_target_host)" \
    "$target_port" \
    "$pid" \
    "$log"
}

status() {
  echo "[bitcoind-zmq-tunnel]"
  echo "  mode: tls"
  echo "  sni: $(tunnel_server_name)"
  status_one rawblock "$BITCOIND_ZMQ_TUNNEL_RAW_BLOCK_LOCAL_PORT" "$BITCOIND_ZMQ_TUNNEL_RAW_BLOCK_TARGET_PORT" "$rawblock_pid" "$rawblock_log"
  status_one rawtx "$BITCOIND_ZMQ_TUNNEL_RAW_TX_LOCAL_PORT" "$BITCOIND_ZMQ_TUNNEL_RAW_TX_TARGET_PORT" "$rawtx_pid" "$rawtx_log"
}

require_target_host() {
  local target_host
  target_host="$(tunnel_target_host)"
  if [ -z "$target_host" ]; then
    echo "missing BITCOIND_ZMQ_TUNNEL_TARGET_HOST, BITCOIND_P2P_TUNNEL_TARGET_HOST, or BITCOIND_RPC_HOST for TLS ZMQ tunnel" >&2
    return 2
  fi
}

start_one() {
  local label="$1" local_port="$2" target_port="$3" pid="$4" log="$5"
  local target_host server_name

  target_host="$(tunnel_target_host)"
  server_name="$(tunnel_server_name)"
  start_bitcoind_tls_tcp_proxy \
    "bitcoind-zmq-${label}-tunnel" \
    "$BITCOIND_ZMQ_TUNNEL_LOCAL_HOST" \
    "$local_port" \
    "$target_host" \
    "$target_port" \
    "$server_name" \
    "$BITCOIND_ZMQ_TUNNEL_INSECURE_SKIP_VERIFY" \
    "$pid" \
    "$log"
}

start() {
  require_target_host
  if [ "$BITCOIND_ZMQ_TUNNEL_RAW_BLOCK_LOCAL_PORT" = "$BITCOIND_ZMQ_TUNNEL_RAW_TX_LOCAL_PORT" ]; then
    echo "BITCOIND_ZMQ_TUNNEL_RAW_BLOCK_LOCAL_PORT and BITCOIND_ZMQ_TUNNEL_RAW_TX_LOCAL_PORT must be different" >&2
    return 2
  fi

  start_one rawblock "$BITCOIND_ZMQ_TUNNEL_RAW_BLOCK_LOCAL_PORT" "$BITCOIND_ZMQ_TUNNEL_RAW_BLOCK_TARGET_PORT" "$rawblock_pid" "$rawblock_log"
  start_one rawtx "$BITCOIND_ZMQ_TUNNEL_RAW_TX_LOCAL_PORT" "$BITCOIND_ZMQ_TUNNEL_RAW_TX_TARGET_PORT" "$rawtx_pid" "$rawtx_log"
}

stop_one() {
  local label="$1" pid="$2"
  stop_bitcoind_tls_tcp_proxy "bitcoind-zmq-${label}-tunnel" "$pid"
}

stop() {
  stop_one rawblock "$rawblock_pid"
  stop_one rawtx "$rawtx_pid"
}

foreground_one() {
  local label="$1" local_port="$2" target_port="$3"
  local target_host server_name
  require_target_host
  target_host="$(tunnel_target_host)"
  server_name="$(tunnel_server_name)"

  foreground_bitcoind_tls_tcp_proxy \
    "bitcoind-zmq-${label}-tunnel" \
    "$BITCOIND_ZMQ_TUNNEL_LOCAL_HOST" \
    "$local_port" \
    "$target_host" \
    "$target_port" \
    "$server_name" \
    "$BITCOIND_ZMQ_TUNNEL_INSECURE_SKIP_VERIFY"
}

case "${1:-start}" in
  start) start ;;
  stop) stop ;;
  status) status ;;
  foreground-rawblock) foreground_one rawblock "$BITCOIND_ZMQ_TUNNEL_RAW_BLOCK_LOCAL_PORT" "$BITCOIND_ZMQ_TUNNEL_RAW_BLOCK_TARGET_PORT" ;;
  foreground-rawtx) foreground_one rawtx "$BITCOIND_ZMQ_TUNNEL_RAW_TX_LOCAL_PORT" "$BITCOIND_ZMQ_TUNNEL_RAW_TX_TARGET_PORT" ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
