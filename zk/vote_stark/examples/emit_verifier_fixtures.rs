//! Emits fixtures for the on-chain Solidity verifier tests:
//!   * field-arithmetic reference values (Goldilocks base + GF(p^2)) computed by winter-math,
//!     so the Solidity `Goldilocks` lib is checked against the AUTHORITATIVE implementation;
//!   * real vote_stark proofs (scalar + ranked) — proof bytes + the 17 public inputs — so the
//!     Solidity public-input codec + bounds-checks run against actual prover output.
//!
//!   cargo run --release --example emit_verifier_fixtures > <fixtures.json>

use vote_stark::{prove, VoteWitness};
use winterfell::crypto::{hashers::Blake3_256, Digest, Hasher};
use winterfell::math::{
    fields::{f64::BaseElement, QuadExtension},
    FieldElement, ToElements,
};

/// The STARK's committed hash (winter-crypto 0.13.1) — the authority the Solidity Blake3 host
/// (precompile adapter) self-test pins against.
type Blake3 = Blake3_256<BaseElement>;

fn b(x: u64) -> BaseElement {
    BaseElement::new(x)
}
fn q(a0: u64, a1: u64) -> QuadExtension<BaseElement> {
    QuadExtension::new(b(a0), b(a1))
}
fn parts(x: QuadExtension<BaseElement>) -> (u64, u64) {
    let p = <QuadExtension<BaseElement> as FieldElement>::base_element(&x, 0);
    let q1 = <QuadExtension<BaseElement> as FieldElement>::base_element(&x, 1);
    (p.as_int(), q1.as_int())
}

fn hex(bytes: &[u8]) -> String {
    let mut s = String::with_capacity(2 + bytes.len() * 2);
    s.push_str("0x");
    for byte in bytes {
        s.push_str(&format!("{:02x}", byte));
    }
    s
}

fn pub_inputs_json(pi: &vote_stark::PublicInputs) -> String {
    let e: Vec<u64> = pi.to_elements().iter().map(|x| x.as_int()).collect();
    let items: Vec<String> = e.iter().map(|v| format!("\"{}\"", v)).collect();
    format!("[{}]", items.join(","))
}

fn main() {
    // ---- field references (winter-math = authority) ----
    let a = b(0x0000_0007);
    let bb = b(0x1234_5678_9abc_def0 % 0xFFFFFFFF00000001);
    let add = (a + bb).as_int();
    let mul = (a * bb).as_int();
    let inv = a.inv().as_int();
    let exp7 = a.exp7().as_int();

    let ea = q(3, 5);
    let eb = q(7, 11);
    let (em0, em1) = parts(ea * eb);
    let (es0, es1) = parts(ea.square());
    let (ei0, ei1) = parts(ea.inv());

    // ---- Blake3 self-test vectors (winter-crypto = authority; V2 precompile attestation) ----
    let v1_in: &[u8] = b"vote_stark/blake3-selftest/1";
    let v2_in: &[u8] = b"vote_stark/blake3-selftest/2 second probe so a mock cannot pass with one constant";
    let v1 = Blake3::hash(v1_in).as_bytes();
    let v2 = Blake3::hash(v2_in).as_bytes();

    // ---- real proofs ----
    let scalar_w = VoteWitness::sample(0x5CA1A5);
    let (sp, spi) = prove(&scalar_w);
    let ranked_w = VoteWitness::sample_ranked(0x4A4Ed, 4);
    let (rp, rpi) = prove(&ranked_w);

    println!("{{");
    println!("  \"field\": {{");
    println!("    \"a\": \"{}\", \"b\": \"{}\",", a.as_int(), bb.as_int());
    println!("    \"add\": \"{}\", \"mul\": \"{}\", \"inv\": \"{}\", \"exp7\": \"{}\",", add, mul, inv, exp7);
    println!("    \"ext_a\": [\"3\",\"5\"], \"ext_b\": [\"7\",\"11\"],");
    println!("    \"ext_mul\": [\"{}\",\"{}\"],", em0, em1);
    println!("    \"ext_square\": [\"{}\",\"{}\"],", es0, es1);
    println!("    \"ext_inv\": [\"{}\",\"{}\"]", ei0, ei1);
    println!("  }},");
    println!("  \"blake3\": {{");
    println!("    \"v1_in\": \"{}\", \"v1\": \"{}\",", hex(v1_in), hex(&v1));
    println!("    \"v2_in\": \"{}\", \"v2\": \"{}\"", hex(v2_in), hex(&v2));
    println!("  }},");
    println!("  \"scalar\": {{");
    println!("    \"publicInputs\": {},", pub_inputs_json(&spi));
    println!("    \"proofLen\": {},", sp.to_bytes().len());
    println!("    \"proof\": \"{}\"", hex(&sp.to_bytes()));
    println!("  }},");
    println!("  \"ranked\": {{");
    println!("    \"publicInputs\": {},", pub_inputs_json(&rpi));
    println!("    \"proofLen\": {},", rp.to_bytes().len());
    println!("    \"proof\": \"{}\"", hex(&rp.to_bytes()));
    println!("  }}");
    println!("}}");
}
