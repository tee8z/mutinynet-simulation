# Proof Artifacts

This directory holds public proof transcripts. It omits local runtime state,
wallet directories, databases, macaroon material, passwords, and operator-only
paths.

Protocol identifiers stay visible when they help prove a run: asset ids,
payment hashes, pubkeys, Ark addresses, BOLT11 invoices, swap ids, contract ids,
and completed-test preimages.

## Current artifacts

- `lightning-ark-bridge-trustless-contract-vtxo/20260531T180806Z/`:
  trustless Ark contract VTXO proof from UI run
  `1780250859-6acb27f1-c0c7-445a-8a43-c56792c82a88`.

  This is the headline trustless proof. Both bridge directions completed with
  contract funding, contract claim, preimage verification, and Lightning/RGB
  settlement recorded as true.

- `lightning-ark-bridge-baseline-20260530T223914Z/`: baseline mapped-asset
  bridge proof derived from the ignored local run
  `state/tests/lightning-ark-bridge-all-20260530T223914Z/`.

  This artifact is intentionally labeled **non-trustless**. It shows that the
  existing CLI/API-coordinated bridge flow completed in both directions, but it
  does not prove the Ark contract-bound VTXO swap logic.

The baseline proof remains useful as a mapped-asset regression artifact, but the
trustless proof above is the contract-bound VTXO evidence.
