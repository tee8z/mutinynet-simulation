#!/usr/bin/env bash

set -euo pipefail

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

export MUTINY_SIM_DIR="$SIM_DIR"
export BRIDGE_UI_BIND="${BRIDGE_UI_BIND:-127.0.0.1:8091}"
export BRIDGE_UI_STATE_DIR="${BRIDGE_UI_STATE_DIR:-$STATE_DIR/bridge-ui}"
export PATH="$SIM_DIR/result/bin:$PATH"

host="${BRIDGE_UI_BIND%:*}"
port="${BRIDGE_UI_BIND##*:}"
if (echo >"/dev/tcp/$host/$port") >/dev/null 2>&1; then
  if command -v curl >/dev/null 2>&1 \
    && curl -fsS "http://$BRIDGE_UI_BIND/health" >/dev/null 2>&1; then
    echo "bridge UI already running at http://$BRIDGE_UI_BIND"
    exit 0
  fi
  echo "bridge UI bind address is already in use: $BRIDGE_UI_BIND" >&2
  exit 1
fi

exec mutinynet-bridge-ui "$@"
