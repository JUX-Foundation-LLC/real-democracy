//! # vote_stark — Phase-0 feasibility spike
//!
//! A faithful Winterfell zk-STARK port of LAIVE's `vote.circom` (Semaphore-style
//! anonymous vote), switched onto the locked re-genesis substrate: **Goldilocks field
//! + RPO256 hash** (see `audits/REGENESIS_SPEC.md`).
//!
//! The circuit proves, in zero knowledge, that the prover:
//!   1. **(membership)** knows an identity whose `commitment` is a leaf of a depth-20
//!      Merkle tree with public `merkleRoot`;
//!   2. **(nullifier)** derived the public `nullifierHash = RPO(externalNullifier,
//!      identityNullifier, revision)` from the *same* identity (rotating per revision);
//!   3. **(choice)** committed a `voteChoice` in `[0, 2^16)`, bound into the trace.
//!
//! Identity scheme (RPO-native, structurally identical to the circom):
//! ```text
//!   secret      = RPO(identityNullifier, identityTrapdoor)
//!   commitment  = RPO(secret)                 // Merkle leaf
//!   nullifier   = RPO(externalNullifier, identityNullifier, revision)
//! ```
//!
//! Scope: SCALAR vote only. Ranked-choice (§1.4) and the on-chain verifier are out of
//! scope for this spike (stubbed / built separately).

// Index loops are intentional throughout: AIR / hash code reads far clearer when state,
// MDS rows, and trace columns are addressed by position (mirrors winterfell's own examples).
#![allow(clippy::needless_range_loop)]

pub mod air;
pub mod prover;
pub mod rap_trace;
pub mod rpo;
pub mod scheme;
pub mod utils;

#[cfg(feature = "wasm")]
pub mod wasm;

pub use air::{PublicInputs, VoteAir, MERKLE_DEPTH};
pub use prover::{default_options, prove, verify, Choice, VoteProver, VoteWitness};
pub use scheme::{merkle_root, ranked_vote_choice, Identity, VoteStatement, N_MAX};

pub use rpo::Word;
/// The Goldilocks base field element (re-exported for callers/tests).
pub use winterfell::math::fields::f64::BaseElement as Felt;
