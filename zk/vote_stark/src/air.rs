//! The unified vote AIR (§1 of the spec): ONE circuit, switched by the public
//! `voteMode`, proving either a SCALAR or a RANKED choice. Membership, the rotating
//! nullifier, AND the cross-revision `prevNullifierHash` binding are identical in both
//! modes; only the choice gadget changes.
//!
//! ## Trace layout (main width 17, length 256, + 1 aux column)
//!
//! A chain of 25 RPO permutations, each an 8-row cycle (7 round rows + 1 init row):
//!
//! | block  | cycle  | computes                                              |
//! |--------|--------|------------------------------------------------------|
//! | 0      | 0      | `secret      = RPO(idN, idT)`                         |
//! | 1      | 1      | `commitment  = RPO(secret)`  (Merkle leaf)           |
//! | 2..21  | 2..21  | Merkle path: 20 × `merge(node, sibling)` → root      |
//! | 22     | 22     | `nullifier   = RPO(extNull, idN, revision)`           |
//! | 23     | 23     | `rankCommit  = RPO(rank[0..N_MAX])`  (ranked only)    |
//! | 24     | 24     | `prevComputed= RPO(extNull, idN, revision-1)` (F1)    |
//! | pad    | 25..31 | padding                                              |
//!
//! Main columns: `0..12` RPO state (capacity `0..4`, rate `4..12`, digest `4..8`);
//! `12` Merkle index bit; `13` id-carry; `14` range-check bit; `15` range-check Horner
//! accumulator; `16` isFirst (revision==0 flag, pinned to the public-derived constant).
//! The ranked ranking lives in the rankCommit block's input row (`state[4..12]` at row
//! 184), used by both the RPO commitment and the permutation argument.
//!
//! ## Choice gadgets (selected by the public `voteMode`, in the BOUNDARY assertions only)
//! Both gadgets' transition constraints are ALWAYS active (degree-uniform); `voteMode`
//! only selects which gadget's output is bound to `voteChoice` (see `get_assertions`).
//! * SCALAR (`voteMode=0`): 16-bit Horner range check of `voteChoice ∈ [0,2¹⁶)`.
//! * RANKED (`voteMode=1`): an auxiliary grand-product permutation argument proving
//!   `{rank[0..N)} == {0,…,N−1}` at a Fiat-Shamir challenge γ drawn from the quadratic
//!   extension (~128-bit soundness), and `voteChoice == RPO(rank)[0]`.
//!
//! ## Cross-revision nullifier binding (F1)
//! `prevNullifierHash` is a public input. Block 24 computes `RPO(extNull, idN, revision-1)`
//! against the SAME `idN` (the `IDC` carry); the masking constraint forces
//! `prevNullifierHash == (1 - isFirst) · prevComputed` — i.e. `0` on the first cast
//! (`revision==0`) and the prior revision's nullifier otherwise. This is what makes the
//! contract's live-head vote-change check sound (the contract cannot recompute it — `idN`
//! is secret).

use winterfell::{
    math::{fields::f64::BaseElement as Felt, ExtensionOf, FieldElement, ToElements},
    Air, AirContext, Assertion, AuxRandElements, EvaluationFrame, ProofOptions, TraceInfo,
    TransitionConstraintDegree,
};

use crate::rpo::{self, Word, DIGEST_SIZE};
use crate::scheme::N_MAX;
use crate::utils::{are_equal, is_binary, is_zero, not, EvaluationResult};

// CONSTANTS
// ================================================================================================

pub const MERKLE_DEPTH: usize = 20;
pub const CYCLE_LEN: usize = 8;
pub const NUM_HASH_ROUNDS: usize = rpo::NUM_ROUNDS; // 7

/// 1 secret + 1 commitment + MERKLE_DEPTH path + 1 nullifier + 1 rankCommit + 1 prevNullifier.
pub const NUM_BLOCKS: usize = 2 + MERKLE_DEPTH + 1 + 1 + 1; // 25
pub const TRACE_WIDTH: usize = 17;
pub const TRACE_LENGTH: usize = 256;

// main column indices
const S: usize = 0; // state[0..12]
const BIT: usize = 12;
const IDC: usize = 13; // id-carry
const RCB: usize = 14; // range-check bit
const RCA: usize = 15; // range-check accumulator
const ISF: usize = 16; // isFirst flag (revision == 0)

const CAP: usize = 0; // capacity = state[0..4]
const RATE: usize = rpo::RATE_START; // 4; rate = state[4..12]
const DIG: usize = rpo::DIGEST_START; // 4; digest = state[4..8]

// key rows
const COMMIT1_INPUT_ROW: usize = 8; // 8 — block 1 (commitment) input
const ROOT_ROW: usize = 8 * 21 + 7; // 175 — Merkle root (block 21 digest)
const NULL_INIT_ROW: usize = ROOT_ROW; // 175 — root→nullifier chain break
const NULL_INPUT_ROW: usize = 8 * 22; // 176 — nullifier permutation input
const NULL_DIGEST_ROW: usize = 8 * 22 + 7; // 183 — nullifier digest
const RANK_INIT_ROW: usize = 8 * 23 - 1; // 183 — nullifier→rankCommit chain break
const COMMIT_INPUT_ROW: usize = 8 * 23; // 184 — ranking lives here (rate = rank[0..8])
const COMMIT_DIGEST_ROW: usize = 8 * 23 + 7; // 191 — rankCommit digest; voteChoice = digest[0]
const PREV_INIT_ROW: usize = 8 * 24 - 1; // 191 — rankCommit→prevNullifier chain break
const PREV_INPUT_ROW: usize = 8 * 24; // 192 — prevNullifier input
const PREV_DIGEST_ROW: usize = 8 * 24 + 7; // 199 — prevComputed; masking row
const RANGE_BITS: usize = 16;
const RC_FINAL_ROW: usize = RANGE_BITS; // 16 — scalar accumulator == voteChoice here

const AUX_Z: usize = 0; // aux column index (grand-product accumulator)

// number of main transition constraints
const NUM_MAIN_CONSTRAINTS: usize = 34;

// periodic column indices (order MUST match get_periodic_column_values)
const P_HASHFLAG: usize = 0;
const P_ARK1: usize = 1;
const P_ARK2: usize = 1 + rpo::STATE_WIDTH;
const P_FBIND0: usize = 1 + 2 * rpo::STATE_WIDTH; // 25
const P_FNULL: usize = P_FBIND0 + 1; // 26 — nullifier + prevNullifier idN bindings
const P_RCACTIVE: usize = P_FBIND0 + 2; // 27
const P_FBREAK: usize = P_FBIND0 + 3; // 28 — chain breaks (nullifier, rankCommit, prevNull)
const P_FPERM: usize = P_FBIND0 + 4; // 29 — permutation-argument row (rankCommit input)
const P_FPREVBIND: usize = P_FBIND0 + 5; // 30 — prevNullifier masking row

// PUBLIC INPUTS
// ================================================================================================

#[derive(Clone, Debug)]
pub struct PublicInputs {
    pub merkle_root: Word,
    pub external_nullifier: Felt,
    pub revision: Felt,
    pub vote_mode: Felt,    // 0 = scalar, 1 = ranked
    pub choice_count: Felt, // N (ranked); public ballot parameter
    pub vote_choice: Felt,
    pub nullifier_hash: Word,
    /// Prior revision's nullifier (the vote-change chaining anchor); `0` on first cast.
    pub prev_nullifier_hash: Word,
}

impl PublicInputs {
    fn is_ranked(&self) -> bool {
        self.vote_mode == Felt::ONE
    }
    /// Ranking length, clamped to `N_MAX` so an out-of-range public `N` can never
    /// underflow the assertion count (F2); such an `N` then fails verification cleanly.
    fn n(&self) -> usize {
        (self.choice_count.as_int() as usize).min(N_MAX)
    }
    /// `1` if this is a first cast (`revision == 0`), else `0` (public-derived).
    fn is_first(&self) -> Felt {
        if self.revision == Felt::ZERO {
            Felt::ONE
        } else {
            Felt::ZERO
        }
    }
}

impl ToElements<Felt> for PublicInputs {
    fn to_elements(&self) -> Vec<Felt> {
        let mut e = Vec::with_capacity(17);
        e.extend_from_slice(&self.merkle_root);
        e.push(self.external_nullifier);
        e.push(self.revision);
        e.push(self.vote_mode);
        e.push(self.choice_count);
        e.push(self.vote_choice);
        e.extend_from_slice(&self.nullifier_hash);
        e.extend_from_slice(&self.prev_nullifier_hash);
        e
    }
}

// AIR
// ================================================================================================

pub struct VoteAir {
    context: AirContext<Felt>,
    pub_inputs: PublicInputs,
}

impl Air for VoteAir {
    type BaseField = Felt;
    type PublicInputs = PublicInputs;

    fn new(trace_info: TraceInfo, pub_inputs: PublicInputs, options: ProofOptions) -> Self {
        let mut main_degrees = Vec::with_capacity(NUM_MAIN_CONSTRAINTS);
        // [0..12] RPO round (degree 7, period-8 hash_flag + ARK)
        for _ in 0..rpo::STATE_WIDTH {
            main_degrees.push(TransitionConstraintDegree::with_cycles(7, vec![CYCLE_LEN]));
        }
        // [12..20] merge digest placement (merge_active * bit * are_equal)
        for _ in 0..(2 * DIGEST_SIZE) {
            main_degrees.push(TransitionConstraintDegree::with_cycles(
                2,
                vec![CYCLE_LEN, TRACE_LENGTH],
            ));
        }
        // [20..24] merge capacity reset (merge_active * is_zero)
        for _ in 0..DIGEST_SIZE {
            main_degrees.push(TransitionConstraintDegree::with_cycles(
                1,
                vec![CYCLE_LEN, TRACE_LENGTH],
            ));
        }
        main_degrees.push(TransitionConstraintDegree::new(2)); // [24] index bit binary
        main_degrees.push(TransitionConstraintDegree::new(1)); // [25] id-carry copy
        main_degrees.push(TransitionConstraintDegree::with_cycles(
            1,
            vec![TRACE_LENGTH],
        )); // [26] f_bind0
        main_degrees.push(TransitionConstraintDegree::with_cycles(
            1,
            vec![TRACE_LENGTH],
        )); // [27] f_null idN
        main_degrees.push(TransitionConstraintDegree::with_cycles(
            1,
            vec![TRACE_LENGTH],
        )); // [28] scalar Horner
        main_degrees.push(TransitionConstraintDegree::with_cycles(
            2,
            vec![TRACE_LENGTH],
        )); // [29] scalar bit binary
            // [30..34] prevNullifier masking: f_prevbind * (prev - (1-isFirst)*prevComputed)
        for _ in 0..DIGEST_SIZE {
            main_degrees.push(TransitionConstraintDegree::with_cycles(
                2,
                vec![TRACE_LENGTH],
            ));
        }
        debug_assert_eq!(main_degrees.len(), NUM_MAIN_CONSTRAINTS);

        // aux: grand product, degree N_MAX, period-256 f_perm selector
        let aux_degrees = vec![TransitionConstraintDegree::with_cycles(
            N_MAX,
            vec![TRACE_LENGTH],
        )];

        // boundary assertion counts (depend on the public mode / N)
        // common: block0(10) + commit1 pad(4,F7) + root(4) + null in(11) + null dig(4)
        //         + cap@184(4) + prevNull in(11) + isFirst pin(1) = 49
        let common = 10 + DIGEST_SIZE + DIGEST_SIZE + 11 + DIGEST_SIZE + DIGEST_SIZE + 11 + 1;
        let num_main_assertions = if pub_inputs.is_ranked() {
            common + 1 + (N_MAX - pub_inputs.n()) // commitment digest + padding zeros
        } else {
            common + 2 // scalar range boundaries
        };
        let num_aux_assertions = 1;

        assert_eq!(TRACE_WIDTH, trace_info.main_trace_width());
        VoteAir {
            context: AirContext::new_multi_segment(
                trace_info,
                main_degrees,
                aux_degrees,
                num_main_assertions,
                num_aux_assertions,
                options,
            ),
            pub_inputs,
        }
    }

    fn context(&self) -> &AirContext<Self::BaseField> {
        &self.context
    }

    fn evaluate_transition<E: FieldElement + From<Self::BaseField>>(
        &self,
        frame: &EvaluationFrame<E>,
        periodic: &[E],
        result: &mut [E],
    ) {
        let cur = frame.current();
        let nxt = frame.next();

        let hash_flag = periodic[P_HASHFLAG];
        let ark1 = &periodic[P_ARK1..P_ARK1 + rpo::STATE_WIDTH];
        let ark2 = &periodic[P_ARK2..P_ARK2 + rpo::STATE_WIDTH];
        let f_bind0 = periodic[P_FBIND0];
        let f_null = periodic[P_FNULL];
        let rc_active = periodic[P_RCACTIVE];
        let f_break = periodic[P_FBREAK];
        let f_prevbind = periodic[P_FPREVBIND];

        // ---- [0..12] RPO round (only when hash_flag == 1) ----
        rpo::enforce_round(
            &mut result[0..rpo::STATE_WIDTH],
            &cur[S..S + rpo::STATE_WIDTH],
            &nxt[S..S + rpo::STATE_WIDTH],
            ark1,
            ark2,
            hash_flag,
        );

        // ---- merge-init at hash_flag==0 rows, except chain-break rows (f_break) ----
        let merge_active = not(hash_flag) * not(f_break);
        let bit = nxt[BIT];
        let not_bit = not(bit);
        for k in 0..DIGEST_SIZE {
            result.agg_constraint(
                12 + k,
                merge_active,
                not_bit * are_equal(nxt[RATE + k], cur[DIG + k]),
            );
            result.agg_constraint(
                16 + k,
                merge_active,
                bit * are_equal(nxt[RATE + DIGEST_SIZE + k], cur[DIG + k]),
            );
            result.agg_constraint(20 + k, merge_active, is_zero(nxt[CAP + k]));
        }

        // ---- [24] index bit binary · [25] id-carry copy ----
        result[24] = is_binary(cur[BIT]);
        result[25] = are_equal(nxt[IDC], cur[IDC]);

        // ---- [26] bind id-carry to idNullifier at row 0 ----
        result.agg_constraint(26, f_bind0, are_equal(cur[IDC], cur[RATE]));
        // ---- [27] nullifier/prevNullifier input idNullifier slot == id-carry ----
        result.agg_constraint(27, f_null, are_equal(nxt[RATE + 1], nxt[IDC]));

        // ---- [28,29] SCALAR range check (always enforced; bound to voteChoice only in
        // scalar mode, via boundary — in ranked mode the columns carry a valid dummy) ----
        let two = E::from(Felt::new(2));
        result.agg_constraint(28, rc_active, nxt[RCA] - (two * cur[RCA] + cur[RCB]));
        result.agg_constraint(29, rc_active, is_binary(cur[RCB]));

        // ---- [30..34] prevNullifier masking (F1): at the prevComputed digest row,
        // prevNullifierHash == (1 - isFirst) * prevComputed.  isFirst (cur[ISF]) is pinned
        // to the public-derived constant by a boundary; prevComputed = digest cur[DIG+k]. ----
        let is_first = cur[ISF];
        for k in 0..DIGEST_SIZE {
            let prev_pub = E::from(self.pub_inputs.prev_nullifier_hash[k]);
            let prev_computed = cur[DIG + k];
            // prev_pub - (1 - isFirst)*prev_computed = prev_pub - prev_computed + isFirst*prev_computed
            let expr = prev_pub - prev_computed + is_first * prev_computed;
            result.agg_constraint(30 + k, f_prevbind, expr);
        }
    }

    fn evaluate_aux_transition<F, E>(
        &self,
        main_frame: &EvaluationFrame<F>,
        aux_frame: &EvaluationFrame<E>,
        periodic: &[F],
        aux_rand_elements: &AuxRandElements<E>,
        result: &mut [E],
    ) where
        F: FieldElement<BaseField = Self::BaseField>,
        E: FieldElement<BaseField = Self::BaseField> + ExtensionOf<F>,
    {
        // Grand product at the rankCommit-input row (f_perm): z == ∏(rank_i + γ). Always
        // enforced; ranked mode ties z to the target product via the aux boundary.
        let main = main_frame.current();
        let z = aux_frame.current()[AUX_Z];
        let gamma = aux_rand_elements.rand_elements()[0];

        let mut prod = E::ONE;
        for i in 0..N_MAX {
            prod *= E::from(main[RATE + i]) + gamma;
        }

        let f_perm: E = periodic[P_FPERM].into();
        result[0] = f_perm * (z - prod);
    }

    fn get_assertions(&self) -> Vec<Assertion<Self::BaseField>> {
        let mut a = Vec::new();
        let zero = Felt::ZERO;

        // --- block 0 input @ row 0: secret = merge([idN, idT, 0, 0], ZERO) ---
        for k in 0..DIGEST_SIZE {
            a.push(Assertion::single(CAP + k, 0, zero));
        }
        a.push(Assertion::single(RATE + 2, 0, zero));
        a.push(Assertion::single(RATE + 3, 0, zero));
        for k in 0..DIGEST_SIZE {
            a.push(Assertion::single(RATE + DIGEST_SIZE + k, 0, zero));
        }

        // --- F7: block 1 (commitment) input second word @ row 8 == ZERO ---
        for k in 0..DIGEST_SIZE {
            a.push(Assertion::single(
                RATE + DIGEST_SIZE + k,
                COMMIT1_INPUT_ROW,
                zero,
            ));
        }

        // --- Merkle root @ row 175 ---
        for k in 0..DIGEST_SIZE {
            a.push(Assertion::single(
                DIG + k,
                ROOT_ROW,
                self.pub_inputs.merkle_root[k],
            ));
        }

        // --- nullifier input @ row 176 ---
        a.push(Assertion::single(
            RATE,
            NULL_INPUT_ROW,
            self.pub_inputs.external_nullifier,
        ));
        a.push(Assertion::single(
            RATE + 2,
            NULL_INPUT_ROW,
            self.pub_inputs.revision,
        ));
        a.push(Assertion::single(RATE + 3, NULL_INPUT_ROW, zero));
        for k in 0..DIGEST_SIZE {
            a.push(Assertion::single(
                RATE + DIGEST_SIZE + k,
                NULL_INPUT_ROW,
                zero,
            ));
        }
        for k in 0..DIGEST_SIZE {
            a.push(Assertion::single(CAP + k, NULL_INPUT_ROW, zero));
        }

        // --- nullifier digest @ row 183 ---
        for k in 0..DIGEST_SIZE {
            a.push(Assertion::single(
                DIG + k,
                NULL_DIGEST_ROW,
                self.pub_inputs.nullifier_hash[k],
            ));
        }

        // --- rankCommit input capacity @ row 184 == 0 (both modes) ---
        for k in 0..DIGEST_SIZE {
            a.push(Assertion::single(CAP + k, COMMIT_INPUT_ROW, zero));
        }

        // --- prevNullifier input @ row 192: merge([extNull, idN, revision-1, 0], ZERO) ---
        a.push(Assertion::single(
            RATE,
            PREV_INPUT_ROW,
            self.pub_inputs.external_nullifier,
        ));
        a.push(Assertion::single(
            RATE + 2,
            PREV_INPUT_ROW,
            self.pub_inputs.revision - Felt::ONE,
        ));
        a.push(Assertion::single(RATE + 3, PREV_INPUT_ROW, zero));
        for k in 0..DIGEST_SIZE {
            a.push(Assertion::single(
                RATE + DIGEST_SIZE + k,
                PREV_INPUT_ROW,
                zero,
            ));
        }
        for k in 0..DIGEST_SIZE {
            a.push(Assertion::single(CAP + k, PREV_INPUT_ROW, zero));
        }

        // --- isFirst pinned to the public-derived constant @ the masking row ---
        a.push(Assertion::single(
            ISF,
            PREV_DIGEST_ROW,
            self.pub_inputs.is_first(),
        ));

        // --- mode-specific choice boundaries ---
        if self.pub_inputs.is_ranked() {
            a.push(Assertion::single(
                DIG,
                COMMIT_DIGEST_ROW,
                self.pub_inputs.vote_choice,
            ));
            for i in self.pub_inputs.n()..N_MAX {
                a.push(Assertion::single(RATE + i, COMMIT_INPUT_ROW, zero));
            }
        } else {
            a.push(Assertion::single(RCA, 0, zero));
            a.push(Assertion::single(
                RCA,
                RC_FINAL_ROW,
                self.pub_inputs.vote_choice,
            ));
        }

        a
    }

    fn get_aux_assertions<E>(&self, aux_rand_elements: &AuxRandElements<E>) -> Vec<Assertion<E>>
    where
        E: FieldElement<BaseField = Self::BaseField>,
    {
        if self.pub_inputs.is_ranked() {
            let gamma = aux_rand_elements.rand_elements()[0];
            let n = self.pub_inputs.n();
            let mut prod = E::ONE;
            for i in 0..N_MAX {
                let target = if i < n {
                    E::from(Felt::new(i as u64))
                } else {
                    E::ZERO
                };
                prod *= target + gamma;
            }
            vec![Assertion::single(AUX_Z, COMMIT_INPUT_ROW, prod)]
        } else {
            vec![Assertion::single(AUX_Z, 0, E::ZERO)]
        }
    }

    fn get_periodic_column_values(&self) -> Vec<Vec<Self::BaseField>> {
        let mut cols = Vec::new();

        let mut hash_flag = vec![Felt::ONE; CYCLE_LEN];
        hash_flag[CYCLE_LEN - 1] = Felt::ZERO;
        cols.push(hash_flag);

        let ark1 = rpo::ark1_felt();
        let ark2 = rpo::ark2_felt();
        for i in 0..rpo::STATE_WIDTH {
            let mut col = vec![Felt::ZERO; CYCLE_LEN];
            for r in 0..NUM_HASH_ROUNDS {
                col[r] = ark1[r][i];
            }
            cols.push(col);
        }
        for i in 0..rpo::STATE_WIDTH {
            let mut col = vec![Felt::ZERO; CYCLE_LEN];
            for r in 0..NUM_HASH_ROUNDS {
                col[r] = ark2[r][i];
            }
            cols.push(col);
        }

        // one-shot selectors (period = trace length)
        let mut f_bind0 = vec![Felt::ZERO; TRACE_LENGTH];
        f_bind0[0] = Felt::ONE;
        cols.push(f_bind0);

        let mut f_null = vec![Felt::ZERO; TRACE_LENGTH];
        f_null[NULL_INIT_ROW] = Felt::ONE; // 175 — nullifier idN bind
        f_null[PREV_INIT_ROW] = Felt::ONE; // 191 — prevNullifier idN bind
        cols.push(f_null);

        let mut rc_active = vec![Felt::ZERO; TRACE_LENGTH];
        for v in rc_active.iter_mut().take(RANGE_BITS) {
            *v = Felt::ONE;
        }
        cols.push(rc_active);

        let mut f_break = vec![Felt::ZERO; TRACE_LENGTH];
        f_break[NULL_INIT_ROW] = Felt::ONE; // 175 — root → nullifier
        f_break[RANK_INIT_ROW] = Felt::ONE; // 183 — nullifier → rankCommit
        f_break[PREV_INIT_ROW] = Felt::ONE; // 191 — rankCommit → prevNullifier
        cols.push(f_break);

        let mut f_perm = vec![Felt::ZERO; TRACE_LENGTH];
        f_perm[COMMIT_INPUT_ROW] = Felt::ONE; // 184
        cols.push(f_perm);

        let mut f_prevbind = vec![Felt::ZERO; TRACE_LENGTH];
        f_prevbind[PREV_DIGEST_ROW] = Felt::ONE; // 199
        cols.push(f_prevbind);

        cols
    }
}
