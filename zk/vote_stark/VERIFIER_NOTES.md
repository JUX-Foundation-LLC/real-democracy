# VERIFIER_NOTES — building the on-chain verifier for `vote_stark`

For whoever builds the on-chain STARK verifier (Solidity-interim or Besu precompile,
per `ZK_STARK_REGENESIS_SPEC.md` §4). This crate is the **off-chain reference prover +
verifier**; the on-chain verifier must reproduce the verification below **byte-for-byte**.
Everything here is fixed by the prover; deviate on any item and valid proofs will fail.

> The fastest way to a correct verifier is to port **`winter-verifier` v0.13.1**
> (`verify::<VoteAir, Blake3_256, DefaultRandomCoin<Blake3_256>, MerkleTree<Blake3_256>>`)
> step-for-step. This doc calls out the parameters and the parts specific to *this* AIR.

## 1. The two hashes (read this first — it drives the host decision)

There are **two distinct hash functions**, do not conflate them:

| hash | where | who computes it | on-chain cost |
|---|---|---|---|
| **RPO256** (Goldilocks) | *inside* the circuit: identity, commitment, Merkle, nullifier, ranking commitment | only the **prover** (in the trace). The verifier checks RPO **algebraically** at the OOD point via the AIR constraints — it never recomputes an RPO hash. | **none** — no RPO precompile needed on-chain |
| **Blake3-256** | the STARK itself: trace/constraint **Merkle commitments**, Merkle auth paths, and the Fiat-Shamir transcript (random coin) | both prover and verifier | **this is the on-chain hashing cost** |

**Host implication.** The verifier's hashing is *all Blake3-256*. Blake3 has **no EVM
opcode** (EIP-152 provides BLAKE2b `F`, not Blake3), so a *pure-Solidity* verifier would
recompute Blake3 in EVM — expensive (every Merkle path node + every Fiat-Shamir absorb).
Two viable hosts:

1. **Besu native-Blake3 precompile (recommended).** Add a precompile that does Blake3
   compression natively; the verifier calls it for Merkle/transcript hashing → cheap,
   fixed cost. On `vote_besu` (gasPrice 0) the only budget is node CPU, and native
   Blake3 is fast. This is the clean production form.
2. **Switch the STARK hash to keccak-256** (EVM-native) *before* freezing. Winterfell can
   instantiate the prover with a keccak hasher instead of `Blake3_256`. This makes a
   pure-Solidity verifier cheap, at some prover cost (keccak is slower than Blake3 in
   WASM) **and it changes the proof bytes** — re-run the benchmark and re-pin. If the
   on-chain path is Solidity-only with no precompile, do this.

Either way the **in-circuit RPO256 stays** (it is what makes the field-friendly circuit
provable); only the STARK's Merkle/transcript hash is the host's choice. Blake3 is the
current default because it is the fastest prover hash for the phone-proving target.

## 2. Public inputs — exact wire order

`PublicInputs::to_elements()` emits Goldilocks field elements in **this order** (17
elements). The transcript seed is `hash(proof.context ‖ these)`, so the order is
consensus-critical:

| # | field | elements | meaning |
|---|---|---|---|
| 0–3 | `merkleRoot` | 4 | eligibility-set RPO root |
| 4 | `externalNullifier` | 1 | ballot scope |
| 5 | `revision` | 1 | nullifier revision |
| 6 | `voteMode` | 1 | `0` = scalar, `1` = ranked |
| 7 | `choiceCount` (N) | 1 | ranking length (ranked); public ballot parameter |
| 8 | `voteChoice` | 1 | scalar: the value · ranked: `RPO(rank)[0]` |
| 9–12 | `nullifierHash` | 4 | the nullifier being spent |
| 13–16 | `prevNullifierHash` | 4 | prior revision's nullifier (chaining anchor); `0` on first cast |

`merkleRoot` / `nullifierHash` / `prevNullifierHash` are 4-element RPO digests (little-endian
element order as returned by `Rpo256`). All are canonical Goldilocks integers in
`[0, 2^64−2^32+1)`.

**The on-chain verifier MUST also bounds-check the public inputs before accepting** (these are
NOT all enforced in-circuit — see §6): `voteMode ∈ {0,1}`; for ranked, `choiceCount ∈
[1, N_MAX]` (`N=0` and `N>N_MAX` must be rejected); and clamp the scalar `voteChoice` to the
ballot's real `maxValue` (the circuit only enforces the fixed `[0, 2¹⁶)`).

## 3. Proof parameters — must match exactly (`prover::default_options`)

```
field          = Goldilocks  p = 2^64 − 2^32 + 1
field_extension= Quadratic   (FRI/DEEP/OOD challenges live in GF(p^2); REQUIRED for ≥96-bit)
trace          = 256 rows × 17 main columns + 1 AUX column
blowup_factor  = 16          (LDE domain = 4096)
num_queries    = 96
grinding       = 20 bits      (proof-of-work nonce on the query-seed coin)
fri_folding    = 4
fri_remainder_max_degree = 31
constraint/DEEP batching = Linear / Linear
hash (STARK)   = Blake3_256   §1
vector commit  = MerkleTree<Blake3_256>
random coin    = DefaultRandomCoin<Blake3_256>
```

`AcceptableOptions` on-chain must accept exactly this option set (reject anything else).

## 4. The AIR the verifier evaluates at the OOD point

The verifier never runs the trace; it checks the constraints **once**, at the
out-of-domain point `z` (and `z·g`), against the prover's OOD evaluations. It must
implement the **same** constraints as `air.rs`:

- **Periodic columns** (31 total), in this order: `hash_flag` (period 8), `ARK1[0..12]`,
  `ARK2[0..12]` (period 8), then **six** period-256 selectors in order `f_bind0`, `f_null`,
  `rc_active`, `f_break`, `f_perm`, `f_prevbind`. Their values at `z` are needed to evaluate
  the transition constraints (the verifier interpolates each periodic column and evaluates
  at `z`). `f_null` fires at rows {175, 191}; `f_break` at {175, 183, 191}; `f_perm` at 184;
  `f_prevbind` at 199.
- **Main transition constraints (34 slots, degrees as declared in `VoteAir::new`):**
  `[0..12]` RPO round (degree 7); `[12..20]` merge digest placement; `[20..24]` merge
  capacity reset; `[24]` index-bit binary; `[25]` id-carry copy; `[26]` id bind @ row 0;
  `[27]` nullifier/prevNullifier id-slot; `[28]` scalar Horner; `[29]` scalar bit-binary;
  `[30..34]` **prevNullifier masking (F1):** `f_prevbind · (prevNullifierHash[k] −
  (1 − isFirst)·prevComputed[k])`, degree 2, where `prevComputed[k] = digest[k]@199`
  (block 24) and `isFirst = main[16]@199` (pinned by boundary to `1` iff `revision==0`).
- **Aux transition constraint (1):** `f_perm · (z_aux − ∏_{i=0}^{7}(rank_i + γ))`, degree
  8, where `γ` is the single aux random element drawn after the main-trace commitment, and
  `rank_i = main[4+i]` at the rankCommit-input row (184).
- **Boundary assertions** depend on the public `voteMode` (and, in ranked, on `N`). Common
  to both modes: block-0 input zeros (10); the commitment block's second input word
  `state[8..12]@8 = 0` (4); `merkleRoot@175` (4); nullifier input @176 (11); nullifier
  digest @183 (4); `cap@184 = 0` (4); prevNullifier input @192 (11, incl. `state[6]@192 =
  revision−1`); and `isFirst@199 = (revision==0 ? 1 : 0)` (1). Scalar adds the two
  range-accumulator boundaries; ranked adds `digest[0]@191 == voteChoice`, the `(N_MAX−N)`
  padding-zero boundaries, and the **aux** boundary `z@184 == ∏(target_i + γ)`
  (`target = [0,1,…,N−1,0,…]`). The count is a function of the public inputs — compute it
  identically on-chain.

The RPO round constants (`MDS_ROW0`, `ARK1`, `ARK2`) and the round identity
(`MDS·sbox(MDS·cur+ARK1) == sbox(next) − ARK2`, degree 7) are in `rpo.rs`; the on-chain
constraint evaluator must use the **same constants**.

## 5. Verification order (RAP-aware Fiat-Shamir — the aux step is easy to miss)

1. Validate options (§3). Seed the coin with `hash(context ‖ public_inputs)`.
2. Read **main trace commitment** (Blake3 Merkle root); reseed.
3. **Draw `γ` (1 aux random element) from the coin**; read **aux trace commitment**;
   reseed. *(This RAP step is what makes the permutation argument sound — `γ` is
   unknowable to the prover before the main trace is fixed.)*
4. Draw constraint-composition coefficients; read **constraint commitment**; reseed.
5. Draw OOD point `z`; read OOD main frame, OOD aux frame, OOD constraint evaluations;
   reseed with them. **Evaluate §4 at `z`** and check it equals the committed composition.
6. Draw DEEP coefficients. Verify the **grinding** nonce (20 bits). Draw 96 query
   positions.
7. For each query: verify main-trace row + aux-trace row + constraint row against their
   Blake3 Merkle roots (auth paths), compute the DEEP composition value.
8. **FRI**: verify layer commitments (Blake3), folding (factor 4) consistency at the
   query positions, and the remainder polynomial (degree ≤ 31).

Soundness: ~127-bit conjectured / 107-bit proven (UDR). The permutation argument
contributes ≈128-bit (γ ∈ GF(p²), bad-set ≤ N_MAX points).

## 6. Byte-exact freeze checklist

- [ ] Goldilocks field; quadratic extension for challenges.
- [ ] RPO256 constants identical to `rpo.rs` (= miden-crypto v0.19.8; proven by tests).
- [ ] STARK hash + Merkle + random coin = Blake3_256 (or keccak-256 if Solidity-only — re-pin).
- [ ] `ProofOptions` exactly §3.
- [ ] Public-input element order exactly §2 (now **17** elements, incl. `prevNullifierHash`).
- [ ] AIR constraint set (34 main + 1 aux), degrees, periodic-column order (31, six selectors),
      and the voteMode/N-dependent assertion layout exactly §4.
- [ ] The RAP step (draw γ → commit aux) in the transcript exactly §5.3.
- [ ] **Input bounds-checks the circuit does NOT enforce** (reject, don't abort):
      `voteMode ∈ {0,1}` (F3); ranked `choiceCount ∈ [1, N_MAX]` (F2/F8); scalar `voteChoice`
      clamped to the ballot's `maxValue` (F5). The reference `verify()` already cleanly
      *rejects* `N > N_MAX` (no panic); the others are the consumer's/contract's job.

## 7. Cross-revision vote-change (now in-circuit — F1)

`prevNullifierHash` is a bound public input: the circuit proves
`prevNullifierHash == RPO(externalNullifier, idN, revision−1)` (block 24) against the SAME
secret `idN`, masked to `0` on the first cast (`revision==0`). **The contract's vote-change
path can now be sound:** on `revision > 0`, require that the submitted `prevNullifierHash` is
the current live head, retire it, and install `nullifierHash` as the new head — the in-circuit
binding guarantees `prev` belongs to the *same* voter (the contract cannot check that itself —
`idN` is secret). Still out of scope here: the contract-side live-head tracking + revision
monotonicity, and the Solidity/precompile verifier itself.

> Privacy note (from the audit, F4): publishing `prevNullifierHash` on-chain makes a single
> anonymous voter's revision *sequence* self-linkable (still not to identity). Acceptable per
> the stated model; flag for the privacy review.
