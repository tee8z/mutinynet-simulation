#!/usr/bin/env bash

set -euo pipefail

SIM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if command -v rgb-ark-contract-swap >/dev/null 2>&1; then
  exec rgb-ark-contract-swap "$@"
fi

for candidate in \
  "$SIM_DIR/providers/ark-lnd-swap-provider/target/debug/rgb-ark-contract-swap" \
  "$SIM_DIR/providers/ark-lnd-swap-provider/target/release/rgb-ark-contract-swap"; do
  if [ -x "$candidate" ]; then
    exec "$candidate" "$@"
  fi
done

echo "rgb-ark-contract-swap is not built. Run via nix app or build providers/ark-lnd-swap-provider." >&2
exit 127
