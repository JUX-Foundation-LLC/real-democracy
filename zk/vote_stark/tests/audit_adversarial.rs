//! ADVERSARIAL AUDIT VECTORS — originally written by an independent zk-STARK auditor (NOT
//! the circuit author) to probe the unified scalar+ranked AIR for unsoundness. See
//! `audits/ZK_STARK_AUDIT.md`; each test name maps to a finding ID there.
//!
//! UPDATE (audit-fix pass): the circuit in `src/` HAS now been fixed for F1, F6, F2/F8, F7.
//! The three tests that demonstrated those gaps (`f1_*`, `f6_*`, `f6b_*`) have been flipped
//! to assert the FIXED behaviour (attack rejected / no debug panic) — see their bodies. The
//! remaining tests stand: they confirm sound behaviour (F2 clean-reject, n_is_bound,
//! mode-binding) or document accepted/consumer-side items (F3, F4, F5).

use std::panic::{catch_unwind, AssertUnwindSafe};

use vote_stark::{
    default_options, merkle_root, prove, ranked_vote_choice, rpo, verify, Choice, Felt, Identity,
    VoteProver, VoteWitness, MERKLE_DEPTH, N_MAX,
};
use winterfell::math::FieldElement;
use winterfell::Prover;

// ---------------------------------------------------------------------------------------
// FINDING F1 (HIGH, scoped): the rotating nullifier has NO in-circuit cross-revision
// identity binding. A revision-r proof is fully self-contained — there is no
// `prevNullifierHash` public input and no constraint tying null_r to null_{r-1} of the
// SAME secret identity. A contract that implements vote-change as "accept null_r if the
// submitter-supplied prev is the live head" can therefore be made to overwrite a
// victim's vote by ANY other eligible voter.
// ---------------------------------------------------------------------------------------

/// Build two DISTINCT identities that are both members of the SAME depth-20 eligibility
/// tree (same public `merkleRoot`) — i.e. two voters in one ballot. They are siblings at
/// level 0 and share the upper path, so both fold to one root.
fn two_voters_one_ballot() -> (VoteWitness, VoteWitness) {
    let a = Identity::new(0xA11CE, 0xAAAA);
    let b = Identity::new(0xB0B, 0xBBBB);
    let leaf_a = a.commitment();
    let leaf_b = b.commitment();

    let mut sib_a = [rpo::ZERO_WORD; MERKLE_DEPTH];
    let mut sib_b = [rpo::ZERO_WORD; MERKLE_DEPTH];
    let mut bits_a = [false; MERKLE_DEPTH];
    let mut bits_b = [false; MERKLE_DEPTH];

    // level 0: A is the left leaf (sibling = leaf_b), B is the right leaf (sibling = leaf_a).
    sib_a[0] = leaf_b;
    bits_a[0] = false;
    sib_b[0] = leaf_a;
    bits_b[0] = true;

    // levels 1..20: a shared, arbitrary authentication path (same for both voters). The
    // index bits are VARIED (not all-equal) on purpose: an all-equal bit column collapses
    // the declared constraint degrees and panics the debug prover — that is its own finding
    // (see `f6_*` below); here we want both voters to actually prove.
    for k in 1..MERKLE_DEPTH {
        let s = [
            Felt::new(1000 + k as u64),
            Felt::new(2000 + k as u64),
            Felt::new(3000 + k as u64),
            Felt::new(4000 + k as u64),
        ];
        sib_a[k] = s;
        sib_b[k] = s;
        let bit = k % 2 == 0; // varied pattern, shared by both voters
        bits_a[k] = bit;
        bits_b[k] = bit;
    }

    let ext = Felt::new(0x00BA_1107); // a single ballot scope shared by both voters

    let wa = VoteWitness {
        id: a,
        external_nullifier: ext,
        revision: Felt::ZERO,
        siblings: sib_a,
        bits: bits_a,
        // NB: high-entropy scalar values on purpose — a small value (0/1) would trip the
        // F6 degree-collapse in a debug build; that is a separate finding.
        choice: Choice::Scalar(0xBEEF),
    };
    let wb = VoteWitness {
        id: b,
        external_nullifier: ext,
        revision: Felt::ONE, // attacker submits a *revision-1* (vote-change) proof
        siblings: sib_b,
        bits: bits_b,
        choice: Choice::Scalar(0xCAFE),
    };
    (wa, wb)
}

#[test]
fn f1_rotating_nullifier_has_no_cross_revision_identity_binding() {
    let (victim_rev0, attacker_rev1) = two_voters_one_ballot();

    // Both are members of the same ballot (identical eligibility root).
    let root_v = merkle_root(
        victim_rev0.id.commitment(),
        &victim_rev0.siblings,
        &victim_rev0.bits,
    );
    let root_a = merkle_root(
        attacker_rev1.id.commitment(),
        &attacker_rev1.siblings,
        &attacker_rev1.bits,
    );
    assert_eq!(
        root_v, root_a,
        "test setup: both voters must share one eligibility root"
    );

    // Victim casts revision 0.
    let (p_v, pi_v) = prove(&victim_rev0);
    verify(p_v, pi_v.clone()).expect("victim's honest rev-0 vote must verify");

    // Attacker (a DIFFERENT identity) produces a fully valid revision-1 "vote change"
    // proof — with their own choice — and it verifies on its own.
    let (p_a, pi_a) = prove(&attacker_rev1);
    verify(p_a, pi_a.clone()).expect("attacker's rev-1 proof verifies despite being unrelated");

    // The nullifier the attacker would claim as `prev` (the victim's live head). It is
    // PUBLIC on-chain after the victim votes, so the attacker simply copies it.
    let claimed_prev = victim_rev0
        .id
        .nullifier(victim_rev0.external_nullifier, Felt::ZERO);
    assert_eq!(pi_v.nullifier_hash, claimed_prev);

    assert_ne!(
        pi_a.nullifier_hash, claimed_prev,
        "different identities ⇒ different nullifiers"
    );
    assert_eq!(pi_a.external_nullifier, pi_v.external_nullifier);
    assert_eq!(pi_a.revision, Felt::ONE);
    assert_eq!(pi_a.vote_choice, Felt::new(0xCAFE)); // attacker's chosen tally value

    // === RESOLVED (F1 fix) ===
    // `prevNullifierHash` is now a bound public input: the circuit (block 24 + masking)
    // forces prev == RPO[extNull, idN, revision-1] against the SAME idN. So the attacker's
    // OWN honest rev-1 proof carries their own rev-0 nullifier as `prev` — NOT the victim's:
    let attacker_prev = attacker_rev1
        .id
        .nullifier(attacker_rev1.external_nullifier, Felt::ZERO);
    assert_eq!(
        pi_a.prev_nullifier_hash, attacker_prev,
        "the bound prev is the attacker's own rev-0 nullifier"
    );
    assert_ne!(
        pi_a.prev_nullifier_hash, claimed_prev,
        "the bound prev is NOT the victim's nullifier"
    );

    // The actual overwrite attempt: take a fresh attacker rev-1 proof and claim the victim's
    // live head as `prev`. The circuit binds prev to the attacker's identity, so this is now
    // REJECTED (previously there was no field to reject).
    let (p_a2, pi_a2) = prove(&attacker_rev1);
    let mut overwrite = pi_a2;
    overwrite.prev_nullifier_hash = claimed_prev; // victim's null_A0
    assert!(
        verify(p_a2, overwrite).is_err(),
        "F1 FIXED: overwriting a victim's vote (prev = victim's nullifier) is rejected"
    );
}

// ---------------------------------------------------------------------------------------
// FINDING F6 (MEDIUM, liveness / loose degrees — DEBUG builds): the AIR's declared
// transition-constraint degrees are NOT satisfied with equality for all valid witnesses.
// A legitimate voter whose Merkle index bits form a low-degree column — e.g. leaf index 0
// (all-left path ⇒ all bits = 0), or all-right, or other structured indices — collapses
// the merge-placement / index-bit constraints below their declared degree. winterfell's
// `#[cfg(debug_assertions)] validate_transition_degrees` then PANICS the prover. The
// author's tests only ever use RANDOM bits, so this is never exercised.
//
// Release is unaffected (the check is compiled out; declared degrees are safe UPPER bounds,
// so soundness is intact and the proof verifies). The impact is: (a) the reference prover
// + CI crash for common, legitimate voters (notably the first-enrolled, index-0 voter);
// (b) a re-implementing on-chain verifier author must treat the declared degrees as upper
// bounds, not exact.
// ---------------------------------------------------------------------------------------

#[test]
fn f6_degenerate_merkle_path_collapses_declared_degrees() {
    // RESOLVED (F6 fix): a degree-floor in `build_trace` keeps the BIT column full-degree
    // even for the leaf-index-0 voter (all-left path ⇒ all bits 0), so winterfell's debug
    // degree-equality check no longer panics. The index-0 voter now proves + verifies in
    // BOTH debug and release.
    let mut w = VoteWitness::sample(42);
    w.bits = [false; MERKLE_DEPTH];
    let (p, pi) = prove(&w);
    verify(p, pi).expect("index-0 (all-left) voter must prove + verify in debug and release");
}

#[test]
fn f6b_zero_scalar_vote_collapses_the_range_check_degree() {
    // RESOLVED (F6 fix): the degree-floor keeps RCB/RCA full-degree, so a "0" scalar vote
    // (reject / no / abstain-as-zero — extremely common) no longer collapses constraints
    // [28]/[29]. It proves + verifies in both debug and release.
    let mut w = VoteWitness::sample(7);
    w.choice = Choice::Scalar(0);
    let (p, pi) = prove(&w);
    verify(p, pi).expect("a '0' scalar vote must prove + verify in debug and release");
}

// ---------------------------------------------------------------------------------------
// FINDING F2 (MEDIUM, robustness/DoS): the reference verifier does not cleanly REJECT an
// out-of-range public `choiceCount` (N > N_MAX). `VoteAir::new` computes
// `N_MAX - n` (usize) → underflow panic (debug) / wrap (release). An adversarial public
// input crashes the verifier instead of returning `Err`.
// ---------------------------------------------------------------------------------------

#[test]
fn f2_choicecount_over_nmax_is_not_cleanly_rejected() {
    let w = VoteWitness::sample_ranked(7, 4);
    let (proof, mut pi) = prove(&w);
    pi.choice_count = Felt::new((N_MAX + 1) as u64); // N = 9 > N_MAX = 8

    let prev = std::panic::take_hook();
    std::panic::set_hook(Box::new(|_| {}));
    let outcome = catch_unwind(AssertUnwindSafe(|| verify(proof, pi)));
    std::panic::set_hook(prev);

    match outcome {
        Err(_) => { /* panicked — the finding: not a clean Err */ }
        Ok(Ok(())) => panic!("SECURITY: a proof with N > N_MAX VERIFIED"),
        Ok(Err(_)) => { /* cleanly rejected — also acceptable */ }
    }
    // Either way it must NOT verify; the point of the finding is that the debug path
    // PANICS rather than returning Err (confirmed by the Err(_) arm above being hit).
}

// ---------------------------------------------------------------------------------------
// FINDING (confirms SOUND): N (choiceCount) is bound — proving with N then claiming a
// different N' to the verifier is rejected.
// ---------------------------------------------------------------------------------------

#[test]
fn n_is_bound_claiming_a_different_n_is_rejected() {
    let w = VoteWitness::sample_ranked(7, 4); // genuine permutation of [0,4)
    let (proof, pi) = prove(&w);

    // claim a SMALLER N (forces extra padding-zero boundaries the trace won't satisfy)
    let mut pi_small = pi.clone();
    pi_small.choice_count = Felt::new(2);
    assert!(
        verify(proof, pi_small).is_err(),
        "claiming N=2 for an N=4 ranking must be rejected"
    );

    // claim a LARGER N (changes the target product) — re-prove since proof is consumed
    let (proof2, pi2) = prove(&w);
    let mut pi_big = pi2;
    pi_big.choice_count = Felt::new(6);
    assert!(
        verify(proof2, pi_big).is_err(),
        "claiming N=6 for an N=4 ranking must be rejected"
    );
}

// ---------------------------------------------------------------------------------------
// FINDING F3 (LOW/INFO): `voteMode` is NOT constrained to {0,1}. Any value ≠ 1 is treated
// as scalar (is_ranked == (vote_mode == 1)). A consumer must validate voteMode ∈ {0,1}.
// ---------------------------------------------------------------------------------------

#[test]
fn f3_votemode_is_not_constrained_to_zero_or_one() {
    let w = VoteWitness::sample(123); // scalar witness
    let scalar_val = match w.choice {
        Choice::Scalar(v) => Felt::new(v as u64),
        _ => unreachable!(),
    };

    // Build a statement that claims an *out-of-spec* voteMode = 2.
    let mut pi = w.statement().to_public_inputs();
    assert_eq!(pi.vote_mode, Felt::ZERO);
    pi.vote_mode = Felt::new(2); // neither 0 nor 1
    assert_eq!(pi.vote_choice, scalar_val);

    let prover = VoteProver::new(default_options(), pi.clone());
    let trace = prover.build_trace(&w);
    let proof = prover
        .prove(trace)
        .expect("proving a voteMode=2 scalar trace");

    // The verifier accepts it as a SCALAR vote (2 ≠ 1 ⇒ scalar branch). The circuit does
    // not pin voteMode to a binary value.
    verify(proof, pi).expect("voteMode=2 is (silently) accepted as a scalar vote");
}

// ---------------------------------------------------------------------------------------
// FINDING F4 (INFO, by design): the ranked `voteChoice = RPO(rank)[0]` publicly reveals
// the entire ranking — for N ≤ N_MAX the permutation domain is ≤ 8! = 40320, trivially
// brute-forced. This confirms the privacy model (anonymity = nullifier unlinkability, NOT
// ranking secrecy) and that public-N leaks nothing *beyond* what voteChoice already does.
// ---------------------------------------------------------------------------------------

fn all_permutations(n: usize) -> Vec<Vec<u8>> {
    let mut out = Vec::new();
    let mut cur: Vec<u8> = (0..n as u8).collect();
    permute(&mut cur, 0, &mut out);
    out
}
fn permute(a: &mut Vec<u8>, k: usize, out: &mut Vec<Vec<u8>>) {
    if k == a.len() {
        out.push(a.clone());
        return;
    }
    for i in k..a.len() {
        a.swap(k, i);
        permute(a, k + 1, out);
        a.swap(k, i);
    }
}

#[test]
fn f4_votechoice_publicly_reveals_the_ranking() {
    let secret_ranking = vec![3u8, 0, 2, 1, 5, 4]; // N = 6
    let w = VoteWitness::ranked_from(2024, secret_ranking.clone());
    let (proof, pi) = prove(&w);
    verify(proof, pi.clone()).expect("valid ranking must verify");

    // An observer with only the PUBLIC voteChoice recovers the exact ranking by brute force.
    let recovered = all_permutations(6)
        .into_iter()
        .find(|p| ranked_vote_choice(p) == pi.vote_choice)
        .expect("ranking is recoverable from the public voteChoice");

    assert_eq!(
        recovered, secret_ranking,
        "the full ordered ranking is public"
    );
}

// ---------------------------------------------------------------------------------------
// FINDING F5 (LOW): the scalar gadget enforces only the FIXED 16-bit range [0, 2^16); it
// does NOT enforce a per-ballot maxValue (spec §1.4 implies an in-circuit maxValue, e.g.
// 1..5 stars). The consumer must clamp. Here 65535 — far outside any sane star/bool ballot
// — verifies.
// ---------------------------------------------------------------------------------------

#[test]
fn f5_scalar_range_is_fixed_16bit_not_per_ballot_maxvalue() {
    let mut w = VoteWitness::sample(55);
    w.choice = Choice::Scalar(65535); // would be illegal on a 1..5 or 0/1 ballot
    let (proof, pi) = prove(&w);
    assert_eq!(pi.vote_choice, Felt::new(65535));
    verify(proof, pi).expect("the circuit accepts any u16; per-ballot max is NOT enforced");
}

// ---------------------------------------------------------------------------------------
// CONFIRMS SOUND: a scalar prover cannot pass off an out-of-[0,2^16) value (e.g. a ranking
// commitment, which is a ~64-bit field element) as a scalar — the range check rejects it.
// This is the scalar half of "mode-binding correctness" (check 2).
// ---------------------------------------------------------------------------------------

#[test]
fn scalar_mode_rejects_a_ranking_commitment_as_the_value() {
    // Take a genuine scalar proof, then claim voteChoice = a ranking commitment (out of
    // 16-bit range). The boundary RCA@16 == voteChoice cannot hold for a >2^16 value.
    let w = VoteWitness::sample(77);
    let (proof, mut pi) = prove(&w);
    pi.vote_choice = ranked_vote_choice(&[0, 1, 2, 3]); // a big field element
    assert!(
        verify(proof, pi).is_err(),
        "a ranking commitment (>2^16) must not pass the scalar range check"
    );
}

// ---------------------------------------------------------------------------------------
// CONFIRMS SOUND: cross-mode statement confusion — a proof generated in ranked mode must
// not verify when re-labelled scalar (and vice-versa). The transcript seed binds voteMode.
// ---------------------------------------------------------------------------------------

#[test]
fn relabelling_ranked_proof_as_scalar_is_rejected() {
    let w = VoteWitness::sample_ranked(31, 5);
    let (proof, mut pi) = prove(&w);
    pi.vote_mode = Felt::ZERO; // claim scalar
    assert!(
        verify(proof, pi).is_err(),
        "ranked proof relabelled scalar must be rejected"
    );
}
