# RGB HTLC Kit

This is the direct RGB path for the RGB/Ark contract work. It does not use
Contractum.

`tools/rgb-htlc-kit` builds a real Sonic/RGB issuer in Rust, saves it as an
importable `RgbArkHtlc.issuer`, creates a local RGB contract ledger, locks owned
state with a real `CellLock`, proves a wrong witness is rejected, then claims
with the correct witness.

Run:

```bash
scripts/rgb-htlc-kit.sh --out state/tests/rgb-htlc-kit-demo
```

Artifacts:

- `RgbArkHtlc.issuer`: importable by `rgb-wallet` / `rgb`.
- `RgbArkHtlc.contract/`: local RGB/Sonic ledger for the demo contract.
- `rgb-htlc-kit.json`: contract IDs, operation IDs, lock/claim addresses, and
  the rejected wrong-witness error.
- `rgb-wallet-import.sh`: imports the issuer into a local `rgb` wallet store.

The current proof is a real RGB witness lock, not yet an Ark-compatible SHA256
HTLC. The published AluVM/zk-AluVM instruction set used by RGB v0.12 exposes
field arithmetic and equality, but not SHA256. That means the RGB lock can
enforce "the witness equals the locked field value" today, while exact
`SHA256(P) == H` parity with an Ark VHTLC needs a VM hash primitive or a
separate proof linking the RGB field witness to the Ark SHA256 hash.

The unfinished Ark hashlock path is stubbed behind:

```bash
scripts/rgb-htlc-kit.sh --hashlock-mode ark-sha256-stub
```

It intentionally errors with the computed Ark-style preimage/hash pair and marks
the code path that should be replaced with contract-level SHA256 execution.
Continuation notes live in `docs/rgb-ark-hashlock-notes.md`.

The stock `rgb` CLI can import and list the issuer:

```bash
cd state/tests/rgb-htlc-kit-demo
RGB=rgb ./rgb-wallet-import.sh
```

Locked HTLC operations are driven by this small binary because the current
`rgb-wallet` transfer helper creates owned outputs with `lock: None`.
