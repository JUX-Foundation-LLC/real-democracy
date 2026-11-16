# vote_stark — unified scalar + ranked zk-STARK vote circuit

A faithful [Winterfell](https://github.com/facebook/winterfell) zk-STARK port of LAIVE's
`vote/smc/circuits/vote.circom` (Semaphore-style anonymous vote), on the locked re-genesis
substrate from `vote/docs/ZK_STARK_REGENESIS_SPEC.md`: **Goldilocks field + RPO256 hash**,
no trusted setup, post-quantum-sound.

**ONE circuit serves every vote shape** (the locked re-genesis decision): a public
`voteMode` switches between a SCALAR choice (Phase 0) and a RANKED choice (Phase 1) without
changing the verifier. Membership and the rotating nullifier are identical in both modes.

* Phase 0 (scalar) — feasibility verdict: a phone proves the depth-20 circuit in ~85 ms.
* **Phase 1 (this) — ranked choice added.** Verdict below.

## What it proves (spec §1)

In zero knowledge, the prover demonstrates that they:

1. **(membership)** know an identity whose `commitment` is a leaf of a depth-20 Merkle tree
   with public `merkleRoot`;
2. **(nullifier)** derived the public `nullifierHash = RPO(externalNullifier,
   identityNullifier, revision)` from the **same** identity — rotating per `revision`;
3. **(cross-revision binding)** for a vote change (`revision > 0`), that the public
   `prevNullifierHash == RPO(externalNullifier, identityNullifier, revision − 1)` of the
   **same** identity (and `prevNullifierHash == 0` on the first cast). This is what makes the
   contract's live-head vote-change check sound — the contract cannot recompute it (`idN` is
   secret). *(Added per the independent audit — finding F1.)*
4. **(choice)**, selected by the public `voteMode`:
   * `voteMode = 0` **scalar**: `voteChoice ∈ [0, 2¹⁶)`, range-checked + bound;
   * `voteMode = 1` **ranked**: a private `rank[0..N)` that is a **valid permutation of
     `[0, N)`** (range + all-distinct), with `voteChoice == RPO(rank)[0]` committing the
     ranking.

Identity scheme (RPO-native, structurally identical to the circom):

```
secret      = RPO(identityNullifier, identityTrapdoor)
commitment  = RPO(secret)                                  // Merkle leaf
nullifier   = RPO(externalNullifier, identityNullifier, revision)
```

Public inputs (17 field elements, exact order in `VERIFIER_NOTES.md §2`): `merkleRoot[4],
externalNullifier, revision, voteMode, choiceCount(N), voteChoice, nullifierHash[4],
prevNullifierHash[4]`.

## Feasibility numbers

`cargo run --release --example feasibility` (native) · `node wasm/run_bench.js` (WASM).
Native = 20-core Linux host; WASM = Node 20, `wasm32-unknown-unknown`, **single-threaded**
(representative of a phone).

| Metric | SCALAR | **RANKED (N=8)** |
|---|---|---|
| Prove — **WASM (phone)** | ~80 ms | **~120 ms** |
| Prove — native (multi-threaded) | ~40 ms | ~52 ms |
| Verify — native / WASM | ~1.6 ms / ~3 ms | ~1.5 ms / ~3 ms |
| Proof size | ~92 KiB | ~91 KiB |
| Security — conjectured | 127-bit | 127-bit |
| Security — proven (UDR / LDR) | 107 / 86-bit | 107 / 86-bit |

Trace: 256 rows × 17 main columns **+ 1 auxiliary column**. Proof options: 96 queries,
blowup 16, grinding 20, quadratic field extension.

> **Verdict: PASS — ranked N=8 phone-proves in ~130 ms, ~15× under the ≲ 2 s target, at the
> same ≥ 96-bit security as scalar. One circuit, one verifier, both vote shapes.**

Notes:
* **Prove-time is independent of N.** The ranked gadget is sized for `N_MAX` and a ranking of
  `N ≤ N_MAX` is zero-padded, so the trace (and proof) are identical for N ∈ {1,…,8}.
* **The prover's 2²⁰ proof-of-work grind dominates WASM prove-time** (and varies a little per
  proof); the STARK proving itself is tens of ms. Lowering `grinding` trades a few proven-λ
  bits for a faster, steadier phone prove.
* Scalar's proof grew vs Phase 0 (~72→~91 KiB): the aux segment is committed in both modes.

## How the ranked gadget works (the Phase-1 addition)

The ranking lives in **one place** — the input row of a new RPO commitment block (block 23,
`state[4..12]` at row 184) — and is used by both:

1. **The commitment.** Block 23 computes `RPO(rank[0..8 padded])`; `voteChoice == digest[0]`
   (boundary). This binds the *ordered* ranking (the permutation argument alone only fixes
   the multiset).
2. **The permutation argument** (range + all-distinct, together). A single **auxiliary
   column** holds the grand product `z = ∏(rankᵢ + γ)` at row 184, and a boundary ties it to
   the public target product `∏(targetᵢ + γ)`, where `target = [0,1,…,N−1,0,…]`. Equality of
   the two products ⟺ `{rank[0..N)} == {0,…,N−1}` ⟺ a valid permutation. The challenge **γ is
   drawn from the quadratic extension after the main trace is committed** (a RAP / Fiat-Shamir
   step), giving ~128-bit soundness — the bad-set is ≤ `N_MAX` points out of `|GF(p²)| ≈ 2¹²⁸`.

### Why a grand product (vs. one-hot matrix or a sorting network)

It has the **cleanest constraint degree and footprint**: ONE aux column and ONE degree-8
constraint (the product over the 8 rank cells), versus ~64 binary cells for a one-hot
permutation matrix or per-comparator range checks for a sorting network (Goldilocks has no
native order, so "≤" needs decomposition). It also reuses the rank cells already present for
the commitment — no extra main columns, no gather across rows.

### Mode-switching without breaking degree-uniformity

Both gadgets' transition constraints are **always active** (the inactive one runs on
trivially-valid dummy data — the scalar range-check decomposes a dummy in ranked mode; the
ranked product runs over zero rank cells in scalar mode). Mode selection happens purely in
the **boundary assertions**, which choose whether `voteChoice` is bound to the scalar
accumulator or to the ranking commitment. (Multiplying a transition constraint by the
`voteMode` constant would collapse its degree to 0 in one mode and fail Winterfell's
declared-vs-actual degree check — hence boundary-only switching.)

## Design decisions (deviations from a literal spec reading, with rationale)

* **N (`choiceCount`) is a PUBLIC input.** The spec lists it as a private witness, but
  `B2_BALLOTBOX_FAMILY.md §9` carries `choiceCount` in the public on-chain `config`, and a
  public N keeps the permutation gadget clean (the verifier computes the public target
  product). The *ranking itself* stays private; only its length (a ballot parameter) is
  public.
* **`voteChoice` (ranked) = `RPO(rank)[0]`** — one field element, matching scalar's single
  `voteChoice`. The ranking is recoverable by the off-chain tally (which needs it anyway);
  anonymity comes from the nullifier, not from hiding the ranking (per the §6 privacy model).
* **Scalar is the N=1 degenerate ranked case** — one unified AIR; `voteMode` only picks which
  output binds to `voteChoice`. (Test: `scalar_is_the_n1_ranked_case`.)

## Locked parameters

| Parameter | Value |
|---|---|
| Field | Goldilocks `p = 2⁶⁴ − 2³² + 1` (quadratic extension for challenges) |
| Hash (in-circuit) | RPO256 (width 12, rate 8, 7 rounds, α = 7) |
| Hash (STARK Merkle/transcript) | Blake3-256 (see `VERIFIER_NOTES.md §1`) |
| Merkle depth | 20 (≤ ~1.05M eligible voters) |
| Scalar range | `[0, 2¹⁶ − 1]` |
| Ranked `N_MAX` | 8 (tunable at the cut) |
| Security target | λ ≥ 96-bit |

## Pinned crate versions

* `winterfell = 0.13.1` — STARK prover/verifier (used here with an auxiliary trace segment / RAP).
* `miden-crypto = 0.19.8` — RPO256 + Merkle reference oracle. **0.19.8 is the last
  winterfell-based release** (0.20+ moved to Plonky3); it shares `winter-math 0.13` with
  winterfell 0.13.1, so `miden_crypto::Felt` *is* `winterfell::math::fields::f64::BaseElement`.
  Used only in tests, proving our in-AIR RPO is byte-identical to canonical RPO256.

`Cargo.lock` is committed.

## Layout

```
src/rpo.rs        RPO256 over a generic field; byte-identical to miden-crypto (proven by tests).
src/air.rs        VoteAir — trace, transition + aux constraints, boundary assertions.
src/prover.rs     Trace builder, aux-trace builder, Prover impl, prove/verify helpers.
src/scheme.rs     Off-circuit identity / commitment / nullifier / Merkle-root / ranked commitment.
src/rap_trace.rs  Minimal aux-segment-capable trace table (RAP).
src/wasm.rs       wasm-bindgen entry points (scalar + ranked) for in-browser proving.
tests/            rpo_vs_miden, roundtrip (scalar + tamper), vectors, ranked (permutation tests).
examples/feasibility.rs   native benchmark (scalar + ranked).
wasm/run_bench.js         node harness for the WASM benchmark.
VERIFIER_NOTES.md         handoff for the on-chain verifier author.
```

## Running

```bash
cargo test                                   # all tests (miden-crypto = RPO oracle)
cargo run --release --example feasibility
wasm-pack build --target nodejs --release --no-default-features --features wasm
node wasm/run_bench.js
```

## Security audit (PR #173) — disposition

An independent adversarial audit (`vote/docs/zk-stark-audit/ZK_STARK_AUDIT.md`,
`tests/audit_adversarial.rs`) found the core circuit sound in release, with fixes needed
before the cut. This crate now addresses them:

| ID | Status |
|----|--------|
| **F1** (HIGH, vote-overwrite) | **FIXED** — in-circuit `prevNullifierHash` binding (block 24 + masking). |
| **F6** (debug-prover panic on index-0 / "0" vote) | **FIXED** — degree-floor injection keeps columns full-degree; both prove + verify in debug *and* release now. |
| **F2/F8** (N out of range) | **FIXED** — `choiceCount` clamped; `verify()` rejects `N>N_MAX` cleanly (no panic). On-chain verifier must also reject `N∉[1,N_MAX]`. |
| **F7** (commitment 2nd word) | **FIXED** — `state[8..12]@8` pinned to 0 (defense-in-depth). |
| **F9** (doc drift) | **FIXED** — `air.rs` comments + `VERIFIER_NOTES` reconciled to the code. |
| F3 (`voteMode∉{0,1}`), F5 (per-ballot `maxValue`) | **Documented** — consumer / on-chain verifier validates (see `VERIFIER_NOTES §2/§6`). |
| F4 (ranking public), F10 (64-bit commitment) | **By design / accepted** for the ≤8! domain. |

## Out of scope (explicitly not built here)

* **The on-chain verifier** (Solidity-interim or Besu precompile) — a separate leg, gated on a
  host decision; see `VERIFIER_NOTES.md`. This crate is the off-chain reference verifier.
* **The contract-side vote-change plumbing** — live-head tracking + revision monotonicity.
  The *cryptographic* binding (`prevNullifierHash == RPO(extNull, idN, revision−1)`) is now
  in-circuit (F1); the contract consumes it.
* Backend / contract integration; changes to existing contracts or circom.

## Conjectured vs. proven security

The headline λ is **conjectured** security — the standard metric for production STARKs
(StarkWare, Polygon, Miden). The more conservative *provable* FRI bound (107/86-bit) is shown
too; both clear 96-bit. Prove-time headroom (>15×) means security can be raised at the cut.
