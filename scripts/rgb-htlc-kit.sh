#!/usr/bin/env bash
set -euo pipefail

SIM_DIR="${MUTINY_SIM_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

if ! command -v cargo >/dev/null 2>&1; then
  echo "cargo is required. Enter the repo dev shell, then run this script again." >&2
  exit 2
fi

exec cargo run --manifest-path "$SIM_DIR/tools/rgb-htlc-kit/Cargo.toml" -- "$@"
