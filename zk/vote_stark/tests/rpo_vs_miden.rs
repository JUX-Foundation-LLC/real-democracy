//! Proves our in-AIR RPO implementation (`vote_stark::rpo`) is BYTE-IDENTICAL to the
//! canonical `miden_crypto::hash::rpo::Rpo256`.
//!
//! This is the linchpin of the whole spike: the AIR can only prove a statement about a
//! hash it computes itself, so we re-express RPO over a generic field. If that
//! re-expression matches miden's RPO exactly, then the off-chain ballotbox DB and the
//! on-chain verifier (which will use canonical RPO256) agree byte-for-byte with what
//! the circuit proves.

use miden_crypto::{hash::rpo::Rpo256, Word as MidenWord};
use vote_stark::rpo::{self, Word};
use winterfell::math::fields::f64::BaseElement as Felt;

/// A tiny xorshift PRNG so the test is deterministic without a rand dependency.
struct Rng(u64);
impl Rng {
    fn next_u64(&mut self) -> u64 {
        let mut x = self.0;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        self.0 = x;
        x
    }
    fn felt(&mut self) -> Felt {
        Felt::new(self.next_u64())
    }
    fn word(&mut self) -> Word {
        [self.felt(), self.felt(), self.felt(), self.felt()]
    }
}

fn to_miden(w: &Word) -> MidenWord {
    MidenWord::new(*w)
}

#[test]
fn permutation_matches_miden() {
    let mut rng = Rng(0x1234_5678_9abc_def0);
    for _ in 0..200 {
        let mut a: [Felt; rpo::STATE_WIDTH] = [Felt::new(0); rpo::STATE_WIDTH];
        for s in a.iter_mut() {
            *s = rng.felt();
        }
        let mut mine = a;
        let mut theirs = a;
        rpo::permutation(&mut mine);
        Rpo256::apply_permutation(&mut theirs);
        assert_eq!(mine, theirs, "RPO permutation diverged from miden-crypto");
    }
}

#[test]
fn merge_matches_miden() {
    let mut rng = Rng(0xdead_beef_cafe_babe);
    for _ in 0..200 {
        let l = rng.word();
        let r = rng.word();
        let mine = rpo::merge(&l, &r);
        let theirs = Rpo256::merge(&[to_miden(&l), to_miden(&r)]);
        assert_eq!(
            &mine[..],
            theirs.as_elements(),
            "RPO merge diverged from miden-crypto"
        );
    }
}

#[test]
fn merge_is_deterministic() {
    let l = [Felt::new(1), Felt::new(2), Felt::new(3), Felt::new(4)];
    let r = rpo::ZERO_WORD;
    assert_eq!(rpo::merge(&l, &r), rpo::merge(&l, &r));
}
