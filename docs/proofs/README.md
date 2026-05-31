# Proof Artifacts

This directory holds public proof transcripts. It omits local runtime state,
wallet directories, databases, macaroon material, passwords, and operator-only
paths.

Protocol identifiers stay visible when they help prove a run: asset ids,
payment hashes, pubkeys, Ark addresses, BOLT11 invoices, swap ids, contract ids,
and completed-test preimages.

## Current artifacts

- `lightning-ark-bridge-baseline-20260530T223914Z/`: baseline mapped-asset
  bridge proof derived from the ignored local run
  `state/tests/lightning-ark-bridge-all-20260530T223914Z/`.

  This artifact is intentionally labeled **non-trustless**. It shows that the
  existing CLI/API-coordinated bridge flow completed in both directions, but it
  does not prove the Ark contract-bound VTXO swap logic.

## Reserved headline proof

- `lightning-ark-bridge-trustless-contract-vtxo/`: placeholder and acceptance
  checklist for the future public proof after the bridge tests are rerun with
  the Ark contract-bound VTXO logic.

The headline public proof of trustless swapping should come from the future
contract-bound VTXO artifact, not from the baseline mapped-asset artifact.
