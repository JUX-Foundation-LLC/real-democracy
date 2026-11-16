# On-chain STARK verifier — implementation notes (for re-audit)

Verifier-side companion to `vote/zk/vote_stark/VERIFIER_NOTES.md` (the circuit-side brief). This
document maps the Solidity verifier to the Winterfell 0.13.1 protocol it must reproduce, marks
exactly what is **implemented + tested** versus **scaffolded**, and pins the two seams the brief
required: the pluggable **Blake3 host** and the generic **AIR boundary**.

> **Phase-1 honesty statement.** A byte-exact, proof-*accepting* Winterfell verifier is a
> multi-week build. Per the agreed scope ("foundation PR now, iterate after") this PR ships the
> **real, tested foundation** — field arithmetic, the audit bounds-gate, the strict options gate,
> the 17-input codec, the §4 boundary layout, the pluggable hash, the byte reader — plus the
> FRI/DEEP/deserialization **core scaffolded to a precise Winterfell→Solidity map**. `verify()`
> runs every implemented gate and then **reverts at the FRI core**; it can never be mistaken for
> accepting a proof it has not actually checked. Nothing here claims end-to-end verification.

---

## 1. File map

```
vote/smc/contracts/core/governance/zk/
  Goldilocks.sol              base field p=2^64-2^32+1 + GF(p^2)         IMPLEMENTED + TESTED
  VoteStarkPublicInputs.sol   17-element codec + audit bounds (F2/F3/F5/F8) IMPLEMENTED + TESTED
  IHasher.sol                 Blake3 host interface (the swap point)     INTERFACE
  Blake3PrecompileHasher.sol  production adapter -> Besu precompile      IMPLEMENTED (plumbing tested)
  KeccakHasher.sol            gas/structural baseline (NOT proof-accepting) IMPLEMENTED + TESTED
  IStarkAir.sol               generic-AIR boundary (spec §8)             INTERFACE
  VoteStarkAir.sol            vote_stark AIR descriptor                  params+boundary+periodicValuesAt+evaluateTransition DONE (full AIR)
  VoteStarkPeriodic.sol       31 periodic columns at z                   IMPLEMENTED + BYTE-EXACT TESTED (FRI core pt.5)
  ProofReader.sol             little-endian byte reader                  primitives + readUsizeVar IMPLEMENTED + TESTED
  Transcript.sol              Fiat-Shamir coin (DefaultRandomCoin)       IMPLEMENTED + BYTE-EXACT TESTED (FRI core pt.1)
  RpoConstraints.sol          RPO round constraint over GF(p^2)          IMPLEMENTED + BYTE-EXACT TESTED (FRI core pt.4)
  StarkVerifier.sol           generic FRI verifier core                  gates + FULL Fiat-Shamir chain (seed→query positions) DONE; verification math SCAFFOLD
```

(VoteStarkAir deployed bytecode: **13,223 B** — comfortably under EIP-170's 24,576 B, so the sparse
periodic design + inlined RPO/periodic libraries fit without an SSTORE2 data contract.)

Tests: `vote/smc/test/zk/*.test.js` (102 passing). Fixtures: `vote_stark_fixtures.json` (real proofs +
winter-math field refs, `emit_verifier_fixtures.rs`); `transcript_ref.json` (the real
`DefaultRandomCoin<Blake3_256>` draw sequence + its genuine-Blake3 preimage→digest table,
`transcript_ref.rs`); `seed_draw_ref.json` (real proofs' full challenge chain — seed/γ/z/DEEP/FRI-α/
query-positions — + genuine-Blake3 table, `seed_draw_ref.rs`). Benchmark: `vote/smc/scripts/zk_bench.js`.

---

## 2. What is proven in this PR

### 2.1 Field arithmetic = winter-math, byte-for-byte
`Goldilocks.sol` implements `f64::BaseElement` and `QuadExtension<BaseElement>` (irreducible
`x^2 - x + 2`, so `β^2 = β - 2`). Base reduction is free: `p < 2^64`, any product of two canonical
elements is `< 2^128 < 2^512`, so EVM `mulmod`/`addmod` reduce exactly. The tests check the
Solidity output against reference values **computed by winter-math itself** (the authority) in the
fixture emitter — `mul`, `inv`, `exp7` (the RPO degree-7 S-box), and GF(p^2) `extMul`/`extSquare`/
`extInv` — plus algebraic invariants on-chain (`x·x⁻¹=1` in both fields, `frob∘frob=id`,
`extSquare=extMul(x,x)`, the non-canonical `[p, 2^64)` gap is rejected).

### 2.2 The audit bounds-gate (the load-bearing security property of this PR)
`VoteStarkPublicInputs.validate` is the rejection gate the on-chain audit requires — the circuit
does **not** self-enforce these:

| Audit finding | Rule enforced | Test |
| --- | --- | --- |
| **F3 / S11** | `voteMode ∈ {0,1}` (AIR treats any `≠1` as scalar) | rejects `voteMode=2`, `voteMode=p-1` |
| **F2 / F8 / S10** | ranked `1 ≤ choiceCount ≤ N_MAX(8)` (circuit silently clamps N) | rejects `0`, `9`; accepts `8` (inclusive) |
| (scalar wire rule) | scalar `choiceCount == 0` | rejects scalar with `choiceCount=1` |
| (canonicality) | every element `< p` | rejects `p`, `2^64-1` at any index |
| **F5** | scalar `voteChoice ≤ ballot maxValue` | `requireScalarMax` — caller-supplied bound |

`validate` accepts the **real** scalar and ranked public inputs emitted by the prover. The gate is
reachable on its own (`StarkVerifier.checkPublicInputs`) and runs **before** any proof bytes are
touched in `verify` (test: a bad `voteMode` reverts with the codec error, not the FRI-core error).

**S9 (externalNullifier domain separation)** is a *protocol* obligation, not a contract bound: the
nullifier binds `externalNullifier` and `revision` (wire indices 4 and 5; enforced in-circuit at
rows 176/192 — see §4 boundary layout). The integrating ballotbox MUST derive `externalNullifier`
as a per-jurisdiction/per-ballot domain tag so a nullifier from one ballot cannot replay into
another. The verifier exposes the value positionally; it cannot itself know the correct domain tag.

### 2.3 The strict options gate (§3) — parsed from the proof + wired into `verify` (V7)
`requireAcceptableOptions` is `AcceptableOptions::OptionSet([pinned])` on-chain: it accepts **only**
`{blowup 16, queries 40, grinding 20, ext-degree 2, FRI folding 4, FRI remainder ≤31}` (queries
re-pinned 96 → 40 by the external auditor — see §9) and reverts on any single deviation (tested
per-field). Per AUDIT **V7**, `verify()` now **parses these options
out of the proof's `Context`** (`parseProofOptions`) and enforces them — tested against the real
proofs (parsed `{16,96,20,2,4,31}`) and a proof with a downgraded `blowup`/`numQueries` byte
(rejected). Per AUDIT **V2** the reference set is **pinned verifier-side** (immutable), not read
from the circuit-supplied AIR. This closes the "downgrade the soundness parameters" attack for real.

### 2.4 The §4 boundary layout against real inputs
`VoteStarkAir.boundaryAssertions` reproduces `VoteAir::get_assertions` exactly: common 49 + mode
tail (scalar +2 range; ranked +1 digest + `(N_MAX−N)` padding). For the real fixtures the assertion
**count** matches `numMainAssertions` (scalar 51, ranked-N4 54) and the **values** land at the
audited `(column,row)`: `merkleRoot@row175`, `nullifierHash@row183`, scalar `voteChoice@(rca,row16)`,
ranked `voteChoice@(digest[0],row191)`; all imaginary parts zero (base-field targets).

---

## 3. Winterfell verification protocol → Solidity (the map the core follows)

`StarkVerifier.verify` executes the RAP-aware sequence of `winter-verifier` 0.13.1
(`perform_verification` in its `lib.rs`). The exact order + each step's module + status:

**Seed (corrected).** The coin is seeded from FIELD ELEMENTS, not raw bytes:
`coin = DefaultRandomCoin::new( context.to_elements() ‖ pub_inputs.to_elements() )`, i.e.
`seed = Blake3.hash_elements(...)`. For vote_stark `context.to_elements()` is the 8 elements
`[0x11010101, 256, 1, 0xffffffff, num_constraints, 0x02041f10, 20, 40]` (trace layout; modulus split
into two halves via `from_bytes_with_padding`; `num_constraints`; options packed as
`ext<<24|friFold<<16|friRem<<8|blowup`, grinding, queries=40) followed by the 17 public inputs.

| # | Step (winter-verifier `perform_verification`) | Module | Status |
| --- | --- | --- | --- |
| 0 | `coin = new(context.to_elements ‖ pub.to_elements)` | `_parseContext` + `Transcript.init` | **DONE** (pt.2, byte-exact on real proofs) |
| 1 | read main + aux trace commitments; `reseed(main)` | `_readEarlyCommitments` + `Transcript.reseed` | **DONE** (pt.2) |
| 2 | RAP: draw aux rand `γ` (`numAuxRand=1` in `E`); `reseed(aux)` | `Transcript.drawElement` | **DONE** (pt.2, γ byte-exact) |
| 3 | draw composition coeffs; read constraint commitment; `reseed` | `Transcript.drawElements` | **DONE** (pt.2); **AUDIT C1**: count RECOMPUTED from the AIR (`constraintCompositionCoeffCount`) + asserted == proof's `num_constraints` (not trusted) |
| 4 | `z = draw::<E>()`; read OOD frame; `reseed(hash_elements(merge_ood_evaluations))` | `_readOodEvals` + `Transcript` | **DONE** (pt.3, byte-exact); the OOD frame VALUES feed step 9's eval |
| 5 | draw DEEP coeffs (`trace_width + num_quotients`) | `Transcript.drawElements` | **DONE** (pt.3, count derived from the OOD frame) |
| 6 | FRI commit: per layer (+remainder) read root, `reseed`, draw `α` | `_readCommitments` + `Transcript` | **DONE** (pt.3, αs byte-exact) |
| 7 | read `pow_nonce` (proof's last 8 B); `check_leading_zeros(nonce) ≥ grinding(20)` | `Transcript.checkLeadingZeros` | **DONE** (pt.3, PoW verified on real proofs) |
| 8 | `query_positions = draw_integers(96, lde=4096, nonce)`; sort; dedup | `Transcript.drawIntegers` | **DONE** (pt.3, 96 positions byte-exact); sort/dedup trivial |
| 9 | verify main/aux/constraint Merkle openings; OOD constraint eval (`evaluateTransition`); DEEP-compose; FRI low-degree | `IHasher.merge` + `IStarkAir` + FRI core | **pending — the verification MATH, all that's left** |

**Part 1 — the Fiat-Shamir transcript, byte-exact.** `Transcript.sol` ports
`DefaultRandomCoin<Blake3_256<f64>>` verbatim; `Transcript.unit.test.js` asserts every primitive
matches winterfell's real coin byte-for-byte (`hash_elements`, `merge`, `merge_with_int`, base/quad
draws with canonical rejection, `check_leading_zeros`'s trailing-zeros-of-LE quirk, `draw_integers`).

**Part 2 (this PR) — the seed + the real draw chain through the OOD point, byte-exact on REAL
proofs.** `_parseContext` reconstructs `context.to_elements()` from the proof (trace-layout pack,
modulus split via `from_bytes_with_padding`, `num_constraints` via the winter-utils var-length
`usize` = `ProofReader.readUsizeVar`, options pack); `initialSeed` = `hash_elements(that ‖ pub)`;
`deriveChallengesThroughZ` reads the main/aux/constraint roots from `Commitments` and runs
`reseed(main) → γ → reseed(aux) → draw num_constraints coeffs → reseed(constraint) → z`.
`FriCoreSeedDraw.test.js` asserts the parsed `context.to_elements`, the seed, **γ**, and **z** equal
winterfell's for the real scalar + ranked proofs, with the on-chain coin running on GENUINE Blake3
(the `seed_draw_ref.rs` table). `verify()` runs this path then reverts post-OOD.

**Part 3 (this PR) — the FULL challenge chain through the query positions, byte-exact on REAL
proofs.** `deriveQueryPositions` continues past z: `_skipToOod` skips the variable-length
`trace_queries(×2)` + `constraint_queries` (each a pair of var-length `Vec<u8>`s) to reach the OOD
frame; `_readOodEvals` reads both OOD blobs and assembles `merge_ood_evaluations` order
(`trace_cur ‖ quot_cur ‖ trace_next ‖ quot_next`, `num_quotients` derived from the blob); the OOD
reseed is `hash_elements` of that; then DEEP coeffs (`trace_width + num_quotients`), the FRI commit
phase (per layer + remainder: `reseed(root) → draw α`, roots from `Commitments`), the **grinding
check** on `pow_nonce` (the proof's last 8 bytes), and the 96 `draw_integers` query positions.
`FriCoreChallenges.test.js` asserts **z, every FRI α, and all 96 query positions** match winterfell
byte-for-byte on genuine Blake3, and that the real `pow_nonce` satisfies the 20-bit grinding factor.
**This completes the entire Fiat-Shamir / challenge layer** — after the query positions the verifier
draws nothing more from the coin. All that remains (step 9) is the verification MATH.

**Part 4 (this PR) — the RPO round constraint over GF(p^2), the heart of the verification math.**
`RpoConstraints.sol` ports `rpo.rs` (`apply_mds`, `pow7`, `enforce_round`) byte-exact: the degree-7
S-box `x^7`, the 12×12 LEFT-CIRCULANT MDS (12 constants), and the per-element round constraint
`next_i^7 − ARK2_i − (MDS·(MDS·cur + ARK1)^7)_i`, accumulated into `result` and gated by a periodic
`flag`. The bulk of vote_stark's 34 main transition constraints ARE RPO rounds, so this is the core
of `evaluateTransition`. `RpoConstraints.unit.test.js` checks `pow7`, `applyMds`, and `enforceRound`
(zero + nonzero accumulator, and `flag==0` ⇒ no-op) against the circuit's own code on GF(p^2) inputs
with nonzero imaginary parts (`rpo_round_ref.rs`). Not yet wired into `evaluateTransition` (which also
needs the periodic ARK/flag values at z + the non-RPO gadgets — the next part).

**Part 5 (this PR) — the periodic columns at z (`periodicValuesAt`, the other `evaluateTransition`
input).** `VoteStarkPeriodic.sol` evaluates all 31 periodic columns at the OOD point, byte-exact with
winterfell's `evaluate_constraints`. Two regimes: the 25 period-8 columns (hash_flag + ARK1[12] +
ARK2[12], dense) use baked 8-coeff polys (dumped from the AIR's own `get_periodic_column_polys()`),
Horner-evaluated at `z^32`; the 6 period-256 selectors are sparse (≤16 nonzero rows — `f_bind0`:1,
`f_null`:2, `rc_active`:16, `f_break`:3, `f_perm`:1, `f_prevbind`:1), so they use the
barycentric-over-subgroup formula on their nonzero rows only — ~24 terms total instead of 1,536 dense
coefficients, which keeps constants tiny (no SSTORE2 data contract, well under any code-size limit).
The barycentric formula was **asserted equal to winterfell's `eval` in Rust** (`periodic_ref.rs`)
using winterfell's exact 256-th root of unity before the port; `VoteStarkPeriodic.unit.test.js`
confirms all 31 values byte-for-byte on-chain. With parts 4 + 5, both `evaluateTransition` inputs (the
RPO round + the periodic values) exist; part 6 assembles the 34 main + 1 aux constraints from them.

**Part 6 (this PR) — the full transition-constraint system (`evaluateTransition`).**
`VoteStarkAir.evaluateTransition` now returns all 34 main + 1 aux constraint evaluations at the OOD
frame, byte-exact with air.rs `evaluate_transition` + `evaluate_aux_transition`: `[0..12]` the RPO
round (part 4, gated by `hash_flag`); `[12..24]` the merge gadget (on `not(hash_flag)·not(f_break)`
rows: rate↔digest copy by the `bit` selector + zero-capacity); `[24]` bit-binary, `[25]` id-carry
copy; `[26]` `f_bind0`, `[27]` `f_null`; `[28,29]` the scalar range check; `[30..34]` the **F1**
cross-revision prevNullifier masking (`prev_pub − (1−isFirst)·prev_computed`, reading
`prevNullifierHash` from the public inputs); `[34]` the aux **grand product** `f_perm·(z −
∏_{i<N_MAX}(rate_i + γ))`. Tested against winterfell's own constraint code on a synthetic OOD frame
(`transition_ref.rs` / `VoteStarkTransition.unit.test.js`) — all 35 byte-for-byte (hand-checked the
bit-binary constraint independently). **The full AIR now evaluates on-chain.** What remains is the OOD
consistency check (compare this composition against the proof's committed evals) + DEEP + Merkle + FRI.

### 3.1 Proof byte layout (deserialization target) — corrected per AUDIT V1
A Winterfell **0.13.1** `Proof` is **8 fields, ending at `pow_nonce`** — verified against the pinned
source (`winter-air-0.13.1/src/proof/mod.rs`, `impl Serializable for Proof::write_into`). It
serializes (winter-utils `ByteWriter`, **little-endian**) in struct-declaration order:

```
context              : Context  (TraceInfo ‖ field-modulus(len u8 ‖ bytes) ‖ ProofOptions ‖ num_constraints)
num_unique_queries   : u8
commitments          : Commitments  (trace-segment roots ‖ constraint root, each ByteDigest<32>)
trace_queries        : write_many(Queries)  ← NO length prefix; count = context.trace_info().num_segments()
constraint_queries   : Queries
ood_frame            : OodFrame  (main+aux current/next rows ‖ constraint evals, GF(p^2) elements)
fri_proof            : FriProof  (layer commitments ‖ layer query values ‖ remainder)
pow_nonce            : u64
```

> **AUDIT V1 (consensus-critical).** An earlier draft listed a 9th field, `gkr_proof :
> Option<Vec<u8>>`. **That field does not exist in winter-air 0.13.1** (`grep -ri gkr` over
> `winter-air-0.13.1/src/proof/` is empty; LogUp-GKR arrived in a *later* winterfell). A
> deserializer built to the old doc would read a trailing `Option` presence byte the prover never
> wrote → OOB / wrong `remaining()==0` → **misparse / consensus break**. The bytes end at
> `pow_nonce`. Also note: `trace_queries` is emitted with `write_many` — **no length prefix**; the
> reader takes the count from the trace layout (main + aux ⇒ **2 segments** for vote_stark), per
> `Proof::read_from`'s `context.trace_info().num_segments()`.

`ProofReader.sol` implements the leaf primitives this walk needs — `readU8/16/32/64LE` (LE ints),
`readDigest` (32 raw bytes via `calldataload`), `readBytes` (calldata slice) — all bounds-checked
and unit-tested. **Confirmation status:** the `Context` **front** is now CONFIRMED against the real
emitted proof — `StarkVerifier.parseProofOptions` (§7/V7) parses `TraceInfo → modulus → ProofOptions`
and the tests assert it yields `{queries 40, blowup 16, grinding 20, ext 2, friFold 4, friRem 31}`
over Goldilocks (`p` LE) with `mainWidth 17 / log2(len) 8`. The remainder of the walk
(`commitments → trace_queries → … → pow_nonce`) is the pending core, confirmed against fixtures
during bring-up. Proof sizes (q=40): scalar 47,322 B, ranked 46,380 B (~49% smaller than the q=96
proofs, ~91 KB — the auditor's storage re-pin; see §9).

---

## 4. Seam 1 — the Blake3 host (LOCKED hash, pluggable host)

> **CONSENSUS-AUDIT SCOPE (ARCHITECT_RESPONSE §7.4 / decision §4):** Blake3 is kept (compute speed on
> a free-gas chain). Because it has no EVM opcode, it is served by a **Besu native-Blake3 precompile**,
> which is therefore **consensus-critical code that MUST be in scope for the same third-party audit as
> the rest of the chain** — a wrong/divergent precompile silently breaks every proof, and it is the one
> trust assumption keccak would not add. The canonical deployment MUST also assert
> `Blake3PrecompileHasher.selfTest() == true` (V2) before trusting the hasher. The `IHasher` seam keeps
> the choice reversible.

The commitment/transcript hash is **Blake3-256** (`winter-crypto::Blake3_256`) and is **locked** —
the circuit is audited with it; do not switch to keccak. Blake3 has no EVM opcode, so the hash is
served through `IHasher`, the single swap point:

- **Production:** `Blake3PrecompileHasher` routes every call to a **Besu native-Blake3 precompile**
  at a constructor-configured address. Precompile ABI (the host must implement exactly):
  `input = raw preimage bytes`, `output = 32-byte Blake3-256 digest`, i.e.
  `digest = staticcall(precompile, preimage)[0..32]`. The adapter owns the canonical preimage
  layout — each Goldilocks element as **8 canonical little-endian bytes**; `merge` is the 64-byte
  `a‖b` pair — so a future precompile change touches only this file.
- **Interim / baseline:** `KeccakHasher` (same LE layout, keccak opcode) for the gas baseline and
  structural tests. **Not proof-accepting** (wrong hash); a real Solidity-Blake3 could drop in
  behind the same interface if no precompile is available.

**Tested:** `MockBlake3Precompile` (returns `keccak256(preimage)`) lets the precompile adapter be
exercised end-to-end; because both adapters share the LE layout, `Blake3PrecompileHasher(mock)`
agrees with `KeccakHasher` byte-for-byte — proving the serialization + `staticcall` + 32-byte
return plumbing. Swapping in the real precompile changes only the digest function, not the layout.

**AUDIT V2 (precompile attestation + deployment trust).** `hasherId()` is a self-asserted label,
not a proof that the configured address computes genuine Blake3. `Blake3PrecompileHasher.selfTest()`
hashes two known inputs and matches the **winter-crypto-0.13.1 Blake3** digests emitted by
`emit_verifier_fixtures.rs` (two distinct probes so a single-constant precompile cannot pass).
Tests: `selfTest()` is `false` against the keccak mock (discriminates) and `true` against a mock
that returns the genuine digests for the probes. **The canonical deployment MUST call `selfTest()`
and assert `true` before trusting this hasher** — the genuine precompile + the audited
`VoteStarkAir` are *trusted-setup inputs* (`hasher`/`air` are immutable but deployer-supplied). The
soundness `ProofOptions` are no longer trusted from the (circuit-supplied) AIR alone: they are
**pinned verifier-side** at construction and cross-checked against `air.proofParams()` (see §6 / the
`StarkVerifier` constructor), closing the "malicious AIR declares weak params" circularity.

**Pending:** the element/`merge` preimage layout must be confirmed byte-exact against
`winter-crypto`'s `Blake3_256::hash_elements`/`merge` during core bring-up (it mirrors the source;
not yet cross-checked against an emitted digest).

---

## 5. Seam 2 — the generic AIR boundary (spec §8, one-genesis insurance)

`StarkVerifier` is circuit-**agnostic**: it verifies any Winterfell 0.13.1 STARK over
Goldilocks/Blake3 and learns everything circuit-specific through `IStarkAir`
(`airParams`, `proofParams`, **`validatePublicInputs`**, `periodicValuesAt(z)`,
`evaluateTransition(...)`, `boundaryAssertions`). A future circuit (the aggregate; ranked
extensions) reuses the **same** verifier by supplying its own `IStarkAir` — no new verifier
contract. `VoteStarkAir` is the vote_stark descriptor:
`airParams`/`proofParams`/`validatePublicInputs`/`boundaryAssertions`/`numMainAssertions` are
complete and tested; `periodicValuesAt`/`evaluateTransition` are the scaffolds in §6.

**AUDIT V3 (genericity made genuine).** The earlier `verify(bytes, uint64[17])` hardcoded
vote_stark (the `uint64[17]` signature, `require(mainWidth==17)`, a direct
`VoteStarkPublicInputs.validate` call), so only the FRI core was actually reusable. It is now
`verify(bytes, uint64[] )` and routes the public-input gate through `air.validatePublicInputs(pub)`
— the per-circuit codec/bounds live BEHIND the boundary, and `StarkVerifier` no longer imports any
vote_stark type. The proof's trace shape is bound to the AIR generically in `parseProofOptions`
(`mainWidth/auxWidth/numAuxRand/traceLength` must match `air.airParams()`). The "a future circuit
reuses this contract unchanged" claim now holds.

---

## 6. Remaining work (the next phase — for the re-auditor's expectations)

Ordered, each fixture-driven (the emitter already produces the real proofs to validate against):

0. **Transcript** — ✅ **DONE** (pt.1), byte-exact (`Transcript.sol`; §3 Part 1). The spine.
1. **Full Fiat-Shamir challenge chain** — ✅ **DONE** (pt.2 + pt.3): seed (`_parseContext` +
   `initialSeed`), γ/z (`deriveChallengesThroughZ`), and through the OOD reseed → DEEP coeffs → FRI
   αs → grinding → query positions (`deriveQueryPositions`, incl. `_skipToOod` + `_readOodEvals`),
   all byte-exact on real proofs (`FriCoreSeedDraw.test.js`, `FriCoreChallenges.test.js`). The coin
   layer is COMPLETE. **Remaining deserialization (for step 2+):** keep the parsed OOD frame VALUES
   (currently only hashed for the reseed) for the constraint eval; parse `fri_proof` layer query
   values + remainder for the FRI math; assert `remaining()==0` (no trailing `gkr_proof` — V1).
2. **`VoteStarkAir.evaluateTransition`** — ✅ **DONE** (pt.6): the full 34 main + 1 aux constraint
   system over GF(p²) (RPO round + merge + bit/idc/range + F1 masking + aux grand-product),
   byte-exact vs winterfell on a synthetic OOD frame. **Remaining — the OOD consistency check (pt.7):**
   combine these evals + the boundary constraints with the drawn constraint-composition coefficients,
   divide by the transition/boundary divisors, and check the result equals the proof's committed
   composition evals reduced at z (`ood_constraint_evaluation_1 == ood_constraint_evaluation_2`), per
   evaluator.rs. Uses the OOD trace frame + composition evals already read by `_readOodEvals`.
4. **`VoteStarkAir.periodicValuesAt`** — ✅ **DONE** (pt.5, `VoteStarkPeriodic.sol`): the 31 periodic
   columns at z, byte-exact (coeff-Horner for the dense period-8 columns; sparse barycentric for the
   period-256 selectors, self-validated vs winterfell's `eval`).
5. **Merkle batch openings** — verify main/aux/constraint query openings against the committed roots
   via `IHasher.merge` (Winterfell `MerkleTree` multi-proof ordering).
6. **DEEP composition** — combine OOD quotients with the query column values using the drawn DEEP
   coeffs; the result is the FRI layer-0 evaluation.
7. **FRI** — layer commitments + folding factor 4 + remainder degree ≤31 + the 96 query consistency
   checks; verify the 20-bit grinding `pow_nonce`.
8. **Blake3 byte-exactness** — confirm §4 against emitted digests, then run a full real proof end to
   end (the acceptance test that flips `verify` from revert to `true`).

Then wire into the `AnonymousVoteVerifier` successor (out of scope here; a human owns the seam and
the F1 contract-side live-head/revision-monotonicity gate).

---

## 7. Gas + Hardhat-node time (Phase-1 measured layer)

`npx hardhat run scripts/zk_bench.js`. `estimateGas` includes ~21k intrinsic + calldata.

| operation | est. gas |
| --- | --- |
| Goldilocks.mul | 21,860 |
| Goldilocks.inv (Fermat `a^(p-2)`) | 31,121 |
| Goldilocks.extMul / extInv (GF(p^2)) | 23,473 / 32,691 |
| checkPublicInputs (audit gate, via AIR — V3) | 41,159 |
| requireAcceptableOptions (§3, pinned — V2) | 23,260 |
| parseProofOptions (32-byte header — V7) | 32,717 |
| Blake3PrecompileHasher.selfTest (V2) | 26,563 |
| boundaryAssertions (scalar 51 / ranked 54) | 98,155 / 102,568 |
| keccak hashElements (17 / 96 elems) | 55,684 / 212,239 |
| keccak merge | 23,720 |
| blake3(mock) hashElements (17) / merge | 59,065 / 25,845 |

Note: `parseProofOptions` on the **full** ~91 KB proof estimates ~3.66 M gas — that is the proof's
**calldata** cost (paid once by `verify`), not the parse; on a 32-byte header it is ~33 k.

Wall-clock (Hardhat node, avg): `checkPublicInputs` 2.7 ms; `boundaryAssertions` 10.9 ms;
`verify(real proof)→FRI revert` 113.7 ms (dominated by ABI-decoding the ~92 KB proof calldata).

**`verify` end-to-end gas is NOT yet measurable** — it reverts at the FRI core. The spec target is
~2M gas with the keccak baseline; the Blake3 precompile is intended to keep the hash leg ~flat on
`vote_besu`. The hashElements row shows the per-call hash cost that the 96-query FRI core will
multiply — the single biggest driver, and the reason the native precompile matters.

---

## 8. Disposition of the verifier audit (PR #200 / `vote/docs/zk-stark-audit/VERIFIER_AUDIT.md`)

Verdict: the implemented Phase-1 layer was found **SOUND**; the findings are a consensus-critical
map error (V1) plus deployment-trust / scoping items. Disposition:

| ID | Sev | Disposition |
| --- | --- | --- |
| **V1** | MED (consensus) | **FIXED (doc).** §3.1 corrected: dropped the phantom `gkr_proof`; pinned to the 8-field 0.13.1 `Proof` ending at `pow_nonce`; documented `trace_queries` = `write_many` (no length prefix; count = `num_segments` = 2). Verified against `winter-air-0.13.1/src/proof/mod.rs`. |
| **V2** | LOW→MED (trust) | **FIXED (code+doc).** `Blake3PrecompileHasher.selfTest()` attests the precompile vs winter-crypto Blake3 vectors; the §3 `ProofOptions` are now **pinned verifier-side** (immutable) and cross-checked against `air.proofParams()` at construction (de-circularized). Trust model documented (§4): genuine precompile + audited AIR are trusted-setup inputs; deploy MUST assert `selfTest()`. |
| **V3** | LOW | **FIXED (code+doc).** `verify(bytes, uint64[])` is now generic; the public-input gate moved behind `IStarkAir.validatePublicInputs`; `StarkVerifier` imports no vote_stark type; proof trace shape bound to the AIR generically (§5). |
| **V4** | INFO | **DOCUMENTED.** The on-chain gate deliberately *rejects* `choiceCount > N_MAX` where the circuit clamps — rejecting is never unsound (the S10/F2 residual fix). `numMainAssertions`/`boundaryAssertions` assume pre-gated inputs; the verify-path ordering (`validatePublicInputs` first) preserves this — noted in `VoteStarkAir` (V4 comment) so the FRI core keeps the order. |
| **V5** | INFO | **DOCUMENTED.** `Goldilocks.sub/neg` underflow-**revert** on non-canonical inputs (fail-safe); the core must hand only reduced elements — noted at `Goldilocks.sub` (V5 comment). |
| **V6** | LOW | **CONFIRMED.** S9 externalNullifier domain separation is the integrator's job (verifier exposes it positionally); tracked in §2.2 and carried from the system audit. |
| **V7** | INFO | **FIXED (code).** `requireAcceptableOptions` is now wired into `verify()`: it parses `ProofOptions` from the proof's `Context` (`parseProofOptions`) and checks them against the pinned set. Tested against real proofs + a downgraded-options proof (rejected). |

Carried for the external human zk auditor: the FRI core is **partially built** — the Fiat-Shamir
transcript (the spine) is now DONE + byte-exact (§3 Part 1); the remaining steps (§6 — full
deserialization, OOD/constraint eval, Merkle openings, DEEP, FRI low-degree) are the next parts and
are what turns `verify()` from revert to `true`. **Update on Blake3 byte-exactness (was residual
#2):** `hash_elements` (the field-element serialization layout) and `merge` are now validated against
GENUINE winter-crypto Blake3 digests in `Transcript.unit.test.js` (the lookup table is captured from
the real `Blake3_256`). The `merge_with_int` 40-byte preimage is likewise exercised by the byte-exact
transcript sequence. What remains unvalidated is Blake3 over the *Merkle/FRI opening* preimages, which
arrives with those components.

---

## 9. Disposition of the second verifier audit (#237) + the ProofOptions re-pin

Pre-part-7 hardening from auditor #237 + the auditor-owned ProofOptions decision:

| ID | Sev | Disposition |
| --- | --- | --- |
| **C1** | MED (consensus) | **FIXED.** The constraint-composition coefficient count is now RECOMPUTED from the AIR (`IStarkAir.constraintCompositionCoeffCount` = `num_transition + num_assertions`), NOT trusted from `proof.context.num_constraints` — which a malicious proof could under-state to leave constraints with zero coefficients (unenforced) once OOD composition consumes them. `StarkVerifier` draws the AIR-authoritative count and asserts the proof's `num_constraints` matches it, BEFORE seeding. Rejection tested (`FriCoreSeedDraw.test.js` — a tampered `num_constraints` reverts in both `deriveChallengesThroughZ` and `deriveQueryPositions`). |
| **C2** | LOW | **FIXED.** `_parseContext` now `require(metaLen == 0)` — the seed builder's `context.to_elements` assembly assumes empty `trace_meta` (true for vote_stark); a non-empty meta is rejected rather than silently mis-seeded (tested). The RAP γ draw is generalized to `air.airParams().numAuxRandElements` rather than a hardcoded 1. |
| **ProofOptions** | — | **RE-PINNED `num_queries` 96 → 40** by the external zk auditor (storage lever): at blowup 16 the conjectured security is field-capped at 127 bits regardless of query count down to ~27, so 40 holds 127-bit conjectured with proven-soundness margin while shrinking every proof ~49% (≈91 KB → ≈47 KB). Changed in `prover.rs default_options` + `VoteStarkAir` (`NUM_QUERIES`/`proofParams`) + the verifier's pinned immutables (deploy params); all real-proof fixtures regenerated. **ProofOptions only — no AIR change, no circuit re-audit.** |

(Done before parts 7–8 so the real-proof fixtures are regenerated once. The size-discrepancy flag from
the prior bridge is resolved: the ~0.5 MB figure was a rough estimate; measured proofs are ~47 KB at
q=40, ~91 KB at q=96.)
