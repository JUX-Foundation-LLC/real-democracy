//! WASM / wasm-bindgen entry points for in-browser (phone) proving (spec §7
//! deliverable 2). Compiled single-threaded (no rayon), the way a phone runs it.
//!
//! Build:  `wasm-pack build --target nodejs --release --no-default-features --features wasm`
//! Run:    `node wasm/run_bench.js`

use wasm_bindgen::prelude::*;

use crate::{prove, verify, VoteWitness};

fn bench_witness(witness: &VoteWitness) -> String {
    let t0 = js_sys::Date::now();
    let (proof, pub_inputs) = prove(witness);
    let prove_ms = js_sys::Date::now() - t0;

    let proof_bytes = proof.to_bytes().len();

    let t1 = js_sys::Date::now();
    let verified = verify(proof, pub_inputs).is_ok();
    let verify_ms = js_sys::Date::now() - t1;

    format!(
        "{{\"prove_ms\":{:.2},\"verify_ms\":{:.2},\"proof_bytes\":{},\"verified\":{}}}",
        prove_ms, verify_ms, proof_bytes, verified
    )
}

/// Prove a SCALAR vote in-browser; returns JSON with the feasibility numbers.
#[wasm_bindgen]
pub fn bench(seed: u32) -> String {
    bench_witness(&VoteWitness::sample(seed as u64))
}

/// Prove a RANKED vote of length `n` in-browser (the Phase-1 headline; goal ≲ 2 s).
#[wasm_bindgen]
pub fn bench_ranked(seed: u32, n: u32) -> String {
    bench_witness(&VoteWitness::sample_ranked(seed as u64, n as usize))
}
