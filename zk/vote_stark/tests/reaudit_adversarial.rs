//! RE-AUDIT adversarial vectors (round 2) — independent of the author's F1 fix (audit Round 1).
//! Written by the auditor, NOT trusting the author's edits to `audit_adversarial.rs`.
//! Targets the new cross-revision `prevNullifierHash` binding (block 24 + isFirst masking)
//! and confirms F2/F6/F7 are closed. Maps to `audits/ZK_STARK_AUDIT.md`
//! (re-audit section). The circuit in `src/` is untouched.
//!
//! Run:  cargo test --test reaudit_adversarial            (debug)
//!       cargo test --release --test reaudit_adversarial  (release)

use std::panic::{catch_unwind, AssertUnwindSafe};

use vote_stark::{
    default_options, merkle_root, prove, rpo, verify, Choice, Felt, Identity, PublicInputs,
    VoteProver, VoteWitness, MERKLE_DEPTH, N_MAX,
};
use winterfell::math::FieldElement;
use winterfell::Prover;

// trace column indices (mirror air.rs / prover.rs)
const RATE: usize = 4;
const PREV_INPUT_ROW: usize = 8 * 24; // 192
const PREV_DIGEST_ROW: usize = 8 * 24 + 7; // 199
const COMMIT1_INPUT_ROW: usize = 8; // block 1 (commitment) input
const ISF: usize = 16;

/// True iff `(pub_inputs, trace)` yields a VERIFYING proof. Catches the debug-build
/// constraint panic (winterfell validates the trace in debug) and the release path (an
/// invalid trace produces a proof that fails verification) uniformly.
fn trace_verifies(pi: PublicInputs, trace: vote_stark::rap_trace::RapTraceTable<Felt>) -> bool {
    let prover = VoteProver::new(default_options(), pi.clone());
    let hook = std::panic::take_hook();
    std::panic::set_hook(Box::new(|_| {}));
    let out = catch_unwind(AssertUnwindSafe(|| match prover.prove(trace) {
        Ok(p) => verify(p, pi).is_ok(),
        Err(_) => false,
    }));
    std::panic::set_hook(hook);
    matches!(out, Ok(true))
}

/// Two DISTINCT identities, both members of ONE depth-20 eligibility tree (shared root) —
/// two voters in the same ballot. Siblings at level 0, shared upper path.
fn two_voters_one_ballot(ext: Felt) -> (VoteWitness, VoteWitness) {
    let a = Identity::new(0xA11CE, 0xAAAA);
    let b = Identity::new(0xB0B, 0xBBBB);
    let (leaf_a, leaf_b) = (a.commitment(), b.commitment());

    let mut sib_a = [rpo::ZERO_WORD; MERKLE_DEPTH];
    let mut sib_b = [rpo::ZERO_WORD; MERKLE_DEPTH];
    let mut bits_a = [false; MERKLE_DEPTH];
    let mut bits_b = [false; MERKLE_DEPTH];
    sib_a[0] = leaf_b;
    bits_a[0] = false; // A left
    sib_b[0] = leaf_a;
    bits_b[0] = true; // B right
    for k in 1..MERKLE_DEPTH {
        let s = [
            Felt::new(900 + k as u64),
            Felt::new(800 + k as u64),
            Felt::new(700 + k as u64),
            Felt::new(600 + k as u64),
        ];
        sib_a[k] = s;
        sib_b[k] = s;
        let bit = k % 2 == 0;
        bits_a[k] = bit;
        bits_b[k] = bit;
    }
    let mk = |id, rev, bits, sibs| VoteWitness {
        id,
        external_nullifier: ext,
        revision: rev,
        siblings: sibs,
        bits,
        choice: Choice::Scalar(0xBEEF),
    };
    (
        mk(a, Felt::ZERO, bits_a, sib_a),
        mk(b, Felt::ONE, bits_b, sib_b),
    )
}

// ===========================================================================================
// F1 — the cross-revision binding. The overwrite must now be REJECTED, for the right reason.
// ===========================================================================================

#[test]
fn f1_honest_vote_change_still_verifies() {
    // Completeness: a voter changing THEIR OWN vote (rev0 -> rev1, prev = own rev0 nullifier).
    let id = Identity::new(0xC01, 0xD00D);
    let w0 = VoteWitness {
        id,
        external_nullifier: Felt::new(42),
        revision: Felt::ZERO,
        siblings: [rpo::ZERO_WORD; MERKLE_DEPTH],
        bits: [false; MERKLE_DEPTH],
        choice: Choice::Scalar(3),
    };
    let mut w1 = w0.clone();
    w1.revision = Felt::ONE;
    w1.choice = Choice::Scalar(4);

    let (p0, pi0) = prove(&w0);
    verify(p0, pi0.clone()).expect("first cast must verify");
    assert_eq!(pi0.prev_nullifier_hash, rpo::ZERO_WORD, "first cast prev == 0");

    let (p1, pi1) = prove(&w1);
    verify(p1, pi1.clone()).expect("honest vote-change must verify");
    assert_eq!(
        pi1.prev_nullifier_hash,
        id.nullifier(Felt::new(42), Felt::ZERO),
        "vote-change prev == own rev-0 nullifier"
    );
}

#[test]
fn f1_overwrite_rejected_masking_binds_prev_to_own_computed() {
    // THE ATTACK. Victim A casts rev0 -> null_A0 (public). Attacker B (own identity, same
    // ballot) tries to submit a rev1 proof whose public prevNullifierHash = null_A0, so the
    // contract's live-head check would replace A's vote. B builds its OWN trace (block 24
    // computes RPO[ext, idN_B, 0] = null_B0), but claims prev = null_A0.
    let ext = Felt::new(0xBA11_07);
    let (victim_rev0, attacker_rev1) = two_voters_one_ballot(ext);

    assert_eq!(
        merkle_root(victim_rev0.id.commitment(), &victim_rev0.siblings, &victim_rev0.bits),
        merkle_root(attacker_rev1.id.commitment(), &attacker_rev1.siblings, &attacker_rev1.bits),
        "setup: one shared ballot root"
    );

    let null_a0 = victim_rev0.id.nullifier(ext, Felt::ZERO);

    // Attacker's statement, with prev FORGED to the victim's live head.
    let mut pi = attacker_rev1.statement().to_public_inputs();
    assert_eq!(
        pi.prev_nullifier_hash,
        attacker_rev1.id.nullifier(ext, Felt::ZERO),
        "B's real prev is its own null_B0"
    );
    pi.prev_nullifier_hash = null_a0; // the forge

    let prover = VoteProver::new(default_options(), pi.clone());
    let trace = prover.build_trace(&attacker_rev1); // block 24 still uses idN_B
    assert!(
        !trace_verifies(pi, trace),
        "SECURITY: B overwrote A — the masking constraint failed to bind prev to B's own prevComputed"
    );
}

#[test]
fn f1_overwrite_via_victim_idn_in_block24_rejected_by_idn_binding() {
    // The other route to prevComputed == null_A0: put the VICTIM's idN into block 24. The
    // [27] f_null binding forces block-24 rate[1] == IDC (the membership identity = idN_B),
    // so a block-24 input carrying idN_A is rejected. We surgically rewrite block 24 (rows
    // 192..199) to compute RPO[ext, idN_A, 0] and set prev = that digest; IDC stays idN_B.
    let ext = Felt::new(0xBA11_07);
    let (victim_rev0, attacker_rev1) = two_voters_one_ballot(ext);
    let idn_a = victim_rev0.id.id_nullifier;
    let null_a0 = victim_rev0.id.nullifier(ext, Felt::ZERO);

    let mut pi = attacker_rev1.statement().to_public_inputs();
    pi.prev_nullifier_hash = null_a0; // masking will be satisfied if block24 == null_A0…

    let prover = VoteProver::new(default_options(), pi.clone());
    let mut trace = prover.build_trace(&attacker_rev1);

    // Rebuild block 24 with the VICTIM's idN: input = merge([ext, idN_A, rev-1=0, 0], ZERO).
    let mut st = [Felt::ZERO; 12];
    st[RATE] = ext;
    st[RATE + 1] = idn_a; // <- victim idN (the forgery); IDC column stays idN_B
    st[RATE + 2] = Felt::ZERO; // revision - 1 = 0  (attacker_rev1.revision == 1)
    let mut row = vec![Felt::ZERO; trace.width()];
    for pos in 0..8 {
        let r = PREV_INPUT_ROW + pos;
        trace.read_row_into(r, &mut row);
        row[..12].copy_from_slice(&st); // overwrite the RPO state, keep BIT/IDC/RCB/RCA/ISF
        trace.update_row(r, &row);
        if pos < 7 {
            let mut s12: [Felt; 12] = st;
            rpo::round(&mut s12, pos);
            st = s12;
        }
    }
    // digest@199 now == RPO[ext, idN_A, 0] == null_A0 (masking would pass) — but [27] fails.
    assert!(
        !trace_verifies(pi, trace),
        "SECURITY: block-24 idN was free — a victim-idN prev was accepted"
    );
}

#[test]
fn f1_first_cast_with_nonzero_prev_rejected() {
    // revision==0 ⇒ isFirst pinned to 1 ⇒ masking forces prevNullifierHash == 0. Claiming a
    // nonzero prev on a first cast must be rejected.
    let w = VoteWitness::sample(7); // sample() revision is random in 0..8; force 0:
    let mut w0 = w.clone();
    w0.revision = Felt::ZERO;

    let mut pi = w0.statement().to_public_inputs();
    assert_eq!(pi.prev_nullifier_hash, rpo::ZERO_WORD);
    pi.prev_nullifier_hash = [Felt::new(1), Felt::new(2), Felt::new(3), Felt::new(4)];

    let prover = VoteProver::new(default_options(), pi.clone());
    let trace = prover.build_trace(&w0);
    assert!(
        !trace_verifies(pi, trace),
        "a first cast with nonzero prev must be rejected"
    );
}

#[test]
fn f1_cannot_forge_isfirst_to_dodge_the_binding() {
    // At revision>0 the verifier pins isFirst@199 == 0. A prover that flips isFirst to 1
    // (to make the masking ignore prevComputed) is rejected by the isFirst boundary.
    let mut w = VoteWitness::sample(9);
    w.revision = Felt::new(3);
    let pi = w.statement().to_public_inputs();
    assert_eq!(pi.revision, Felt::new(3));

    let prover = VoteProver::new(default_options(), pi.clone());
    let mut trace = prover.build_trace(&w);

    // Honest trace has ISF@199 == 0; flip it to 1.
    let mut row = vec![Felt::ZERO; trace.width()];
    trace.read_row_into(PREV_DIGEST_ROW, &mut row);
    assert_eq!(row[ISF], Felt::ZERO, "honest ISF@199 is 0 for revision>0");
    row[ISF] = Felt::ONE;
    trace.update_row(PREV_DIGEST_ROW, &row);

    assert!(
        !trace_verifies(pi, trace),
        "forging isFirst=1 at revision>0 must be rejected by the isFirst boundary"
    );
}

#[test]
fn f1_binding_active_in_scalar_and_ranked_modes() {
    // The prev binding is mode-independent. A scalar vote-change with a tampered prev is
    // rejected; so is a ranked one.
    for (label, mut w) in [
        ("scalar", {
            let mut w = VoteWitness::sample(21);
            w.revision = Felt::new(2);
            w
        }),
        ("ranked", {
            let mut w = VoteWitness::sample_ranked(22, 5);
            w.revision = Felt::new(2);
            w
        }),
    ] {
        // honest verifies
        let (p, pi) = prove(&w);
        verify(p, pi.clone()).unwrap_or_else(|e| panic!("{label} honest vote-change: {e}"));
        // tamper prev -> reject (regenerate; proof consumed)
        let _ = &mut w;
        let mut pi_bad = pi.clone();
        pi_bad.prev_nullifier_hash[0] += Felt::ONE;
        let (p2, _) = prove(&w);
        assert!(
            verify(p2, pi_bad).is_err(),
            "{label}: tampered prev must be rejected"
        );
    }
}

// ===========================================================================================
// F7 — the commitment block's 2nd input word is now PINNED to zero.
// ===========================================================================================

#[test]
fn f7_commitment_second_input_word_is_pinned_zero() {
    let w = VoteWitness::sample(5);
    let pi = w.statement().to_public_inputs();
    let prover = VoteProver::new(default_options(), pi.clone());
    let mut trace = prover.build_trace(&w);

    // Honest row-8 second input word (state[8..12]) is zero; set it nonzero.
    let mut row = vec![Felt::ZERO; trace.width()];
    trace.read_row_into(COMMIT1_INPUT_ROW, &mut row);
    for k in 0..4 {
        assert_eq!(row[RATE + 4 + k], Felt::ZERO, "honest commit 2nd word is 0");
    }
    row[RATE + 4] = Felt::new(0xDEAD);
    trace.update_row(COMMIT1_INPUT_ROW, &row);
    assert!(
        !trace_verifies(pi, trace),
        "a nonzero commitment 2nd input word must now be rejected (F7 boundary)"
    );
}

// ===========================================================================================
// F6 — degenerate-but-legitimate witnesses must PROVE + VERIFY (no debug panic).
// ===========================================================================================

#[test]
fn f6_index0_voter_and_zero_vote_prove_in_debug_and_release() {
    // leaf index 0 -> all-left path (all bits 0)
    let mut w_idx0 = VoteWitness::sample(42);
    w_idx0.bits = [false; MERKLE_DEPTH];
    let (p, pi) = prove(&w_idx0);
    verify(p, pi).expect("index-0 voter must prove+verify (F6 degree floor)");

    // "0" reject/no vote
    let mut w_zero = VoteWitness::sample(43);
    w_zero.choice = Choice::Scalar(0);
    let (p, pi) = prove(&w_zero);
    verify(p, pi).expect("a '0' scalar vote must prove+verify (F6 degree floor)");

    // both degeneracies at once
    let mut w_both = VoteWitness::sample(44);
    w_both.bits = [false; MERKLE_DEPTH];
    w_both.choice = Choice::Scalar(0);
    w_both.revision = Felt::new(5); // ISF all-zero too
    let (p, pi) = prove(&w_both);
    verify(p, pi).expect("index-0 + '0' vote + revision>0 must prove+verify");
}

// ===========================================================================================
// F2 / F8 — N bounds. The panic is gone; verify the residual (silent clamp / N=0).
// ===========================================================================================

#[test]
fn f2_tampered_choicecount_over_nmax_rejects_without_panic() {
    let w = VoteWitness::sample_ranked(7, 4);
    let (proof, mut pi) = prove(&w);
    pi.choice_count = Felt::new((N_MAX + 1) as u64); // N = 9

    let hook = std::panic::take_hook();
    std::panic::set_hook(Box::new(|_| {}));
    let out = catch_unwind(AssertUnwindSafe(|| verify(proof, pi)));
    std::panic::set_hook(hook);
    match out {
        Ok(Err(_)) => {} // clean rejection — the fix
        Ok(Ok(())) => panic!("SECURITY: N>N_MAX verified"),
        Err(_) => panic!("F2 not closed: verify still PANICS on N>N_MAX"),
    }
}

#[test]
fn f2_residual_generated_n_over_nmax_silently_clamps_to_nmax() {
    // RESIDUAL: a maliciously *generated* proof with choiceCount = N_MAX+1 and a valid
    // N_MAX ranking still VERIFIES (n() clamps to N_MAX). No false-accept of a bad ranking,
    // but the public choiceCount is not rejected in-circuit — the consumer MUST bounds-check.
    let ranks: Vec<u8> = (0..N_MAX as u8).collect(); // a valid permutation of [0, N_MAX)
    let w = VoteWitness::ranked_from(31, ranks);
    let mut pi = w.statement().to_public_inputs();
    assert_eq!(pi.choice_count, Felt::new(N_MAX as u64));
    pi.choice_count = Felt::new((N_MAX + 1) as u64); // claim N = 9

    let prover = VoteProver::new(default_options(), pi.clone());
    let trace = prover.build_trace(&w);
    let verified = trace_verifies(pi, trace);
    assert!(
        verified,
        "documents the residual: N>N_MAX clamps to N_MAX rather than rejecting in-circuit"
    );
}

#[test]
fn f8_residual_n_zero_ranked_is_accepted_in_circuit() {
    // RESIDUAL: N=0 (empty ranking) verifies as a degenerate all-zero ranking. The consumer
    // must reject N=0.
    let w = VoteWitness::ranked_from(33, vec![]);
    let pi = w.statement().to_public_inputs();
    assert_eq!(pi.choice_count, Felt::ZERO);
    let (proof, pi2) = prove(&w);
    assert!(
        verify(proof, pi2).is_ok(),
        "documents the residual: N=0 ranked is accepted in-circuit"
    );
}
