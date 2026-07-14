# RGB/Ark Hashlock Notes

Date: 2026-06-12

Branch: `feat/rgb-ark-hashlock-stub`

## Current Artifact

`tools/rgb-htlc-kit` is a real RGB/Sonic playground. It builds an issuer,
creates a local contract ledger, locks owned state with `CellLock`, rejects a
wrong witness, and accepts the correct witness.

The default mode is still `witness-equality`:

```bash
scripts/rgb-htlc-kit.sh --out state/tests/rgb-htlc-kit-demo
```

A future Ark-compatible mode is stubbed:

```bash
scripts/rgb-htlc-kit.sh \
  --out state/tests/rgb-htlc-kit-demo \
  --hashlock-mode ark-sha256-stub
```

That mode intentionally errors after computing the intended 32-byte Ark-style
preimage and SHA256 hash. It marks the exact code path where VM/runtime
execution needs to replace the current witness-equality lock.

## Target Contract Shape

The RGB side should lock owned state with:

- `CellLock.aux`: the 32-byte Ark HTLC hash `H`.
- Input witness: the 32-byte preimage `P`.
- Lock condition: `SHA256(P) == H`.

The RGB `AuthToken` should not carry the Ark hash. It is field-backed and
exposed as a 30-byte token in the current Ultrasonic API. The full 32-byte hash
belongs in `CellLock.aux` or an equivalent lock-data field.

## Search Findings

No public implementation was found for an Ark-compatible RGB contract HTLC that
removes Lightning from the middle.

Relevant public artifacts:

- `RGB-Tools/rgb-lightning-node`: real RGB-over-Lightning implementation, but it
  keeps Lightning channels/HTLCs and anchors RGB state through an extra
  commitment transaction output.
  <https://github.com/RGB-Tools/rgb-lightning-node>
- `UTEXO-Protocol/rgb-lightning-node`: fork of the RGB Lightning node path, not
  a standalone RGB/Ark contract HTLC.
  <https://github.com/UTEXO-Protocol/rgb-lightning-node>
- `AluVM/sonic/examples/dao/dao.con`: contains intended Contractum-style syntax
  for `sha256 preimage =?= $`, but the matching Rust verifier path is still a
  `todo!()`.
  <https://github.com/AluVM/sonic/blob/2d311c0efaed83d64b46ef40198fcd8234a2306f/examples/dao/dao.con>
- `RGB-WG/contractum-lang`: language/prototype repo, not a released compiler
  path for this flow.
  <https://github.com/RGB-WG/contractum-lang>

GitHub searches for `CellLock sha256`, `CellLock preimage`, `rgb htlc sha256`,
and `Ark RGB swap` did not turn up a finished implementation.

## Missing Piece

The current RGB/AluVM stack can load lock data and witness data, and the kit
already proves that a per-input `CellLock` script gates state spending. The
missing part is contract-level SHA256 execution over witness bytes.

The practical continuation path is:

1. Add or locate a VM/runtime primitive that can evaluate SHA256 inside the RGB
   lock script.
2. Encode the 32-byte Ark hash into `CellLock.aux`.
3. Change the witness type from the current demo `u64` field value to a 32-byte
   preimage.
4. Replace `witness_equality_cell_lock` in `tools/rgb-htlc-kit/src/main.rs`
   with a hashlock cell lock that checks `SHA256(preimage) == CellLock.aux`.
5. Keep test vectors in the generated `rgb-htlc-kit.json`: wrong preimage
   rejected, correct preimage accepted, and the same hash usable by Ark.

## Current Limitation

Until the SHA256 primitive exists in the validation path, the RGB contract can
demonstrate locked owned-state spending but cannot enforce the same hashlock as
an Ark VHTLC.
