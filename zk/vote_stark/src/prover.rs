//! Trace builder + Winterfell `Prover` implementation, plus `prove`/`verify` helpers.

use winterfell::{
    crypto::{hashers::Blake3_256, DefaultRandomCoin, MerkleTree},
    math::{fields::f64::BaseElement as Felt, FieldElement},
    matrix::ColMatrix,
    AcceptableOptions, AuxRandElements, BatchingMethod, CompositionPoly, CompositionPolyTrace,
    ConstraintCompositionCoefficients, DefaultConstraintCommitment, DefaultConstraintEvaluator,
    DefaultTraceLde, FieldExtension, PartitionOptions, Proof, ProofOptions, Prover, StarkDomain,
    Trace, TraceInfo, TracePolyTable, VerifierError,
};

use crate::air::{
    PublicInputs, VoteAir, CYCLE_LEN, MERKLE_DEPTH, NUM_BLOCKS, NUM_HASH_ROUNDS, TRACE_LENGTH,
    TRACE_WIDTH,
};
use crate::rap_trace::RapTraceTable;
use crate::rpo::{self, Word, DIGEST_SIZE, STATE_WIDTH, ZERO_WORD};
use crate::scheme::{self, merkle_root, Identity, VoteStatement, N_MAX};

/// The STARK's internal commitment/transcript hash (distinct from the in-circuit RPO).
pub type StarkHash = Blake3_256<Felt>;

// trace column indices (mirror air.rs)
const BIT: usize = 12;
const IDC: usize = 13;
const RCB: usize = 14;
const RCA: usize = 15;
const ISF: usize = 16; // isFirst flag (revision == 0)
const RATE: usize = rpo::RATE_START; // 4
const RANGE_BITS: usize = 16;

const RANK_COMMIT_BLOCK: usize = 23;
const PREV_BLOCK: usize = 24; // prevNullifier block (= NUM_BLOCKS - 1)
const COMMIT_INPUT_ROW: usize = RANK_COMMIT_BLOCK * CYCLE_LEN; // 184 — rank cells (aux product)
const PREV_DIGEST_ROW: usize = PREV_BLOCK * CYCLE_LEN + 7; // 199 — prevComputed / masking row

// WITNESS
// ================================================================================================

/// The voter's choice — scalar value or a ranking (a permutation of `[0, N)`).
#[derive(Clone, Debug)]
pub enum Choice {
    Scalar(u16),
    Ranked(Vec<u8>),
}

/// Full private witness for one anonymous vote.
#[derive(Clone, Debug)]
pub struct VoteWitness {
    pub id: Identity,
    pub external_nullifier: Felt,
    pub revision: Felt,
    pub siblings: [Word; MERKLE_DEPTH],
    pub bits: [bool; MERKLE_DEPTH],
    pub choice: Choice,
}

impl VoteWitness {
    /// Derive the public statement this witness proves.
    pub fn statement(&self) -> VoteStatement {
        let leaf = self.id.commitment();
        let (vote_mode, choice_count, vote_choice) = match &self.choice {
            Choice::Scalar(v) => (Felt::ZERO, Felt::ZERO, Felt::new(*v as u64)),
            Choice::Ranked(ranks) => (
                Felt::ONE,
                Felt::new(ranks.len() as u64),
                scheme::ranked_vote_choice(ranks),
            ),
        };
        // Cross-revision chaining anchor (F1): 0 on the first cast, else the prior
        // revision's nullifier of the SAME identity. The circuit binds this in-circuit.
        let prev_nullifier_hash = if self.revision == Felt::ZERO {
            ZERO_WORD
        } else {
            self.id
                .nullifier(self.external_nullifier, self.revision - Felt::ONE)
        };
        VoteStatement {
            merkle_root: merkle_root(leaf, &self.siblings, &self.bits),
            external_nullifier: self.external_nullifier,
            revision: self.revision,
            vote_mode,
            choice_count,
            vote_choice,
            nullifier_hash: self.id.nullifier(self.external_nullifier, self.revision),
            prev_nullifier_hash,
        }
    }

    /// The padded ranking `[Felt; N_MAX]` hashed by the commitment block (0 in scalar).
    fn rank_padded(&self) -> [Felt; N_MAX] {
        match &self.choice {
            Choice::Ranked(ranks) => scheme::pad_ranks(ranks),
            Choice::Scalar(_) => [Felt::ZERO; N_MAX],
        }
    }

    // -- test/bench helpers --

    fn sample_base(
        seed: u64,
    ) -> (
        Identity,
        Felt,
        Felt,
        [Word; MERKLE_DEPTH],
        [bool; MERKLE_DEPTH],
    ) {
        let mut rng = XorShift(seed | 1);
        let id = Identity {
            id_nullifier: Felt::new(rng.next()),
            id_trapdoor: Felt::new(rng.next()),
        };
        let mut siblings = [ZERO_WORD; MERKLE_DEPTH];
        let mut bits = [false; MERKLE_DEPTH];
        for k in 0..MERKLE_DEPTH {
            siblings[k] = [
                Felt::new(rng.next()),
                Felt::new(rng.next()),
                Felt::new(rng.next()),
                Felt::new(rng.next()),
            ];
            bits[k] = rng.next() & 1 == 1;
        }
        (
            id,
            Felt::new(rng.next()),
            Felt::new(rng.next() % 8),
            siblings,
            bits,
        )
    }

    /// A deterministic SCALAR witness (Phase-0 regression).
    pub fn sample(seed: u64) -> Self {
        let (id, ext, rev, siblings, bits) = Self::sample_base(seed);
        let vc = (XorShift(seed ^ 0x9e37).next() % 65536) as u16;
        VoteWitness {
            id,
            external_nullifier: ext,
            revision: rev,
            siblings,
            bits,
            choice: Choice::Scalar(vc),
        }
    }

    /// A deterministic RANKED witness with a valid permutation of `[0, n)` (Fisher-Yates).
    pub fn sample_ranked(seed: u64, n: usize) -> Self {
        assert!((1..=N_MAX).contains(&n), "n must be in 1..=N_MAX");
        let (id, ext, rev, siblings, bits) = Self::sample_base(seed);
        let mut ranks: Vec<u8> = (0..n as u8).collect();
        let mut rng = XorShift(seed ^ 0xfeed);
        for i in (1..n).rev() {
            let j = (rng.next() % (i as u64 + 1)) as usize;
            ranks.swap(i, j);
        }
        VoteWitness {
            id,
            external_nullifier: ext,
            revision: rev,
            siblings,
            bits,
            choice: Choice::Ranked(ranks),
        }
    }

    /// Build a ranked witness from an explicit ranking (for negative tests).
    pub fn ranked_from(seed: u64, ranks: Vec<u8>) -> Self {
        let (id, ext, rev, siblings, bits) = Self::sample_base(seed);
        VoteWitness {
            id,
            external_nullifier: ext,
            revision: rev,
            siblings,
            bits,
            choice: Choice::Ranked(ranks),
        }
    }
}

struct XorShift(u64);
impl XorShift {
    fn next(&mut self) -> u64 {
        let mut x = self.0;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        self.0 = x;
        x
    }
}

// PROVER
// ================================================================================================

pub struct VoteProver {
    options: ProofOptions,
    pub_inputs: PublicInputs,
}

impl VoteProver {
    pub fn new(options: ProofOptions, pub_inputs: PublicInputs) -> Self {
        Self {
            options,
            pub_inputs,
        }
    }

    /// Build the full execution trace from a witness.
    pub fn build_trace(&self, w: &VoteWitness) -> RapTraceTable<Felt> {
        let idn = w.id.id_nullifier;
        let idt = w.id.id_trapdoor;

        let leaf = w.id.commitment();
        let secret = w.id.secret();
        let mut node = leaf;

        let mut block_inputs: Vec<[Felt; STATE_WIDTH]> = Vec::with_capacity(NUM_BLOCKS);
        let mut block_bits: Vec<bool> = Vec::with_capacity(NUM_BLOCKS);

        // block 0: secret = merge([idN, idT, 0, 0], ZERO)
        block_inputs.push(merge_input(&rpo::pack(&[idn, idt]), &ZERO_WORD));
        block_bits.push(false);

        // block 1: commitment = merge(secret, ZERO)
        block_inputs.push(merge_input(&secret, &ZERO_WORD));
        block_bits.push(false);

        // blocks 2..21: Merkle path
        for k in 0..MERKLE_DEPTH {
            let (l, r) = if w.bits[k] {
                (w.siblings[k], node)
            } else {
                (node, w.siblings[k])
            };
            block_inputs.push(merge_input(&l, &r));
            block_bits.push(w.bits[k]);
            node = rpo::merge(&l, &r);
        }

        // block 22: nullifier = merge([extNull, idN, revision, 0], ZERO)
        block_inputs.push(merge_input(
            &rpo::pack(&[w.external_nullifier, idn, w.revision]),
            &ZERO_WORD,
        ));
        block_bits.push(false);

        // block 23: rankCommit = RPO(rank[0..N_MAX]); fresh input (chain broken at row 183)
        let rank = w.rank_padded();
        let rank_left: Word = [rank[0], rank[1], rank[2], rank[3]];
        let rank_right: Word = [rank[4], rank[5], rank[6], rank[7]];
        block_inputs.push(merge_input(&rank_left, &rank_right));
        block_bits.push(false);

        // block 24: prevNullifier = RPO(extNull, idN, revision-1) (F1); fresh input (chain
        // broken at row 191). On the first cast (revision==0) this hashes revision-1 = p-1
        // and the masking constraint ignores it (isFirst forces prevNullifierHash = 0).
        let prev_rev = w.revision - Felt::ONE;
        let prev_left = rpo::pack(&[w.external_nullifier, idn, prev_rev]);
        block_inputs.push(merge_input(&prev_left, &ZERO_WORD));
        block_bits.push(false);

        // padding blocks: keep hashing the prevNullifier digest harmlessly
        let mut last_digest = rpo::merge(&prev_left, &ZERO_WORD);
        while block_inputs.len() < TRACE_LENGTH / CYCLE_LEN {
            block_inputs.push(merge_input(&last_digest, &ZERO_WORD));
            block_bits.push(false);
            last_digest = rpo::merge(&last_digest, &ZERO_WORD);
        }

        // --- expand blocks into per-row column data ---
        let mut cols: Vec<Vec<Felt>> = vec![vec![Felt::ZERO; TRACE_LENGTH]; TRACE_WIDTH];
        for (b, input) in block_inputs.iter().enumerate() {
            let mut st = *input;
            for pos in 0..CYCLE_LEN {
                let row = b * CYCLE_LEN + pos;
                if row >= TRACE_LENGTH {
                    break;
                }
                for (i, &v) in st.iter().enumerate() {
                    cols[i][row] = v;
                }
                cols[BIT][row] = bool_felt(block_bits[b]);
                cols[IDC][row] = idn;
                if pos < NUM_HASH_ROUNDS {
                    rpo::round(&mut st, pos);
                }
            }
        }

        // --- range-check columns (16-bit MSB-first decomposition), ALWAYS populated so
        // the constraint keeps its declared degree. Scalar: the real voteChoice (tied to
        // the public value by a boundary). Ranked: a fixed non-trivial dummy (no boundary
        // ties it, so it is inert — but it must be non-zero to keep the column degree). ---
        let rc_value: u16 = match w.choice {
            Choice::Scalar(vc) => vc,
            Choice::Ranked(_) => 0x5555,
        };
        let mut acc = 0u64;
        for i in 0..RANGE_BITS {
            let bit = ((rc_value >> (RANGE_BITS - 1 - i)) & 1) as u64;
            cols[RCB][i] = Felt::new(bit);
            cols[RCA][i] = Felt::new(acc);
            acc = 2 * acc + bit;
        }
        for row in cols[RCA].iter_mut().take(TRACE_LENGTH).skip(RANGE_BITS) {
            *row = Felt::new(acc);
        }

        // --- isFirst flag (F1): pinned at the masking row to (revision == 0) ---
        cols[ISF][PREV_DIGEST_ROW] = if w.revision == Felt::ZERO {
            Felt::ONE
        } else {
            Felt::ZERO
        };

        // --- F6 degree-floor: keep BIT / RCB / RCA / ISF full-degree even for degenerate-
        // but-valid witnesses (leaf-index-0 ⇒ all bits 0; "0" scalar vote ⇒ all-zero range
        // columns; revision>0 ⇒ ISF all 0), so winterfell's debug degree-equality check does
        // not panic. Each cell sits where NO active constraint reads it, so soundness is
        // untouched: BIT row 1 is mid-block-0 (never a merge bit); RCB/RCA rows ≥16 are past
        // rc_active; ISF row 0 is not the masking row.
        cols[BIT][1] = Felt::ONE;
        cols[RCB][RANGE_BITS] = Felt::ONE;
        cols[RCA][RANGE_BITS + 1] += Felt::ONE;
        cols[ISF][0] = Felt::ONE;

        RapTraceTable::init(cols)
    }
}

/// A merge permutation's input state: rate = left‖right (state[4..12]), capacity = 0.
fn merge_input(left: &Word, right: &Word) -> [Felt; STATE_WIDTH] {
    let mut st = [Felt::ZERO; STATE_WIDTH];
    st[RATE..RATE + DIGEST_SIZE].copy_from_slice(left);
    st[RATE + DIGEST_SIZE..STATE_WIDTH].copy_from_slice(right);
    st
}

fn bool_felt(b: bool) -> Felt {
    if b {
        Felt::ONE
    } else {
        Felt::ZERO
    }
}

impl Prover for VoteProver {
    type BaseField = Felt;
    type Air = VoteAir;
    type Trace = RapTraceTable<Felt>;
    type HashFn = StarkHash;
    type VC = MerkleTree<StarkHash>;
    type RandomCoin = DefaultRandomCoin<StarkHash>;
    type TraceLde<E: FieldElement<BaseField = Felt>> = DefaultTraceLde<E, StarkHash, Self::VC>;
    type ConstraintCommitment<E: FieldElement<BaseField = Felt>> =
        DefaultConstraintCommitment<E, StarkHash, Self::VC>;
    type ConstraintEvaluator<'a, E: FieldElement<BaseField = Felt>> =
        DefaultConstraintEvaluator<'a, VoteAir, E>;

    fn get_pub_inputs(&self, _trace: &Self::Trace) -> PublicInputs {
        self.pub_inputs.clone()
    }

    fn options(&self) -> &ProofOptions {
        &self.options
    }

    fn new_trace_lde<E: FieldElement<BaseField = Felt>>(
        &self,
        trace_info: &TraceInfo,
        main_trace: &ColMatrix<Felt>,
        domain: &StarkDomain<Felt>,
        partition_option: PartitionOptions,
    ) -> (Self::TraceLde<E>, TracePolyTable<E>) {
        DefaultTraceLde::new(trace_info, main_trace, domain, partition_option)
    }

    fn new_evaluator<'a, E: FieldElement<BaseField = Felt>>(
        &self,
        air: &'a VoteAir,
        aux_rand_elements: Option<AuxRandElements<E>>,
        composition_coefficients: ConstraintCompositionCoefficients<E>,
    ) -> Self::ConstraintEvaluator<'a, E> {
        DefaultConstraintEvaluator::new(air, aux_rand_elements, composition_coefficients)
    }

    fn build_constraint_commitment<E: FieldElement<BaseField = Felt>>(
        &self,
        composition_poly_trace: CompositionPolyTrace<E>,
        num_constraint_composition_columns: usize,
        domain: &StarkDomain<Felt>,
        partition_options: PartitionOptions,
    ) -> (Self::ConstraintCommitment<E>, CompositionPoly<E>) {
        DefaultConstraintCommitment::new(
            composition_poly_trace,
            num_constraint_composition_columns,
            domain,
            partition_options,
        )
    }

    fn build_aux_trace<E>(
        &self,
        trace: &Self::Trace,
        aux_rand_elements: &AuxRandElements<E>,
    ) -> ColMatrix<E>
    where
        E: FieldElement<BaseField = Self::BaseField>,
    {
        let main = trace.main_segment();
        let gamma = aux_rand_elements.rand_elements()[0];
        let mut z = vec![E::ZERO; main.num_rows()];

        // z at the commitment-input row = ∏(rank_i + γ) over the 8 rank cells (both modes;
        // in scalar the rank cells are zero, giving z = γ^N_MAX, which no boundary checks).
        let mut prod = E::ONE;
        for i in 0..N_MAX {
            prod *= E::from(main.get(RATE + i, COMMIT_INPUT_ROW)) + gamma;
        }
        z[COMMIT_INPUT_ROW] = prod;

        ColMatrix::new(vec![z])
    }
}

// PUBLIC API
// ================================================================================================

/// Proof parameters on the Goldilocks field (quadratic extension REQUIRED for FRI/DEEP soundness
/// since the base field is 64-bit). `num_queries` re-pinned 96 → 40 by the external zk auditor
/// (storage lever): at blowup 16 the conjectured security is field-capped at 127 bits regardless of
/// query count down to ~27, so 40 holds 127-bit conjectured with comfortable proven-soundness margin
/// while shrinking every stored proof. ProofOptions only; no AIR change, no circuit re-audit.
pub fn default_options() -> ProofOptions {
    ProofOptions::new(
        40, // num_queries (auditor re-pin; was 96)
        16, // blowup factor (≥ max constraint degree; 16 covers the degree-8 ranked product)
        20, // grinding factor (bits; kept ≤20 so WASM grind stays fast)
        FieldExtension::Quadratic,
        4,  // FRI folding factor
        31, // FRI remainder max degree
        BatchingMethod::Linear,
        BatchingMethod::Linear,
    )
}

impl VoteStatement {
    /// Convert to the AIR's `PublicInputs`.
    pub fn to_public_inputs(&self) -> PublicInputs {
        PublicInputs {
            merkle_root: self.merkle_root,
            external_nullifier: self.external_nullifier,
            revision: self.revision,
            vote_mode: self.vote_mode,
            choice_count: self.choice_count,
            vote_choice: self.vote_choice,
            nullifier_hash: self.nullifier_hash,
            prev_nullifier_hash: self.prev_nullifier_hash,
        }
    }
}

/// Generate a proof for the given witness; returns the proof and the public statement.
pub fn prove(witness: &VoteWitness) -> (Proof, PublicInputs) {
    let pub_inputs = witness.statement().to_public_inputs();
    let prover = VoteProver::new(default_options(), pub_inputs.clone());
    let trace = prover.build_trace(witness);
    let proof = prover.prove(trace).expect("proving failed");
    (proof, pub_inputs)
}

/// Verify a proof against a public statement.
pub fn verify(proof: Proof, pub_inputs: PublicInputs) -> Result<(), VerifierError> {
    let acceptable = AcceptableOptions::OptionSet(vec![proof.options().clone()]);
    winterfell::verify::<VoteAir, StarkHash, DefaultRandomCoin<StarkHash>, MerkleTree<StarkHash>>(
        proof,
        pub_inputs,
        &acceptable,
    )
}
