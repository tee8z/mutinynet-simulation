#!/usr/bin/env bash

set -euo pipefail

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

require_cmd jq

RGB_MM_NODE="${RGB_MM_NODE:-node4}"
RGB_MM_ASSET_FUNDER_NODE="${RGB_MM_ASSET_FUNDER_NODE:-node1}"
RGB_MM_LND_NODE="${RGB_MM_LND_NODE:-lnd1}"
RGB_MM_ASSET_ID="${RGB_MM_ASSET_ID:-}"
RGB_MM_SKIP_RGB_CHANNEL="${RGB_MM_SKIP_RGB_CHANNEL:-0}"
RGB_MM_SKIP_LND_CHANNEL="${RGB_MM_SKIP_LND_CHANNEL:-0}"
RGB_MM_RGB_CHANNEL_CAPACITY_SAT="${RGB_MM_RGB_CHANNEL_CAPACITY_SAT:-100000}"
RGB_MM_RGB_CHANNEL_PUSH_MSAT="${RGB_MM_RGB_CHANNEL_PUSH_MSAT:-50000000}"
RGB_MM_RGB_CHANNEL_ASSET_AMOUNT="${RGB_MM_RGB_CHANNEL_ASSET_AMOUNT:-1000}"
RGB_MM_RGB_CHANNEL_PUSH_ASSET_AMOUNT="${RGB_MM_RGB_CHANNEL_PUSH_ASSET_AMOUNT:-$((RGB_MM_RGB_CHANNEL_ASSET_AMOUNT / 2))}"
RGB_MM_LND_CHANNEL_CAPACITY_SAT="${RGB_MM_LND_CHANNEL_CAPACITY_SAT:-100000}"
RGB_MM_LND_CHANNEL_PUSH_SAT="${RGB_MM_LND_CHANNEL_PUSH_SAT:-40000}"
RGB_MM_LND_CHANNEL_PUBLIC="${RGB_MM_LND_CHANNEL_PUBLIC:-1}"
RGB_MM_WAIT_TIMEOUT_SEC="${RGB_MM_WAIT_TIMEOUT_SEC:-$WAIT_TIMEOUT_SEC}"

json_bool() {
  case "$1" in
    1|true|TRUE|yes|YES) printf 'true' ;;
    *) printf 'false' ;;
  esac
}

rln_pubkey() {
  api "$1" GET /nodeinfo | jq -r .pubkey
}

lnd_pubkey() {
  lnd_cli "$1" getinfo | jq -r .identity_pubkey
}

rln_has_usable_channel() {
  local node="$1" peer="$2" asset="${3:-}"
  api "$node" GET /listchannels | jq -e \
    --arg peer "$peer" \
    --arg asset "$asset" \
    '[.channels[]? | select(.peer_pubkey == $peer and ((.asset_id // "") == $asset) and (.is_usable == true))] | length > 0' \
    >/dev/null
}

wait_for_rln_channel() {
  local node="$1" peer="$2" asset="${3:-}" label="$4" start
  start="$(date +%s)"
  while true; do
    if rln_has_usable_channel "$node" "$peer" "$asset"; then
      return 0
    fi
    if [ $(( "$(date +%s)" - start )) -ge "$RGB_MM_WAIT_TIMEOUT_SEC" ]; then
      echo "$label did not become usable" >&2
      api "$node" GET /listchannels | jq . >&2 || true
      return 1
    fi
    sleep 5
  done
}

lnd_has_active_channel() {
  local label="$1" peer="$2"
  lnd_cli "$label" listchannels | jq -e \
    --arg peer "$peer" \
    '[.channels[]? | select(.remote_pubkey == $peer and (.active == true))] | length > 0' \
    >/dev/null
}

wait_for_lnd_channel() {
  local label="$1" peer="$2" start
  start="$(date +%s)"
  while true; do
    if lnd_has_active_channel "$label" "$peer"; then
      return 0
    fi
    if [ $(( "$(date +%s)" - start )) -ge "$RGB_MM_WAIT_TIMEOUT_SEC" ]; then
      echo "$label channel to $peer did not become active" >&2
      lnd_cli "$label" listchannels | jq . >&2 || true
      return 1
    fi
    sleep 5
  done
}

connect_rln_to_rln() {
  local from="$1" to="$2" to_pubkey
  to_pubkey="$(rln_pubkey "$to")"
  api "$from" POST /connectpeer "$(jq -nc \
    --arg peer "${to_pubkey}@127.0.0.1:$(node_peer_port "$to")" \
    '{peer_pubkey_and_addr:$peer}')" >/dev/null || true
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

open_rgb_inventory_channel() {
  local funder="$1" maker="$2" maker_pubkey funder_pubkey
  if [ -z "$RGB_MM_ASSET_ID" ]; then
    echo "missing RGB_MM_ASSET_ID; set it to the RGB asset id for the market-maker inventory channel" >&2
    return 2
  fi

  wait_for_rln_node "$funder"
  wait_for_rln_node "$maker"
  maker_pubkey="$(rln_pubkey "$maker")"
  funder_pubkey="$(rln_pubkey "$funder")"

  if rln_has_usable_channel "$funder" "$maker_pubkey" "$RGB_MM_ASSET_ID"; then
    echo "RGB inventory channel already usable: $funder -> $maker asset=$RGB_MM_ASSET_ID"
    return 0
  fi

  connect_rln_to_rln "$funder" "$maker"
  connect_rln_to_rln "$maker" "$funder"

  echo "opening RGB inventory channel $funder -> $maker asset=$RGB_MM_ASSET_ID amount=${RGB_MM_RGB_CHANNEL_ASSET_AMOUNT} push_asset=${RGB_MM_RGB_CHANNEL_PUSH_ASSET_AMOUNT}"
  api "$funder" POST /openchannel "$(jq -nc \
    --arg peer "${maker_pubkey}@127.0.0.1:$(node_peer_port "$maker")" \
    --arg asset_id "$RGB_MM_ASSET_ID" \
    --argjson capacity "$RGB_MM_RGB_CHANNEL_CAPACITY_SAT" \
    --argjson push_msat "$RGB_MM_RGB_CHANNEL_PUSH_MSAT" \
    --argjson asset_amount "$RGB_MM_RGB_CHANNEL_ASSET_AMOUNT" \
    --argjson push_asset_amount "$RGB_MM_RGB_CHANNEL_PUSH_ASSET_AMOUNT" \
    '{
      peer_pubkey_and_opt_addr:$peer,
      capacity_sat:$capacity,
      push_msat:$push_msat,
      asset_amount:$asset_amount,
      asset_id:$asset_id,
      push_asset_amount:$push_asset_amount,
      public:false,
      with_anchors:true,
      fee_base_msat:null,
      fee_proportional_millionths:null,
      temporary_channel_id:null
    }')" | jq .

  wait_for_rln_channel "$funder" "$maker_pubkey" "$RGB_MM_ASSET_ID" "$funder -> $maker RGB inventory channel"
  wait_for_rln_channel "$maker" "$funder_pubkey" "$RGB_MM_ASSET_ID" "$maker -> $funder RGB inventory channel"
}

open_lnd_payment_channel() {
  local maker="$1" lnd="$2" lnd_pubkey maker_pubkey public
  wait_for_rln_node "$maker"
  wait_for_lnd_unlocked "$lnd"
  lnd_pubkey="$(lnd_pubkey "$lnd")"
  maker_pubkey="$(rln_pubkey "$maker")"

  if rln_has_usable_channel "$maker" "$lnd_pubkey" ""; then
    echo "BTC payment channel already usable: $maker -> $lnd"
    return 0
  fi

  connect_rln_to_lnd "$maker" "$lnd"
  public="$(json_bool "$RGB_MM_LND_CHANNEL_PUBLIC")"

  echo "opening BTC payment channel $maker -> $lnd capacity=${RGB_MM_LND_CHANNEL_CAPACITY_SAT} push_sat=${RGB_MM_LND_CHANNEL_PUSH_SAT} public=${public}"
  api "$maker" POST /openchannel "$(jq -nc \
    --arg peer "${lnd_pubkey}@127.0.0.1:$(lnd_peer_port "$lnd")" \
    --argjson capacity "$RGB_MM_LND_CHANNEL_CAPACITY_SAT" \
    --argjson push_msat "$((RGB_MM_LND_CHANNEL_PUSH_SAT * 1000))" \
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
    }')" | jq .

  wait_for_rln_channel "$maker" "$lnd_pubkey" "" "$maker -> $lnd BTC payment channel"
  wait_for_lnd_channel "$lnd" "$maker_pubkey"
}

maker_node="$(node_label "$RGB_MM_NODE")"
asset_funder_node="$(node_label "$RGB_MM_ASSET_FUNDER_NODE")"

case "$RGB_MM_SKIP_RGB_CHANNEL" in
  1|true|TRUE|yes|YES) echo "skipping RGB inventory channel" ;;
  *) open_rgb_inventory_channel "$asset_funder_node" "$maker_node" ;;
esac

case "$RGB_MM_SKIP_LND_CHANNEL" in
  1|true|TRUE|yes|YES) echo "skipping LND payment channel" ;;
  *) open_lnd_payment_channel "$maker_node" "$RGB_MM_LND_NODE" ;;
esac

echo "[market-maker channels]"
api "$maker_node" GET /listchannels | jq '.channels[] | {peer_pubkey,is_usable,asset_id,asset_amount,local_balance_sat,outbound_balance_msat,inbound_balance_msat,next_outbound_htlc_minimum_msat}'
