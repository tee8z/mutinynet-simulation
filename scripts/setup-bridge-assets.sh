#!/usr/bin/env bash

set -euo pipefail

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

export PATH="$SIM_DIR/result/bin:$PATH"

require_cmd curl jq ark

BRIDGE_SETUP_OUTPUT_DIR="${BRIDGE_SETUP_OUTPUT_DIR:-${BRIDGE_TEST_OUTPUT_DIR:-$STATE_DIR/tests/bridge-asset-setup-$(date -u +%Y%m%dT%H%M%SZ)}}"
BRIDGE_SETUP_RGB_TICKER="${BRIDGE_SETUP_RGB_TICKER:-USDX}"
BRIDGE_SETUP_RGB_NAME="${BRIDGE_SETUP_RGB_NAME:-Demo USD}"
BRIDGE_SETUP_RGB_AMOUNT="${BRIDGE_SETUP_RGB_AMOUNT:-2000}"
BRIDGE_SETUP_RGB_PRECISION="${BRIDGE_SETUP_RGB_PRECISION:-0}"
BRIDGE_SETUP_ARK_AMOUNT="${BRIDGE_SETUP_ARK_AMOUNT:-2000}"
BRIDGE_SETUP_ARK_TAKER_AMOUNT="${BRIDGE_SETUP_ARK_TAKER_AMOUNT:-${BRIDGE_TEST_ARK_ASSET_AMOUNT:-100}}"
BRIDGE_SETUP_ARK_TICKER="${BRIDGE_SETUP_ARK_TICKER:-ARKUSD}"

mkdir -p "$BRIDGE_SETUP_OUTPUT_DIR"

log() {
  printf '[bridge-setup] %s\n' "$*"
}

save_json() {
  local file="$1"
  jq . >"$file"
}

extract_rgb_asset_id() {
  jq -er '.asset.asset_id // .asset_id'
}

extract_ark_asset_id() {
  jq -er '.asset_id // .assetId // .asset.id // .id'
}

ark_receive_address() {
  local wallet="$1" response_file="$2"
  ark_cli "$wallet" receive | tee "$response_file" | jq -er '.offchain_address // .address // .addr'
}

ark_balance_has_asset() {
  local wallet="$1" asset_id="$2" needed="$3" balance_file="$4"
  ark_cli "$wallet" balance | save_json "$balance_file"
  jq -e \
    --arg asset_id "$asset_id" \
    --arg amount "$needed" \
    '(.asset_balances[$asset_id] // 0 | tonumber) >= ($amount | tonumber)' \
    "$balance_file" >/dev/null
}

wait_for_rln_node node1
wait_for_rln_node node4
wait_for_arkd
wait_for_ark_lnd_provider

rgb_asset_id="${BRIDGE_TEST_RGB_ASSET_ID:-${RGB_MM_ASSET_ID:-}}"
if [ -z "$rgb_asset_id" ]; then
  log "issuing RGB asset on node1"
  rgb_issue_file="$BRIDGE_SETUP_OUTPUT_DIR/rgb-issue.json"
  api node1 POST /issueassetnia "$(jq -nc \
    --arg ticker "$BRIDGE_SETUP_RGB_TICKER" \
    --arg name "$BRIDGE_SETUP_RGB_NAME" \
    --arg amount "$BRIDGE_SETUP_RGB_AMOUNT" \
    --argjson precision "$BRIDGE_SETUP_RGB_PRECISION" \
    '{ticker:$ticker,name:$name,amount:($amount|tonumber),precision:$precision}')" |
    save_json "$rgb_issue_file"
  rgb_asset_id="$(extract_rgb_asset_id <"$rgb_issue_file")"
else
  log "using RGB asset id from environment"
  jq -nc --arg asset_id "$rgb_asset_id" '{asset_id:$asset_id,source:"env"}' \
    >"$BRIDGE_SETUP_OUTPUT_DIR/rgb-issue.json"
fi

export RGB_MM_ASSET_ID="$rgb_asset_id"
export BRIDGE_TEST_RGB_ASSET_ID="$rgb_asset_id"

log "setting up RGB market-maker channels"
"$SIM_DIR/scripts/setup-market-maker.sh" >"$BRIDGE_SETUP_OUTPUT_DIR/market-maker-setup.log" 2>&1

ark_asset_id="${BRIDGE_TEST_ARK_ASSET_ID:-${ARK_TEST_ASSET_ID:-}}"
if [ -z "$ark_asset_id" ]; then
  log "issuing Ark asset in maker wallet"
  ark_issue_file="$BRIDGE_SETUP_OUTPUT_DIR/ark-issue.json"
  ark_cli maker issue \
    --amount "$BRIDGE_SETUP_ARK_AMOUNT" \
    --control-asset-amount 1 \
    --password "$ARK_CLI_PASSWORD" \
    --metadata "ticker=$BRIDGE_SETUP_ARK_TICKER" |
    save_json "$ark_issue_file"
  ark_asset_id="$(extract_ark_asset_id <"$ark_issue_file")"
else
  log "using Ark asset id from environment"
  jq -nc --arg asset_id "$ark_asset_id" '{asset_id:$asset_id,source:"env"}' \
    >"$BRIDGE_SETUP_OUTPUT_DIR/ark-issue.json"
fi

export BRIDGE_TEST_ARK_ASSET_ID="$ark_asset_id"

maker_balance_file="$BRIDGE_SETUP_OUTPUT_DIR/ark-maker-balance.json"
ark_balance_has_asset maker "$ark_asset_id" "${BRIDGE_TEST_ARK_ASSET_AMOUNT:-100}" "$maker_balance_file" ||
  {
    log "maker wallet does not show the expected Ark asset balance"
    exit 1
  }

taker_balance_file="$BRIDGE_SETUP_OUTPUT_DIR/ark-taker-balance.json"
if ark_balance_has_asset taker "$ark_asset_id" "$BRIDGE_SETUP_ARK_TAKER_AMOUNT" "$taker_balance_file"; then
  log "taker wallet already has Ark asset inventory"
else
  log "funding taker wallet with Ark asset inventory"
  taker_receive_file="$BRIDGE_SETUP_OUTPUT_DIR/ark-taker-receive.json"
  taker_recipient="$(ark_receive_address taker "$taker_receive_file")"
  ark_cli maker send \
    --to "$taker_recipient" \
    --asset-id "$ark_asset_id" \
    --amount "$BRIDGE_SETUP_ARK_TAKER_AMOUNT" \
    --password "$ARK_CLI_PASSWORD" |
    save_json "$BRIDGE_SETUP_OUTPUT_DIR/ark-maker-send-to-taker.json"
  ark_cli taker balance | save_json "$taker_balance_file"
fi

jq -nc \
  --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg rgb_asset_id "$rgb_asset_id" \
  --arg ark_asset_id "$ark_asset_id" \
  --arg output_dir "$BRIDGE_SETUP_OUTPUT_DIR" \
  --arg p2p_endpoint "$(bitcoind_p2p_endpoint)" \
  '{
    generated_at:$generated_at,
    rgb_asset_id:$rgb_asset_id,
    ark_asset_id:$ark_asset_id,
    output_dir:$output_dir,
    p2p_endpoint:$p2p_endpoint
  }' >"$BRIDGE_SETUP_OUTPUT_DIR/setup-summary.json"

log "ready"
cat "$BRIDGE_SETUP_OUTPUT_DIR/setup-summary.json"
