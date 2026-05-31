# Trustless Contract-Bound VTXO Proof

Status: pending future rerun.

This directory is reserved for the headline public proof of trustless
Lightning/Ark swapping after the tests are rerun with the Ark
contract-bound VTXO logic. Do not populate or promote this proof using the
baseline CLI-coordinated artifact from
`state/tests/lightning-ark-bridge-all-20260530T223914Z/`.

## Required artifact shape

When the contract-bound VTXO test run exists, add a timestamped child directory,
for example:

```text
docs/proofs/lightning-ark-bridge-trustless-contract-vtxo/<run-id>/
  README.md
  status-snippets.json
```

The run `README.md` should include:

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

## Trustless acceptance criteria

A future artifact can be treated as the public headline proof only if it shows:

1. The test used the Ark contract-bound VTXO implementation, not only
   provider-coordinated CLI release steps.
2. Both bridge directions complete with the expected final statuses.
3. The transcript demonstrates how the contract binding protects settlement
   ordering without relying on private wallet state, passwords, macaroons, local
   paths, or operator-only runtime files.
4. Any abort/refund or non-cooperative path required by the implementation is
   either exercised or explicitly linked to a separate proof artifact.

Until those conditions are met, the baseline proof remains a regression artifact
only and should be described as non-trustless.
