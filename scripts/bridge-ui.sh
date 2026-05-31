#!/usr/bin/env bash

set -euo pipefail

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

export MUTINY_SIM_DIR="$SIM_DIR"
export BRIDGE_UI_BIND="${BRIDGE_UI_BIND:-127.0.0.1:8091}"
export BRIDGE_UI_STATE_DIR="${BRIDGE_UI_STATE_DIR:-$STATE_DIR/bridge-ui}"
export PATH="$SIM_DIR/result/bin:$PATH"

exec mutinynet-bridge-ui "$@"
