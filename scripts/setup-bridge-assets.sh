#!/usr/bin/env bash

set -euo pipefail

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

export PATH="$SIM_DIR/result/bin:$PATH"

require_cmd curl jq ark "$LNCLI_BINARY"

BRIDGE_SETUP_OUTPUT_DIR="${BRIDGE_SETUP_OUTPUT_DIR:-${BRIDGE_TEST_OUTPUT_DIR:-$STATE_DIR/tests/bridge-asset-setup-$(date -u +%Y%m%dT%H%M%SZ)}}"
BRIDGE_SETUP_RGB_TICKER="${BRIDGE_SETUP_RGB_TICKER:-USDX}"
BRIDGE_SETUP_RGB_NAME="${BRIDGE_SETUP_RGB_NAME:-Demo USD}"
BRIDGE_SETUP_RGB_AMOUNT="${BRIDGE_SETUP_RGB_AMOUNT:-2000}"
BRIDGE_SETUP_RGB_PRECISION="${BRIDGE_SETUP_RGB_PRECISION:-0}"
BRIDGE_SETUP_ARK_AMOUNT="${BRIDGE_SETUP_ARK_AMOUNT:-2000}"
BRIDGE_SETUP_ARK_UNIT_AMOUNT="${BRIDGE_TEST_ARK_ASSET_AMOUNT:-100}"
BRIDGE_SETUP_ARK_RESERVE_RUNS="${BRIDGE_SETUP_ARK_RESERVE_RUNS:-5}"
BRIDGE_SETUP_ARK_PROVIDER_AMOUNT="${BRIDGE_SETUP_ARK_PROVIDER_AMOUNT:-$((BRIDGE_SETUP_ARK_UNIT_AMOUNT * BRIDGE_SETUP_ARK_RESERVE_RUNS))}"
BRIDGE_SETUP_ARK_PROVIDER_MIN_SATS="${BRIDGE_SETUP_ARK_PROVIDER_MIN_SATS:-5000}"
BRIDGE_SETUP_ARK_TAKER_AMOUNT="${BRIDGE_SETUP_ARK_TAKER_AMOUNT:-$((BRIDGE_SETUP_ARK_UNIT_AMOUNT * BRIDGE_SETUP_ARK_RESERVE_RUNS))}"
BRIDGE_SETUP_ARK_TAKER_MIN_SATS="${BRIDGE_SETUP_ARK_TAKER_MIN_SATS:-5000}"
BRIDGE_SETUP_ARK_TICKER="${BRIDGE_SETUP_ARK_TICKER:-ARKUSD}"
BRIDGE_TEST_LND_RGB_NODE="${BRIDGE_TEST_LND_RGB_NODE:-lnd1}"
BRIDGE_TEST_LND_PROVIDER_NODE="${BRIDGE_TEST_LND_PROVIDER_NODE:-$ARK_LND_PROVIDER_LND_NODE}"
BRIDGE_TEST_LN_TO_ARK_SATS="${BRIDGE_TEST_LN_TO_ARK_SATS:-6000}"
BRIDGE_SETUP_LND_MIN_OUTBOUND_SATS="${BRIDGE_SETUP_LND_MIN_OUTBOUND_SATS:-20000}"
BRIDGE_SETUP_LND_REBALANCE_SATS="${BRIDGE_SETUP_LND_REBALANCE_SATS:-20000}"
BRIDGE_SETUP_LND_REBALANCE_FEE_LIMIT_SAT="${BRIDGE_SETUP_LND_REBALANCE_FEE_LIMIT_SAT:-20}"

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
  local current
  current="$(ark_asset_amount "$wallet" "$asset_id" "$balance_file")"
  [ "$current" -ge "$needed" ]
}

ark_asset_amount() {
  local wallet="$1" asset_id="$2" balance_file="$3"
  ark_cli "$wallet" balance | save_json "$balance_file"
  jq -er \
    --arg asset_id "$asset_id" \
    '(.asset_balances[$asset_id] // 0) | tonumber' \
    "$balance_file"
}

provider_post() {
  local path="$1" body="${2:-}"
  if [ -z "$body" ]; then
    body='{}'
  fi
  local response_file status
  response_file="$(mktemp "$BRIDGE_SETUP_OUTPUT_DIR/provider-response.XXXXXX")"
  status="$(curl -sS --output "$response_file" --write-out '%{http_code}' \
    -H 'Content-Type: application/json' \
    --data "$body" "$(ark_lnd_provider_url)$path")" || {
    cat "$response_file" >&2 || true
    rm -f "$response_file"
    return 1
  }
  if [ "$status" -lt 200 ] || [ "$status" -ge 300 ]; then
    cat "$response_file" >&2 || true
    rm -f "$response_file"
    return 1
  fi
  cat "$response_file"
  rm -f "$response_file"
}

provider_ark_balance_has_asset() {
  local asset_id="$1" needed="$2" balance_file="$3"
  local current
  current="$(provider_ark_asset_amount "$asset_id" "$balance_file")"
  [ "$current" -ge "$needed" ]
}

provider_ark_asset_amount() {
  local asset_id="$1" balance_file="$2"
  provider_post /v1/ark/balance '{}' | save_json "$balance_file"
  jq -er \
    --arg asset_id "$asset_id" \
    '((.stdout.assets // []) | map(select(.asset_id == $asset_id) | (.amount | tonumber)) | add) // 0' \
    "$balance_file"
}

provider_ark_total_sats() {
  local balance_file="$1"
  provider_post /v1/ark/balance '{}' | save_json "$balance_file"
  jq -er '(.stdout.total_sat // 0) | tonumber' "$balance_file"
}

ark_grpc_wallet_body() {
  local private_key_hex="$1"
  jq -nc --arg wallet_private_key_hex "$private_key_hex" \
    '{wallet_private_key_hex:$wallet_private_key_hex}'
}

ark_grpc_balance_has_asset() {
  local private_key_hex="$1" asset_id="$2" needed="$3" balance_file="$4"
  local current
  current="$(ark_grpc_asset_amount "$private_key_hex" "$asset_id" "$balance_file")"
  [ "$current" -ge "$needed" ]
}

ark_grpc_asset_amount() {
  local private_key_hex="$1" asset_id="$2" balance_file="$3"
  provider_post /v1/ark/balance "$(ark_grpc_wallet_body "$private_key_hex")" | save_json "$balance_file"
  jq -er \
    --arg asset_id "$asset_id" \
    '((.stdout.assets // []) | map(select(.asset_id == $asset_id) | (.amount | tonumber)) | add) // 0' \
    "$balance_file"
}

ark_grpc_total_sats() {
  local private_key_hex="$1" balance_file="$2"
  provider_post /v1/ark/balance "$(ark_grpc_wallet_body "$private_key_hex")" | save_json "$balance_file"
  jq -er '(.stdout.total_sat // 0) | tonumber' "$balance_file"
}

ensure_ark_grpc_sats() {
  local label="$1" private_key_hex="$2" needed="$3" balance_file="$4" receive_file="$5" send_file="$6"
  local current recipient amount start
  current="$(ark_grpc_total_sats "$private_key_hex" "$balance_file")"
  if [ "$current" -ge "$needed" ]; then
    log "$label Ark gRPC wallet already has BTC liquidity"
    return 0
  fi

  amount="$(( needed - current ))"
  log "funding $label Ark gRPC wallet with BTC liquidity"
  provider_post /v1/ark/receive "$(ark_grpc_wallet_body "$private_key_hex")" | save_json "$receive_file"
  recipient="$(jq -er '.stdout.ark_address // .stdout.address // .ark_address // .address' "$receive_file")"
  ark_cli maker send \
    --to "$recipient" \
    --amount "$amount" \
    --password "$ARK_CLI_PASSWORD" |
    save_json "$send_file"

  start="$(date +%s)"
  while true; do
    current="$(ark_grpc_total_sats "$private_key_hex" "$balance_file")"
    if [ "$current" -ge "$needed" ]; then
      return 0
    fi
    if [ $(( "$(date +%s)" - start )) -ge "$WAIT_TIMEOUT_SEC" ]; then
      log "$label Ark gRPC wallet did not show the expected BTC liquidity before timeout"
      cat "$balance_file" >&2 || true
      return 1
    fi
    sleep 5
  done
}

ensure_ark_grpc_asset() {
  local label="$1" private_key_hex="$2" asset_id="$3" needed="$4" balance_file="$5" receive_file="$6" send_file="$7"
  local current recipient amount start
  current="$(ark_grpc_asset_amount "$private_key_hex" "$asset_id" "$balance_file")"
  if [ "$current" -ge "$needed" ]; then
    log "$label Ark gRPC wallet already has asset inventory"
    return 0
  fi

  amount="$(( needed - current ))"
  log "funding $label Ark gRPC wallet with asset inventory"
  provider_post /v1/ark/receive "$(ark_grpc_wallet_body "$private_key_hex")" | save_json "$receive_file"
  recipient="$(jq -er '.stdout.ark_address // .stdout.address // .ark_address // .address' "$receive_file")"
  ark_cli maker send \
    --to "$recipient" \
    --asset-id "$asset_id" \
    --amount "$amount" \
    --password "$ARK_CLI_PASSWORD" |
    save_json "$send_file"

  start="$(date +%s)"
  while true; do
    if ark_grpc_balance_has_asset "$private_key_hex" "$asset_id" "$needed" "$balance_file"; then
      return 0
    fi
    if [ $(( "$(date +%s)" - start )) -ge "$WAIT_TIMEOUT_SEC" ]; then
      log "$label Ark gRPC wallet did not show the expected asset balance before timeout"
      cat "$balance_file" >&2 || true
      return 1
    fi
    sleep 5
  done
}

ensure_provider_ark_sats() {
  local needed="$1" balance_file="$2" receive_file="$3" send_file="$4"
  local current recipient amount start
  current="$(provider_ark_total_sats "$balance_file")"
  if [ "$current" -ge "$needed" ]; then
    log "provider Ark gRPC wallet already has BTC liquidity"
    return 0
  fi

  amount="$(( needed - current ))"
  log "funding provider Ark gRPC wallet with BTC liquidity"
  provider_post /v1/ark/receive '{}' | save_json "$receive_file"
  recipient="$(jq -er '.stdout.ark_address // .stdout.address // .ark_address // .address' "$receive_file")"
  ark_cli maker send \
    --to "$recipient" \
    --amount "$amount" \
    --password "$ARK_CLI_PASSWORD" |
    save_json "$send_file"

  start="$(date +%s)"
  while true; do
    current="$(provider_ark_total_sats "$balance_file")"
    if [ "$current" -ge "$needed" ]; then
      return 0
    fi
    if [ $(( "$(date +%s)" - start )) -ge "$WAIT_TIMEOUT_SEC" ]; then
      log "provider Ark gRPC wallet did not show the expected BTC liquidity before timeout"
      cat "$balance_file" >&2 || true
      return 1
    fi
    sleep 5
  done
}

ensure_provider_ark_asset() {
  local asset_id="$1" needed="$2" balance_file="$3" receive_file="$4" send_file="$5" recipient start
  local current amount
  current="$(provider_ark_asset_amount "$asset_id" "$balance_file")"
  if [ "$current" -ge "$needed" ]; then
    log "provider Ark gRPC wallet already has asset inventory"
    return 0
  fi

  amount="$(( needed - current ))"
  log "funding provider Ark gRPC wallet with asset inventory"
  provider_post /v1/ark/receive '{}' | save_json "$receive_file"
  recipient="$(jq -er '.stdout.ark_address // .stdout.address // .ark_address // .address' "$receive_file")"
  ark_cli maker send \
    --to "$recipient" \
    --asset-id "$asset_id" \
    --amount "$amount" \
    --password "$ARK_CLI_PASSWORD" |
    save_json "$send_file"

  start="$(date +%s)"
  while true; do
    if provider_ark_balance_has_asset "$asset_id" "$needed" "$balance_file"; then
      return 0
    fi
    if [ $(( "$(date +%s)" - start )) -ge "$WAIT_TIMEOUT_SEC" ]; then
      log "provider Ark gRPC wallet did not show the expected asset balance before timeout"
      cat "$balance_file" >&2 || true
      return 1
    fi
    sleep 5
  done
}

node_has_colorable_utxo() {
  local node="$1"
  api "$node" POST /listunspents '{"skip_sync":false}' | jq -e \
    '[.unspents[]? | select((.utxo.colorable == true) and ((.rgb_allocations // []) | length == 0))] | length > 0' \
    >/dev/null
}

ensure_colorable_utxos() {
  local node="$1" create_file="$2" start
  if node_has_colorable_utxo "$node"; then
    log "$node already has a colorable RGB UTXO"
    return 0
  fi

  log "creating RGB colorable UTXOs on $node"
  api "$node" POST /createutxos '{"up_to":false,"num":4,"size":32000,"fee_rate":7,"skip_sync":false}' |
    save_json "$create_file"

  start="$(date +%s)"
  while true; do
    if node_has_colorable_utxo "$node"; then
      return 0
    fi
    if [ $(( "$(date +%s)" - start )) -ge "$WAIT_TIMEOUT_SEC" ]; then
      log "$node did not show a colorable RGB UTXO before timeout"
      api "$node" POST /listunspents '{"skip_sync":false}' | jq . >&2 || true
      return 1
    fi
    sleep 5
  done
}

ensure_lnd_bridge_liquidity() {
  local left="$BRIDGE_TEST_LND_RGB_NODE" right="$BRIDGE_TEST_LND_PROVIDER_NODE"
  local min_sats="$BRIDGE_SETUP_LND_MIN_OUTBOUND_SATS" rebalance_sats="$BRIDGE_SETUP_LND_REBALANCE_SATS"
  local fee_limit="$BRIDGE_SETUP_LND_REBALANCE_FEE_LIMIT_SAT" right_pubkey current invoice invoice_file pay_file status_file

  if [ "$min_sats" -lt "$((BRIDGE_TEST_LN_TO_ARK_SATS + 2000))" ]; then
    min_sats="$((BRIDGE_TEST_LN_TO_ARK_SATS + 2000))"
  fi

  wait_for_lnd_unlocked "$left"
  wait_for_lnd_unlocked "$right"
  right_pubkey="$(lnd_cli "$right" getinfo | jq -er .identity_pubkey)"
  status_file="$BRIDGE_SETUP_OUTPUT_DIR/lnd-bridge-liquidity.json"
  lnd_cli "$left" listchannels |
    jq --arg right_pubkey "$right_pubkey" \
      '[.channels[] | select(.remote_pubkey == $right_pubkey) | {active,local_balance,remote_balance,capacity,unsettled_balance}]' \
      >"$status_file"
  current="$(jq -er '([.[] | select(.active == true) | (.local_balance | tonumber)] | max) // 0' "$status_file")"
  if [ "$current" -ge "$min_sats" ]; then
    log "$left -> $right already has outbound Lightning liquidity"
    return 0
  fi

  log "rebalancing Lightning liquidity from $right to $left"
  invoice_file="$BRIDGE_SETUP_OUTPUT_DIR/lnd-bridge-rebalance-invoice.json"
  pay_file="$BRIDGE_SETUP_OUTPUT_DIR/lnd-bridge-rebalance-pay.txt"
  invoice="$(lnd_cli "$left" addinvoice --amt "$rebalance_sats" --memo bridge-liquidity-rebalance |
    tee "$invoice_file" |
    jq -er .payment_request)"
  lnd_cli "$right" payinvoice --force --fee_limit "$fee_limit" "$invoice" >"$pay_file" 2>&1 || {
    cat "$pay_file" >&2 || true
    return 1
  }

  local start
  start="$(date +%s)"
  while true; do
    lnd_cli "$left" listchannels |
      jq --arg right_pubkey "$right_pubkey" \
        '[.channels[] | select(.remote_pubkey == $right_pubkey) | {active,local_balance,remote_balance,capacity,unsettled_balance}]' \
        >"$status_file"
    current="$(jq -er '([.[] | select(.active == true) | (.local_balance | tonumber)] | max) // 0' "$status_file")"
    if [ "$current" -ge "$min_sats" ]; then
      return 0
    fi
    if [ $(( "$(date +%s)" - start )) -ge 60 ]; then
      log "$left -> $right did not reach $min_sats sats outbound liquidity; current=$current"
      return 1
    fi
    sleep 2
  done
}

wait_for_rln_node node1
wait_for_rln_node node4
wait_for_arkd
wait_for_ark_lnd_provider
ensure_lnd_bridge_liquidity

rgb_asset_id="${BRIDGE_TEST_RGB_ASSET_ID:-${RGB_MM_ASSET_ID:-}}"
if [ -z "$rgb_asset_id" ]; then
  ensure_colorable_utxos node1 "$BRIDGE_SETUP_OUTPUT_DIR/rgb-create-utxos.json"
  log "issuing RGB asset on node1"
  rgb_issue_file="$BRIDGE_SETUP_OUTPUT_DIR/rgb-issue.json"
  api node1 POST /issueassetnia "$(jq -nc \
    --arg ticker "$BRIDGE_SETUP_RGB_TICKER" \
    --arg name "$BRIDGE_SETUP_RGB_NAME" \
    --arg amount "$BRIDGE_SETUP_RGB_AMOUNT" \
    --argjson precision "$BRIDGE_SETUP_RGB_PRECISION" \
    '{ticker:$ticker,name:$name,amounts:[($amount|tonumber)],precision:$precision}')" |
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

provider_balance_file="$BRIDGE_SETUP_OUTPUT_DIR/ark-provider-balance.json"
ensure_provider_ark_sats \
  "$BRIDGE_SETUP_ARK_PROVIDER_MIN_SATS" \
  "$BRIDGE_SETUP_OUTPUT_DIR/ark-provider-btc-balance.json" \
  "$BRIDGE_SETUP_OUTPUT_DIR/ark-provider-btc-receive.json" \
  "$BRIDGE_SETUP_OUTPUT_DIR/ark-maker-send-btc-to-provider.json"

ensure_provider_ark_asset \
  "$ark_asset_id" \
  "$BRIDGE_SETUP_ARK_PROVIDER_AMOUNT" \
  "$provider_balance_file" \
  "$BRIDGE_SETUP_OUTPUT_DIR/ark-provider-receive.json" \
  "$BRIDGE_SETUP_OUTPUT_DIR/ark-maker-send-to-provider.json"

taker_balance_file="$BRIDGE_SETUP_OUTPUT_DIR/ark-taker-balance.json"
taker_current="$(ark_asset_amount taker "$ark_asset_id" "$taker_balance_file")"
if [ "$taker_current" -ge "$BRIDGE_SETUP_ARK_TAKER_AMOUNT" ]; then
  log "taker wallet already has Ark asset inventory"
else
  taker_topup_amount="$(( BRIDGE_SETUP_ARK_TAKER_AMOUNT - taker_current ))"
  log "funding taker wallet with Ark asset inventory"
  taker_receive_file="$BRIDGE_SETUP_OUTPUT_DIR/ark-taker-receive.json"
  taker_recipient="$(ark_receive_address taker "$taker_receive_file")"
  ark_cli maker send \
    --to "$taker_recipient" \
    --asset-id "$ark_asset_id" \
    --amount "$taker_topup_amount" \
    --password "$ARK_CLI_PASSWORD" |
    save_json "$BRIDGE_SETUP_OUTPUT_DIR/ark-maker-send-to-taker.json"
  ark_cli taker balance | save_json "$taker_balance_file"
fi

if [ -n "${BRIDGE_TEST_ARK_TAKER_PRIVATE_KEY_HEX:-}" ]; then
  ensure_ark_grpc_sats \
    taker \
    "$BRIDGE_TEST_ARK_TAKER_PRIVATE_KEY_HEX" \
    "$BRIDGE_SETUP_ARK_TAKER_MIN_SATS" \
    "$BRIDGE_SETUP_OUTPUT_DIR/ark-taker-grpc-btc-balance.json" \
    "$BRIDGE_SETUP_OUTPUT_DIR/ark-taker-grpc-btc-receive.json" \
    "$BRIDGE_SETUP_OUTPUT_DIR/ark-maker-send-btc-to-taker-grpc.json"

  ensure_ark_grpc_asset \
    taker \
    "$BRIDGE_TEST_ARK_TAKER_PRIVATE_KEY_HEX" \
    "$ark_asset_id" \
    "$BRIDGE_SETUP_ARK_TAKER_AMOUNT" \
    "$BRIDGE_SETUP_OUTPUT_DIR/ark-taker-grpc-balance.json" \
    "$BRIDGE_SETUP_OUTPUT_DIR/ark-taker-grpc-receive.json" \
    "$BRIDGE_SETUP_OUTPUT_DIR/ark-maker-send-to-taker-grpc.json"
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
