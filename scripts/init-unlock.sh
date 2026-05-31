#!/usr/bin/env bash

set -euo pipefail

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

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
      *) echo "unknown init target: $arg" >&2; return 2 ;;
    esac
  done
}

init_unlock_rln_node() {
  local node data rpc_host rpc_port announce payload output error rc
  node="$(node_label "$1")"
  data="$(node_dir "$node")"

  require_env BITCOIND_RPC_HOST BITCOIND_RPC_USER BITCOIND_RPC_PASS
  "$SIM_DIR/scripts/start.sh" bitcoind-rpc-proxy
  "$SIM_DIR/scripts/start.sh" esplora
  if rln_indexer_uses_local; then
    wait_for_esplora_http
  fi
  rpc_host="$(bitcoind_rpc_effective_host)"
  rpc_port="$(bitcoind_rpc_effective_port)"
  wait_for_rln_node "$node"

  if [ ! -f "$data/mnemonic" ]; then
    echo "initializing $node"
    api "$node" POST /init "$(jq -nc --arg password "$RLN_NODE_PASSWORD" '{password:$password,mnemonic:null}')" | jq .
  else
    echo "$node already initialized"
  fi

  announce='[]'
  payload="$(jq -nc \
    --arg password "$RLN_NODE_PASSWORD" \
    --arg user "$BITCOIND_RPC_USER" \
    --arg pass "$BITCOIND_RPC_PASS" \
    --arg host "$rpc_host" \
    --argjson port "$rpc_port" \
    --arg indexer "$RLN_INDEXER_URL" \
    --arg proxy "$RGB_PROXY_ENDPOINT" \
    --argjson skip_consistency_check "$(json_bool "$RLN_SKIP_CONSISTENCY_CHECK")" \
    --argjson announce "$announce" \
    --arg alias "$(node_alias "$node")" \
    '{
      password:$password,
      bitcoind_rpc_username:$user,
      bitcoind_rpc_password:$pass,
      bitcoind_rpc_host:$host,
      bitcoind_rpc_port:$port,
      indexer_url:$indexer,
      proxy_endpoint:$proxy,
      skip_consistency_check:$skip_consistency_check,
      announce_addresses:$announce,
      announce_alias:$alias
    }')"

  echo "unlocking $node"
  output="$(mktemp)"
  error="$(mktemp)"
  if api "$node" POST /unlock "$payload" >"$output" 2>"$error"; then
    jq . "$output"
  else
    rc=$?
    if jq -e '.name == "AlreadyUnlocked"' "$output" >/dev/null 2>&1; then
      echo "$node already unlocked"
    else
      cat "$error" >&2
      cat "$output" >&2
      rm -f "$output" "$error"
      return "$rc"
    fi
  fi
  rm -f "$output" "$error"
}

init_lnd_wallet() {
  local label="$1" create_log
  require_cmd expect "$LNCLI_BINARY"
  wait_for_lnd "$label"

  if lnd_cli "$label" getinfo >/dev/null 2>&1; then
    echo "$label already initialized and unlocked"
    return 0
  fi

  if [ ! -f "$(lnd_wallet_file "$label")" ]; then
    create_log="$STATE_DIR/${label}-create-wallet.log"
    echo "initializing $label wallet"
    (
      umask 077
      : >"$create_log"
    )

    LND_EXPECT_PASS="$LND_WALLET_PASSWORD" \
    LND_EXPECT_LABEL="$label" \
    LND_EXPECT_DIR="$(lnd_dir "$label")" \
    LND_EXPECT_RPC="127.0.0.1:$(lnd_rpc_port "$label")" \
    LND_EXPECT_NETWORK="$LND_NETWORK" \
    LND_EXPECT_TLS="$(lnd_tls_cert_file "$label")" \
    LND_EXPECT_LNCLI="$LNCLI_BINARY" \
    LND_EXPECT_NO_MACAROONS="$LND_NO_MACAROONS" \
      expect >"$create_log" 2>&1 <<'EOF'
set timeout 120
set pass $env(LND_EXPECT_PASS)
set args [list $env(LND_EXPECT_LNCLI) --lnddir=$env(LND_EXPECT_DIR) --rpcserver=$env(LND_EXPECT_RPC) --network=$env(LND_EXPECT_NETWORK) --tlscertpath=$env(LND_EXPECT_TLS)]
if {$env(LND_EXPECT_NO_MACAROONS) == "1"} {
  lappend args --no-macaroons
}
lappend args create
spawn {*}$args
expect {
  -re {Input wallet password:} { send "$pass\r"; exp_continue }
  -re {Confirm password:} { send "$pass\r"; exp_continue }
  -re {Enter.*y/x/n.*:} { send "n\r"; exp_continue }
  -re {Input your passphrase.*:} { send "\r"; exp_continue }
  eof {}
  timeout { exit 124 }
}
catch wait result
exit [lindex $result 3]
EOF
    echo "$label wallet initialized; transcript: $create_log"
  else
    echo "unlocking $label wallet"
    printf '%s\n' "$LND_WALLET_PASSWORD" | lnd_cli "$label" unlock --stdin >/dev/null
  fi

  wait_for_lnd_unlocked "$label"
}

arkd_admin() {
  arkd --url "http://127.0.0.1:${ARKD_ADMIN_PORT}" --datadir "$ARKD_DIR" "$@"
}

init_arkd_server_wallet() {
  require_cmd arkd
  wait_for_arkd

  echo "checking arkd server wallet"
  if arkd_admin wallet status >/dev/null 2>&1; then
    echo "arkd wallet status is reachable"
  fi

  if ! arkd_admin wallet balance >/dev/null 2>&1; then
    echo "creating arkd server wallet"
    arkd_admin wallet create --password "$ARKD_PASSWORD" || true
  fi

  echo "unlocking arkd server wallet"
  arkd_admin wallet unlock --password "$ARKD_PASSWORD" || true
  arkd_admin wallet status || true
}

init_ark_cli_wallet() {
  local wallet="$1" label
  label="${wallet#ark-}"
  require_cmd ark
  wait_for_arkd

  if ark_cli "$label" config >/dev/null 2>&1; then
    echo "ark CLI wallet $label already initialized"
    ark_cli "$label" config || true
    return 0
  fi

  echo "initializing ark CLI wallet $label"
  ark_cli "$label" init \
    --server-url "$(arkd_url)" \
    --explorer "$ARK_EXPLORER_URL" \
    --password "$ARK_CLI_PASSWORD"
  ark_cli "$label" config
}

while read -r target; do
  case "$target" in
    node1|node2|node3|node4) init_unlock_rln_node "$target" ;;
    lnd1|lnd2) init_lnd_wallet "$target" ;;
    arkd) init_arkd_server_wallet ;;
    ark-maker|ark-taker) init_ark_cli_wallet "$target" ;;
  esac
done < <(targets_from_args "$@")
