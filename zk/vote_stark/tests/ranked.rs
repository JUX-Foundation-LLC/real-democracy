//! Phase-1 ranked-choice tests: valid permutations accepted, non-permutations rejected,
//! the ranking commitment bound, and scalar shown to be the N=1 degenerate ranked case.

use std::panic::{catch_unwind, AssertUnwindSafe};

use vote_stark::{prove, ranked_vote_choice, verify, Choice, Felt, VoteWitness};
use winterfell::math::FieldElement;

/// True if the witness CANNOT be turned into a verifying proof — either proving fails
/// (debug constraint check panics) or the produced proof is rejected by the verifier
/// (release: no debug check, so an invalid trace yields a proof that fails verification).
fn rejected(w: &VoteWitness) -> bool {
    let prev = std::panic::take_hook();
    std::panic::set_hook(Box::new(|_| {})); // silence the expected panic
    let out = catch_unwind(AssertUnwindSafe(|| {
        let (proof, pi) = prove(w);
        verify(proof, pi).is_ok()
    }));
    std::panic::set_hook(prev);
    match out {
        Ok(verified) => !verified, // produced a proof: must NOT verify
        Err(_) => true,            // panicked while proving: correctly rejected
    }
}

#[test]
fn ranked_roundtrip_all_n() {
    for n in [1usize, 2, 4, 8] {
        let w = VoteWitness::sample_ranked(1000 + n as u64, n);
        let (proof, pi) = prove(&w);
        assert_eq!(pi.vote_mode, Felt::ONE);
        assert_eq!(pi.choice_count, Felt::new(n as u64));
        verify(proof, pi).unwrap_or_else(|e| panic!("valid ranking N={n} must verify: {e}"));
    }
}

#[test]
fn ranked_vote_choice_is_the_commitment() {
    let ranks = vec![2u8, 0, 3, 1];
    let w = VoteWitness::ranked_from(7, ranks.clone());
    let (proof, pi) = prove(&w);
    assert_eq!(pi.vote_choice, ranked_vote_choice(&ranks));
    verify(proof, pi).expect("must verify");
}

#[test]
fn tampered_ranked_vote_choice_rejected() {
    let w = VoteWitness::sample_ranked(7, 6);
    let (proof, mut pi) = prove(&w);
    pi.vote_choice += Felt::ONE; // claim a different ranking commitment
    assert!(verify(proof, pi).is_err());
}

#[test]
fn non_permutation_duplicate_rejected() {
    // N=4, duplicate 0, missing 1 (the spec's example)
    assert!(rejected(&VoteWitness::ranked_from(11, vec![0, 0, 2, 3])));
}

#[test]
fn non_permutation_out_of_range_rejected() {
    // N=3, value 3 ∉ [0,3)
    assert!(rejected(&VoteWitness::ranked_from(12, vec![0, 1, 3])));
    // N=4, value 7 ∉ [0,4)
    assert!(rejected(&VoteWitness::ranked_from(13, vec![0, 1, 2, 7])));
}

#[test]
fn non_permutation_missing_value_rejected() {
    // N=4, missing 2 (1 appears twice)
    assert!(rejected(&VoteWitness::ranked_from(14, vec![0, 1, 1, 3])));
}

#[test]
fn valid_permutations_accepted() {
    // a handful of genuine permutations of [0,4)
    for r in [[0u8, 1, 2, 3], [3, 2, 1, 0], [1, 3, 0, 2], [2, 0, 3, 1]] {
        let w = VoteWitness::ranked_from(20, r.to_vec());
        assert!(!rejected(&w), "valid permutation {r:?} must be accepted");
    }
}

#[test]
fn scalar_is_the_n1_ranked_case() {
    // N=1: the only permutation of [0,1) is [0]; it is the degenerate ranked vote.
    let w = VoteWitness::ranked_from(99, vec![0]);
    let (proof, pi) = prove(&w);
    verify(proof, pi.clone()).expect("N=1 ranked must verify");

    // Its commitment is deterministic and equals the canonical ranked commitment of [0].
    assert_eq!(pi.vote_choice, ranked_vote_choice(&[0]));
    assert_eq!(pi.choice_count, Felt::ONE);

    // And any N=1 ranking must be [0] — e.g. [1] is not a permutation of [0,1).
    assert!(rejected(&VoteWitness::ranked_from(99, vec![1])));

    // Consistency: scalar mode still round-trips (the other half of the one circuit).
    let s = VoteWitness::sample(99);
    assert!(matches!(s.choice, Choice::Scalar(_)));
    let (p, spi) = prove(&s);
    assert_eq!(spi.vote_mode, Felt::ZERO);
    verify(p, spi).expect("scalar must verify");
}
