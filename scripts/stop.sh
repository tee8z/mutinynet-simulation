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

mapfile -t services < <(services_from_args "$@")
for ((i = ${#services[@]} - 1; i >= 0; i--)); do
  stop_service "${services[$i]}"
done
