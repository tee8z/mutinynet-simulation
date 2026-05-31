#!/usr/bin/env bash

set -euo pipefail

SIM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

exec "$SIM_DIR/scripts/test-lightning-ark-bridge.sh" ark-asset-to-rgb-asset "$@"
