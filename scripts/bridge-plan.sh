#!/usr/bin/env bash

set -euo pipefail

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

cat <<EOF
RGB asset <-> Ark asset experiment plan

This setup does not make RGB and Ark mutually aware. It adds a local
ark-lnd-provider service that treats lnd2 as the Lightning-side swap provider
and keeps swap state in SQLite while Ark-side provider operations use Rust Ark
gRPC/client code. Simulation bootstrap uses Ark CLI for local wallet setup and
Ark asset issuance. RGB asset issuance and RGB-side swap logic stay inside the
RGB Lightning node: the Ark provider sees only plain Lightning invoices.

Forward flow:
  <rgb wallet> -> <rgb asset node> -> <rgb market maker/swap> -> <lnd1> -> <lnd2> -> <ark swap provider> -> <ark>

Reverse flow:
  <ark> -> <ark swap provider> -> <lnd2> -> <lnd1> -> <rgb market maker/swap> -> <rgb asset node> -> <rgb wallet>

1. RGB asset leg
   - issue an RGB asset on r1
   - use rmm/node4 as the RGB market-maker node
   - move it through RGB-aware channels using mapped BTC invoices
   - record RGB asset balances before and after

2. LND settlement leg
   - use lnd1/lnd2 as plain BTC Lightning nodes
   - give rmm a BTC channel to lnd1, with lnd1 connected publicly to lnd2
   - verify RLN <-> LND channel compatibility with BTC-only invoices
   - use ark-lnd-provider to create mapped hold invoices, pay invoices, settle, or cancel

3. Ark asset leg
   - initialize ark-maker and ark-taker wallets against local arkd
   - issue or reissue an Ark asset for the provider and taker wallets
   - map Lightning invoices to Ark asset sends through ark-lnd-provider

Useful commands:

  sim-build-rln
  sim-start all
  sim-init-unlock all
  sim-faucet-auth
  sim-faucet-fund all
  RGB_MM_ASSET_ID=<rgb_asset_id> sim-setup-market-maker
  BRIDGE_TEST_ARK_ASSET_ID=<ark_asset_id> sim-rgb-asset-to-ark-asset
  sim-ark-asset-to-rgb-asset

RGB API examples:

  r1 POST /issueassetnia '{"ticker":"USDX","name":"Demo USD","amount":1000,"precision":0}'
  r1 GET /listassets
  r1 GET /nodeinfo
  rmm GET /nodeinfo

LND examples:

  lnd1 getinfo
  lnd2 addinvoice --amt 1000
  lnd1 payinvoice <bolt11>

Provider examples:

  provider GET /health
  provider GET /v1/swaps
  provider POST /v1/swaps/ln-to-ark '{"amount_sat":1000,"asset_id":"<asset_id>","asset_amount":"100","ark_recipient":"<ark_address>"}'
  provider POST /v1/swaps/ark-to-ln '{"bolt11":"<rgb_mapped_invoice>","amount_sat":1000,"asset_id":"<asset_id>","asset_amount":"100","execute":false}'
  provider POST /v1/swaps/<swap_id>/settle-ln '{"preimage":"<32_byte_hex_preimage>"}'
  provider POST /v1/swaps/<swap_id>/cancel-ln

Ark examples:

  arkmaker receive
  arkmaker issue --amount 1000 --control-asset-amount 1 --password "$ARK_CLI_PASSWORD" --metadata ticker=ARKUSD
  arktaker receive
  arkmaker send --to <arktaker_offchain_address> --asset-id <asset_id> --amount 100 --password "$ARK_CLI_PASSWORD"
  arktaker balance

The success criterion for the repeatable tests is one mapped invoice per flow:
  RGB pays a plain Lightning invoice with an RGB asset and the Ark recipient is
  funded, then Ark pays a plain Lightning invoice and the RGB recipient receives
  the mapped RGB asset.
EOF
