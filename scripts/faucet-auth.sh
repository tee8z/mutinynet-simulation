#!/usr/bin/env bash

set -euo pipefail

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

ensure_faucet_auth
case "$FAUCET_PROVIDER" in
  ben|mutinynet|public) mutinynet-cli limits ;;
  voltage) echo "Voltage faucet credentials are configured for $VOLTAGE_AUTH_USERNAME" ;;
esac
