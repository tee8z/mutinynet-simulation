#!/usr/bin/env bash

set -euo pipefail

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

export PATH="$SIM_DIR/result/bin:$PATH"

require_cmd curl jq "$LNCLI_BINARY"

lnd_label() {
  case "$1" in
    lnd1|lnda|lnd-rgb|rgb) printf 'lnd1' ;;
    lnd2|lndb|lnd-ark|ark) printf 'lnd2' ;;
    *) echo "unknown lnd node: $1" >&2; return 2 ;;
  esac
}

log() {
  printf '[rln-btc-channel] %s\n' "$*"
}

fail() {
  echo "error: $*" >&2
  exit 1
}

save_json() {
  local file="$1"
  jq . >"$file"
}

rln_pubkey() {
  api "$1" GET /nodeinfo | jq -r .pubkey
}

lnd_pubkey() {
  lnd_cli "$1" getinfo | jq -r .identity_pubkey
}

rln_has_usable_btc_channel() {
  local node="$1" peer="$2"
  api "$node" GET /listchannels | jq -e \
    --arg peer "$peer" \
    '[.channels[]? | select(.peer_pubkey == $peer and (.is_usable == true) and ((.asset_id // "") == ""))] | length > 0' \
    >/dev/null
}

lnd_has_active_channel() {
  local label="$1" peer="$2"
  lnd_cli "$label" listchannels | jq -e \
    --arg peer "$peer" \
    '[.channels[]? | select(.remote_pubkey == $peer and (.active == true))] | length > 0' \
    >/dev/null
}

wait_for_rln_btc_channel() {
  local node="$1" peer="$2" start
  start="$(date +%s)"
  while true; do
    if rln_has_usable_btc_channel "$node" "$peer"; then
      return 0
    fi
    if [ $(( "$(date +%s)" - start )) -ge "$RLN_BTC_TEST_WAIT_TIMEOUT_SEC" ]; then
      api "$node" GET /listchannels | save_json "$RLN_BTC_TEST_OUTPUT_DIR/${node}-channels-timeout.json" || true
      fail "$node did not report a usable BTC channel to $peer before timeout"
    fi
    sleep 5
  done
}

wait_for_lnd_channel() {
  local label="$1" peer="$2" start
  start="$(date +%s)"
  while true; do
    if lnd_has_active_channel "$label" "$peer"; then
      return 0
    fi
    if [ $(( "$(date +%s)" - start )) -ge "$RLN_BTC_TEST_WAIT_TIMEOUT_SEC" ]; then
      lnd_cli "$label" listchannels | save_json "$RLN_BTC_TEST_OUTPUT_DIR/${label}-channels-timeout.json" || true
      fail "$label did not report an active channel to $peer before timeout"
    fi
    sleep 5
  done
}

connect_rln_to_lnd() {
  local node="$1" lnd="$2" lnd_pubkey node_pubkey
  lnd_pubkey="$(lnd_pubkey "$lnd")"
  node_pubkey="$(rln_pubkey "$node")"

  api "$node" POST /connectpeer "$(jq -nc \
    --arg peer "${lnd_pubkey}@127.0.0.1:$(lnd_peer_port "$lnd")" \
    '{peer_pubkey_and_addr:$peer}')" >/dev/null || true
  lnd_cli "$lnd" connect "${node_pubkey}@127.0.0.1:$(node_peer_port "$node")" --perm >/dev/null 2>&1 || true
}

ensure_rln_vanilla_funds() {
  local node="$1" balance_file spendable
  balance_file="$RLN_BTC_TEST_OUTPUT_DIR/${node}-btcbalance-before.json"
  api "$node" POST /btcbalance '{"skip_sync":false}' | save_json "$balance_file"
  spendable="$(jq -r '.vanilla.spendable // 0' "$balance_file")"
  if [ "$spendable" -lt "$RLN_BTC_TEST_CHANNEL_CAPACITY_SAT" ]; then
    fail "$node has only ${spendable} spendable vanilla sats; fund it with: sim-faucet-fund $node"
  fi
}

open_btc_channel() {
  local node="$1" lnd="$2" lnd_pubkey request_file response_file public
  lnd_pubkey="$(lnd_pubkey "$lnd")"
  public="$(json_bool "$RLN_BTC_TEST_CHANNEL_PUBLIC")"
  request_file="$RLN_BTC_TEST_OUTPUT_DIR/openchannel-request.json"
  response_file="$RLN_BTC_TEST_OUTPUT_DIR/openchannel-response.json"

  jq -nc \
    --arg peer "${lnd_pubkey}@127.0.0.1:$(lnd_peer_port "$lnd")" \
    --argjson capacity "$RLN_BTC_TEST_CHANNEL_CAPACITY_SAT" \
    --argjson push_msat "$((RLN_BTC_TEST_CHANNEL_PUSH_SAT * 1000))" \
    --argjson public "$public" \
    '{
      peer_pubkey_and_opt_addr:$peer,
      capacity_sat:$capacity,
      push_msat:$push_msat,
      asset_amount:null,
      asset_id:null,
      push_asset_amount:null,
      public:$public,
      with_anchors:false,
      fee_base_msat:null,
      fee_proportional_millionths:null,
      temporary_channel_id:null
    }' >"$request_file"

  log "opening BTC-only channel $node -> $lnd capacity=${RLN_BTC_TEST_CHANNEL_CAPACITY_SAT} push_sat=${RLN_BTC_TEST_CHANNEL_PUSH_SAT} public=${public}"
  if ! api "$node" POST /openchannel "$(tr -d '\n' <"$request_file")" >"$response_file"; then
    jq . "$response_file" >&2 || cat "$response_file" >&2
    return 1
  fi
  jq . "$response_file"
}

RGB_NODE="$(node_label "${1:-${RLN_BTC_TEST_RGB_NODE:-node4}}")"
LND_NODE="$(lnd_label "${2:-${RLN_BTC_TEST_LND_NODE:-lnd1}}")"
RLN_BTC_TEST_CHANNEL_CAPACITY_SAT="${RLN_BTC_TEST_CHANNEL_CAPACITY_SAT:-100000}"
RLN_BTC_TEST_CHANNEL_PUSH_SAT="${RLN_BTC_TEST_CHANNEL_PUSH_SAT:-40000}"
RLN_BTC_TEST_CHANNEL_PUBLIC="${RLN_BTC_TEST_CHANNEL_PUBLIC:-1}"
RLN_BTC_TEST_WAIT_TIMEOUT_SEC="${RLN_BTC_TEST_WAIT_TIMEOUT_SEC:-$WAIT_TIMEOUT_SEC}"
RLN_BTC_TEST_OUTPUT_DIR="${RLN_BTC_TEST_OUTPUT_DIR:-$STATE_DIR/tests/rln-btc-channel-$(date -u +%Y%m%dT%H%M%SZ)}"
RLN_BTC_TEST_START_SERVICES="${RLN_BTC_TEST_START_SERVICES:-1}"
RLN_BTC_TEST_WAIT_FOR_LND_SYNC="${RLN_BTC_TEST_WAIT_FOR_LND_SYNC:-1}"

mkdir -p "$RLN_BTC_TEST_OUTPUT_DIR"

if [ "$RLN_BTC_TEST_START_SERVICES" = "1" ]; then
  log "starting $RGB_NODE and $LND_NODE"
  "$SIM_DIR/scripts/start.sh" "$RGB_NODE" "$LND_NODE"
  "$SIM_DIR/scripts/init-unlock.sh" "$RGB_NODE" "$LND_NODE"
fi

wait_for_rln_node "$RGB_NODE"
wait_for_lnd_unlocked "$LND_NODE"
if [ "$RLN_BTC_TEST_WAIT_FOR_LND_SYNC" = "1" ]; then
  wait_for_lnd_chain_synced "$LND_NODE"
fi

rgb_pubkey="$(rln_pubkey "$RGB_NODE")"
lnd_pubkey="$(lnd_pubkey "$LND_NODE")"

api "$RGB_NODE" GET /nodeinfo | save_json "$RLN_BTC_TEST_OUTPUT_DIR/${RGB_NODE}-nodeinfo.json"
lnd_cli "$LND_NODE" getinfo | save_json "$RLN_BTC_TEST_OUTPUT_DIR/${LND_NODE}-getinfo.json"

if rln_has_usable_btc_channel "$RGB_NODE" "$lnd_pubkey" &&
  lnd_has_active_channel "$LND_NODE" "$rgb_pubkey"; then
  log "BTC-only channel already usable between $RGB_NODE and $LND_NODE"
else
  ensure_rln_vanilla_funds "$RGB_NODE"
  connect_rln_to_lnd "$RGB_NODE" "$LND_NODE"
  open_btc_channel "$RGB_NODE" "$LND_NODE"
  wait_for_rln_btc_channel "$RGB_NODE" "$lnd_pubkey"
  wait_for_lnd_channel "$LND_NODE" "$rgb_pubkey"
fi

api "$RGB_NODE" GET /listchannels | save_json "$RLN_BTC_TEST_OUTPUT_DIR/${RGB_NODE}-channels.json"
lnd_cli "$LND_NODE" listchannels | save_json "$RLN_BTC_TEST_OUTPUT_DIR/${LND_NODE}-channels.json"

jq -nc \
  --arg rgb_node "$RGB_NODE" \
  --arg lnd_node "$LND_NODE" \
  --arg rgb_pubkey "$rgb_pubkey" \
  --arg lnd_pubkey "$lnd_pubkey" \
  --arg output_dir "$RLN_BTC_TEST_OUTPUT_DIR" \
  '{
    ok:true,
    rgb_node:$rgb_node,
    lnd_node:$lnd_node,
    rgb_pubkey:$rgb_pubkey,
    lnd_pubkey:$lnd_pubkey,
    output_dir:$output_dir
  }' | save_json "$RLN_BTC_TEST_OUTPUT_DIR/summary.json"

log "BTC-only RLN <-> LND channel validation passed"
log "artifacts: $RLN_BTC_TEST_OUTPUT_DIR"
