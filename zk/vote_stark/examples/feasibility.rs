//! Native feasibility benchmark (spec §5 / §7) — Phase 1: scalar AND ranked.
//!
//! Run with:  `cargo run --release --example feasibility`
//!
//! Prints prove/verify time, proof size, and security for both vote modes. (The WASM
//! phone-proving figure — goal ≲ 2 s — is measured by `wasm/run_bench.js`.)

use std::time::Instant;

use vote_stark::prover::StarkHash;
use vote_stark::{prove, ranked_vote_choice, verify, Identity, VoteWitness, N_MAX};
use winterfell::math::fields::f64::BaseElement as Felt;

fn fmt_word(w: &[Felt; 4]) -> String {
    format!(
        "[{}, {}, {}, {}]",
        w[0].as_int(),
        w[1].as_int(),
        w[2].as_int(),
        w[3].as_int()
    )
}

fn median(mut xs: Vec<f64>) -> f64 {
    xs.sort_by(|a, b| a.partial_cmp(b).unwrap());
    xs[xs.len() / 2]
}

fn bench(label: &str, witness: &VoteWitness) {
    const N: usize = 15;
    let (proof, pi) = prove(witness);
    verify(proof.clone(), pi.clone()).expect("warm-up must verify");

    let proof_bytes = proof.to_bytes().len();
    let conj = proof.conjectured_security::<StarkHash>();
    let prov = proof.proven_security::<StarkHash>();
    let trace_info = proof.trace_info();

    let mut prove_ms = Vec::with_capacity(N);
    for _ in 0..N {
        let t = Instant::now();
        let (p, _pi) = prove(witness);
        prove_ms.push(t.elapsed().as_secs_f64() * 1000.0);
        std::hint::black_box(p);
    }
    let mut verify_ms = Vec::with_capacity(N);
    for _ in 0..N {
        let (p, q) = prove(witness);
        let t = Instant::now();
        verify(p, q).expect("verify");
        verify_ms.push(t.elapsed().as_secs_f64() * 1000.0);
    }
    let p_min = prove_ms.iter().cloned().fold(f64::INFINITY, f64::min);
    let v_min = verify_ms.iter().cloned().fold(f64::INFINITY, f64::min);

    println!("--- {label} ---");
    println!(
        "  trace            = {} rows x {} main cols (+{} aux)",
        trace_info.length(),
        trace_info.main_trace_width(),
        trace_info.aux_segment_width()
    );
    println!(
        "  proof size       = {} bytes ({:.1} KiB)",
        proof_bytes,
        proof_bytes as f64 / 1024.0
    );
    println!(
        "  prove  (native)  = {:.2} ms  (min {:.2} ms)",
        median(prove_ms),
        p_min
    );
    println!(
        "  verify (native)  = {:.2} ms  (min {:.2} ms)",
        median(verify_ms),
        v_min
    );
    println!(
        "  security         = {} bits conjectured · {} / {} bits proven (UDR / LDR)\n",
        conj.bits(),
        prov.udr_bits(),
        prov.ldr_bits()
    );
}

fn main() {
    println!("=== vote_stark — Phase-1 feasibility benchmark (unified scalar + ranked) ===\n");

    // ---- test vectors ----
    let id = Identity::new(0xA11CE, 0xBEEF);
    let ext = Felt::new(0x1234_5678);
    let ranking = vec![2u8, 0, 3, 1];
    println!("Test vectors (RPO256 / Goldilocks):");
    println!("  commitment (leaf)    = {}", fmt_word(&id.commitment()));
    println!(
        "  nullifier(rev=0)     = {}",
        fmt_word(&id.nullifier(ext, Felt::new(0)))
    );
    println!(
        "  nullifier(rev=1)     = {}",
        fmt_word(&id.nullifier(ext, Felt::new(1)))
    );
    println!(
        "  ranking {ranking:?} -> voteChoice = {}\n",
        ranked_vote_choice(&ranking).as_int()
    );

    println!("Field/hash = Goldilocks (2^64-2^32+1) / RPO256 · Merkle depth 20 · N_max = {N_MAX}");
    println!("The trace is fixed-size for every N, so ranked prove-time does not grow with N.\n");

    // ---- scalar (Phase-0 path, regression) ----
    bench("SCALAR (voteMode=0)", &VoteWitness::sample(0xDEC0DE));

    // ---- ranked, full N_MAX (the Phase-1 headline) ----
    bench(
        &format!("RANKED  (voteMode=1, N={N_MAX})"),
        &VoteWitness::sample_ranked(0xDEC0DE, N_MAX),
    );
}
