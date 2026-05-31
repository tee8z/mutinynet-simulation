#!/usr/bin/env bash

set -euo pipefail

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

require_cmd jq
ensure_faucet_auth

targets_from_args() {
  if [ "$#" -eq 0 ] || [ "${1:-}" = "all" ]; then
    printf '%s\n' node1 node2 node3 node4 lnd1 lnd2 arkd ark-maker ark-taker
    return 0
  fi

  local arg
  for arg in "$@"; do
    case "$arg" in
      r1|node1) printf 'node1\n' ;;
      r2|node2) printf 'node2\n' ;;
      r3|node3) printf 'node3\n' ;;
      r4|node4|rmm|rgb-mm|market-maker) printf 'node4\n' ;;
      lnd1|lnda|lnd-rgb) printf 'lnd1\n' ;;
      lnd2|lndb|lnd-ark) printf 'lnd2\n' ;;
      ark|arkd) printf 'arkd\n' ;;
      ark-maker|maker) printf 'ark-maker\n' ;;
      ark-taker|taker) printf 'ark-taker\n' ;;
      *) echo "unknown funding target: $arg" >&2; return 2 ;;
    esac
  done
}

extract_address() {
  local input
  input="$(cat)"
  printf '%s' "$input" | jq -r '
    .address //
    .onchain_address //
    .boarding_address //
    .result.address //
    empty
  ' 2>/dev/null || printf '%s\n' "$input" | sed -nE 's/.*((tb|bc|bcrt)1[0-9a-z]+).*/\1/p' | head -n 1
}

fund_address() {
  local label="$1" address="$2"
  if [ -z "$address" ] || [ "$address" = "null" ]; then
    echo "could not derive address for $label" >&2
    return 1
  fi
  echo "funding $label $address sats=$FAUCET_AMOUNT provider=$FAUCET_PROVIDER"
  post_faucet_address "$address" "$FAUCET_AMOUNT"
}

fund_rln() {
  local node="$1" address
  wait_for_rln_node "$node"
  address="$(api "$node" POST /address | extract_address)"
  fund_address "$node" "$address"
}

fund_lnd() {
  local label="$1" address
  wait_for_lnd_unlocked "$label"
  address="$(lnd_cli "$label" newaddress p2wkh | extract_address)"
  fund_address "$label" "$address"
}

fund_arkd() {
  local address
  wait_for_arkd
  address="$(arkd --url "http://127.0.0.1:${ARKD_ADMIN_PORT}" --datadir "$ARKD_DIR" wallet address | extract_address)"
  fund_address "arkd" "$address"
}

fund_ark_cli() {
  local wallet="$1" label address
  label="${wallet#ark-}"
  wait_for_arkd
  address="$(ark_cli "$label" receive | extract_address)"
  fund_address "$wallet" "$address"
}

while read -r target; do
  case "$target" in
    node1|node2|node3|node4) fund_rln "$target" ;;
    lnd1|lnd2) fund_lnd "$target" ;;
    arkd) fund_arkd ;;
    ark-maker|ark-taker) fund_ark_cli "$target" ;;
  esac
done < <(targets_from_args "$@")
