# Proof Artifacts

This directory holds proof transcripts. The current headline proof omits only local filesystem paths that are not portable across machines.

Protocol identifiers stay visible when they help prove a run: asset ids, payment hashes, pubkeys, Ark addresses, BOLT11 invoices, swap ids, contract ids, and completed-test preimages.

## Current artifacts

- `lightning-ark-bridge-contract-vtxo/20260531T195250Z/`: contract-bound Ark contract VTXO proof from UI run `1780257136-743967ac-caee-4021-877e-ada558470f6e`.

  This is the headline contract-bound proof. Both bridge directions completed with contract funding, contract claim, preimage verification, and Lightning/RGB settlement recorded as true. The proof records the setup duration, full run duration, per-leg payment completion timings, payment preimages, wallet private key material, and UI screenshots from the proof run.
