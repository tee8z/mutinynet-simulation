#!/usr/bin/env bash

set -euo pipefail

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

write_bitcoind_config() {
  mkdir -p "$BITCOIND_DIR"
  {
    printf 'signet=1\n'
    printf 'server=1\n'
    printf 'daemon=0\n'
    printf 'txindex=%s\n' "$BITCOIND_TXINDEX"
    printf 'blockfilterindex=%s\n' "$BITCOIND_BLOCKFILTERINDEX"
    printf 'peerblockfilters=%s\n' "$BITCOIND_PEERBLOCKFILTERS"
    printf 'dnsseed=%s\n' "$BITCOIND_DNSSEED"
    printf 'dbcache=%s\n' "$BITCOIND_DBCACHE"
    printf 'blocksonly=%s\n' "$BITCOIND_BLOCKSONLY"
    printf 'maxconnections=%s\n' "$BITCOIND_MAXCONNECTIONS"
    if [ -n "$BITCOIND_ASSUMEVALID" ]; then
      printf 'assumevalid=%s\n' "$BITCOIND_ASSUMEVALID"
    fi
    printf 'fallbackfee=0.0002\n'
    printf '\n[signet]\n'
    printf 'signetchallenge=%s\n' "$SIGNET_CHALLENGE"
    printf 'signetblocktime=%s\n' "$BITCOIND_SIGNET_BLOCK_TIME"
    printf 'rpcbind=%s\n' "$BITCOIND_RPC_BIND"
    printf 'rpcallowip=%s\n' "$BITCOIND_RPC_ALLOW_IP"
    printf 'rpcport=%s\n' "$BITCOIND_RPC_PORT"
    printf 'rpcuser=%s\n' "$BITCOIND_RPC_USER"
    printf 'rpcpassword=%s\n' "$BITCOIND_RPC_PASS"
    printf 'bind=%s\n' "$BITCOIND_BIND"
    printf 'port=%s\n' "$BITCOIND_P2P_PORT"
    printf 'zmqpubrawblock=tcp://127.0.0.1:%s\n' "$BITCOIND_ZMQ_RAW_BLOCK_PORT"
    printf 'zmqpubrawtx=tcp://127.0.0.1:%s\n' "$BITCOIND_ZMQ_RAW_TX_PORT"
    for node in $BITCOIND_ADDNODE; do
      printf 'addnode=%s\n' "$node"
    done
  } >"$BITCOIND_CONF"
}

start_bitcoind() {
  if ! bitcoind_managed; then
    echo "bitcoind external; using $(bitcoind_rpc_target_url)"
    if [ "$BITCOIND_P2P_PORT_FORWARD_ENABLED" = "1" ]; then
      "$SIM_DIR/scripts/bitcoind-p2p-port-forward.sh" start
    fi
    return 0
  fi

  require_cmd "$BITCOIND_BINARY" "$BITCOIN_CLI_BINARY"

  local pid log
  pid="$(pid_file bitcoind)"
  log="$(log_file bitcoind)"

  if [ -f "$pid" ] && kill -0 "$(cat "$pid")" >/dev/null 2>&1; then
    echo "bitcoind already running: pid $(cat "$pid")"
    wait_for_bitcoind
    return 0
  fi

  write_bitcoind_config
  echo "starting bitcoind rpc=127.0.0.1:${BITCOIND_RPC_PORT} p2p=127.0.0.1:${BITCOIND_P2P_PORT} data=${BITCOIND_DIR}"
  setsid "$BITCOIND_BINARY" -datadir="$BITCOIND_DIR" -conf="$BITCOIND_CONF" </dev/null >"$log" 2>&1 &
  echo $! >"$pid"

  wait_for_bitcoind
  wait_for_bitcoind_p2p
}

start_bitcoind_rpc_proxy() {
  require_env BITCOIND_RPC_HOST BITCOIND_RPC_USER BITCOIND_RPC_PASS
  start_bitcoind

  if ! bitcoind_rpc_uses_proxy; then
    echo "bitcoind-rpc-proxy not needed; using $(bitcoind_rpc_target_url)"
    return 0
  fi

  require_cmd python3

  local pid log target
  pid="$(pid_file bitcoind-rpc-proxy)"
  log="$(log_file bitcoind-rpc-proxy)"
  target="$(bitcoind_rpc_target_url)"

  if [ -f "$pid" ] && kill -0 "$(cat "$pid")" >/dev/null 2>&1; then
    echo "bitcoind-rpc-proxy already running: pid $(cat "$pid")"
    wait_for_bitcoind_rpc_proxy
    return 0
  fi

  echo "starting bitcoind-rpc-proxy $(bitcoind_rpc_proxy_url) -> $target"
  BITCOIND_RPC_TARGET_URL="$target" \
  BITCOIND_RPC_PROXY_HOST="$BITCOIND_RPC_PROXY_HOST" \
  BITCOIND_RPC_PROXY_PORT="$BITCOIND_RPC_PROXY_PORT" \
  BITCOIND_RPC_PROXY_TIMEOUT="$BITCOIND_RPC_PROXY_TIMEOUT" \
  BITCOIND_RPC_USER="$BITCOIND_RPC_USER" \
  BITCOIND_RPC_PASS="$BITCOIND_RPC_PASS" \
    setsid python3 "$SIM_DIR/scripts/bitcoind-rpc-proxy.py" </dev/null >"$log" 2>&1 &
  echo $! >"$pid"

  wait_for_bitcoind_rpc_proxy
}

start_esplora() {
  if ! rln_indexer_uses_local; then
    echo "esplora external; RGB indexer=$RLN_INDEXER_URL"
    return 0
  fi

  require_env BITCOIND_RPC_HOST BITCOIND_RPC_USER BITCOIND_RPC_PASS
  require_cmd "$ESPLORA_BINARY"
  start_bitcoind_rpc_proxy

  local pid log rpc_host rpc_port
  pid="$(pid_file esplora)"
  log="$(log_file esplora)"
  rpc_host="$(bitcoind_rpc_effective_host)"
  rpc_port="$(bitcoind_rpc_effective_port)"

  if [ -f "$pid" ] && kill -0 "$(cat "$pid")" >/dev/null 2>&1; then
    echo "esplora already running: pid $(cat "$pid")"
    wait_for_esplora
    return 0
  fi

  mkdir -p "$ESPLORA_DIR" "$ESPLORA_DB_DIR"

  local -a args
  args=(
    -vv
    --network "$ESPLORA_NETWORK"
    --db-dir "$ESPLORA_DB_DIR"
    --cookie "$BITCOIND_RPC_USER:$BITCOIND_RPC_PASS"
    --daemon-rpc-addr "$rpc_host:$rpc_port"
    --http-addr "$ESPLORA_HTTP_HOST:$ESPLORA_HTTP_PORT"
    --electrum-rpc-addr "$ESPLORA_ELECTRUM_HOST:$ESPLORA_ELECTRUM_PORT"
    --monitoring-addr "$ESPLORA_MONITORING_HOST:$ESPLORA_MONITORING_PORT"
  )
  if bitcoind_managed; then
    args+=(--daemon-dir "$BITCOIND_DIR")
  fi
  case "$ESPLORA_JSONRPC_IMPORT" in
    1|true|TRUE|yes|YES|on|ON) args+=(--jsonrpc-import) ;;
  esac
  case "$ESPLORA_LIGHTMODE" in
    1|true|TRUE|yes|YES|on|ON) args+=(--lightmode) ;;
  esac
  case "$ESPLORA_INDEX_UNSPENDABLES" in
    1|true|TRUE|yes|YES|on|ON) args+=(--index-unspendables) ;;
  esac
  case "$ESPLORA_ADDRESS_SEARCH" in
    1|true|TRUE|yes|YES|on|ON) args+=(--address-search) ;;
  esac
  if [ -n "$ESPLORA_CORS" ]; then
    args+=(--cors "$ESPLORA_CORS")
  fi
  if [ -n "$ESPLORA_EXTRA_ARGS" ]; then
    # shellcheck disable=SC2206
    args+=($ESPLORA_EXTRA_ARGS)
  fi

  echo "starting esplora $(esplora_url) network=${ESPLORA_NETWORK} rpc=${rpc_host}:${rpc_port} db=${ESPLORA_DB_DIR}"
  setsid "$ESPLORA_BINARY" "${args[@]}" </dev/null >"$log" 2>&1 &
  echo $! >"$pid"

  wait_for_esplora
}

ensure_nbxplorer_postgres_db() {
  createdb \
    -h "$NBXPLORER_POSTGRES_HOST" \
    -p "$NBXPLORER_POSTGRES_PORT" \
    -U "$NBXPLORER_POSTGRES_USER" \
    "$NBXPLORER_POSTGRES_DB" >/dev/null 2>&1 || true
  psql \
    -h "$NBXPLORER_POSTGRES_HOST" \
    -p "$NBXPLORER_POSTGRES_PORT" \
    -U "$NBXPLORER_POSTGRES_USER" \
    -d "$NBXPLORER_POSTGRES_DB" \
    -Atqc 'SELECT 1' >/dev/null
}

start_nbxplorer_postgres() {
  if [ "$NBXPLORER_ENABLED" != "1" ]; then
    echo "nbxplorer-postgres skipped; nbxplorer disabled"
    return 0
  fi
  if [ -n "$NBXPLORER_POSTGRES" ] || [ "$NBXPLORER_POSTGRES_MANAGED" != "1" ]; then
    echo "nbxplorer-postgres external"
    return 0
  fi

  require_cmd initdb postgres createdb psql

  local pid log
  pid="$(pid_file nbxplorer-postgres)"
  log="$(log_file nbxplorer-postgres)"

  if [ -f "$pid" ] && kill -0 "$(cat "$pid")" >/dev/null 2>&1; then
    echo "nbxplorer-postgres already running: pid $(cat "$pid")"
    wait_for_nbxplorer_postgres
    ensure_nbxplorer_postgres_db
    return 0
  fi

  mkdir -p "$NBXPLORER_POSTGRES_DIR" "$NBXPLORER_POSTGRES_SOCKET_DIR"
  if [ ! -f "$NBXPLORER_POSTGRES_DIR/PG_VERSION" ]; then
    echo "initializing nbxplorer-postgres data=$NBXPLORER_POSTGRES_DIR"
    initdb \
      -D "$NBXPLORER_POSTGRES_DIR" \
      --auth=trust \
      --encoding=UTF8 \
      --no-locale >"$log" 2>&1
  fi

  echo "starting nbxplorer-postgres ${NBXPLORER_POSTGRES_HOST}:${NBXPLORER_POSTGRES_PORT} db=${NBXPLORER_POSTGRES_DB}"
  setsid postgres \
    -D "$NBXPLORER_POSTGRES_DIR" \
    -h "$NBXPLORER_POSTGRES_HOST" \
    -p "$NBXPLORER_POSTGRES_PORT" \
    -k "$NBXPLORER_POSTGRES_SOCKET_DIR" \
    </dev/null >>"$log" 2>&1 &
  echo $! >"$pid"

  wait_for_nbxplorer_postgres
  ensure_nbxplorer_postgres_db
}

start_nbxplorer() {
  if [ "$NBXPLORER_ENABLED" != "1" ]; then
    echo "nbxplorer disabled; arkd-wallet must use ARKD_WALLET_NBXPLORER_URL"
    return 0
  fi

  require_env BITCOIND_RPC_HOST BITCOIND_RPC_USER BITCOIND_RPC_PASS
  require_cmd nbxplorer
  start_bitcoind_rpc_proxy
  start_nbxplorer_postgres

  local pid log
  pid="$(pid_file nbxplorer)"
  log="$(log_file nbxplorer)"

  if [ -f "$pid" ] && kill -0 "$(cat "$pid")" >/dev/null 2>&1; then
    echo "nbxplorer already running: pid $(cat "$pid")"
    wait_for_nbxplorer
    return 0
  fi

  mkdir -p "$NBXPLORER_DIR"

  local -a args
  args=(
    --chains btc
    --btcrpcurl "$(bitcoind_rpc_service_url)"
    --btcrpcuser "$BITCOIND_RPC_USER"
    --btcrpcpassword "$BITCOIND_RPC_PASS"
    --btcexposerpc true
    --noauth
    --bind "$NBXPLORER_BIND"
    --port "$NBXPLORER_PORT"
    --datadir "$NBXPLORER_DIR"
    --postgres "$(nbxplorer_postgres_connection_string)"
  )
  case "$NBXPLORER_NETWORK" in
    mutinynet|mutiny) args+=(--network mutinynet) ;;
    signet) args+=(--signet) ;;
    testnet) args+=(--testnet) ;;
    regtest) args+=(--regtest --nowarmup) ;;
    mainnet|bitcoin) ;;
    *) args+=(--network "$NBXPLORER_NETWORK") ;;
  esac
  if [ -n "$NBXPLORER_BTCNODEENDPOINT" ]; then
    args+=(--btcnodeendpoint "$NBXPLORER_BTCNODEENDPOINT")
  elif [ -n "$BITCOIND_P2P_HOST" ]; then
    args+=(--btcnodeendpoint "$(bitcoind_p2p_endpoint)")
  fi

  echo "starting nbxplorer $(nbxplorer_url) btc_rpc=$(bitcoind_rpc_service_url)"
  setsid nbxplorer "${args[@]}" </dev/null >"$log" 2>&1 &
  echo $! >"$pid"

  wait_for_nbxplorer
}

start_rgb_proxy() {
  if [ "$RGB_PROXY_ENABLED" != "1" ]; then
    echo "rgb-proxy disabled; RGB nodes will use $RGB_PROXY_ENDPOINT"
    return 0
  fi

  require_cmd rgb-proxy-server

  local pid log
  pid="$(pid_file rgb-proxy)"
  log="$(log_file rgb-proxy)"

  if [ -f "$pid" ] && kill -0 "$(cat "$pid")" >/dev/null 2>&1; then
    echo "rgb-proxy already running: pid $(cat "$pid")"
    wait_for_rgb_proxy
    return 0
  fi

  mkdir -p "$RGB_PROXY_DATA_DIR"
  echo "starting rgb-proxy endpoint=$RGB_PROXY_ENDPOINT"
  APP_DATA="$RGB_PROXY_DATA_DIR" PORT="$RGB_PROXY_PORT" \
    setsid rgb-proxy-server </dev/null >"$log" 2>&1 &
  echo $! >"$pid"

  wait_for_rgb_proxy
}

start_rln_node() {
  local node data daemon_port peer_port pid log bin
  node="$(node_label "$1")"
  data="$(node_dir "$node")"
  daemon_port="$(node_daemon_port "$node")"
  peer_port="$(node_peer_port "$node")"
  pid="$(pid_file "$node")"
  log="$(log_file "$node")"

  if [ -f "$pid" ] && kill -0 "$(cat "$pid")" >/dev/null 2>&1; then
    echo "$node already running: pid $(cat "$pid")"
    wait_for_rln_node "$node"
    return 0
  fi

  bin="$(rln_binary || true)"
  if [ -z "$bin" ]; then
    echo "missing rgb-lightning-node binary; run sim-build-rln or set RLN_BINARY" >&2
    return 2
  fi

  mkdir -p "$data"
  echo "starting $node api=:${daemon_port} peer=:${peer_port} network=${RLN_NETWORK}"
  setsid "$bin" \
    "$data" \
    --daemon-listening-port "$daemon_port" \
    --ldk-peer-listening-port "$peer_port" \
    --network "$RLN_NETWORK" \
    --disable-authentication \
    </dev/null >"$log" 2>&1 &
  echo $! >"$pid"

  wait_for_rln_node "$node"
}

write_lnd_config() {
  local label="$1" rpc_host="${2:-}" rpc_port="${3:-}" dir config neutrino_connect
  dir="$(lnd_dir "$label")"
  config="$(lnd_config_file "$label")"
  mkdir -p "$dir"

  (
    umask 077
    {
      printf '[Application Options]\n'
      printf 'rpclisten=127.0.0.1:%s\n' "$(lnd_rpc_port "$label")"
      printf 'restlisten=127.0.0.1:%s\n' "$(lnd_rest_port "$label")"
      printf 'listen=127.0.0.1:%s\n' "$(lnd_peer_port "$label")"
      printf 'tlsextraip=127.0.0.1\n'
      printf 'alias=%s\n' "$(lnd_alias "$label")"
      printf 'debuglevel=%s\n' "$LND_LOG_LEVEL"
      printf 'nobootstrap=true\n'
      local peer
      for peer in ${LND_ADD_PEERS//,/ }; do
        printf 'addpeer=%s\n' "$peer"
      done
      if [ "$LND_NO_MACAROONS" = "1" ]; then
        printf 'no-macaroons=true\n'
      fi
      if [ "$LND_NO_SEED_BACKUP" = "1" ]; then
        printf 'noseedbackup=true\n'
      fi
      printf '\n[db]\n'
      printf 'db.backend=%s\n' "$LND_DB_BACKEND"
      if [ "$LND_DB_BACKEND" = "sqlite" ]; then
        printf 'db.sqlite.timeout=%s\n' "$LND_DB_SQLITE_TIMEOUT"
        printf 'db.sqlite.busytimeout=%s\n' "$LND_DB_SQLITE_BUSY_TIMEOUT"
        printf 'db.sqlite.maxconnections=%s\n' "$LND_DB_SQLITE_MAX_CONNECTIONS"
      fi
      printf '\n[Bitcoin]\n'
      printf 'bitcoin.active=true\n'
      printf 'bitcoin.node=%s\n' "$LND_CHAIN_BACKEND"
      printf 'bitcoin.signet=true\n'
      printf 'bitcoin.defaultchanconfs=1\n'
      if lnd_uses_neutrino && [ -n "$LND_SIGNET_CHALLENGE" ]; then
        printf 'bitcoin.signetchallenge=%s\n' "$LND_SIGNET_CHALLENGE"
      fi
      if lnd_uses_neutrino && [ -n "$LND_SIGNET_BLOCK_TIME" ]; then
        printf 'bitcoin.signetblocktime=%s\n' "$LND_SIGNET_BLOCK_TIME"
      fi
      case "$LND_CHAIN_BACKEND" in
        bitcoind)
          printf '\n[Bitcoind]\n'
          printf 'bitcoind.rpchost=%s:%s\n' "$rpc_host" "$rpc_port"
          printf 'bitcoind.rpcuser=%s\n' "$BITCOIND_RPC_USER"
          printf 'bitcoind.rpcpass=%s\n' "$BITCOIND_RPC_PASS"
          if lnd_zmq_enabled; then
            printf 'bitcoind.zmqpubrawblock=%s\n' "$LND_ZMQ_PUB_RAW_BLOCK"
            printf 'bitcoind.zmqpubrawtx=%s\n' "$LND_ZMQ_PUB_RAW_TX"
            printf 'bitcoind.zmqreaddeadline=%s\n' "$LND_ZMQ_READ_DEADLINE"
          else
            printf 'bitcoind.rpcpolling=true\n'
            printf 'bitcoind.blockpollinginterval=10s\n'
            printf 'bitcoind.txpollinginterval=10s\n'
          fi
          printf 'bitcoind.estimatemode=ECONOMICAL\n'
          ;;
        neutrino)
          neutrino_connect="$(lnd_neutrino_connect_endpoint)"
          printf '\n[neutrino]\n'
          printf 'neutrino.connect=%s\n' "$neutrino_connect"
          if [ -n "$LND_NEUTRINO_ADD_PEER" ]; then
            printf 'neutrino.addpeer=%s\n' "$LND_NEUTRINO_ADD_PEER"
          fi
          printf 'neutrino.maxpeers=%s\n' "$LND_NEUTRINO_MAX_PEERS"
          case "$LND_NEUTRINO_PERSIST_FILTERS" in
            1|true|TRUE|yes|YES) printf 'neutrino.persistfilters=true\n' ;;
            0|false|FALSE|no|NO) printf 'neutrino.persistfilters=false\n' ;;
          esac
          ;;
        *)
          echo "unknown LND_CHAIN_BACKEND: $LND_CHAIN_BACKEND" >&2
          return 2
          ;;
      esac
      case "$LND_NO_ANCHORS" in
        1|true|TRUE|yes|YES)
          printf '\n[protocol]\n'
          printf 'protocol.no-anchors=true\n'
          ;;
      esac
    } >"$config"
  )
}

start_lnd_node() {
  local label="$1" pid log rpc_host="" rpc_port=""
  require_cmd "$LND_BINARY" "$LNCLI_BINARY"

  case "$LND_CHAIN_BACKEND" in
    bitcoind)
      require_env BITCOIND_RPC_HOST BITCOIND_RPC_USER BITCOIND_RPC_PASS
      validate_lnd_zmq_config
      start_bitcoind_rpc_proxy
      rpc_host="$(bitcoind_rpc_effective_host)"
      rpc_port="$(bitcoind_rpc_effective_port)"
      ;;
    neutrino)
      require_lnd_neutrino_connect
      ;;
    *)
      echo "unknown LND_CHAIN_BACKEND: $LND_CHAIN_BACKEND" >&2
      exit 2
      ;;
  esac

  pid="$(pid_file "$label")"
  log="$(log_file "$label")"

  if [ -f "$pid" ] && kill -0 "$(cat "$pid")" >/dev/null 2>&1; then
    echo "$label already running: pid $(cat "$pid")"
    wait_for_lnd "$label"
    return 0
  fi

  write_lnd_config "$label" "$rpc_host" "$rpc_port"

  if lnd_uses_neutrino; then
    echo "starting $label rpc=:$(lnd_rpc_port "$label") peer=:$(lnd_peer_port "$label") db=${LND_DB_BACKEND} backend=neutrino connect=$(lnd_neutrino_connect_endpoint)"
  elif lnd_zmq_enabled; then
    echo "starting $label rpc=:$(lnd_rpc_port "$label") peer=:$(lnd_peer_port "$label") db=${LND_DB_BACKEND} bitcoind=${rpc_host}:${rpc_port} zmq_rawblock=${LND_ZMQ_PUB_RAW_BLOCK} zmq_rawtx=${LND_ZMQ_PUB_RAW_TX}"
  else
    echo "starting $label rpc=:$(lnd_rpc_port "$label") peer=:$(lnd_peer_port "$label") db=${LND_DB_BACKEND} bitcoind=${rpc_host}:${rpc_port} polling=true"
  fi
  setsid "$LND_BINARY" --lnddir="$(lnd_dir "$label")" --configfile="$(lnd_config_file "$label")" </dev/null >"$log" 2>&1 &
  echo $! >"$pid"

  wait_for_lnd "$label"
}

start_arkd_wallet() {
  require_cmd arkd-wallet
  if [ "$NBXPLORER_ENABLED" = "1" ]; then
    start_nbxplorer
  fi

  local pid log nbx_url
  pid="$(pid_file arkd-wallet)"
  log="$(log_file arkd-wallet)"
  nbx_url="${ARKD_WALLET_NBXPLORER_URL:-$(nbxplorer_url)}"

  if [ -f "$pid" ] && kill -0 "$(cat "$pid")" >/dev/null 2>&1; then
    echo "arkd-wallet already running: pid $(cat "$pid")"
    wait_for_arkd_wallet
    return 0
  fi

  mkdir -p "$ARKD_WALLET_DIR"
  echo "starting arkd-wallet port=${ARKD_WALLET_PORT} network=${ARK_NETWORK} nbxplorer=${nbx_url}"
  ARKD_WALLET_DATADIR="$ARKD_WALLET_DIR" \
  ARKD_WALLET_PORT="$ARKD_WALLET_PORT" \
  ARKD_WALLET_NETWORK="$ARK_NETWORK" \
  ARKD_WALLET_NBXPLORER_URL="$nbx_url" \
  ARKD_WALLET_SIGNER_KEY="$ARKD_WALLET_SIGNER_KEY" \
    setsid arkd-wallet </dev/null >"$log" 2>&1 &
  echo $! >"$pid"

  wait_for_arkd_wallet
}

start_arkd() {
  require_cmd arkd
  start_arkd_wallet

  local pid log
  pid="$(pid_file arkd)"
  log="$(log_file arkd)"

  if [ -f "$pid" ] && kill -0 "$(cat "$pid")" >/dev/null 2>&1; then
    echo "arkd already running: pid $(cat "$pid")"
    wait_for_arkd
    return 0
  fi

  mkdir -p "$ARKD_DIR"
  echo "starting arkd public=:${ARKD_PORT} admin=:${ARKD_ADMIN_PORT} wallet=127.0.0.1:${ARKD_WALLET_PORT}"
  ARKD_DATADIR="$ARKD_DIR" \
  ARKD_PORT="$ARKD_PORT" \
  ARKD_ADMIN_PORT="$ARKD_ADMIN_PORT" \
  ARKD_WALLET_ADDR="127.0.0.1:${ARKD_WALLET_PORT}" \
  ARKD_ESPLORA_URL="$ARK_EXPLORER_URL" \
  ARKD_DB_TYPE="${ARKD_DB_TYPE:-sqlite}" \
  ARKD_EVENT_DB_TYPE="${ARKD_EVENT_DB_TYPE:-badger}" \
  ARKD_LIVE_STORE_TYPE="${ARKD_LIVE_STORE_TYPE:-inmemory}" \
  ARKD_ROUND_MIN_PARTICIPANTS_COUNT="${ARKD_ROUND_MIN_PARTICIPANTS_COUNT:-1}" \
  ARKD_ROUND_MAX_PARTICIPANTS_COUNT="${ARKD_ROUND_MAX_PARTICIPANTS_COUNT:-128}" \
  ARKD_NO_MACAROONS="${ARKD_NO_MACAROONS:-true}" \
  ARKD_NO_TLS="${ARKD_NO_TLS:-true}" \
  ARKD_LOG_LEVEL="${ARKD_LOG_LEVEL:-5}" \
    setsid arkd </dev/null >"$log" 2>&1 &
  echo $! >"$pid"

  wait_for_arkd
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

ensure_ark_lnd_provider_wallet_key() {
  if [ -n "$ARK_LND_PROVIDER_ARK_PRIVATE_KEY_HEX" ]; then
    return 0
  fi

  require_cmd ark jq
  if ! ark_cli "$ARK_LND_PROVIDER_ARK_WALLET" config >/dev/null 2>&1; then
    echo "initializing Ark provider CLI wallet $ARK_LND_PROVIDER_ARK_WALLET for startup key bootstrap"
    ark_cli "$ARK_LND_PROVIDER_ARK_WALLET" init \
      --server-url "$(arkd_url)" \
      --explorer "$ARK_EXPLORER_URL" \
      --password "$ARK_CLI_PASSWORD"
  fi

  local output key
  output="$(ark_cli "$ARK_LND_PROVIDER_ARK_WALLET" dump-privkey --password "$ARK_CLI_PASSWORD" 2>&1)" || {
    printf '%s\n' "$output" >&2
    echo "failed to read Ark provider wallet private key; set ARK_LND_PROVIDER_ARK_PRIVATE_KEY_HEX explicitly" >&2
    return 1
  }
  key="$(printf '%s' "$output" | extract_hex32_secret)"
  if ! [[ "$key" =~ ^[0-9a-fA-F]{64}$ ]]; then
    echo "ark dump-privkey did not return a 32-byte hex private key; set ARK_LND_PROVIDER_ARK_PRIVATE_KEY_HEX explicitly" >&2
    return 1
  fi
  ARK_LND_PROVIDER_ARK_PRIVATE_KEY_HEX="$key"
}

start_ark_lnd_provider() {
  if [ "$ARK_LND_PROVIDER_ENABLED" != "1" ]; then
    echo "ark-lnd-provider disabled"
    return 0
  fi

  require_cmd ark-lnd-swap-provider

  local pid log lnd_node lnd_dir lnd_rpcserver lnd_tls lnd_macaroon
  pid="$(pid_file ark-lnd-provider)"
  log="$(log_file ark-lnd-provider)"
  lnd_node="$ARK_LND_PROVIDER_LND_NODE"
  lnd_dir="$(lnd_dir "$lnd_node")"
  lnd_rpcserver="127.0.0.1:$(lnd_rpc_port "$lnd_node")"
  lnd_tls="$(lnd_tls_cert_file "$lnd_node")"
  lnd_macaroon="$(lnd_admin_macaroon_file "$lnd_node")"

  start_lnd_node "$lnd_node"
  start_arkd
  ensure_ark_lnd_provider_wallet_key

  if [ -f "$pid" ] && kill -0 "$(cat "$pid")" >/dev/null 2>&1; then
    echo "ark-lnd-provider already running: pid $(cat "$pid")"
    wait_for_ark_lnd_provider
    return 0
  fi

  mkdir -p "$ARK_LND_PROVIDER_DIR" "$ARK_LND_PROVIDER_ARK_WALLET_DIR"
  echo "starting ark-lnd-provider $(ark_lnd_provider_url) lnd=${lnd_node} ark_server=${ARK_LND_PROVIDER_ARK_SERVER_URL}"

  ARK_LND_PROVIDER_BIND="$ARK_LND_PROVIDER_BIND" \
  ARK_LND_PROVIDER_DB="$ARK_LND_PROVIDER_DB" \
  ARK_LND_PROVIDER_COMMAND_TIMEOUT_SEC="$ARK_LND_PROVIDER_COMMAND_TIMEOUT_SEC" \
  ARK_LND_PROVIDER_LND_DIR="${ARK_LND_PROVIDER_LND_DIR:-$lnd_dir}" \
  ARK_LND_PROVIDER_LND_RPCSERVER="${ARK_LND_PROVIDER_LND_RPCSERVER:-$lnd_rpcserver}" \
  ARK_LND_PROVIDER_LND_NETWORK="${ARK_LND_PROVIDER_LND_NETWORK:-$LND_NETWORK}" \
  ARK_LND_PROVIDER_LND_TLS_CERT="${ARK_LND_PROVIDER_LND_TLS_CERT:-$lnd_tls}" \
  ARK_LND_PROVIDER_LND_NO_MACAROONS="${ARK_LND_PROVIDER_LND_NO_MACAROONS:-$LND_NO_MACAROONS}" \
  ARK_LND_PROVIDER_LND_MACAROON="${ARK_LND_PROVIDER_LND_MACAROON:-$lnd_macaroon}" \
  ARK_LND_PROVIDER_ARK_WALLET_DIR="$ARK_LND_PROVIDER_ARK_WALLET_DIR" \
  ARK_LND_PROVIDER_ARK_PRIVATE_KEY_HEX="$ARK_LND_PROVIDER_ARK_PRIVATE_KEY_HEX" \
  ARK_LND_PROVIDER_ARK_SERVER_URL="$ARK_LND_PROVIDER_ARK_SERVER_URL" \
  ARK_LND_PROVIDER_ARK_NETWORK="$ARK_LND_PROVIDER_ARK_NETWORK" \
  ARK_LND_PROVIDER_ARK_CONTRACT_VTXO_SATS="$ARK_LND_PROVIDER_ARK_CONTRACT_VTXO_SATS" \
  ARK_LND_PROVIDER_ARK_CONTRACT_CLAIM_DELAY_BLOCKS="$ARK_LND_PROVIDER_ARK_CONTRACT_CLAIM_DELAY_BLOCKS" \
  ARK_LND_PROVIDER_ARK_CONTRACT_REFUND_DELAY_BLOCKS="$ARK_LND_PROVIDER_ARK_CONTRACT_REFUND_DELAY_BLOCKS" \
    setsid ark-lnd-swap-provider </dev/null >"$log" 2>&1 &
  echo $! >"$pid"

  wait_for_ark_lnd_provider
}

while read -r service; do
  case "$service" in
    bitcoind) start_bitcoind ;;
    bitcoind-rpc-proxy) start_bitcoind_rpc_proxy ;;
    esplora) start_esplora ;;
    nbxplorer-postgres) start_nbxplorer_postgres ;;
    nbxplorer) start_nbxplorer ;;
    rgb-proxy) start_rgb_proxy ;;
    node1|node2|node3|node4) start_esplora; start_rgb_proxy; start_rln_node "$service" ;;
    lnd1|lnd2) start_lnd_node "$service" ;;
    arkd-wallet) start_arkd_wallet ;;
    arkd) start_arkd ;;
    ark-lnd-provider) start_ark_lnd_provider ;;
  esac
done < <(services_from_args "$@")
