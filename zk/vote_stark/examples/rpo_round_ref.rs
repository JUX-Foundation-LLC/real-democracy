//! Byte-exact reference for the Solidity RPO round constraint (FRI core part 4 — the meaty math).
//!
//! The bulk of vote_stark's 34 main transition constraints are RPO permutation rounds, enforced as
//! the degree-7 relation `sbox(next) = MDS·sbox(MDS·cur + ARK1) + ARK2` (see rpo.rs::enforce_round).
//! This dumps the round constraint (and its building blocks `apply_mds`, `pow7`) over GF(p^2) on
//! deterministic Fp2 inputs, so `RpoConstraints.sol` can be checked against the circuit's own code.
//!
//!   cargo run --release --example rpo_round_ref > <rpo_round_ref.json>

use vote_stark::rpo::{apply_mds, enforce_round, pow7, MDS_ROW0, STATE_WIDTH};
use vote_stark::Felt;
use winterfell::math::{fields::QuadExtension, FieldElement};

type E = QuadExtension<Felt>;

fn e(a0: u64, a1: u64) -> E {
    QuadExtension::new(Felt::new(a0), Felt::new(a1))
}
fn parts(x: E) -> (u64, u64) {
    (
        <E as FieldElement>::base_element(&x, 0).as_int(),
        <E as FieldElement>::base_element(&x, 1).as_int(),
    )
}
/// flatten [E;12] -> "[\"a0\",\"a1\", ...]" (24 base limbs).
fn flat(xs: &[E]) -> String {
    let mut s = Vec::new();
    for x in xs {
        let (a0, a1) = parts(*x);
        s.push(format!("\"{}\"", a0));
        s.push(format!("\"{}\"", a1));
    }
    format!("[{}]", s.join(","))
}

fn main() {
    // deterministic Fp2 inputs with nonzero imaginary parts (exercise the full extension math).
    let mut current = [E::ZERO; STATE_WIDTH];
    let mut next = [E::ZERO; STATE_WIDTH];
    let mut ark1 = [E::ZERO; STATE_WIDTH];
    let mut ark2 = [E::ZERO; STATE_WIDTH];
    for i in 0..STATE_WIDTH {
        let k = i as u64;
        current[i] = e(1000 + k, 7 + k);
        next[i] = e(2000 + k, 11 + k);
        ark1[i] = e(3000 + k, 13 + k);
        ark2[i] = e(4000 + k, 17 + k);
    }
    let flag = e(5, 9);

    let mut result = [E::ZERO; STATE_WIDTH];
    enforce_round(&mut result, &current, &next, &ark1, &ark2, flag);

    // granular building blocks
    let mds_out = apply_mds(&current);
    let p7 = pow7(e(9, 4));

    // a non-zero accumulator start, to prove enforceRound ACCUMULATES (result[i] += ...)
    let mut result_acc = [E::ZERO; STATE_WIDTH];
    for i in 0..STATE_WIDTH {
        result_acc[i] = e(100 + i as u64, 200 + i as u64);
    }
    enforce_round(&mut result_acc, &current, &next, &ark1, &ark2, flag);

    let mds_row0: Vec<String> = MDS_ROW0.iter().map(|c| format!("\"{}\"", c)).collect();
    let (p70, p71) = parts(p7);

    println!("{{");
    println!("  \"mdsRow0\": [{}],", mds_row0.join(","));
    println!("  \"current\": {},", flat(&current));
    println!("  \"next\": {},", flat(&next));
    println!("  \"ark1\": {},", flat(&ark1));
    println!("  \"ark2\": {},", flat(&ark2));
    println!("  \"flag\": [\"{}\",\"{}\"],", parts(flag).0, parts(flag).1);
    println!("  \"mdsOut\": {},", flat(&mds_out));
    println!("  \"pow7In\": [\"9\",\"4\"], \"pow7Out\": [\"{}\",\"{}\"],", p70, p71);
    println!("  \"result\": {},", flat(&result));
    println!("  \"accStart\": {},", flat(&{
        let mut a = [E::ZERO; STATE_WIDTH];
        for i in 0..STATE_WIDTH { a[i] = e(100 + i as u64, 200 + i as u64); }
        a
    }));
    println!("  \"resultAcc\": {}", flat(&result_acc));
    println!("}}");
}
