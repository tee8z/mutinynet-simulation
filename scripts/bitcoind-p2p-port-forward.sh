#!/usr/bin/env bash

set -euo pipefail

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

pid="$RUN_DIR/bitcoind-p2p-port-forward.pid"
log="$LOG_DIR/bitcoind-p2p-port-forward.log"

usage() {
  cat <<EOF
usage: $(basename "$0") [start|stop|status|foreground]

For hosted Bitcoin Core nodes with an internal Kubernetes P2P service, this
starts a local tunnel that cluster services can use as:

  BITCOIND_P2P_HOST=$BITCOIND_P2P_PORT_FORWARD_LOCAL_HOST
  BITCOIND_P2P_PORT=$BITCOIND_P2P_PORT_FORWARD_LOCAL_PORT
  NBXPLORER_BTCNODEENDPOINT=$(bitcoind_p2p_endpoint)
  LND_NEUTRINO_CONNECT=$(bitcoind_p2p_endpoint)
EOF
}

port_forward_args() {
  require_env BITCOIND_P2P_PORT_FORWARD_NAMESPACE BITCOIND_P2P_PORT_FORWARD_SERVICE
  printf '%s\0' \
    -n "$BITCOIND_P2P_PORT_FORWARD_NAMESPACE" \
    port-forward \
    --address "$BITCOIND_P2P_PORT_FORWARD_LOCAL_HOST" \
    "svc/$BITCOIND_P2P_PORT_FORWARD_SERVICE" \
    "$BITCOIND_P2P_PORT_FORWARD_LOCAL_PORT:$BITCOIND_P2P_PORT_FORWARD_REMOTE_PORT"
}

port_is_open() {
  if (echo >"/dev/tcp/$BITCOIND_P2P_PORT_FORWARD_LOCAL_HOST/$BITCOIND_P2P_PORT_FORWARD_LOCAL_PORT") >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

print_forward_port() {
  if port_is_open; then
    echo "  port: ${BITCOIND_P2P_PORT_FORWARD_LOCAL_HOST}:${BITCOIND_P2P_PORT_FORWARD_LOCAL_PORT} open"
  else
    echo "  port: ${BITCOIND_P2P_PORT_FORWARD_LOCAL_HOST}:${BITCOIND_P2P_PORT_FORWARD_LOCAL_PORT} closed"
  fi
}

is_running() {
  [ -f "$pid" ] && kill -0 "$(cat "$pid")" >/dev/null 2>&1
}

status() {
  echo "[bitcoind-p2p-port-forward]"
  echo "  namespace: ${BITCOIND_P2P_PORT_FORWARD_NAMESPACE:-missing}"
  echo "  service: ${BITCOIND_P2P_PORT_FORWARD_SERVICE:-missing}"
  echo "  local: ${BITCOIND_P2P_PORT_FORWARD_LOCAL_HOST}:${BITCOIND_P2P_PORT_FORWARD_LOCAL_PORT}"
  echo "  remote: ${BITCOIND_P2P_PORT_FORWARD_REMOTE_PORT}"
  echo "  log: $log"
  if is_running; then
    echo "  pid: $(cat "$pid")"
  else
    echo "  pid: not running"
  fi
  print_forward_port
}

start() {
  require_cmd kubectl
  mkdir -p "$RUN_DIR" "$LOG_DIR"

  if is_running; then
    echo "bitcoind-p2p-port-forward already running: pid $(cat "$pid")"
    wait_for_tcp "$BITCOIND_P2P_PORT_FORWARD_LOCAL_HOST" "$BITCOIND_P2P_PORT_FORWARD_LOCAL_PORT" bitcoind-p2p-port-forward 30
    return 0
  fi
  if port_is_open; then
    echo "bitcoind-p2p-port-forward already listening on ${BITCOIND_P2P_PORT_FORWARD_LOCAL_HOST}:${BITCOIND_P2P_PORT_FORWARD_LOCAL_PORT}"
    return 0
  fi
  rm -f "$pid"

  local -a args cmd
  mapfile -d '' -t args < <(port_forward_args)
  cmd=(kubectl "${args[@]}")
  if [ -n "$BITCOIND_P2P_PORT_FORWARD_AWS_PROFILE" ]; then
    cmd=(env AWS_PROFILE="$BITCOIND_P2P_PORT_FORWARD_AWS_PROFILE" "${cmd[@]}")
  fi

  echo "starting bitcoind-p2p-port-forward ${BITCOIND_P2P_PORT_FORWARD_LOCAL_HOST}:${BITCOIND_P2P_PORT_FORWARD_LOCAL_PORT} -> ${BITCOIND_P2P_PORT_FORWARD_NAMESPACE}/svc/${BITCOIND_P2P_PORT_FORWARD_SERVICE}:${BITCOIND_P2P_PORT_FORWARD_REMOTE_PORT}"
  setsid "${cmd[@]}" </dev/null >"$log" 2>&1 &
  echo $! >"$pid"

  wait_for_tcp "$BITCOIND_P2P_PORT_FORWARD_LOCAL_HOST" "$BITCOIND_P2P_PORT_FORWARD_LOCAL_PORT" bitcoind-p2p-port-forward 30
}

stop() {
  if is_running; then
    echo "stopping bitcoind-p2p-port-forward pid $(cat "$pid")"
    kill "$(cat "$pid")"
  fi
  rm -f "$pid"
}

foreground() {
  require_cmd kubectl
  local -a args cmd
  mapfile -d '' -t args < <(port_forward_args)
  cmd=(kubectl "${args[@]}")
  if [ -n "$BITCOIND_P2P_PORT_FORWARD_AWS_PROFILE" ]; then
    cmd=(env AWS_PROFILE="$BITCOIND_P2P_PORT_FORWARD_AWS_PROFILE" "${cmd[@]}")
  fi
  echo "foreground bitcoind-p2p-port-forward ${BITCOIND_P2P_PORT_FORWARD_LOCAL_HOST}:${BITCOIND_P2P_PORT_FORWARD_LOCAL_PORT} -> ${BITCOIND_P2P_PORT_FORWARD_NAMESPACE}/svc/${BITCOIND_P2P_PORT_FORWARD_SERVICE}:${BITCOIND_P2P_PORT_FORWARD_REMOTE_PORT}"
  exec "${cmd[@]}"
}

case "${1:-start}" in
  start) start ;;
  stop) stop ;;
  status) status ;;
  foreground) foreground ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
