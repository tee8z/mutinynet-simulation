#!/usr/bin/env bash

set -euo pipefail

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

require_cmd jq curl

echo "[init-local] starting local stack"
"$SIM_DIR/scripts/start.sh" all

if bitcoind_managed; then
  echo "[init-local] waiting for local bitcoind to finish initial block download"
  wait_for_bitcoind_synced
else
  echo "[init-local] bitcoind is external; skipping local IBD wait"
fi

if rln_indexer_uses_local; then
  echo "[init-local] waiting for local Esplora HTTP API"
  "$SIM_DIR/scripts/start.sh" esplora
  wait_for_esplora_http
fi

echo "[init-local] unlocking and initializing RGB and Ark wallets"
"$SIM_DIR/scripts/init-unlock.sh" all

echo "[init-local] waiting for LND chain sync"
wait_for_lnd_chain_synced lnd1
wait_for_lnd_chain_synced lnd2

echo "[init-local] waiting for provider"
wait_for_ark_lnd_provider

echo "[init-local] ready"
"$SIM_DIR/scripts/status.sh" bitcoind esplora lnd1 lnd2 ark-lnd-provider node1 node4
