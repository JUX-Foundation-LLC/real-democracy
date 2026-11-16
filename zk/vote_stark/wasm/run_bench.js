// Runs the WASM proving benchmark under Node (no browser needed) and prints the
// in-browser/phone prove-time — the headline feasibility number (goal: prove < 2 s).
//
//   wasm-pack build --target nodejs --release --no-default-features --features wasm
//   node wasm/run_bench.js
//
// (wasm-pack emits the package into ./pkg)

const wasm = require("../pkg/vote_stark.js");

const RUNS = 5;

function benchMode(label, call) {
  let best = Infinity;
  let last = null;
  call(1); // warm-up (one-time codegen/instantiation)
  for (let i = 0; i < RUNS; i++) {
    const r = JSON.parse(call(100 + i));
    last = r;
    if (!r.verified) throw new Error(`${label}: WASM proof failed to verify!`);
    if (r.prove_ms < best) best = r.prove_ms;
  }
  console.log(
    `${label.padEnd(16)} best prove ${best.toFixed(0).padStart(4)} ms · verify ${last.verify_ms.toFixed(
      1
    )} ms · proof ${last.proof_bytes} bytes · target<2000ms ${best < 2000 ? "PASS" : "FAIL"}`
  );
  return best;
}

console.log("=== WASM feasibility (single-threaded; representative of a phone) ===");
benchMode("SCALAR", (s) => wasm.bench(s));
benchMode("RANKED N=8", (s) => wasm.bench_ranked(s, 8));
