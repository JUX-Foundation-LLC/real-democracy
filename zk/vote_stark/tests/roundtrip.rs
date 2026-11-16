//! prove → verify roundtrip + negative tests (tampered public inputs must be rejected).

use vote_stark::{prove, verify, Felt, VoteWitness};
use winterfell::math::FieldElement;

#[test]
fn prove_verify_roundtrip() {
    let w = VoteWitness::sample(42);
    let (proof, pub_inputs) = prove(&w);
    verify(proof, pub_inputs).expect("honest proof must verify");
}

#[test]
fn roundtrip_many_witnesses() {
    for seed in [1u64, 7, 99, 1234, 0xabcdef] {
        let w = VoteWitness::sample(seed);
        let (proof, pi) = prove(&w);
        verify(proof, pi).unwrap_or_else(|e| panic!("seed {seed} failed: {e}"));
    }
}

#[test]
fn wrong_root_rejected() {
    let w = VoteWitness::sample(7);
    let (proof, mut pi) = prove(&w);
    pi.merkle_root[0] += Felt::ONE; // tamper with the eligibility root
    assert!(verify(proof, pi).is_err(), "tampered root must be rejected");
}

#[test]
fn wrong_nullifier_rejected() {
    let w = VoteWitness::sample(7);
    let (proof, mut pi) = prove(&w);
    pi.nullifier_hash[0] += Felt::ONE;
    assert!(
        verify(proof, pi).is_err(),
        "tampered nullifier must be rejected"
    );
}

#[test]
fn wrong_choice_rejected() {
    let w = VoteWitness::sample(7);
    let (proof, mut pi) = prove(&w);
    pi.vote_choice += Felt::ONE;
    assert!(
        verify(proof, pi).is_err(),
        "tampered vote choice must be rejected"
    );
}
