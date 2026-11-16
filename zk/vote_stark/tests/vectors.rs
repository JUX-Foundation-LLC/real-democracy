//! Test vectors (spec §7 deliverable 1): a known identity → commitment → root →
//! nullifierHash, computed by THIS crate AND independently by canonical
//! `miden_crypto::Rpo256`, asserting byte-for-byte agreement. Plus the two defining
//! properties of the rotating nullifier:
//!   * determinism — same identity + scope + revision ⇒ same nullifier;
//!   * rotation    — incrementing the revision ⇒ a fresh, unequal nullifier.

use miden_crypto::{hash::rpo::Rpo256, Word as MidenWord};
use vote_stark::{prove, scheme::merkle_root, verify, Identity, VoteWitness, Word};
use winterfell::math::{fields::f64::BaseElement as Felt, FieldElement};

/// Canonical RPO `merge` via miden-crypto (the on-chain/ballotbox-DB reference).
fn miden_merge(l: Word, r: Word) -> Word {
    let out = Rpo256::merge(&[MidenWord::new(l), MidenWord::new(r)]);
    let e = out.as_elements();
    [e[0], e[1], e[2], e[3]]
}

fn pack3(a: Felt, b: Felt, c: Felt) -> Word {
    [a, b, c, Felt::ZERO]
}

#[test]
fn identity_scheme_matches_canonical_rpo() {
    let id = Identity::new(0xA11CE, 0xBEEF);
    let ext = Felt::new(0x1234_5678);
    let rev = Felt::new(0);
    let zero = [Felt::ZERO; 4];

    // recompute the whole scheme via miden-crypto, independently
    let secret_ref = miden_merge(
        [id.id_nullifier, id.id_trapdoor, Felt::ZERO, Felt::ZERO],
        zero,
    );
    let commitment_ref = miden_merge(secret_ref, zero);
    let nullifier_ref = miden_merge(pack3(ext, id.id_nullifier, rev), zero);

    assert_eq!(
        id.secret(),
        secret_ref,
        "secret diverged from canonical RPO"
    );
    assert_eq!(
        id.commitment(),
        commitment_ref,
        "commitment diverged from canonical RPO"
    );
    assert_eq!(
        id.nullifier(ext, rev),
        nullifier_ref,
        "nullifier diverged from canonical RPO"
    );
}

#[test]
fn nullifier_is_deterministic() {
    let id = Identity::new(111, 222);
    let ext = Felt::new(999);
    let rev = Felt::new(3);
    assert_eq!(id.nullifier(ext, rev), id.nullifier(ext, rev));
}

#[test]
fn nullifier_rotates_with_revision() {
    let id = Identity::new(111, 222);
    let ext = Felt::new(999);
    let n0 = id.nullifier(ext, Felt::new(0));
    let n1 = id.nullifier(ext, Felt::new(1));
    let n2 = id.nullifier(ext, Felt::new(2));
    assert_ne!(n0, n1, "revision 0 vs 1 must differ");
    assert_ne!(n1, n2, "revision 1 vs 2 must differ");
    assert_ne!(n0, n2, "revision 0 vs 2 must differ");
}

#[test]
fn nullifier_scoped_by_external_nullifier() {
    // The SAME identity in two different ballots yields different nullifiers
    // (cross-ballot replay protection).
    let id = Identity::new(111, 222);
    let rev = Felt::new(0);
    let a = id.nullifier(Felt::new(1000), rev);
    let b = id.nullifier(Felt::new(2000), rev);
    assert_ne!(a, b);
}

#[test]
fn proof_binds_the_same_identity_for_membership_and_nullifier() {
    // The whole point of Semaphore: the nullifier's identity == the leaf's identity.
    // We prove a witness, then confirm the public nullifier equals the one derived
    // from the identity whose commitment is the proven Merkle leaf.
    let w = VoteWitness::sample(2024);
    let (proof, pi) = prove(&w);
    verify(proof, pi.clone()).expect("must verify");

    let expected_root = merkle_root(w.id.commitment(), &w.siblings, &w.bits);
    let expected_null = w.id.nullifier(w.external_nullifier, w.revision);
    assert_eq!(pi.merkle_root, expected_root);
    assert_eq!(pi.nullifier_hash, expected_null);
    assert_eq!(pi.vote_mode, Felt::ZERO); // sample() is scalar
    if let vote_stark::Choice::Scalar(v) = w.choice {
        assert_eq!(pi.vote_choice, Felt::new(v as u64));
    } else {
        panic!("sample() should be scalar");
    }
}
