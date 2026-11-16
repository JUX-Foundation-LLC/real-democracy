//! Byte-exact reference for the Solidity Fiat-Shamir transcript (the FRI-core spine).
//!
//! Runs winterfell's REAL `DefaultRandomCoin<Blake3_256<Goldilocks>>` through a scripted sequence
//! (new → draw base ×2 → draw quad → reseed → draw quad → check_leading_zeros → draw_integers) and
//! dumps every drawn value. To let the Solidity test reproduce this with TRUE Blake3 (the EVM has
//! no Blake3 opcode), it wraps the coin's hasher in `TracingBlake3`, which delegates to the real
//! `Blake3_256` and records every (preimage → digest) the coin computes. The Solidity test feeds
//! those pairs into a lookup-backed Blake3 mock, so its transcript hits real Blake3 outputs and
//! MUST match winterfell's draws byte-for-byte (a wrong preimage misses the table and reverts).
//!
//!   cargo run --release --example transcript_ref > <transcript_ref.json>

use core::cell::RefCell;

use winterfell::crypto::{
    hashers::Blake3_256, DefaultRandomCoin, Digest, ElementHasher, Hasher, RandomCoin,
};
use winterfell::math::{fields::f64::BaseElement, fields::QuadExtension, FieldElement};

type B3 = Blake3_256<BaseElement>;

thread_local! {
    // (preimage bytes, 32-byte digest) for every hash the coin performs.
    static LOG: RefCell<Vec<(Vec<u8>, [u8; 32])>> = const { RefCell::new(Vec::new()) };
}

fn record(preimage: Vec<u8>, digest: [u8; 32]) {
    LOG.with(|l| l.borrow_mut().push((preimage, digest)));
}

/// A `Blake3_256` that records every (preimage → digest). Delegates the actual hashing to the real
/// `Blake3_256`, so digests are genuine; we only reconstruct the preimage bytes (verified against
/// winter-crypto's serialization in `mod.rs`: merge = a‖b, merge_with_int = seed‖v_le8,
/// hash_elements = canonical 8-LE per base element).
struct TracingBlake3;

impl Hasher for TracingBlake3 {
    type Digest = <B3 as Hasher>::Digest;
    const COLLISION_RESISTANCE: u32 = 128;

    fn hash(bytes: &[u8]) -> Self::Digest {
        let d = B3::hash(bytes);
        record(bytes.to_vec(), d.as_bytes());
        d
    }

    fn merge(values: &[Self::Digest; 2]) -> Self::Digest {
        let mut pre = Vec::with_capacity(64);
        pre.extend_from_slice(&values[0].as_bytes());
        pre.extend_from_slice(&values[1].as_bytes());
        let d = B3::merge(values);
        record(pre, d.as_bytes());
        d
    }

    fn merge_many(values: &[Self::Digest]) -> Self::Digest {
        let mut pre = Vec::new();
        for v in values {
            pre.extend_from_slice(&v.as_bytes());
        }
        let d = B3::merge_many(values);
        record(pre, d.as_bytes());
        d
    }

    fn merge_with_int(seed: Self::Digest, value: u64) -> Self::Digest {
        let mut pre = Vec::with_capacity(40);
        pre.extend_from_slice(&seed.as_bytes());
        pre.extend_from_slice(&value.to_le_bytes());
        let d = B3::merge_with_int(seed, value);
        record(pre, d.as_bytes());
        d
    }
}

impl ElementHasher for TracingBlake3 {
    type BaseField = BaseElement;

    fn hash_elements<E: FieldElement<BaseField = BaseElement>>(elements: &[E]) -> Self::Digest {
        // canonical 8-LE bytes per base element (IS_CANONICAL=false → serialize path; same bytes).
        let base = E::slice_as_base_elements(elements);
        let mut pre = Vec::with_capacity(base.len() * 8);
        for b in base {
            pre.extend_from_slice(&b.as_int().to_le_bytes());
        }
        let d = B3::hash_elements(elements);
        record(pre, d.as_bytes());
        d
    }
}

fn hexs(b: &[u8]) -> String {
    let mut s = String::from("0x");
    for x in b {
        s.push_str(&format!("{:02x}", x));
    }
    s
}

fn main() {
    let seed_elems: Vec<BaseElement> =
        [1u64, 2, 3, 17, 256, 0xffff_ffff, 9].iter().map(|&x| BaseElement::new(x)).collect();
    let nonce: u64 = 0x0123_4567_89ab_cdef;
    let num_ints: usize = 12;
    let domain_size: usize = 4096; // 2^12

    let mut coin = DefaultRandomCoin::<TracingBlake3>::new(&seed_elems);

    let b1 = coin.draw::<BaseElement>().unwrap().as_int();
    let b2 = coin.draw::<BaseElement>().unwrap().as_int();

    let q1 = coin.draw::<QuadExtension<BaseElement>>().unwrap();
    let q1a = <QuadExtension<BaseElement> as FieldElement>::base_element(&q1, 0).as_int();
    let q1b = <QuadExtension<BaseElement> as FieldElement>::base_element(&q1, 1).as_int();

    let reseed_data = B3::hash(b"reseed-probe");
    coin.reseed(reseed_data);

    let q2 = coin.draw::<QuadExtension<BaseElement>>().unwrap();
    let q2a = <QuadExtension<BaseElement> as FieldElement>::base_element(&q2, 0).as_int();
    let q2b = <QuadExtension<BaseElement> as FieldElement>::base_element(&q2, 1).as_int();

    let lz = coin.check_leading_zeros(nonce);

    let ints = coin.draw_integers(num_ints, domain_size, nonce).unwrap();

    // emit
    let seeds: Vec<String> = seed_elems.iter().map(|e| format!("\"{}\"", e.as_int())).collect();
    let ints_s: Vec<String> = ints.iter().map(|v| format!("\"{}\"", v)).collect();
    let table: Vec<String> = LOG.with(|l| {
        l.borrow()
            .iter()
            .map(|(pre, dig)| format!("    {{\"pre\":\"{}\",\"dig\":\"{}\"}}", hexs(pre), hexs(dig)))
            .collect()
    });

    println!("{{");
    println!("  \"seedElems\": [{}],", seeds.join(","));
    println!("  \"reseedData\": \"{}\",", hexs(&reseed_data.as_bytes()));
    println!("  \"nonce\": \"{}\",", nonce);
    println!("  \"numInts\": {}, \"domainSize\": {},", num_ints, domain_size);
    println!("  \"b1\": \"{}\", \"b2\": \"{}\",", b1, b2);
    println!("  \"q1\": [\"{}\",\"{}\"], \"q2\": [\"{}\",\"{}\"],", q1a, q1b, q2a, q2b);
    println!("  \"lz\": {},", lz);
    println!("  \"ints\": [{}],", ints_s.join(","));
    println!("  \"table\": [\n{}\n  ]", table.join(",\n"));
    println!("}}");
}
