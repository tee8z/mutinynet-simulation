#!/usr/bin/env bash

set -euo pipefail

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

stop_service() {
  local service="$1" pid pid_value start
  pid="$(pid_file "$service")"

  if [ ! -f "$pid" ]; then
    echo "$service is not running"
    return 0
  fi

  pid_value="$(cat "$pid")"
  if kill -0 "$pid_value" >/dev/null 2>&1; then
    echo "stopping $service pid $pid_value"
    kill "$pid_value" || true
    start="$(date +%s)"
    while kill -0 "$pid_value" >/dev/null 2>&1; do
      if [ $(( "$(date +%s)" - start )) -ge "${STOP_TIMEOUT_SEC:-30}" ]; then
        echo "$service pid $pid_value is still running after ${STOP_TIMEOUT_SEC:-30}s" >&2
        return 1
      fi
      sleep 1
    done
  else
    echo "$service pid file exists, but process is gone"
  fi

  rm -f "$pid"
}

should_stop_bitcoind_tunnel() {
  local tunnel="$1" arg
  shift
  if [ "$#" -eq 0 ]; then
    return 0
  fi

  for arg in "$@"; do
    case "$tunnel:$arg" in
      p2p:all|p2p:bitcoin|p2p:bitcoin-core|p2p:core|p2p:bitcoind|p2p:bitcoind-p2p|p2p:p2p|p2p:p2p-tunnel|p2p:bitcoind-p2p-tunnel)
        return 0
        ;;
      zmq:all|zmq:bitcoin|zmq:bitcoin-core|zmq:core|zmq:bitcoind|zmq:bitcoind-zmq|zmq:zmq|zmq:zmq-tunnel|zmq:bitcoind-zmq-tunnel)
        return 0
        ;;
    esac
  done
  return 1
}

mapfile -t services < <(services_from_args "$@")
stopped_bitcoind_p2p_tunnel=0
stopped_bitcoind_zmq_tunnel=0
for ((i = ${#services[@]} - 1; i >= 0; i--)); do
  if [ "${services[$i]}" = "bitcoind-p2p-tunnel" ]; then
    "$SIM_DIR/scripts/bitcoind-p2p-tunnel.sh" stop || true
    stopped_bitcoind_p2p_tunnel=1
  elif [ "${services[$i]}" = "bitcoind-zmq-tunnel" ]; then
    "$SIM_DIR/scripts/bitcoind-zmq-tunnel.sh" stop || true
    stopped_bitcoind_zmq_tunnel=1
  else
    stop_service "${services[$i]}"
  fi
done

if should_stop_bitcoind_tunnel p2p "$@" && [ "$stopped_bitcoind_p2p_tunnel" = "0" ]; then
  "$SIM_DIR/scripts/bitcoind-p2p-tunnel.sh" stop || true
fi
if should_stop_bitcoind_tunnel zmq "$@" && [ "$stopped_bitcoind_zmq_tunnel" = "0" ]; then
  "$SIM_DIR/scripts/bitcoind-zmq-tunnel.sh" stop || true
fi
