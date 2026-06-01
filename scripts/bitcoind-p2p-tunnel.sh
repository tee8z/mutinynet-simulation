#!/usr/bin/env bash

set -euo pipefail

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

pid="$(pid_file bitcoind-p2p-tunnel)"
legacy_pid="$RUN_DIR/bitcoind-p2p-port-forward.pid"
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

port_is_open() {
  if (echo >"/dev/tcp/$BITCOIND_P2P_TUNNEL_LOCAL_HOST/$BITCOIND_P2P_TUNNEL_LOCAL_PORT") >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

print_tunnel_port() {
  if port_is_open; then
    echo "  port: ${BITCOIND_P2P_TUNNEL_LOCAL_HOST}:${BITCOIND_P2P_TUNNEL_LOCAL_PORT} open"
  else
    echo "  port: ${BITCOIND_P2P_TUNNEL_LOCAL_HOST}:${BITCOIND_P2P_TUNNEL_LOCAL_PORT} closed"
  fi
}

pid_is_running() {
  local candidate="$1"
  [ -f "$candidate" ] && kill -0 "$(cat "$candidate")" >/dev/null 2>&1
}

current_pid_file() {
  local candidate
  for candidate in "$pid" "$legacy_pid"; do
    if pid_is_running "$candidate"; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

status() {
  local running_pid
  echo "[bitcoind-p2p-tunnel]"
  echo "  mode: tls"
  echo "  local: ${BITCOIND_P2P_TUNNEL_LOCAL_HOST}:${BITCOIND_P2P_TUNNEL_LOCAL_PORT}"
  echo "  target: $(tunnel_target_host):${BITCOIND_P2P_TUNNEL_TARGET_PORT}"
  echo "  sni: $(tunnel_server_name)"
  echo "  log: $log"
  if running_pid="$(current_pid_file)"; then
    echo "  pid: $(cat "$running_pid")"
  else
    echo "  pid: not running"
  fi
  print_tunnel_port
}

start() {
  mkdir -p "$RUN_DIR" "$LOG_DIR"

  local running_pid
  if running_pid="$(current_pid_file)"; then
    echo "bitcoind-p2p-tunnel already running: pid $(cat "$running_pid")"
    wait_for_tcp "$BITCOIND_P2P_TUNNEL_LOCAL_HOST" "$BITCOIND_P2P_TUNNEL_LOCAL_PORT" bitcoind-p2p-tunnel 30
    return 0
  fi
  if port_is_open; then
    echo "bitcoind-p2p-tunnel already listening on ${BITCOIND_P2P_TUNNEL_LOCAL_HOST}:${BITCOIND_P2P_TUNNEL_LOCAL_PORT}"
    return 0
  fi
  rm -f "$pid" "$legacy_pid"

  require_cmd python3
  local target_host server_name
  target_host="$(tunnel_target_host)"
  server_name="$(tunnel_server_name)"
  if [ -z "$target_host" ]; then
    echo "missing BITCOIND_P2P_TUNNEL_TARGET_HOST or BITCOIND_RPC_HOST for TLS P2P tunnel" >&2
    return 2
  fi

  echo "starting bitcoind-p2p-tunnel ${BITCOIND_P2P_TUNNEL_LOCAL_HOST}:${BITCOIND_P2P_TUNNEL_LOCAL_PORT} -> tls://${target_host}:${BITCOIND_P2P_TUNNEL_TARGET_PORT} sni=${server_name}"
  TCP_TLS_TUNNEL_LISTEN_HOST="$BITCOIND_P2P_TUNNEL_LOCAL_HOST" \
  TCP_TLS_TUNNEL_LISTEN_PORT="$BITCOIND_P2P_TUNNEL_LOCAL_PORT" \
  TCP_TLS_TUNNEL_TARGET_HOST="$target_host" \
  TCP_TLS_TUNNEL_TARGET_PORT="$BITCOIND_P2P_TUNNEL_TARGET_PORT" \
  TCP_TLS_TUNNEL_SERVER_NAME="$server_name" \
  TCP_TLS_TUNNEL_INSECURE_SKIP_VERIFY="$BITCOIND_P2P_TUNNEL_INSECURE_SKIP_VERIFY" \
    setsid python3 "$SIM_DIR/scripts/tcp-tls-tunnel.py" </dev/null >"$log" 2>&1 &
  echo $! >"$pid"

  wait_for_tcp "$BITCOIND_P2P_TUNNEL_LOCAL_HOST" "$BITCOIND_P2P_TUNNEL_LOCAL_PORT" bitcoind-p2p-tunnel 30
}

stop() {
  local candidate
  for candidate in "$pid" "$legacy_pid"; do
    if pid_is_running "$candidate"; then
      echo "stopping bitcoind-p2p-tunnel pid $(cat "$candidate")"
      kill "$(cat "$candidate")"
    fi
    rm -f "$candidate"
  done
}

foreground() {
  require_cmd python3
  local target_host server_name
  target_host="$(tunnel_target_host)"
  server_name="$(tunnel_server_name)"
  if [ -z "$target_host" ]; then
    echo "missing BITCOIND_P2P_TUNNEL_TARGET_HOST or BITCOIND_RPC_HOST for TLS P2P tunnel" >&2
    return 2
  fi

  echo "foreground bitcoind-p2p-tunnel ${BITCOIND_P2P_TUNNEL_LOCAL_HOST}:${BITCOIND_P2P_TUNNEL_LOCAL_PORT} -> tls://${target_host}:${BITCOIND_P2P_TUNNEL_TARGET_PORT} sni=${server_name}"
  TCP_TLS_TUNNEL_LISTEN_HOST="$BITCOIND_P2P_TUNNEL_LOCAL_HOST" \
  TCP_TLS_TUNNEL_LISTEN_PORT="$BITCOIND_P2P_TUNNEL_LOCAL_PORT" \
  TCP_TLS_TUNNEL_TARGET_HOST="$target_host" \
  TCP_TLS_TUNNEL_TARGET_PORT="$BITCOIND_P2P_TUNNEL_TARGET_PORT" \
  TCP_TLS_TUNNEL_SERVER_NAME="$server_name" \
  TCP_TLS_TUNNEL_INSECURE_SKIP_VERIFY="$BITCOIND_P2P_TUNNEL_INSECURE_SKIP_VERIFY" \
    exec python3 "$SIM_DIR/scripts/tcp-tls-tunnel.py"
}

case "${1:-start}" in
  start) start ;;
  stop) stop ;;
  status) status ;;
  foreground) foreground ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
