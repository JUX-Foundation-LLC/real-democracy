//! The off-circuit identity / commitment / nullifier scheme, in RPO-native form.
//!
//! Structurally identical to `vote.circom` (Semaphore), with `H` instantiated as the
//! RPO256 `merge` (capacity-0 two-to-one compression), scalars zero-padded into Words.
//! Because every hash here goes through [`rpo::merge`] (proven == miden's `Rpo256`),
//! the on-chain verifier and ballotbox DB can reproduce every value byte-for-byte.
//!
//! ```text
//!   secret      = RPO( [idN, idT, 0, 0] , 0 )
//!   commitment  = RPO( secret , 0 )                       // Merkle leaf
//!   nullifier   = RPO( [extNull, idN, revision, 0] , 0 )  // rotates with revision
//! ```

use winterfell::math::{fields::f64::BaseElement as Felt, FieldElement};

use crate::rpo::{self, Word, ZERO_WORD};

/// Maximum ranking length (spec §1.5 `N_max`; tunable at the cut). The ranked gadget is
/// sized for this many entries; a ranking of `N ≤ N_MAX` is padded with zeros.
pub const N_MAX: usize = 8;

/// A voter identity (derived off-circuit from VoteToken custody / RFID fob).
#[derive(Clone, Copy, Debug)]
pub struct Identity {
    pub id_nullifier: Felt,
    pub id_trapdoor: Felt,
}

impl Identity {
    pub fn new(id_nullifier: u64, id_trapdoor: u64) -> Self {
        Self {
            id_nullifier: Felt::new(id_nullifier),
            id_trapdoor: Felt::new(id_trapdoor),
        }
    }

    /// `secret = RPO(idNullifier, idTrapdoor)`
    pub fn secret(&self) -> Word {
        rpo::merge(
            &rpo::pack(&[self.id_nullifier, self.id_trapdoor]),
            &ZERO_WORD,
        )
    }

    /// `commitment = RPO(secret)` — the Merkle leaf (eligibility).
    pub fn commitment(&self) -> Word {
        rpo::merge(&self.secret(), &ZERO_WORD)
    }

    /// `nullifierHash = RPO(externalNullifier, idNullifier, revision)` — rotates per
    /// revision, so a captured nullifier is replay-dead and computing the next one
    /// requires the secret identity.
    pub fn nullifier(&self, external_nullifier: Felt, revision: Felt) -> Word {
        rpo::merge(
            &rpo::pack(&[external_nullifier, self.id_nullifier, revision]),
            &ZERO_WORD,
        )
    }
}

/// Zero-pad a ranking of length `N ≤ N_MAX` to a fixed `[Felt; N_MAX]` (the rate the
/// commitment block hashes). Padding entries are 0.
pub fn pad_ranks(ranks: &[u8]) -> [Felt; N_MAX] {
    assert!(ranks.len() <= N_MAX, "ranking longer than N_MAX");
    let mut out = [Felt::ZERO; N_MAX];
    for (i, &r) in ranks.iter().enumerate() {
        out[i] = Felt::new(r as u64);
    }
    out
}

/// The full RPO commitment to a ranking: `RPO(rank[0..N] padded to N_MAX)`. The two
/// halves of the padded rank form the two input words of one RPO `merge` (capacity 0,
/// rate 8) — exactly what commitment block 23 computes in-circuit.
pub fn ranked_commitment_word(ranks: &[u8]) -> Word {
    let p = pad_ranks(ranks);
    let left: Word = [p[0], p[1], p[2], p[3]];
    let right: Word = [p[4], p[5], p[6], p[7]];
    rpo::merge(&left, &right)
}

/// The public `voteChoice` in ranked mode: the first element of the RPO ranking
/// commitment (one field element, matching scalar mode's single `voteChoice`).
pub fn ranked_vote_choice(ranks: &[u8]) -> Felt {
    ranked_commitment_word(ranks)[0]
}

/// Fold a leaf up a Merkle authentication path to its root. `bit = false` ⇒ the running
/// node is the LEFT input (sibling on the right); `bit = true` ⇒ running node is RIGHT.
pub fn merkle_root(leaf: Word, siblings: &[Word], bits: &[bool]) -> Word {
    assert_eq!(siblings.len(), bits.len());
    let mut node = leaf;
    for (sib, &bit) in siblings.iter().zip(bits.iter()) {
        node = if bit {
            rpo::merge(sib, &node)
        } else {
            rpo::merge(&node, sib)
        };
    }
    node
}

/// The public statement a verifier checks (the proof reveals only these).
#[derive(Clone, Debug)]
pub struct VoteStatement {
    pub merkle_root: Word,
    pub external_nullifier: Felt,
    pub revision: Felt,
    /// `0` = scalar, `1` = ranked.
    pub vote_mode: Felt,
    /// Ranking length `N` (ranked mode); a public ballot parameter. Ignored in scalar.
    pub choice_count: Felt,
    /// Scalar: the value. Ranked: `ranked_vote_choice` (commitment to the ranking).
    pub vote_choice: Felt,
    pub nullifier_hash: Word,
    /// Prior revision's nullifier (vote-change chaining anchor); `0` on first cast.
    pub prev_nullifier_hash: Word,
}
