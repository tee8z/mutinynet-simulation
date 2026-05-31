#!/usr/bin/env bash

set -euo pipefail

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

export PATH="$SIM_DIR/result/bin:$PATH"

require_cmd curl jq ark "$LNCLI_BINARY"

BRIDGE_TEST_RGB_PAYER_NODE="${BRIDGE_TEST_RGB_PAYER_NODE:-${RGB_MM_ASSET_FUNDER_NODE:-node1}}"
BRIDGE_TEST_RGB_MAKER_NODE="${BRIDGE_TEST_RGB_MAKER_NODE:-${RGB_MM_NODE:-node4}}"
BRIDGE_TEST_RGB_RECEIVER_NODE="${BRIDGE_TEST_RGB_RECEIVER_NODE:-$BRIDGE_TEST_RGB_PAYER_NODE}"
BRIDGE_TEST_RGB_ASSET_ID="${BRIDGE_TEST_RGB_ASSET_ID:-${RGB_MM_ASSET_ID:-}}"
BRIDGE_TEST_RGB_ASSET_AMOUNT="${BRIDGE_TEST_RGB_ASSET_AMOUNT:-10}"
BRIDGE_TEST_LND_RGB_NODE="${BRIDGE_TEST_LND_RGB_NODE:-lnd1}"
BRIDGE_TEST_LND_PROVIDER_NODE="${BRIDGE_TEST_LND_PROVIDER_NODE:-$ARK_LND_PROVIDER_LND_NODE}"
BRIDGE_TEST_PROVIDER_URL="${BRIDGE_TEST_PROVIDER_URL:-$(ark_lnd_provider_url)}"
BRIDGE_TEST_ARK_TAKER_WALLET="${BRIDGE_TEST_ARK_TAKER_WALLET:-taker}"
BRIDGE_TEST_ARK_ASSET_ID="${BRIDGE_TEST_ARK_ASSET_ID:-${ARK_TEST_ASSET_ID:-}}"
BRIDGE_TEST_ARK_ASSET_AMOUNT="${BRIDGE_TEST_ARK_ASSET_AMOUNT:-100}"
BRIDGE_TEST_LN_TO_ARK_SATS="${BRIDGE_TEST_LN_TO_ARK_SATS:-6000}"
BRIDGE_TEST_ARK_TO_RGB_SATS="${BRIDGE_TEST_ARK_TO_RGB_SATS:-1000}"
BRIDGE_TEST_RGB_ASSET_KEYSEND_MSAT="${BRIDGE_TEST_RGB_ASSET_KEYSEND_MSAT:-3000000}"
BRIDGE_TEST_FEE_LIMIT_SAT="${BRIDGE_TEST_FEE_LIMIT_SAT:-10}"
BRIDGE_TEST_WAIT_TIMEOUT_SEC="${BRIDGE_TEST_WAIT_TIMEOUT_SEC:-180}"

usage() {
  cat <<'EOF'
usage: sim-test-lightning-ark-bridge [all|rgb-asset-to-ark-asset|ark-asset-to-rgb-asset]

Modes:
  all                       Run both asset bridge directions.
  rgb-asset-to-ark-asset    Pay Ark asset invoice from the RGB-side Lightning edge.
  ark-asset-to-rgb-asset    Pay RGB-side Lightning invoice from the Ark-side provider edge.

Backward-compatible aliases:
  ln-to-ark
  ark-to-ln
EOF
}

BRIDGE_TEST_MODE="${BRIDGE_TEST_MODE:-all}"
if [ "$#" -gt 0 ]; then
  BRIDGE_TEST_MODE="$1"
  shift
fi
if [ "$#" -gt 0 ]; then
  usage >&2
  exit 2
fi
case "$BRIDGE_TEST_MODE" in
  all|rgb-asset-to-ark-asset|ark-asset-to-rgb-asset|ln-to-ark|ark-to-ln) ;;
  *)
    usage >&2
    exit 2
    ;;
esac
case "$BRIDGE_TEST_MODE" in
  ln-to-ark) BRIDGE_TEST_MODE="rgb-asset-to-ark-asset" ;;
  ark-to-ln) BRIDGE_TEST_MODE="ark-asset-to-rgb-asset" ;;
esac

BRIDGE_TEST_OUTPUT_DIR="${BRIDGE_TEST_OUTPUT_DIR:-$STATE_DIR/tests/lightning-ark-bridge-${BRIDGE_TEST_MODE}-$(date -u +%Y%m%dT%H%M%SZ)}"

mkdir -p "$BRIDGE_TEST_OUTPUT_DIR"

fail() {
  echo "error: $*" >&2
  exit 1
}

log() {
  printf '[bridge-test] %s\n' "$*"
}

save_json() {
  local file="$1"
  jq . >"$file"
}

provider_get() {
  local path="$1"
  provider_request GET "$path"
}

provider_post() {
  local path="$1" body request_file rc
  body="${2:-}"
  if [ -z "$body" ]; then
    body='{}'
  fi
  request_file="$(mktemp "$BRIDGE_TEST_OUTPUT_DIR/provider-request.XXXXXX.json")"
  printf '%s' "$body" >"$request_file"
  set +e
  provider_request POST "$path" "$request_file" file
  rc=$?
  set -e
  rm -f "$request_file"
  return "$rc"
}

provider_post_file() {
  local path="$1" file="$2"
  provider_request POST "$path" "$file" file
}

provider_request() {
  local method="$1" path="$2" body="${3:-}" body_mode="${4:-value}" attempt max_attempts status response_file
  local -a args
  max_attempts="${BRIDGE_TEST_PROVIDER_HTTP_ATTEMPTS:-3}"
  response_file="$(mktemp "$BRIDGE_TEST_OUTPUT_DIR/provider-response.XXXXXX")"

  for attempt in $(seq 1 "$max_attempts"); do
    args=(
      -sS
      -w '%{http_code}'
      -o "$response_file"
      -H 'Content-Type: application/json'
      -X "$method"
    )
    if [ "$method" != GET ]; then
      if [ "$body_mode" = file ]; then
        args+=(--data-binary "@$body")
      else
        args+=(--data-binary "$body")
      fi
    fi

    status="$(curl "${args[@]}" "$BRIDGE_TEST_PROVIDER_URL$path" || true)"
    if [[ "$status" == 2* ]]; then
      cat "$response_file"
      rm -f "$response_file"
      return 0
    fi

    echo "provider $method $path failed attempt $attempt/$max_attempts http=${status:-curl-error}" >&2
    sed 's/^/provider response: /' "$response_file" >&2 || true
    printf '\n' >&2
    if [ "$attempt" -lt "$max_attempts" ]; then
      sleep "$attempt"
    fi
  done

  echo "provider response left at $response_file" >&2
  return 1
}

rln_pubkey() {
  api "$1" GET /nodeinfo | jq -r .pubkey
}

lnd_pubkey() {
  lnd_cli "$1" getinfo | jq -r .identity_pubkey
}

ark_receive_address() {
  local wallet="$1" response_file="$2"
  ark_cli "$wallet" receive | tee "$response_file" | jq -er '.offchain_address // .address // .addr'
}

assert_provider_healthy() {
  local health_file="$BRIDGE_TEST_OUTPUT_DIR/provider-health.json"
  provider_get /health | save_json "$health_file"
  jq -e '.ok == true and .database == true' "$health_file" >/dev/null ||
    fail "provider is not healthy; see $health_file"
}

assert_ark_wallet_asset_ready() {
  local wallet="$1" label="$2" balance_file="$3"
  ark_cli "$wallet" balance | save_json "$balance_file" ||
    fail "$label Ark wallet is not ready; see $balance_file"

  jq -e \
    --arg asset_id "$BRIDGE_TEST_ARK_ASSET_ID" \
    --arg amount "$BRIDGE_TEST_ARK_ASSET_AMOUNT" \
    '(.asset_balances[$asset_id] // 0 | tonumber) >= ($amount | tonumber)' \
    "$balance_file" >/dev/null ||
    fail "$label Ark wallet lacks asset balance; see $balance_file"
}

assert_provider_ark_ready() {
  assert_ark_wallet_asset_ready \
    "$ARK_LND_PROVIDER_ARK_WALLET" \
    "provider maker" \
    "$BRIDGE_TEST_OUTPUT_DIR/provider-maker-balance.json"
}

assert_public_lnd_bridge_channel() {
  local left="$1" right="$2" right_pubkey channels_file
  right_pubkey="$(lnd_pubkey "$right")"
  channels_file="$BRIDGE_TEST_OUTPUT_DIR/${left}-channels.json"
  lnd_cli "$left" listchannels | save_json "$channels_file"
  jq -e --arg peer "$right_pubkey" \
    '[.channels[]? | select(.remote_pubkey == $peer and .active == true and .private == false)] | length > 0' \
    "$channels_file" >/dev/null ||
    fail "$left does not have an active public channel to $right; see $channels_file"
}

assert_single_lnd_rgb_channel() {
  local lnd_node="$1" rgb_node="$2" rgb_pubkey channels_file active_count
  rgb_pubkey="$(rln_pubkey "$rgb_node")"
  channels_file="$BRIDGE_TEST_OUTPUT_DIR/${lnd_node}-rgb-channels.json"
  lnd_cli "$lnd_node" listchannels | save_json "$channels_file"
  active_count="$(jq --arg peer "$rgb_pubkey" \
    '[.channels[]? | select(.remote_pubkey == $peer and .active == true)] | length' \
    "$channels_file")"
  if [ "$active_count" -eq 0 ]; then
    fail "$lnd_node does not have an active channel to $rgb_node; see $channels_file"
  fi
  if [ "$active_count" -gt 1 ]; then
    fail "$lnd_node has multiple active channels to $rgb_node; close stale channels before this test"
  fi
}

assert_rgb_lnd_channel() {
  local rgb_node="$1" lnd_node="$2" lnd_pubkey channels_file
  lnd_pubkey="$(lnd_pubkey "$lnd_node")"
  channels_file="$BRIDGE_TEST_OUTPUT_DIR/${rgb_node}-channels.json"
  api "$rgb_node" GET /listchannels | save_json "$channels_file"
  jq -e --arg peer "$lnd_pubkey" \
    '[.channels[]? | select(.peer_pubkey == $peer and .is_usable == true and ((.asset_id // "") == ""))] | length > 0' \
    "$channels_file" >/dev/null ||
    fail "$rgb_node does not have a usable BTC Lightning channel to $lnd_node; see $channels_file"
}

assert_rgb_asset_channel() {
  local payer_node="$1" maker_node="$2" asset_id="$3" maker_pubkey channels_file
  maker_pubkey="$(rln_pubkey "$maker_node")"
  channels_file="$BRIDGE_TEST_OUTPUT_DIR/${payer_node}-${maker_node}-rgb-asset-channels.json"
  api "$payer_node" GET /listchannels | save_json "$channels_file"
  jq -e --arg peer "$maker_pubkey" --arg asset_id "$asset_id" \
    '[.channels[]? | select(.peer_pubkey == $peer and .is_usable == true and .asset_id == $asset_id)] | length > 0' \
    "$channels_file" >/dev/null ||
    fail "$payer_node does not have a usable RGB asset channel to $maker_node for $asset_id; see $channels_file"
}

assert_bridge_edges_ready() {
  wait_for_rln_node "$BRIDGE_TEST_RGB_PAYER_NODE"
  wait_for_rln_node "$BRIDGE_TEST_RGB_MAKER_NODE"
  wait_for_lnd_unlocked "$BRIDGE_TEST_LND_RGB_NODE"
  wait_for_lnd_unlocked "$BRIDGE_TEST_LND_PROVIDER_NODE"
  wait_for_ark_lnd_provider

  assert_provider_healthy
  assert_public_lnd_bridge_channel "$BRIDGE_TEST_LND_RGB_NODE" "$BRIDGE_TEST_LND_PROVIDER_NODE"
  assert_public_lnd_bridge_channel "$BRIDGE_TEST_LND_PROVIDER_NODE" "$BRIDGE_TEST_LND_RGB_NODE"
  assert_single_lnd_rgb_channel "$BRIDGE_TEST_LND_RGB_NODE" "$BRIDGE_TEST_RGB_MAKER_NODE"
  assert_rgb_lnd_channel "$BRIDGE_TEST_RGB_MAKER_NODE" "$BRIDGE_TEST_LND_RGB_NODE"
}

assert_rgb_to_ark_ready() {
  [ -n "$BRIDGE_TEST_RGB_ASSET_ID" ] ||
    fail "set BRIDGE_TEST_RGB_ASSET_ID or RGB_MM_ASSET_ID to the RGB asset used for the payer -> maker channel"
  [ -n "$BRIDGE_TEST_ARK_ASSET_ID" ] ||
    fail "set BRIDGE_TEST_ARK_ASSET_ID to an Ark asset held by the provider maker wallet"
  assert_bridge_edges_ready
  assert_rgb_asset_channel "$BRIDGE_TEST_RGB_PAYER_NODE" "$BRIDGE_TEST_RGB_MAKER_NODE" "$BRIDGE_TEST_RGB_ASSET_ID"
  assert_provider_ark_ready
}

assert_ark_to_rgb_ready() {
  [ -n "$BRIDGE_TEST_RGB_ASSET_ID" ] ||
    fail "set BRIDGE_TEST_RGB_ASSET_ID or RGB_MM_ASSET_ID to the RGB asset used for the maker -> receiver channel"
  [ -n "$BRIDGE_TEST_ARK_ASSET_ID" ] ||
    fail "set BRIDGE_TEST_ARK_ASSET_ID to an Ark asset held by the Ark payer wallet"
  assert_bridge_edges_ready
  assert_rgb_asset_channel "$BRIDGE_TEST_RGB_MAKER_NODE" "$BRIDGE_TEST_RGB_RECEIVER_NODE" "$BRIDGE_TEST_RGB_ASSET_ID"
  assert_ark_wallet_asset_ready \
    "$BRIDGE_TEST_ARK_TAKER_WALLET" \
    "Ark payer/taker" \
    "$BRIDGE_TEST_OUTPUT_DIR/ark-payer-balance.json"
}

wait_for_lnd_invoice_state() {
  local lnd_node="$1" payment_hash="$2" desired="$3" label="$4" start state invoice_file
  invoice_file="$BRIDGE_TEST_OUTPUT_DIR/${label}-lnd-invoice.json"
  start="$(date +%s)"
  while true; do
    lnd_cli "$lnd_node" lookupinvoice "$payment_hash" | save_json "$invoice_file" || true
    state="$(jq -r '.state // empty' "$invoice_file" 2>/dev/null || true)"
    if [ "$state" = "$desired" ]; then
      return 0
    fi
    if [ $(( "$(date +%s)" - start )) -ge "$BRIDGE_TEST_WAIT_TIMEOUT_SEC" ]; then
      fail "$label invoice did not reach $desired, last state=${state:-unknown}; see $invoice_file"
    fi
    sleep 2
  done
}

wait_for_lnd_invoice_state_or_rgb_payment_failure() {
  local lnd_node="$1" payment_hash="$2" desired="$3" label="$4" rgb_node="$5"
  local start state status invoice_file payment_file response
  invoice_file="$BRIDGE_TEST_OUTPUT_DIR/${label}-lnd-invoice.json"
  payment_file="$BRIDGE_TEST_OUTPUT_DIR/${label}-rgb-payment.json"
  start="$(date +%s)"
  while true; do
    lnd_cli "$lnd_node" lookupinvoice "$payment_hash" | save_json "$invoice_file" || true
    state="$(jq -r '.state // empty' "$invoice_file" 2>/dev/null || true)"
    if [ "$state" = "$desired" ]; then
      return 0
    fi

    if response="$(api "$rgb_node" POST /getpayment "$(jq -nc --arg payment_hash "$payment_hash" '{payment_hash:$payment_hash}')" 2>/dev/null)"; then
      printf '%s' "$response" | save_json "$payment_file" || true
      status="$(jq -r '.payment.status // empty' "$payment_file" 2>/dev/null || true)"
      if [ "$status" = "Failed" ]; then
        fail "$label RGB payment failed before invoice reached $desired; see $payment_file and $invoice_file"
      fi
    fi

    if [ $(( "$(date +%s)" - start )) -ge "$BRIDGE_TEST_WAIT_TIMEOUT_SEC" ]; then
      fail "$label invoice did not reach $desired, last state=${state:-unknown}; see $invoice_file"
    fi
    sleep 2
  done
}

wait_for_rgb_payment_status() {
  local rgb_node="$1" payment_hash="$2" desired="$3" label="$4" start status payment_file response
  payment_file="$BRIDGE_TEST_OUTPUT_DIR/${label}-rgb-payment.json"
  start="$(date +%s)"
  while true; do
    if response="$(api "$rgb_node" POST /getpayment "$(jq -nc --arg payment_hash "$payment_hash" '{payment_hash:$payment_hash}')" 2>/dev/null)"; then
      printf '%s' "$response" | save_json "$payment_file" || true
    fi
    status="$(jq -r '.payment.status // empty' "$payment_file" 2>/dev/null || true)"
    if [ "$status" = "$desired" ]; then
      return 0
    fi
    if [ "$status" = "Failed" ] && [ "$desired" != "Failed" ]; then
      fail "$label payment failed; see $payment_file"
    fi
    if [ $(( "$(date +%s)" - start )) -ge "$BRIDGE_TEST_WAIT_TIMEOUT_SEC" ]; then
      fail "$label payment did not reach $desired, last status=${status:-unknown}; see $payment_file"
    fi
    sleep 2
  done
}

wait_for_rgb_asset_invoice_status() {
  local rgb_node="$1" payment_hash="$2" desired="$3" label="$4" start status invoice_file
  invoice_file="$BRIDGE_TEST_OUTPUT_DIR/${label}-rgb-asset-invoice.json"
  start="$(date +%s)"
  while true; do
    api "$rgb_node" POST /getassetinvoice "$(jq -nc --arg payment_hash "$payment_hash" '{payment_hash:$payment_hash}')" |
      save_json "$invoice_file" || true
    status="$(jq -r '.status // empty' "$invoice_file" 2>/dev/null || true)"
    if [ "$status" = "$desired" ]; then
      return 0
    fi
    if [ $(( "$(date +%s)" - start )) -ge "$BRIDGE_TEST_WAIT_TIMEOUT_SEC" ]; then
      fail "$label asset invoice did not reach $desired, last status=${status:-unknown}; see $invoice_file"
    fi
    sleep 2
  done
}

run_rgb_asset_to_ark_asset() {
  local receive_file recipient request_file swap_file swap_id bolt11 payment_hash preimage
  local prepare_file taker_file send_file ark_send_file settle_file taker_balance_file
  local rgb_maker_pubkey swapstring

  log "rgb-asset-to-ark-asset: creating Ark recipient"
  receive_file="$BRIDGE_TEST_OUTPUT_DIR/rgb-asset-to-ark-asset-ark-receive.json"
  recipient="$(ark_receive_address "$BRIDGE_TEST_ARK_TAKER_WALLET" "$receive_file")"

  log "rgb-asset-to-ark-asset: creating provider hold invoice"
  request_file="$BRIDGE_TEST_OUTPUT_DIR/rgb-asset-to-ark-asset-request.json"
  jq -nc \
    --argjson amount_sat "$BRIDGE_TEST_LN_TO_ARK_SATS" \
    --arg asset_id "$BRIDGE_TEST_ARK_ASSET_ID" \
    --arg asset_amount "$BRIDGE_TEST_ARK_ASSET_AMOUNT" \
    --arg ark_recipient "$recipient" \
    '{
      amount_sat:$amount_sat,
      memo:"mutinynet-simulation rgb-asset-to-ark-asset bridge test",
      asset_id:$asset_id,
      asset_amount:$asset_amount,
      ark_recipient:$ark_recipient,
      metadata:{test:"lightning-ark-bridge", leg:"rgb-asset-to-ark-asset", provider_leg:"ln-to-ark"}
    }' >"$request_file"

  swap_file="$BRIDGE_TEST_OUTPUT_DIR/rgb-asset-to-ark-asset-swap-created.json"
  provider_post_file /v1/swaps/ln-to-ark "$request_file" | save_json "$swap_file"
  swap_id="$(jq -er .id "$swap_file")"
  bolt11="$(jq -er .bolt11 "$swap_file")"
  payment_hash="$(jq -er .preimage_hash "$swap_file")"
  preimage="$(jq -er .preimage "$swap_file")"

  log "rgb-asset-to-ark-asset: preparing RGB asset swap payment from $BRIDGE_TEST_RGB_PAYER_NODE through $BRIDGE_TEST_RGB_MAKER_NODE"
  prepare_file="$BRIDGE_TEST_OUTPUT_DIR/rgb-asset-to-ark-asset-rgb-prepare.json"
  api "$BRIDGE_TEST_RGB_PAYER_NODE" POST /prepareassetpayment "$(jq -nc \
    --arg invoice "$bolt11" \
    --arg asset_id "$BRIDGE_TEST_RGB_ASSET_ID" \
    --argjson asset_amount "$BRIDGE_TEST_RGB_ASSET_AMOUNT" \
    '{invoice:$invoice,amt_msat:null,asset_id:$asset_id,asset_amount:$asset_amount}')" |
    save_json "$prepare_file"
  swapstring="$(jq -er .swapstring "$prepare_file")"

  log "rgb-asset-to-ark-asset: registering swap on $BRIDGE_TEST_RGB_MAKER_NODE"
  taker_file="$BRIDGE_TEST_OUTPUT_DIR/rgb-asset-to-ark-asset-rgb-maker-taker.json"
  api "$BRIDGE_TEST_RGB_MAKER_NODE" POST /taker "$(jq -nc --arg swapstring "$swapstring" '{swapstring:$swapstring}')" |
    save_json "$taker_file"

  log "rgb-asset-to-ark-asset: paying hold invoice from $BRIDGE_TEST_RGB_PAYER_NODE with RGB asset"
  send_file="$BRIDGE_TEST_OUTPUT_DIR/rgb-asset-to-ark-asset-rgb-sendpayment.json"
  rgb_maker_pubkey="$(rln_pubkey "$BRIDGE_TEST_RGB_MAKER_NODE")"
  api "$BRIDGE_TEST_RGB_PAYER_NODE" POST /sendassetpayment "$(jq -nc \
    --arg invoice "$bolt11" \
    --arg asset_id "$BRIDGE_TEST_RGB_ASSET_ID" \
    --argjson asset_amount "$BRIDGE_TEST_RGB_ASSET_AMOUNT" \
    --arg swap_provider_pubkey "$rgb_maker_pubkey" \
    '{invoice:$invoice,amt_msat:null,asset_id:$asset_id,asset_amount:$asset_amount,swap_provider_pubkey:$swap_provider_pubkey}')" |
    save_json "$send_file"

  wait_for_lnd_invoice_state_or_rgb_payment_failure \
    "$BRIDGE_TEST_LND_PROVIDER_NODE" \
    "$payment_hash" \
    ACCEPTED \
    rgb-asset-to-ark-asset \
    "$BRIDGE_TEST_RGB_PAYER_NODE"

  log "rgb-asset-to-ark-asset: sending Ark asset from provider maker wallet"
  ark_send_file="$BRIDGE_TEST_OUTPUT_DIR/rgb-asset-to-ark-asset-ark-send.json"
  provider_post "/v1/swaps/$swap_id/ark-send" '{}' | save_json "$ark_send_file"

  log "rgb-asset-to-ark-asset: settling provider hold invoice"
  settle_file="$BRIDGE_TEST_OUTPUT_DIR/rgb-asset-to-ark-asset-settle.json"
  provider_post "/v1/swaps/$swap_id/settle-ln" "$(jq -nc --arg preimage "$preimage" '{preimage:$preimage}')" |
    save_json "$settle_file"

  wait_for_rgb_payment_status "$BRIDGE_TEST_RGB_PAYER_NODE" "$payment_hash" Succeeded rgb-asset-to-ark-asset
  wait_for_lnd_invoice_state "$BRIDGE_TEST_LND_PROVIDER_NODE" "$payment_hash" SETTLED rgb-asset-to-ark-asset-settled

  taker_balance_file="$BRIDGE_TEST_OUTPUT_DIR/rgb-asset-to-ark-asset-taker-balance.json"
  ark_cli "$BRIDGE_TEST_ARK_TAKER_WALLET" balance | save_json "$taker_balance_file" || true

  log "rgb-asset-to-ark-asset: swap $swap_id succeeded"
}

run_ark_asset_to_rgb_asset() {
  local invoice_file bolt11 payment_hash request_file swap_file swap_id status
  local rgb_receiver_pubkey provider_receive_file provider_recipient ark_send_file
  local pay_file pay_pid asset_send_file asset_payment_hash claim_file

  log "ark-asset-to-rgb-asset: creating RGB mapped BTC invoice on $BRIDGE_TEST_RGB_MAKER_NODE"
  invoice_file="$BRIDGE_TEST_OUTPUT_DIR/ark-asset-to-rgb-asset-rgb-invoice.json"
  rgb_receiver_pubkey="$(rln_pubkey "$BRIDGE_TEST_RGB_RECEIVER_NODE")"
  api "$BRIDGE_TEST_RGB_MAKER_NODE" POST /assetinvoice "$(jq -nc \
    --argjson amt_msat "$((BRIDGE_TEST_ARK_TO_RGB_SATS * 1000))" \
    --arg asset_id "$BRIDGE_TEST_RGB_ASSET_ID" \
    --argjson asset_amount "$BRIDGE_TEST_RGB_ASSET_AMOUNT" \
    --arg recipient_pubkey "$rgb_receiver_pubkey" \
    '{amt_msat:$amt_msat,expiry_sec:900,asset_id:$asset_id,asset_amount:$asset_amount,recipient_pubkey:$recipient_pubkey}')" |
    save_json "$invoice_file"
  bolt11="$(jq -er .invoice "$invoice_file")"
  payment_hash="$(jq -er .payment_hash "$invoice_file")"

  log "ark-asset-to-rgb-asset: moving Ark asset from payer to provider"
  provider_receive_file="$BRIDGE_TEST_OUTPUT_DIR/ark-asset-to-rgb-asset-provider-receive.json"
  provider_recipient="$(ark_receive_address "$ARK_LND_PROVIDER_ARK_WALLET" "$provider_receive_file")"
  ark_send_file="$BRIDGE_TEST_OUTPUT_DIR/ark-asset-to-rgb-asset-ark-user-send.json"
  ark_cli "$BRIDGE_TEST_ARK_TAKER_WALLET" send \
    --to "$provider_recipient" \
    --asset-id "$BRIDGE_TEST_ARK_ASSET_ID" \
    --amount "$BRIDGE_TEST_ARK_ASSET_AMOUNT" \
    --password "$ARK_CLI_PASSWORD" |
    save_json "$ark_send_file"

  log "ark-asset-to-rgb-asset: registering RGB invoice with provider"
  request_file="$BRIDGE_TEST_OUTPUT_DIR/ark-asset-to-rgb-asset-request.json"
  jq -nc \
    --arg bolt11 "$bolt11" \
    --argjson amount_sat "$BRIDGE_TEST_ARK_TO_RGB_SATS" \
    --arg asset_id "$BRIDGE_TEST_ARK_ASSET_ID" \
    --arg asset_amount "$BRIDGE_TEST_ARK_ASSET_AMOUNT" \
    --argjson fee_limit_sat "$BRIDGE_TEST_FEE_LIMIT_SAT" \
    '{
      bolt11:$bolt11,
      amount_sat:$amount_sat,
      asset_id:$asset_id,
      asset_amount:$asset_amount,
      execute:false,
      fee_limit_sat:$fee_limit_sat,
      metadata:{test:"lightning-ark-bridge", leg:"ark-asset-to-rgb-asset", provider_leg:"ark-to-ln", asset_invoice:true}
    }' >"$request_file"

  swap_file="$BRIDGE_TEST_OUTPUT_DIR/ark-asset-to-rgb-asset-swap-created.json"
  provider_post_file /v1/swaps/ark-to-ln "$request_file" | save_json "$swap_file"
  swap_id="$(jq -er .id "$swap_file")"

  log "ark-asset-to-rgb-asset: starting provider Lightning payment in background"
  pay_file="$BRIDGE_TEST_OUTPUT_DIR/ark-asset-to-rgb-asset-provider-pay.json"
  (
    provider_post "/v1/swaps/$swap_id/pay-ln" "$(jq -nc --argjson fee_limit_sat "$BRIDGE_TEST_FEE_LIMIT_SAT" '{fee_limit_sat:$fee_limit_sat}')" |
      save_json "$pay_file"
  ) &
  pay_pid="$!"

  wait_for_rgb_asset_invoice_status "$BRIDGE_TEST_RGB_MAKER_NODE" "$payment_hash" ln_accepted ark-asset-to-rgb-asset

  log "ark-asset-to-rgb-asset: sending RGB asset from $BRIDGE_TEST_RGB_MAKER_NODE to $BRIDGE_TEST_RGB_RECEIVER_NODE"
  asset_send_file="$BRIDGE_TEST_OUTPUT_DIR/ark-asset-to-rgb-asset-rgb-keysend.json"
  api "$BRIDGE_TEST_RGB_MAKER_NODE" POST /keysend "$(jq -nc \
    --arg dest_pubkey "$rgb_receiver_pubkey" \
    --argjson amt_msat "$BRIDGE_TEST_RGB_ASSET_KEYSEND_MSAT" \
    --arg asset_id "$BRIDGE_TEST_RGB_ASSET_ID" \
    --argjson asset_amount "$BRIDGE_TEST_RGB_ASSET_AMOUNT" \
    '{dest_pubkey:$dest_pubkey,amt_msat:$amt_msat,asset_id:$asset_id,asset_amount:$asset_amount}')" |
    save_json "$asset_send_file"
  asset_payment_hash="$(jq -er .payment_hash "$asset_send_file")"
  wait_for_rgb_payment_status "$BRIDGE_TEST_RGB_RECEIVER_NODE" "$asset_payment_hash" Succeeded ark-asset-to-rgb-asset-rgb-delivery

  log "ark-asset-to-rgb-asset: claiming RGB mapped BTC invoice"
  claim_file="$BRIDGE_TEST_OUTPUT_DIR/ark-asset-to-rgb-asset-rgb-claim.json"
  api "$BRIDGE_TEST_RGB_MAKER_NODE" POST /claimassetinvoice "$(jq -nc --arg payment_hash "$payment_hash" '{payment_hash:$payment_hash}')" |
    save_json "$claim_file"

  if ! wait "$pay_pid"; then
    fail "ark-asset-to-rgb-asset provider pay failed; see $pay_file"
  fi
  status="$(jq -er .status "$pay_file")"
  [ "$status" = "ln_paid" ] ||
    fail "ark-asset-to-rgb-asset provider swap $swap_id ended with status $status; see $pay_file"

  wait_for_rgb_asset_invoice_status "$BRIDGE_TEST_RGB_MAKER_NODE" "$payment_hash" ln_claimed ark-asset-to-rgb-asset-claimed

  log "ark-asset-to-rgb-asset: swap $swap_id succeeded"
}

cat >"$BRIDGE_TEST_OUTPUT_DIR/config.json" <<EOF
{
  "rgb_payer_node": "$BRIDGE_TEST_RGB_PAYER_NODE",
  "rgb_maker_node": "$BRIDGE_TEST_RGB_MAKER_NODE",
  "rgb_receiver_node": "$BRIDGE_TEST_RGB_RECEIVER_NODE",
  "rgb_asset_id": "$BRIDGE_TEST_RGB_ASSET_ID",
  "rgb_asset_amount": "$BRIDGE_TEST_RGB_ASSET_AMOUNT",
  "mode": "$BRIDGE_TEST_MODE",
  "lnd_rgb_node": "$BRIDGE_TEST_LND_RGB_NODE",
  "lnd_provider_node": "$BRIDGE_TEST_LND_PROVIDER_NODE",
  "provider_url": "$BRIDGE_TEST_PROVIDER_URL",
  "ark_taker_wallet": "$BRIDGE_TEST_ARK_TAKER_WALLET",
  "ark_asset_id": "$BRIDGE_TEST_ARK_ASSET_ID",
  "ark_asset_amount": "$BRIDGE_TEST_ARK_ASSET_AMOUNT",
  "ln_to_ark_sats": "$BRIDGE_TEST_LN_TO_ARK_SATS",
  "ark_to_rgb_sats": "$BRIDGE_TEST_ARK_TO_RGB_SATS",
  "rgb_asset_keysend_msat": "$BRIDGE_TEST_RGB_ASSET_KEYSEND_MSAT",
  "fee_limit_sat": "$BRIDGE_TEST_FEE_LIMIT_SAT"
}
EOF

log "artifacts: $BRIDGE_TEST_OUTPUT_DIR"
case "$BRIDGE_TEST_MODE" in
  all)
    assert_rgb_to_ark_ready
    run_rgb_asset_to_ark_asset
    assert_ark_to_rgb_ready
    run_ark_asset_to_rgb_asset
    ;;
  rgb-asset-to-ark-asset)
    assert_rgb_to_ark_ready
    run_rgb_asset_to_ark_asset
    ;;
  ark-asset-to-rgb-asset)
    assert_ark_to_rgb_ready
    run_ark_asset_to_rgb_asset
    ;;
esac

log "bridge test $BRIDGE_TEST_MODE passed"
