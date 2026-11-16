//! Byte-exact reference for the Solidity `periodicValuesAt(z)` (FRI core part 5).
//!
//! The verifier evaluates each of the 31 periodic columns at the OOD point z, exactly as
//! winter-verifier's `evaluate_constraints` does: `eval(periodic_poly_i, z^(trace_len/period_i))`.
//! Columns 0..25 are period-8 (hash_flag + ARK1[12] + ARK2[12], dense) → we bake their 8 coeffs and
//! Horner-eval. Columns 25..31 are period-256 selectors (sparse: ~24 nonzero rows total) → we bake
//! only the nonzero rows and evaluate via the barycentric-over-subgroup formula.
//!
//! Crucially this dumps BOTH the ground truth (Winterfell's `eval`) AND asserts our barycentric
//! formula equals it in Rust, so the Solidity port rests on a self-validated formula + the exact
//! root-of-unity Winterfell uses.
//!
//!   cargo run --release --example periodic_ref > <periodic_ref.json>

use vote_stark::{prove, VoteAir, VoteWitness};
use winterfell::math::{fields::f64::BaseElement, fields::QuadExtension, polynom, FieldElement, StarkField};
use winterfell::Air;

type E = QuadExtension<BaseElement>;

const TRACE_LEN: usize = 256;

fn parts(x: E) -> (u64, u64) {
    (
        <E as FieldElement>::base_element(&x, 0).as_int(),
        <E as FieldElement>::base_element(&x, 1).as_int(),
    )
}

/// barycentric eval of the column whose period-N subgroup values are `v` (here indicator selectors:
/// `v_i = 1` at `nonzero_rows`, else 0), at point y:  ((y^N - 1)/N) * Σ_{i: v_i=1} ω^i/(y - ω^i).
fn barycentric_selector(nonzero_rows: &[usize], y: E, omega: BaseElement, n: usize) -> E {
    let y_n = y.exp_vartime((n as u32).into());
    let pref = (y_n - E::ONE) * E::from(BaseElement::new(n as u64)).inv();
    let mut acc = E::ZERO;
    for &i in nonzero_rows {
        let wi = omega.exp_vartime((i as u32).into()); // ω^i (base)
        acc += E::from(wi) * (y - E::from(wi)).inv();
    }
    pref * acc
}

fn main() {
    let (proof, pub_inputs) = prove(&VoteWitness::sample(0x5CA1A5));
    let air = VoteAir::new(proof.trace_info().clone(), pub_inputs.clone(), proof.options().clone());

    let polys = air.get_periodic_column_polys(); // coeff form, 31 columns
    let values = air.get_periodic_column_values(); // value arrays, 31 columns
    assert_eq!(polys.len(), 31);

    // a deterministic OOD-like point with nonzero imaginary part
    let z = QuadExtension::new(BaseElement::new(0xABCD_1234_5678), BaseElement::new(0x9999_0001));

    // ground truth: winterfell's exact computation for every column
    let mut target: Vec<E> = Vec::new();
    for poly in polys.iter() {
        let num_cycles = (TRACE_LEN / poly.len()) as u32;
        let x = z.exp_vartime(num_cycles.into());
        let poly_e: Vec<E> = poly.iter().map(|&c| E::from(c)).collect();
        target.push(polynom::eval(&poly_e, x));
    }

    // self-validate the barycentric selector formula (cols 25..31, period 256) vs ground truth
    let omega256 = BaseElement::get_root_of_unity(8); // 2^8 = 256-th root of unity
    let y256 = z; // num_cycles == 1
    let mut selector_rows: Vec<Vec<usize>> = Vec::new();
    for col in 25..31 {
        let rows: Vec<usize> =
            values[col].iter().enumerate().filter(|(_, v)| **v == BaseElement::ONE).map(|(i, _)| i).collect();
        let bary = barycentric_selector(&rows, y256, omega256, TRACE_LEN);
        assert_eq!(bary, target[col], "barycentric != winterfell at col {col}");
        selector_rows.push(rows);
    }

    // emit
    let hexu = |b: &BaseElement| b.as_int().to_string();
    let coeffs8: Vec<String> = (0..25)
        .map(|c| {
            let cs: Vec<String> = polys[c].iter().map(|x| format!("\"{}\"", hexu(x))).collect();
            format!("[{}]", cs.join(","))
        })
        .collect();
    let sel: Vec<String> = selector_rows
        .iter()
        .map(|rows| {
            let rs: Vec<String> = rows.iter().map(|r| r.to_string()).collect();
            format!("[{}]", rs.join(","))
        })
        .collect();
    let vals: Vec<String> = target.iter().map(|v| { let (a, b) = parts(*v); format!("[\"{}\",\"{}\"]", a, b) }).collect();

    // packed hex of the 25×8 period-8 coeffs (8 LE bytes each), col-major, for the Solidity constant
    let mut packed = String::from("0x");
    for c in 0..25 {
        for k in 0..8 {
            for b in polys[c][k].as_int().to_le_bytes() {
                packed.push_str(&format!("{:02x}", b));
            }
        }
    }

    println!("{{");
    println!("  \"z\": [\"{}\",\"{}\"],", parts(z).0, parts(z).1);
    println!("  \"omega256\": \"{}\",", hexu(&omega256));
    println!("  \"coeffs8Packed\": \"{}\",", packed);
    println!("  \"coeffs8\": [{}],", coeffs8.join(","));
    println!("  \"selectorRows\": [{}],", sel.join(","));
    println!("  \"values\": [{}]", vals.join(","));
    println!("}}");
}
