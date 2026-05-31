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
BRIDGE_TEST_ARK_TAKER_PRIVATE_KEY_HEX="${BRIDGE_TEST_ARK_TAKER_PRIVATE_KEY_HEX:-}"
BRIDGE_TEST_ARK_PROVIDER_PRIVATE_KEY_HEX="${BRIDGE_TEST_ARK_PROVIDER_PRIVATE_KEY_HEX:-$ARK_LND_PROVIDER_ARK_PRIVATE_KEY_HEX}"
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
  all                                  Run both VHTLC-bound asset bridge directions.
  rgb-asset-to-ark-asset               RGB/LN hold invoice settles from observed Ark VHTLC claim preimage.
  ark-asset-to-rgb-asset               Provider claims Ark VHTLC from Lightning/RGB preimage.

Aliases:
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

if [ -z "${BRIDGE_TEST_OUTPUT_DIR:-}" ]; then
  BRIDGE_TEST_OUTPUT_DIR="$STATE_DIR/tests/lightning-ark-bridge-${BRIDGE_TEST_MODE}-$(date -u +%Y%m%dT%H%M%SZ)"
fi

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

ark_wallet_dir() {
  local wallet="$1"
  printf '%s/%s' "$ARK_CLI_DIR" "$wallet"
}

random_preimage_hex() {
  python3 - <<'PY'
import secrets
print(secrets.token_hex(32))
PY
}

sha256_hex32() {
  local value="$1"
  python3 - "$value" <<'PY'
import hashlib
import re
import sys

value = sys.argv[1].strip()
if not re.fullmatch(r"[0-9a-fA-F]{64}", value):
    raise SystemExit("expected 32-byte hex")
print(hashlib.sha256(bytes.fromhex(value)).hexdigest())
PY
}

extract_hex32_secret() {
  local input key
  input="$(cat)"
  key="$(printf '%s' "$input" | jq -r '.private_key // .privateKey // .privkey // .hex // .raw // empty' 2>/dev/null | head -n 1 || true)"
  if [[ "$key" =~ ^[0-9a-fA-F]{64}$ ]]; then
    printf '%s\n' "$key"
    return 0
  fi
  printf '%s\n' "$input" | grep -Eo '[0-9a-fA-F]{64}' | head -n 1
}

ark_cli_private_key_hex() {
  local wallet="$1" output key
  output="$(ark_cli "$wallet" dump-privkey --password "$ARK_CLI_PASSWORD" 2>&1)" || {
    printf '%s\n' "$output" >&2
    return 1
  }
  key="$(printf '%s' "$output" | extract_hex32_secret)"
  if ! [[ "$key" =~ ^[0-9a-fA-F]{64}$ ]]; then
    echo "ark $wallet dump-privkey did not return a 32-byte hex private key" >&2
    return 1
  fi
  printf '%s\n' "$key"
}

ensure_contract_private_keys() {
  if [ -z "$BRIDGE_TEST_ARK_PROVIDER_PRIVATE_KEY_HEX" ]; then
    BRIDGE_TEST_ARK_PROVIDER_PRIVATE_KEY_HEX="$(ark_cli_private_key_hex "$ARK_LND_PROVIDER_ARK_WALLET")"
    export BRIDGE_TEST_ARK_PROVIDER_PRIVATE_KEY_HEX
  fi
  if [ -z "$BRIDGE_TEST_ARK_TAKER_PRIVATE_KEY_HEX" ]; then
    BRIDGE_TEST_ARK_TAKER_PRIVATE_KEY_HEX="$(ark_cli_private_key_hex "$BRIDGE_TEST_ARK_TAKER_WALLET")"
    export BRIDGE_TEST_ARK_TAKER_PRIVATE_KEY_HEX
  fi
}

require_contract_commands() {
  require_cmd python3
  ensure_contract_private_keys
  [ -n "$BRIDGE_TEST_ARK_PROVIDER_PRIVATE_KEY_HEX" ] ||
    fail "contract swaps require BRIDGE_TEST_ARK_PROVIDER_PRIVATE_KEY_HEX"
  [ -n "$BRIDGE_TEST_ARK_TAKER_PRIVATE_KEY_HEX" ] ||
    fail "contract swaps require BRIDGE_TEST_ARK_TAKER_PRIVATE_KEY_HEX"
}

ark_wallet_private_key_hex() {
  local wallet="$1"
  case "$wallet" in
    "$ARK_LND_PROVIDER_ARK_WALLET"|maker|provider)
      printf '%s\n' "$BRIDGE_TEST_ARK_PROVIDER_PRIVATE_KEY_HEX"
      ;;
    "$BRIDGE_TEST_ARK_TAKER_WALLET"|taker)
      printf '%s\n' "$BRIDGE_TEST_ARK_TAKER_PRIVATE_KEY_HEX"
      ;;
    *)
      fail "no private key configured for Ark wallet '$wallet'"
      ;;
  esac
}

ark_contract_pubkey_for_wallet() {
  local wallet="$1" response_file="$2" request_file
  request_file="$(mktemp "$BRIDGE_TEST_OUTPUT_DIR/ark-contract-pubkey-request.XXXXXX.json")"
  jq -nc \
    --arg wallet_private_key_hex "$(ark_wallet_private_key_hex "$wallet")" \
    '{wallet_private_key_hex:$wallet_private_key_hex}' >"$request_file"
  provider_post_file /v1/ark/contract/pubkey "$request_file" | save_json "$response_file"
  rm -f "$request_file"
}

contract_field() {
  local file="$1" field="$2"
  jq -er --arg field "$field" \
    '.[$field] // .stdout[$field] // .ark_contract_result[$field] // .ark_contract_result.stdout[$field] // empty' \
    "$file"
}

extract_preimage_from_provider_pay() {
  local file="$1"
  jq -er '
    .preimage //
    .ln_result.stdout.payment_preimage //
    .ln_result.stdout.payment_preimage_hex //
    (try ((.ln_result.stdout.raw? // "") | capture("preimage: (?<preimage>[0-9a-fA-F]{64})").preimage) catch null) //
    empty
  ' "$file" | tr '[:upper:]' '[:lower:]'
}

json_bool() {
  local filter="$1" file="$2"
  if jq -e "$filter" "$file" >/dev/null; then
    printf 'true'
  else
    printf 'false'
  fi
}

write_combined_proof_summary() {
  local summary_file="$BRIDGE_TEST_OUTPUT_DIR/proof-summary.json"
  local -a leg_summaries=()
  while IFS= read -r file; do
    leg_summaries+=("$file")
  done < <(find "$BRIDGE_TEST_OUTPUT_DIR" -maxdepth 1 -name '*-proof-summary.json' | sort)
  if [ "${#leg_summaries[@]}" -eq 0 ]; then
    return 0
  fi
  jq -s \
    --arg mode "$BRIDGE_TEST_MODE" \
    --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{mode:$mode,generated_at:$generated_at,legs:.}' \
    "${leg_summaries[@]}" >"$summary_file"
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

ark_grpc_wallet_body() {
  local private_key_hex="$1"
  jq -nc --arg wallet_private_key_hex "$private_key_hex" \
    '{wallet_private_key_hex:$wallet_private_key_hex}'
}

assert_ark_grpc_wallet_asset_ready() {
  local private_key_hex="$1" label="$2" balance_file="$3"
  provider_post /v1/ark/balance "$(ark_grpc_wallet_body "$private_key_hex")" | save_json "$balance_file" ||
    fail "$label Ark gRPC wallet is not ready; see $balance_file"

  jq -e \
    --arg asset_id "$BRIDGE_TEST_ARK_ASSET_ID" \
    --arg amount "$BRIDGE_TEST_ARK_ASSET_AMOUNT" \
    '((.stdout.assets // []) | map(select(.asset_id == $asset_id) | (.amount | tonumber)) | add // 0) >= ($amount | tonumber)' \
    "$balance_file" >/dev/null ||
    fail "$label Ark gRPC wallet lacks asset balance; run setup-assets and see $balance_file"
}

assert_provider_ark_ready() {
  provider_post /v1/ark/balance '{}' | save_json "$BRIDGE_TEST_OUTPUT_DIR/provider-maker-balance.json" ||
    fail "provider Ark gRPC wallet is not ready; see $BRIDGE_TEST_OUTPUT_DIR/provider-maker-balance.json"

  jq -e \
    --arg asset_id "$BRIDGE_TEST_ARK_ASSET_ID" \
    --arg amount "$BRIDGE_TEST_ARK_ASSET_AMOUNT" \
    '((.stdout.assets // []) | map(select(.asset_id == $asset_id) | (.amount | tonumber)) | add // 0) >= ($amount | tonumber)' \
    "$BRIDGE_TEST_OUTPUT_DIR/provider-maker-balance.json" >/dev/null ||
    fail "provider Ark gRPC wallet lacks asset balance; run setup-assets and see $BRIDGE_TEST_OUTPUT_DIR/provider-maker-balance.json"
}

mode_uses_contract_ark_wallet() {
  case "$BRIDGE_TEST_MODE" in
    all|ark-asset-to-rgb-asset) return 0 ;;
    *) return 1 ;;
  esac
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
  if mode_uses_contract_ark_wallet; then
    require_contract_commands
    assert_ark_grpc_wallet_asset_ready \
      "$BRIDGE_TEST_ARK_TAKER_PRIVATE_KEY_HEX" \
      "Ark payer/taker" \
      "$BRIDGE_TEST_OUTPUT_DIR/ark-payer-balance.json"
  else
    assert_ark_wallet_asset_ready \
      "$BRIDGE_TEST_ARK_TAKER_WALLET" \
      "Ark payer/taker" \
      "$BRIDGE_TEST_OUTPUT_DIR/ark-payer-balance.json"
  fi
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

run_contract_rgb_asset_to_ark_asset() {
  local receive_file recipient pubkey_file ark_claim_pubkey request_file swap_file swap_id bolt11
  local preimage payment_hash now ark_refund_time ln_expiry prepare_file taker_file send_file rgb_maker_pubkey
  local fund_file outpoint claim_request_file claim_file claim_txid observe_file taker_balance_file
  local rgb_payment_file settled_invoice_file
  local contract_funded contract_claimed preimage_verified ln_or_rgb_settled no_preimage_before_claim

  require_contract_commands

  log "rgb-asset-to-ark-asset: creating Ark claim destination and claim key"
  receive_file="$BRIDGE_TEST_OUTPUT_DIR/rgb-asset-to-ark-asset-ark-receive.json"
  recipient="$(ark_receive_address "$BRIDGE_TEST_ARK_TAKER_WALLET" "$receive_file")"
  pubkey_file="$BRIDGE_TEST_OUTPUT_DIR/rgb-asset-to-ark-asset-ark-claim-pubkey.json"
  ark_contract_pubkey_for_wallet "$BRIDGE_TEST_ARK_TAKER_WALLET" "$pubkey_file"
  ark_claim_pubkey="$(contract_field "$pubkey_file" ark_claim_pubkey)"

  preimage="$(random_preimage_hex)"
  payment_hash="$(sha256_hex32 "$preimage")"
  now="$(date +%s)"
  ark_refund_time="$((now + ${BRIDGE_TEST_LN_TO_ARK_REFUND_SEC:-600}))"
  ln_expiry="$((now + ${BRIDGE_TEST_LN_TO_ARK_EXPIRY_SEC:-900}))"
  [ "$ark_refund_time" -lt "$ln_expiry" ] ||
    fail "ln-to-ark requires BRIDGE_TEST_LN_TO_ARK_REFUND_SEC < BRIDGE_TEST_LN_TO_ARK_EXPIRY_SEC"

  log "rgb-asset-to-ark-asset: creating preimage-hash hold invoice and Ark VHTLC template"
  request_file="$BRIDGE_TEST_OUTPUT_DIR/rgb-asset-to-ark-asset-request.json"
  jq -nc \
    --argjson amount_sat "$BRIDGE_TEST_LN_TO_ARK_SATS" \
    --arg preimage_hash "$payment_hash" \
    --arg asset_id "$BRIDGE_TEST_ARK_ASSET_ID" \
    --arg asset_amount "$BRIDGE_TEST_ARK_ASSET_AMOUNT" \
    --arg ark_claim_pubkey "$ark_claim_pubkey" \
    --argjson ark_refund_time "$ark_refund_time" \
    --argjson ln_expiry "$ln_expiry" \
    '{
      contract:true,
      amount_sat:$amount_sat,
      memo:"mutinynet-simulation rgb-asset-to-ark-asset bridge test",
      preimage_hash:$preimage_hash,
      asset_id:$asset_id,
      asset_amount:$asset_amount,
      ark_claim_pubkey:$ark_claim_pubkey,
      ark_refund_time:$ark_refund_time,
      ln_expiry:$ln_expiry,
      metadata:{test:"ark-vhtlc-swap", leg:"rgb-asset-to-ark-asset", provider_leg:"ln-to-ark", contract:true}
    }' >"$request_file"

  swap_file="$BRIDGE_TEST_OUTPUT_DIR/rgb-asset-to-ark-asset-swap-created.json"
  provider_post_file /v1/swaps/ln-to-ark "$request_file" | save_json "$swap_file"
  swap_id="$(jq -er .id "$swap_file")"
  bolt11="$(jq -er .bolt11 "$swap_file")"
  jq -e '.preimage == null and .preimage_hash_sha256 != null and .ark_contract_address != null' "$swap_file" >/dev/null ||
    fail "swap leaked a preimage or did not create a contract template; see $swap_file"

  log "rgb-asset-to-ark-asset: preparing RGB asset swap payment"
  prepare_file="$BRIDGE_TEST_OUTPUT_DIR/rgb-asset-to-ark-asset-rgb-prepare.json"
  api "$BRIDGE_TEST_RGB_PAYER_NODE" POST /prepareassetpayment "$(jq -nc \
    --arg invoice "$bolt11" \
    --arg asset_id "$BRIDGE_TEST_RGB_ASSET_ID" \
    --argjson asset_amount "$BRIDGE_TEST_RGB_ASSET_AMOUNT" \
    '{invoice:$invoice,amt_msat:null,asset_id:$asset_id,asset_amount:$asset_amount}')" |
    save_json "$prepare_file"

  log "rgb-asset-to-ark-asset: registering RGB maker swap"
  taker_file="$BRIDGE_TEST_OUTPUT_DIR/rgb-asset-to-ark-asset-rgb-maker-taker.json"
  api "$BRIDGE_TEST_RGB_MAKER_NODE" POST /taker "$(jq -nc --arg swapstring "$(jq -er .swapstring "$prepare_file")" '{swapstring:$swapstring}')" |
    save_json "$taker_file"

  log "rgb-asset-to-ark-asset: paying provider hold invoice with RGB asset"
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

  log "rgb-asset-to-ark-asset: funding Ark VHTLC from provider maker wallet"
  fund_file="$BRIDGE_TEST_OUTPUT_DIR/rgb-asset-to-ark-asset-contract-fund.json"
  provider_post "/v1/swaps/$swap_id/ark-contract/fund" '{}' | save_json "$fund_file"
  outpoint="$(contract_field "$fund_file" ark_vtxo_outpoint)"

  log "rgb-asset-to-ark-asset: claiming Ark VHTLC from taker wallet"
  claim_request_file="$BRIDGE_TEST_OUTPUT_DIR/rgb-asset-to-ark-asset-contract-claim-request.json"
  jq -n \
    --slurpfile swap "$fund_file" \
    --arg preimage "$preimage" \
    --arg ark_vtxo_outpoint "$outpoint" \
    --arg destination_address "$recipient" \
    --arg wallet_private_key_hex "$BRIDGE_TEST_ARK_TAKER_PRIVATE_KEY_HEX" \
    '{
        preimage_hash_sha256:($swap[0].preimage_hash_sha256 // $swap[0].preimage_hash),
        asset_id:$swap[0].asset_id,
        asset_amount:$swap[0].asset_amount,
        ark_claim_pubkey:$swap[0].ark_claim_pubkey,
        ark_refund_pubkey:$swap[0].ark_refund_pubkey,
        ark_refund_time:($swap[0].ark_refund_time|tonumber),
        ark_vtxo_outpoint:$ark_vtxo_outpoint,
        preimage:$preimage,
        destination_address:$destination_address,
        wallet_private_key_hex:$wallet_private_key_hex
      }' >"$claim_request_file"
  claim_file="$BRIDGE_TEST_OUTPUT_DIR/rgb-asset-to-ark-asset-contract-claim.json"
  provider_post_file "/v1/swaps/$swap_id/ark-contract/claim" "$claim_request_file" | save_json "$claim_file"
  claim_txid="$(contract_field "$claim_file" ark_claim_txid)"
  [ "$(contract_field "$claim_file" decoded_witness_preimage)" = "$preimage" ] ||
    fail "Ark claim did not reveal the expected preimage; see $claim_file"

  log "rgb-asset-to-ark-asset: settling hold invoice from observed Ark claim preimage"
  observe_file="$BRIDGE_TEST_OUTPUT_DIR/rgb-asset-to-ark-asset-observe-claim.json"
  provider_post "/v1/swaps/$swap_id/ark-contract/observe-claim" "$(jq -nc \
    --arg preimage "$preimage" \
    --arg ark_claim_txid "$claim_txid" \
    '{preimage:$preimage,ark_claim_txid:$ark_claim_txid,settle_ln:true}')" |
    save_json "$observe_file"

  wait_for_rgb_payment_status "$BRIDGE_TEST_RGB_PAYER_NODE" "$payment_hash" Succeeded rgb-asset-to-ark-asset
  wait_for_lnd_invoice_state "$BRIDGE_TEST_LND_PROVIDER_NODE" "$payment_hash" SETTLED rgb-asset-to-ark-asset-settled

  taker_balance_file="$BRIDGE_TEST_OUTPUT_DIR/rgb-asset-to-ark-asset-taker-balance.json"
  ark_cli "$BRIDGE_TEST_ARK_TAKER_WALLET" balance | save_json "$taker_balance_file" || true

  contract_funded="$(json_bool '.ark_vtxo_outpoint != null' "$fund_file")"
  contract_claimed="$(json_bool '(.ark_claim_txid // .stdout.ark_claim_txid // .ark_contract_result.stdout.ark_claim_txid) != null and (.decoded_witness_preimage // .stdout.decoded_witness_preimage // .ark_contract_result.stdout.decoded_witness_preimage) != null' "$claim_file")"
  if [ "$(sha256_hex32 "$(contract_field "$claim_file" decoded_witness_preimage)")" = "$payment_hash" ]; then
    preimage_verified=true
  else
    preimage_verified=false
  fi
  if jq -e '.status == "ln_settled"' "$observe_file" >/dev/null; then
    ln_or_rgb_settled=true
  else
    ln_or_rgb_settled=false
  fi
  no_preimage_before_claim="$(json_bool '.preimage == null' "$fund_file")"
  rgb_payment_file="$BRIDGE_TEST_OUTPUT_DIR/rgb-asset-to-ark-asset-rgb-payment.json"
  settled_invoice_file="$BRIDGE_TEST_OUTPUT_DIR/rgb-asset-to-ark-asset-settled-lnd-invoice.json"
  jq -nc \
    --slurpfile swap "$swap_file" \
    --slurpfile claim "$claim_file" \
    --slurpfile payment "$rgb_payment_file" \
    --slurpfile invoice "$settled_invoice_file" \
    --arg leg "rgb-asset-to-ark-asset" \
    --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg swap_id "$swap_id" \
    --arg payment_hash "$payment_hash" \
    --arg ark_vtxo_outpoint "$outpoint" \
    --arg ark_claim_txid "$claim_txid" \
    --argjson contract_funded "$contract_funded" \
    --argjson contract_claimed "$contract_claimed" \
    --argjson preimage_verified "$preimage_verified" \
    --argjson ln_or_rgb_settled "$ln_or_rgb_settled" \
    --argjson no_preimage_before_claim "$no_preimage_before_claim" \
    'def n($v): if $v == null then null else ($v|tonumber) end;
    def delta($end;$start): if $end == null or $start == null then null else ($end - $start) end;
    def maxp($vals): ($vals | map(select(. != null)) | max);
    ($swap[0].created_at | n(.)) as $start |
    ($claim[0].updated_at | n(.)) as $contract_claimed_at |
    ($invoice[0].settle_date | n(.)) as $ln_settled_at |
    ($payment[0].payment.updated_at | n(.)) as $rgb_paid_at |
    (maxp([$contract_claimed_at,$ln_settled_at,$rgb_paid_at])) as $completed_at |
    {
      leg:$leg,
      generated_at:$generated_at,
      swap_id:$swap_id,
      payment_hash:$payment_hash,
      ark_vtxo_outpoint:$ark_vtxo_outpoint,
      ark_claim_txid:$ark_claim_txid,
      contract_funded:$contract_funded,
      contract_claimed:$contract_claimed,
      preimage_verified:$preimage_verified,
      ln_or_rgb_settled:$ln_or_rgb_settled,
      refund_test_passed:false,
      refund_test_note:"not run by default; use the contract refund endpoint for timeout-path validation",
      no_direct_ark_send:true,
      no_preimage_before_claim:$no_preimage_before_claim,
      timings:{
        start_at_unix:$start,
        completed_at_unix:$completed_at,
        total_seconds:delta($completed_at;$start),
        ark_contract_seconds:delta($contract_claimed_at;$start),
        lightning_settlement_seconds:delta($ln_settled_at;($invoice[0].creation_date | n(.))),
        rgb_payment_seconds:delta($rgb_paid_at;($payment[0].payment.created_at | n(.)))
      }
    }' >"$BRIDGE_TEST_OUTPUT_DIR/rgb-asset-to-ark-asset-proof-summary.json"

  log "rgb-asset-to-ark-asset: swap $swap_id succeeded"
}

run_contract_ark_asset_to_rgb_asset() {
  local invoice_file bolt11 payment_hash ln_expiry request_file swap_file swap_id status
  local rgb_receiver_pubkey pubkey_file ark_refund_pubkey now ark_refund_time fund_request_file fund_file outpoint
  local verify_file pay_file pay_pid asset_send_file asset_payment_hash claim_file claimed_invoice_file preimage provider_receive_file provider_recipient
  local asset_delivery_file
  local contract_claim_file contract_funded contract_claimed preimage_verified ln_or_rgb_settled no_preimage_before_claim

  require_contract_commands

  log "ark-asset-to-rgb-asset: creating RGB mapped BTC invoice"
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
  ln_expiry="$(jq -er '((.timestamp // .created_at) + (.expiry_sec // 900)) | floor' "$invoice_file")"

  log "ark-asset-to-rgb-asset: creating payer refund key"
  pubkey_file="$BRIDGE_TEST_OUTPUT_DIR/ark-asset-to-rgb-asset-ark-refund-pubkey.json"
  ark_contract_pubkey_for_wallet "$BRIDGE_TEST_ARK_TAKER_WALLET" "$pubkey_file"
  ark_refund_pubkey="$(contract_field "$pubkey_file" ark_refund_pubkey)"
  now="$(date +%s)"
  ark_refund_time="$((ln_expiry + ${BRIDGE_TEST_ARK_TO_RGB_REFUND_AFTER_EXPIRY_SEC:-600}))"
  [ "$now" -lt "$ln_expiry" ] ||
    fail "RGB/LN invoice is already expired; see $invoice_file"

  log "ark-asset-to-rgb-asset: registering RGB invoice with provider and creating Ark VHTLC template"
  request_file="$BRIDGE_TEST_OUTPUT_DIR/ark-asset-to-rgb-asset-request.json"
  jq -nc \
    --arg bolt11 "$bolt11" \
    --argjson amount_sat "$BRIDGE_TEST_ARK_TO_RGB_SATS" \
    --arg asset_id "$BRIDGE_TEST_ARK_ASSET_ID" \
    --arg asset_amount "$BRIDGE_TEST_ARK_ASSET_AMOUNT" \
    --arg ark_refund_pubkey "$ark_refund_pubkey" \
    --argjson ark_refund_time "$ark_refund_time" \
    --argjson ln_expiry "$ln_expiry" \
    --argjson fee_limit_sat "$BRIDGE_TEST_FEE_LIMIT_SAT" \
    '{
      contract:true,
      bolt11:$bolt11,
      amount_sat:$amount_sat,
      asset_id:$asset_id,
      asset_amount:$asset_amount,
      ark_refund_pubkey:$ark_refund_pubkey,
      ark_refund_time:$ark_refund_time,
      ln_expiry:$ln_expiry,
      execute:false,
      fee_limit_sat:$fee_limit_sat,
      metadata:{test:"ark-vhtlc-swap", leg:"ark-asset-to-rgb-asset", provider_leg:"ark-to-ln", contract:true, asset_invoice:true}
    }' >"$request_file"

  swap_file="$BRIDGE_TEST_OUTPUT_DIR/ark-asset-to-rgb-asset-swap-created.json"
  provider_post_file /v1/swaps/ark-to-ln "$request_file" | save_json "$swap_file"
  swap_id="$(jq -er .id "$swap_file")"
  jq -e '.preimage == null and .preimage_hash_sha256 != null and .ark_contract_address != null' "$swap_file" >/dev/null ||
    fail "swap leaked a preimage or did not create a contract template; see $swap_file"

  log "ark-asset-to-rgb-asset: funding Ark VHTLC from payer wallet"
  fund_request_file="$BRIDGE_TEST_OUTPUT_DIR/ark-asset-to-rgb-asset-contract-fund-request.json"
  jq -n \
    --slurpfile swap "$swap_file" \
    --arg wallet_private_key_hex "$BRIDGE_TEST_ARK_TAKER_PRIVATE_KEY_HEX" \
    '{
        preimage_hash_sha256:($swap[0].preimage_hash_sha256 // $swap[0].preimage_hash),
        asset_id:$swap[0].asset_id,
        asset_amount:$swap[0].asset_amount,
        ark_claim_pubkey:$swap[0].ark_claim_pubkey,
        ark_refund_pubkey:$swap[0].ark_refund_pubkey,
        ark_refund_time:($swap[0].ark_refund_time|tonumber),
        wallet_private_key_hex:$wallet_private_key_hex
      }' >"$fund_request_file"
  fund_file="$BRIDGE_TEST_OUTPUT_DIR/ark-asset-to-rgb-asset-contract-fund.json"
  provider_post_file "/v1/swaps/$swap_id/ark-contract/fund" "$fund_request_file" | save_json "$fund_file"
  outpoint="$(contract_field "$fund_file" ark_vtxo_outpoint)"

  log "ark-asset-to-rgb-asset: verifying funded VHTLC before Lightning payment"
  verify_file="$BRIDGE_TEST_OUTPUT_DIR/ark-asset-to-rgb-asset-contract-verify-funded.json"
  provider_post "/v1/swaps/$swap_id/ark-contract/verify-funded" "$(jq -nc --arg ark_vtxo_outpoint "$outpoint" '{ark_vtxo_outpoint:$ark_vtxo_outpoint}')" |
    save_json "$verify_file"
  jq -e '.ark_vtxo_outpoint != null and .status == "ark_contract_funded"' "$verify_file" >/dev/null ||
    fail "provider did not verify Ark VHTLC funding; see $verify_file"

  log "ark-asset-to-rgb-asset: starting provider Lightning payment in background"
  pay_file="$BRIDGE_TEST_OUTPUT_DIR/ark-asset-to-rgb-asset-provider-pay.json"
  (
    provider_post "/v1/swaps/$swap_id/pay-ln" "$(jq -nc --argjson fee_limit_sat "$BRIDGE_TEST_FEE_LIMIT_SAT" '{fee_limit_sat:$fee_limit_sat}')" |
      save_json "$pay_file"
  ) &
  pay_pid="$!"

  wait_for_rgb_asset_invoice_status "$BRIDGE_TEST_RGB_MAKER_NODE" "$payment_hash" ln_accepted ark-asset-to-rgb-asset

  log "ark-asset-to-rgb-asset: sending RGB asset to receiver"
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
  preimage="$(extract_preimage_from_provider_pay "$pay_file")"
  [ -n "$preimage" ] ||
    fail "provider pay result did not expose a payment preimage; see $pay_file"
  [ "$(sha256_hex32 "$preimage")" = "$payment_hash" ] ||
    fail "provider payment preimage does not match RGB/LN invoice hash; see $pay_file"

  wait_for_rgb_asset_invoice_status "$BRIDGE_TEST_RGB_MAKER_NODE" "$payment_hash" ln_claimed ark-asset-to-rgb-asset-claimed

  log "ark-asset-to-rgb-asset: claiming Ark VHTLC from provider wallet"
  provider_receive_file="$BRIDGE_TEST_OUTPUT_DIR/ark-asset-to-rgb-asset-provider-receive.json"
  provider_recipient="$(ark_receive_address "$ARK_LND_PROVIDER_ARK_WALLET" "$provider_receive_file")"
  contract_claim_file="$BRIDGE_TEST_OUTPUT_DIR/ark-asset-to-rgb-asset-contract-claim.json"
  provider_post "/v1/swaps/$swap_id/ark-contract/claim" "$(jq -nc \
    --arg preimage "$preimage" \
    --arg ark_vtxo_outpoint "$outpoint" \
    --arg destination_address "$provider_recipient" \
    '{preimage:$preimage,ark_vtxo_outpoint:$ark_vtxo_outpoint,destination_address:$destination_address}')" |
    save_json "$contract_claim_file"

  contract_funded="$(json_bool '.ark_vtxo_outpoint != null' "$verify_file")"
  contract_claimed="$(json_bool '.ark_claim_txid != null and .preimage_source == "ark_claim_witness"' "$contract_claim_file")"
  if [ "$(sha256_hex32 "$preimage")" = "$payment_hash" ]; then
    preimage_verified=true
  else
    preimage_verified=false
  fi
  claimed_invoice_file="$BRIDGE_TEST_OUTPUT_DIR/ark-asset-to-rgb-asset-claimed-rgb-asset-invoice.json"
  if jq -e '.status == "ln_paid"' "$pay_file" >/dev/null &&
    jq -e '.status == "ln_claimed"' "$claimed_invoice_file" >/dev/null; then
    ln_or_rgb_settled=true
  else
    ln_or_rgb_settled=false
  fi
  no_preimage_before_claim="$(json_bool '.preimage == null' "$verify_file")"
  asset_delivery_file="$BRIDGE_TEST_OUTPUT_DIR/ark-asset-to-rgb-asset-rgb-delivery-rgb-payment.json"
  jq -nc \
    --slurpfile swap "$swap_file" \
    --slurpfile fund "$fund_file" \
    --slurpfile pay "$pay_file" \
    --slurpfile claimed_invoice "$claimed_invoice_file" \
    --slurpfile contract_claim "$contract_claim_file" \
    --slurpfile asset_delivery "$asset_delivery_file" \
    --arg leg "ark-asset-to-rgb-asset" \
    --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg swap_id "$swap_id" \
    --arg payment_hash "$payment_hash" \
    --arg ark_vtxo_outpoint "$outpoint" \
    --arg ark_claim_txid "$(contract_field "$contract_claim_file" ark_claim_txid)" \
    --argjson contract_funded "$contract_funded" \
    --argjson contract_claimed "$contract_claimed" \
    --argjson preimage_verified "$preimage_verified" \
    --argjson ln_or_rgb_settled "$ln_or_rgb_settled" \
    --argjson no_preimage_before_claim "$no_preimage_before_claim" \
    'def n($v): if $v == null then null else ($v|tonumber) end;
    def delta($end;$start): if $end == null or $start == null then null else ($end - $start) end;
    def maxp($vals): ($vals | map(select(. != null)) | max);
    ($swap[0].created_at | n(.)) as $start |
    ($fund[0].updated_at | n(.)) as $contract_funded_at |
    ($pay[0].updated_at | n(.)) as $ln_paid_at |
    ($claimed_invoice[0].claimed_at | n(.)) as $rgb_claimed_at |
    ($contract_claim[0].updated_at | n(.)) as $contract_claimed_at |
    (maxp([$ln_paid_at,$rgb_claimed_at,$contract_claimed_at])) as $completed_at |
    {
      leg:$leg,
      generated_at:$generated_at,
      swap_id:$swap_id,
      payment_hash:$payment_hash,
      ark_vtxo_outpoint:$ark_vtxo_outpoint,
      ark_claim_txid:$ark_claim_txid,
      contract_funded:$contract_funded,
      contract_claimed:$contract_claimed,
      preimage_verified:$preimage_verified,
      ln_or_rgb_settled:$ln_or_rgb_settled,
      refund_test_passed:false,
      refund_test_note:"not run by default; use the contract refund endpoint for timeout-path validation",
      no_direct_ark_send:true,
      no_preimage_before_claim:$no_preimage_before_claim,
      timings:{
        start_at_unix:$start,
        completed_at_unix:$completed_at,
        total_seconds:delta($completed_at;$start),
        ark_contract_funding_seconds:delta($contract_funded_at;$start),
        lightning_payment_seconds:delta($ln_paid_at;$start),
        rgb_invoice_claim_seconds:delta($rgb_claimed_at;($claimed_invoice[0].accepted_at | n(.))),
        rgb_delivery_seconds:delta(($asset_delivery[0].payment.updated_at | n(.));($asset_delivery[0].payment.created_at | n(.)))
      }
    }' >"$BRIDGE_TEST_OUTPUT_DIR/ark-asset-to-rgb-asset-proof-summary.json"

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
  "fee_limit_sat": "$BRIDGE_TEST_FEE_LIMIT_SAT",
  "ark_contract_server_url": "$ARK_LND_PROVIDER_ARK_SERVER_URL",
  "ark_contract_network": "$ARK_LND_PROVIDER_ARK_NETWORK",
  "ark_contract_adapter": "rust-ark-grpc"
}
EOF

log "artifacts: $BRIDGE_TEST_OUTPUT_DIR"
case "$BRIDGE_TEST_MODE" in
  all)
    assert_rgb_to_ark_ready
    run_contract_rgb_asset_to_ark_asset
    assert_ark_to_rgb_ready
    run_contract_ark_asset_to_rgb_asset
    write_combined_proof_summary
    ;;
  rgb-asset-to-ark-asset)
    assert_rgb_to_ark_ready
    run_contract_rgb_asset_to_ark_asset
    write_combined_proof_summary
    ;;
  ark-asset-to-rgb-asset)
    assert_ark_to_rgb_ready
    run_contract_ark_asset_to_rgb_asset
    write_combined_proof_summary
    ;;
esac

log "bridge test $BRIDGE_TEST_MODE passed"
