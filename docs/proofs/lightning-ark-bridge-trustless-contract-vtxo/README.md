# Trustless Contract-Bound VTXO Proof

Status: validated locally.

This directory contains the headline public proof of trustless Lightning/Ark
swapping with the Ark contract-bound VTXO logic.

## Artifact Shape

Each proof run lives in a timestamped child directory:

```text
docs/proofs/lightning-ark-bridge-trustless-contract-vtxo/<run-id>/
  README.md
  status-snippets.json
```

Current proof:

- `20260531T180806Z/`

The run `README.md` includes:

- exact test command and output directory;
- commit or build identifier for the provider and scripts under test;
- public topology and amounts;
- step-by-step path progression for each tested direction;
- CLI/API transcript with local-only secrets and paths omitted;
- explicit evidence that the Ark side used contract-bound VTXO logic;
- success criteria and observed final statuses.

The `status-snippets.json` should include only stable, public-safe fields:

- run id and mode;
- asset ids, payment hashes, and pubkeys;
- swap ids or contract ids;
- contract-bound VTXO status progression;
- Lightning invoice/payment status progression;
- RGB payment/invoice status progression;
- timestamps;
- redaction list.

## Trustless Acceptance Criteria

A proof artifact can be treated as the public headline proof only if it shows:

1. The test used the Ark contract-bound VTXO implementation, not only
   provider-coordinated CLI release steps.
2. Both bridge directions complete with the expected final statuses.
3. The transcript demonstrates how the contract binding protects settlement
   ordering without relying on private wallet state, passwords, macaroons, local
   paths, or operator-only runtime files.
4. Refund timeout coverage is either exercised or explicitly marked as not part
   of the fast-path proof.
