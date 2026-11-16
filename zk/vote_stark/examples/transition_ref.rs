//! Byte-exact reference for the Solidity `evaluateTransition` (FRI core part 6).
//!
//! Runs winterfell's own `VoteAir::evaluate_transition` (34 main constraints) + `evaluate_aux_transition`
//! (1 aux grand-product) on a SYNTHETIC OOD frame (arbitrary GF(p^2) rows, like parts 4–5 — byte-exactness
//! is what matters, not whether the constraints are satisfied) and dumps the 35 evaluations, so the
//! Solidity port can be checked against the circuit's own constraint code.
//!
//!   cargo run --release --example transition_ref > <transition_ref.json>

use vote_stark::{prove, PublicInputs, VoteAir, VoteWitness};
use winterfell::math::{fields::f64::BaseElement, fields::QuadExtension, FieldElement, ToElements};
use winterfell::{Air, AuxRandElements, EvaluationFrame};

type E = QuadExtension<BaseElement>;

fn e(a0: u64, a1: u64) -> E {
    QuadExtension::new(BaseElement::new(a0), BaseElement::new(a1))
}
fn parts(x: E) -> (u64, u64) {
    (
        <E as FieldElement>::base_element(&x, 0).as_int(),
        <E as FieldElement>::base_element(&x, 1).as_int(),
    )
}
fn flat(xs: &[E]) -> String {
    let s: Vec<String> = xs
        .iter()
        .map(|x| {
            let (a, b) = parts(*x);
            format!("[\"{}\",\"{}\"]", a, b)
        })
        .collect();
    format!("[{}]", s.join(","))
}

fn main() {
    // real pub_inputs so the F1 masking constraints [30..34] read real prev_nullifier_hash[k]
    let (proof, pub_inputs) = prove(&VoteWitness::sample(0x5CA1A5));
    let air = VoteAir::new(proof.trace_info().clone(), pub_inputs.clone(), proof.options().clone());
    let pub_e = <PublicInputs as ToElements<BaseElement>>::to_elements(&pub_inputs);
    let pub_s: Vec<String> = pub_e.iter().map(|x| format!("\"{}\"", x.as_int())).collect();

    // synthetic OOD frame (arbitrary, nonzero imaginary parts)
    let main_cur: Vec<E> = (0..17).map(|i| e(1000 + i as u64, 7 + i as u64)).collect();
    let main_nxt: Vec<E> = (0..17).map(|i| e(2000 + i as u64, 11 + i as u64)).collect();
    let aux_cur: Vec<E> = vec![e(5, 9)];
    let aux_nxt: Vec<E> = vec![e(6, 10)];
    let periodic: Vec<E> = (0..31).map(|i| e(3000 + i as u64, 13 + i as u64)).collect();
    let gamma = e(42, 99);

    let main_frame = EvaluationFrame::from_rows(main_cur.clone(), main_nxt.clone());
    let aux_frame = EvaluationFrame::from_rows(aux_cur.clone(), aux_nxt.clone());
    let aux_rand = AuxRandElements::new(vec![gamma]);

    let mut main_res = vec![E::ZERO; 34];
    air.evaluate_transition::<E>(&main_frame, &periodic, &mut main_res);

    let mut aux_res = vec![E::ZERO; 1];
    air.evaluate_aux_transition::<E, E>(&main_frame, &aux_frame, &periodic, &aux_rand, &mut aux_res);

    let mut all = main_res.clone();
    all.extend_from_slice(&aux_res); // 35 = 34 main + 1 aux

    println!("{{");
    println!("  \"publicInputs\": [{}],", pub_s.join(","));
    println!("  \"mainCur\": {},", flat(&main_cur));
    println!("  \"mainNxt\": {},", flat(&main_nxt));
    println!("  \"auxCur\": {},", flat(&aux_cur));
    println!("  \"auxNxt\": {},", flat(&aux_nxt));
    println!("  \"periodic\": {},", flat(&periodic));
    println!("  \"gamma\": [\"{}\",\"{}\"],", parts(gamma).0, parts(gamma).1);
    println!("  \"evaluations\": {}", flat(&all));
    println!("}}");
}
