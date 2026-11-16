//! Byte-exact reference for FRI-core part 2: the coin SEED from a real proof's `Context`, and the
//! first real challenges — γ (RAP aux rand, after the main-trace commitment) and z (the OOD point,
//! after the constraint commitment). Replays winterfell's exact coin ops (`perform_verification`)
//! on REAL proofs through a tracing `Blake3_256` that captures every genuine (preimage → digest),
//! so the Solidity verifier can reproduce seed/γ/z on the same proofs with TRUE Blake3.
//!
//!   cargo run --release --example seed_draw_ref > <seed_draw_ref.json>

use core::cell::RefCell;

use vote_stark::{prove, PublicInputs, VoteAir, VoteWitness};
use winterfell::crypto::{hashers::Blake3_256, DefaultRandomCoin, Digest, ElementHasher, Hasher, RandomCoin};
use winterfell::math::{fields::f64::BaseElement, fields::QuadExtension, FieldElement, ToElements};
use winterfell::Air;

type B3 = Blake3_256<BaseElement>;
type E = QuadExtension<BaseElement>;

thread_local! {
    static LOG: RefCell<Vec<(Vec<u8>, [u8; 32])>> = const { RefCell::new(Vec::new()) };
}
fn record(pre: Vec<u8>, dig: [u8; 32]) {
    LOG.with(|l| l.borrow_mut().push((pre, dig)));
}

/// `Blake3_256` that records every (preimage → genuine digest); see transcript_ref.rs.
struct TB3;
impl Hasher for TB3 {
    type Digest = <B3 as Hasher>::Digest;
    const COLLISION_RESISTANCE: u32 = 128;
    fn hash(bytes: &[u8]) -> Self::Digest {
        let d = B3::hash(bytes);
        record(bytes.to_vec(), d.as_bytes());
        d
    }
    fn merge(values: &[Self::Digest; 2]) -> Self::Digest {
        let mut p = Vec::with_capacity(64);
        p.extend_from_slice(&values[0].as_bytes());
        p.extend_from_slice(&values[1].as_bytes());
        let d = B3::merge(values);
        record(p, d.as_bytes());
        d
    }
    fn merge_many(values: &[Self::Digest]) -> Self::Digest {
        let mut p = Vec::new();
        for v in values {
            p.extend_from_slice(&v.as_bytes());
        }
        let d = B3::merge_many(values);
        record(p, d.as_bytes());
        d
    }
    fn merge_with_int(seed: Self::Digest, value: u64) -> Self::Digest {
        let mut p = Vec::with_capacity(40);
        p.extend_from_slice(&seed.as_bytes());
        p.extend_from_slice(&value.to_le_bytes());
        let d = B3::merge_with_int(seed, value);
        record(p, d.as_bytes());
        d
    }
}
impl ElementHasher for TB3 {
    type BaseField = BaseElement;
    fn hash_elements<EE: FieldElement<BaseField = BaseElement>>(elements: &[EE]) -> Self::Digest {
        let base = EE::slice_as_base_elements(elements);
        let mut p = Vec::with_capacity(base.len() * 8);
        for b in base {
            p.extend_from_slice(&b.as_int().to_le_bytes());
        }
        let d = B3::hash_elements(elements);
        record(p, d.as_bytes());
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
fn parts(x: E) -> (u64, u64) {
    (
        <E as FieldElement>::base_element(&x, 0).as_int(),
        <E as FieldElement>::base_element(&x, 1).as_int(),
    )
}

fn dump(name: &str, witness: &VoteWitness, last: bool) {
    LOG.with(|l| l.borrow_mut().clear());

    let (proof, pub_inputs) = prove(witness);
    let air = VoteAir::new(proof.trace_info().clone(), pub_inputs.clone(), proof.options().clone());

    let ctx_elems_f: Vec<BaseElement> = proof.context.to_elements();
    let ctx_elems: Vec<String> = ctx_elems_f.iter().map(|e| format!("\"{}\"", e.as_int())).collect();
    let pe = <PublicInputs as ToElements<BaseElement>>::to_elements(&pub_inputs);
    let pub_s: Vec<String> = pe.iter().map(|e| format!("\"{}\"", e.as_int())).collect();
    let mut seed_elems = ctx_elems_f.clone();
    seed_elems.extend(pe.iter().cloned());
    let seed = B3::hash_elements(&seed_elems);

    let fri_options = air.options().to_fri_options();
    let num_fri_layers = fri_options.num_fri_layers(air.lde_domain_size());
    let (trace_roots, constraint_root, fri_roots) =
        proof.commitments.clone().parse::<B3>(2, num_fri_layers).expect("parse commitments");
    let num_q = air.context().num_constraint_composition_columns();

    // replay the WHOLE coin chain, capturing genuine Blake3 (preimage → digest) into LOG.
    let mut coin = DefaultRandomCoin::<TB3>::new(&seed_elems);
    coin.reseed(trace_roots[0]); // main-trace commitment
    let gamma = coin.draw::<E>().unwrap(); // RAP aux rand
    coin.reseed(trace_roots[1]); // aux-trace commitment
    let _cc = air.get_constraint_composition_coefficients::<E, DefaultRandomCoin<TB3>>(&mut coin).unwrap();
    coin.reseed(constraint_root); // constraint commitment
    let z = coin.draw::<E>().unwrap(); // OOD point

    // OOD reseed: hash_elements(merge_ood_evaluations(trace_frame, quotient_frame))
    let (ootf, oqf) = proof.ood_frame.clone().parse::<E>(17, 1, num_q).expect("parse ood");
    let mut ood_evals = ootf.current_row().to_vec();
    ood_evals.extend_from_slice(oqf.current_row());
    ood_evals.extend_from_slice(ootf.next_row());
    ood_evals.extend_from_slice(oqf.next_row());
    let ood_digest = <TB3 as ElementHasher>::hash_elements(&ood_evals);
    coin.reseed(ood_digest);

    let _deep = air.get_deep_composition_coefficients::<E, DefaultRandomCoin<TB3>>(&mut coin).unwrap();

    let mut alphas = Vec::new();
    for root in fri_roots.iter() {
        coin.reseed(*root); // FRI layer (and remainder) commitment
        alphas.push(coin.draw::<E>().unwrap());
    }

    let pow_nonce = proof.pow_nonce;
    let num_queries = air.options().num_queries(); // re-pinned to 40 (was hardcoded 96)
    let positions = coin.draw_integers(num_queries, air.lde_domain_size(), pow_nonce).unwrap();

    let (g0, g1) = parts(gamma);
    let (z0, z1) = parts(z);
    let alphas_s: Vec<String> = alphas
        .iter()
        .map(|a| {
            let (a0, a1) = parts(*a);
            format!("[\"{}\",\"{}\"]", a0, a1)
        })
        .collect();
    let pos_s: Vec<String> = positions.iter().map(|p| format!("\"{}\"", p)).collect();
    let proof_bytes = proof.to_bytes();
    let table: Vec<String> = LOG.with(|l| {
        l.borrow()
            .iter()
            .map(|(pre, dig)| format!("    {{\"pre\":\"{}\",\"dig\":\"{}\"}}", hexs(pre), hexs(dig)))
            .collect()
    });

    println!("  \"{}\": {{", name);
    println!("    \"publicInputs\": [{}],", pub_s.join(","));
    println!("    \"contextElems\": [{}],", ctx_elems.join(","));
    println!("    \"numConstraints\": {},", proof.context.num_constraints());
    println!("    \"numQuotients\": {},", num_q);
    println!("    \"friRootCount\": {},", fri_roots.len());
    println!("    \"seed\": \"{}\",", hexs(&seed.as_bytes()));
    println!("    \"mainRoot\": \"{}\",", hexs(&trace_roots[0].as_bytes()));
    println!("    \"auxRoot\": \"{}\",", hexs(&trace_roots[1].as_bytes()));
    println!("    \"constraintRoot\": \"{}\",", hexs(&constraint_root.as_bytes()));
    println!("    \"gamma\": [\"{}\",\"{}\"],", g0, g1);
    println!("    \"z\": [\"{}\",\"{}\"],", z0, z1);
    println!("    \"oodDigest\": \"{}\",", hexs(&ood_digest.as_bytes()));
    println!("    \"alphas\": [{}],", alphas_s.join(","));
    println!("    \"powNonce\": \"{}\",", pow_nonce);
    println!("    \"positions\": [{}],", pos_s.join(","));
    println!("    \"proof\": \"{}\",", hexs(&proof_bytes));
    println!("    \"table\": [\n{}\n    ]", table.join(",\n"));
    println!("  }}{}", if last { "" } else { "," });
}

fn main() {
    println!("{{");
    dump("scalar", &VoteWitness::sample(0x5CA1A5), false);
    dump("ranked", &VoteWitness::sample_ranked(0x4A4Ed, 4), true);
    println!("}}");
}
