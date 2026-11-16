// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./Goldilocks.sol";
import "./IStarkAir.sol";
import "./RpoConstraints.sol";
import "./VoteStarkPeriodic.sol";
import "./VoteStarkPublicInputs.sol";

/**
 * @title VoteStarkAir
 * @notice The `vote_stark` AIR as an {IStarkAir} — the circuit-specific component the generic
 *         {StarkVerifier} plugs in. Mirrors vote/zk/vote_stark/src/air.rs + VERIFIER_NOTES §4
 *         (34 main + 1 aux constraints; 31 periodic columns; the voteMode/N-dependent
 *         boundary layout). A different circuit supplies a different IStarkAir to the same
 *         core (spec §8, one-genesis).
 *
 *         Phase-1 status (foundation; see VERIFIER_IMPL_NOTES "remaining work"):
 *           - airParams / proofParams ......................... COMPLETE (the locked §3 set)
 *           - boundaryAssertions (MAIN) ....................... COMPLETE (the §4 layout)
 *           - periodicColumnSpec .............................. COMPLETE (the §4 structure)
 *           - periodicValuesAt / evaluateTransition ........... SCAFFOLD (the constraint math
 *             + RPO constants port + periodic interpolation are validated against emitted
 *             proof fixtures alongside the FRI core; reverts until then).
 */
contract VoteStarkAir is IStarkAir {
    using Goldilocks for uint64;

    // ---- AIR shape (air.rs) ----
    uint256 internal constant TRACE_LENGTH = 256;
    uint16 internal constant MAIN_WIDTH = 17;
    uint16 internal constant AUX_WIDTH = 1;
    uint16 internal constant NUM_AUX_RAND = 1;
    uint16 internal constant NUM_MAIN_CONSTRAINTS = 34;
    uint16 internal constant NUM_AUX_CONSTRAINTS = 1;
    uint8 internal constant NUM_PERIODIC = 31;

    // ---- locked ProofOptions (prover.rs default_options / VERIFIER_NOTES §3) ----
    uint8 internal constant BLOWUP = 16;
    uint16 internal constant NUM_QUERIES = 40; // auditor re-pin (was 96; storage lever, 127-bit conjectured held)
    uint8 internal constant GRINDING = 20;
    uint8 internal constant EXT_DEGREE = 2;
    uint8 internal constant FRI_FOLDING = 4;
    uint16 internal constant FRI_REMAINDER_MAX_DEGREE = 31;

    // ---- column indices (air.rs) ----
    uint16 internal constant CAP0 = 0; // capacity = state[0..4]
    uint16 internal constant RATE = 4; // rate = state[4..12]
    uint16 internal constant DIG = 4; // digest = state[4..8]
    uint16 internal constant BIT = 12;
    uint16 internal constant IDC = 13;
    uint16 internal constant RCA = 15;
    uint16 internal constant ISF = 16;
    uint16 internal constant DIGEST_SIZE = 4;

    // ---- key rows (air.rs) ----
    uint256 internal constant ROOT_ROW = 175;
    uint256 internal constant NULL_INPUT_ROW = 176;
    uint256 internal constant NULL_DIGEST_ROW = 183;
    uint256 internal constant COMMIT_INPUT_ROW = 184;
    uint256 internal constant COMMIT_DIGEST_ROW = 191;
    uint256 internal constant PREV_INPUT_ROW = 192;
    uint256 internal constant PREV_DIGEST_ROW = 199;
    uint256 internal constant COMMIT1_INPUT_ROW = 8;
    uint256 internal constant RC_FINAL_ROW = 16;

    uint64 internal constant N_MAX = 8;

    function airParams() external pure override returns (AirParams memory) {
        return AirParams({
            traceLength: TRACE_LENGTH,
            mainWidth: MAIN_WIDTH,
            auxWidth: AUX_WIDTH,
            numAuxRandElements: NUM_AUX_RAND,
            numMainConstraints: NUM_MAIN_CONSTRAINTS,
            numAuxConstraints: NUM_AUX_CONSTRAINTS,
            numPeriodicColumns: NUM_PERIODIC
        });
    }

    function proofParams() external pure override returns (ProofParams memory) {
        return ProofParams({
            blowupFactor: BLOWUP,
            numQueries: NUM_QUERIES,
            grindingBits: GRINDING,
            fieldExtensionDegree: EXT_DEGREE,
            friFoldingFactor: FRI_FOLDING,
            friRemainderMaxDegree: FRI_REMAINDER_MAX_DEGREE
        });
    }

    /// AUDIT V3 — the per-circuit public-input gate, behind the {IStarkAir} boundary. Enforces
    /// the 17-element wire format + the audit residual bounds (F2/F3/F8/S10/S11) via
    /// {VoteStarkPublicInputs.validate}. The generic core calls this; it does not know the
    /// vote_stark codec itself.
    function validatePublicInputs(uint64[] calldata publicInputs) external pure override {
        require(publicInputs.length == VoteStarkPublicInputs.NUM_INPUTS, "VoteStarkAir: 17 inputs");
        uint64[17] memory e;
        for (uint256 i = 0; i < 17; i++) e[i] = publicInputs[i];
        VoteStarkPublicInputs.validate(VoteStarkPublicInputs.fromElements(e));
    }

    /// The number of MAIN boundary assertions for these public inputs (matches
    /// `VoteAir::new`'s `num_main_assertions`: common 49 + mode-specific). Exposed so the
    /// FRI core can size the boundary divisor identically; also independently testable.
    ///
    /// AUDIT V4: this and {boundaryAssertions} ASSUME pre-gated inputs — for ranked
    /// `choiceCount > N_MAX` the `N_MAX - n` term underflow-reverts, and `voteMode==1,
    /// choiceCount==0` would produce a wrong-shaped descriptor. Safe ONLY because
    /// `validatePublicInputs` precedes them in the verify path; the FRI core MUST keep that
    /// ordering when it wires these into the divisor math.
    function numMainAssertions(uint64[] calldata publicInputs) public pure returns (uint256) {
        // common: block0(10) + commit1 pad(4) + root(4) + null in(11) + null dig(4)
        //         + cap@184(4) + prevNull in(11) + isFirst(1) = 49
        uint256 common = 49;
        uint64 voteMode = publicInputs[6];
        if (voteMode == 1) {
            uint64 n = publicInputs[7];
            // commitment digest (1) + (N_MAX - N) padding zeros
            return common + 1 + (uint256(N_MAX) - uint256(n));
        }
        return common + 2; // scalar range boundaries
    }

    /// AUDIT C1 — the constraint-composition coefficient count, RECOMPUTED from the AIR:
    /// `num_transition_constraints + num_assertions` = (main+aux transition) + (main+aux boundary).
    /// num_transition = NUM_MAIN_CONSTRAINTS(34) + NUM_AUX_CONSTRAINTS(1); num_assertions =
    /// numMainAssertions(pub) + 1 aux boundary (the grand-product target / zero). The generic core
    /// uses THIS for the coeff draw and asserts `proof.context.num_constraints` matches it.
    function constraintCompositionCoeffCount(uint64[] calldata publicInputs)
        external
        pure
        override
        returns (uint256)
    {
        return uint256(NUM_MAIN_CONSTRAINTS) + uint256(NUM_AUX_CONSTRAINTS)
            + numMainAssertions(publicInputs) + 1;
    }

    /// MAIN boundary assertions, in the exact section-4 / air.rs `get_assertions` layout. (The
    /// single AUX boundary, z at row 184 == product(target_i + gamma), depends on the drawn
    /// gamma and is produced by the FRI core via the AIR's aux hook in the full build; see
    /// notes.) Values are in GF(p^2) with zero imaginary part (boundary targets are base-field).
    function boundaryAssertions(uint64[] calldata pub)
        external
        pure
        override
        returns (Assertion[] memory a)
    {
        VoteStarkPublicInputs.PublicInputs memory pi = _parse(pub);
        uint256 n = numMainAssertions(pub);
        a = new Assertion[](n);
        uint256 k = 0;

        // block 0 input @ row 0: capacity[0..4]=0, state[6],[7]=0, state[8..12]=0
        for (uint16 c = 0; c < DIGEST_SIZE; c++) k = _zero(a, k, 0, CAP0 + c, 0);
        k = _zero(a, k, 0, RATE + 2, 0);
        k = _zero(a, k, 0, RATE + 3, 0);
        for (uint16 c = 0; c < DIGEST_SIZE; c++) k = _zero(a, k, 0, RATE + DIGEST_SIZE + c, 0);

        // F7: block 1 (commitment) input second word @ row 8 = 0
        for (uint16 c = 0; c < DIGEST_SIZE; c++) k = _zero(a, k, 0, RATE + DIGEST_SIZE + c, COMMIT1_INPUT_ROW);

        // Merkle root @ 175
        for (uint16 c = 0; c < DIGEST_SIZE; c++) k = _val(a, k, 0, DIG + c, ROOT_ROW, pi.merkleRoot[c]);

        // nullifier input @ 176
        k = _val(a, k, 0, RATE, NULL_INPUT_ROW, pi.externalNullifier);
        k = _val(a, k, 0, RATE + 2, NULL_INPUT_ROW, pi.revision);
        k = _zero(a, k, 0, RATE + 3, NULL_INPUT_ROW);
        for (uint16 c = 0; c < DIGEST_SIZE; c++) k = _zero(a, k, 0, RATE + DIGEST_SIZE + c, NULL_INPUT_ROW);
        for (uint16 c = 0; c < DIGEST_SIZE; c++) k = _zero(a, k, 0, CAP0 + c, NULL_INPUT_ROW);

        // nullifier digest @ 183
        for (uint16 c = 0; c < DIGEST_SIZE; c++) k = _val(a, k, 0, DIG + c, NULL_DIGEST_ROW, pi.nullifierHash[c]);

        // rankCommit input capacity @ 184 = 0
        for (uint16 c = 0; c < DIGEST_SIZE; c++) k = _zero(a, k, 0, CAP0 + c, COMMIT_INPUT_ROW);

        // prevNullifier input @ 192: ext, revision-1, pad, right ZERO, cap 0
        k = _val(a, k, 0, RATE, PREV_INPUT_ROW, pi.externalNullifier);
        k = _val(a, k, 0, RATE + 2, PREV_INPUT_ROW, Goldilocks.sub(pi.revision, 1));
        k = _zero(a, k, 0, RATE + 3, PREV_INPUT_ROW);
        for (uint16 c = 0; c < DIGEST_SIZE; c++) k = _zero(a, k, 0, RATE + DIGEST_SIZE + c, PREV_INPUT_ROW);
        for (uint16 c = 0; c < DIGEST_SIZE; c++) k = _zero(a, k, 0, CAP0 + c, PREV_INPUT_ROW);

        // isFirst @ 199 = (revision == 0 ? 1 : 0)
        k = _val(a, k, 0, ISF, PREV_DIGEST_ROW, pi.revision == 0 ? uint64(1) : uint64(0));

        // mode-specific
        if (pi.voteMode == 1) {
            k = _val(a, k, 0, DIG, COMMIT_DIGEST_ROW, pi.voteChoice); // voteChoice == digest[0]
            for (uint64 i = pi.choiceCount; i < N_MAX; i++) {
                k = _zero(a, k, 0, RATE + uint16(i), COMMIT_INPUT_ROW); // padding ranks = 0
            }
        } else {
            k = _zero(a, k, 0, RCA, 0); // rca@0 = 0
            k = _val(a, k, 0, RCA, RC_FINAL_ROW, pi.voteChoice); // rca@16 = voteChoice
        }

        require(k == n, "VoteStarkAir: assertion count mismatch");
    }

    /// The 31 periodic-column values at the OOD point z (DONE, part 5). hash_flag + ARK1[12] +
    /// ARK2[12] (period-8, coeff-Horner) then the 6 period-256 selectors (sparse barycentric);
    /// byte-exact with winterfell's `evaluate_constraints` — see {VoteStarkPeriodic}.
    function periodicValuesAt(Goldilocks.Fp2 calldata z)
        external
        pure
        override
        returns (Goldilocks.Fp2[] memory)
    {
        return VoteStarkPeriodic.evaluate(z);
    }

    // column indices (air.rs): state 0..12, BIT 12, IDC 13, RCB 14, RCA 15, ISF 16; CAP 0; RATE/DIG 4.
    // periodic indices: P_HASHFLAG 0, P_ARK1 1..13, P_ARK2 13..25, P_FBIND0 25, P_FNULL 26,
    // P_RCACTIVE 27, P_FBREAK 28, P_FPERM 29, P_FPREVBIND 30.
    /**
     * @notice The 34 main + 1 aux transition-constraint evaluations at the OOD frame (DONE, part 6),
     *         byte-exact with air.rs `evaluate_transition` + `evaluate_aux_transition`:
     *           [0..12]  RPO round (RpoConstraints.enforceRound, gated by hash_flag)
     *           [12..24] merge gadget (not(hash_flag)·not(f_break) rows: rate↔digest copy + zero cap)
     *           [24]     bit binary · [25] id-carry copy
     *           [26]     f_bind0: id-carry == idNullifier at row 0 · [27] f_null: input idN slot == id-carry
     *           [28,29]  scalar range check (rc_active)
     *           [30..34] F1 prevNullifier masking (f_prevbind): prev_pub − (1−isFirst)·prev_computed
     *           [34]     aux grand product (f_perm): z − ∏_{i<N_MAX}(rate_i + γ)
     */
    function evaluateTransition(
        Goldilocks.Fp2[] calldata mainCur,
        Goldilocks.Fp2[] calldata mainNxt,
        Goldilocks.Fp2[] calldata auxCur,
        Goldilocks.Fp2[] calldata, // auxNxt — unused (the grand product reads current rows)
        Goldilocks.Fp2[] calldata periodic,
        Goldilocks.Fp2[] calldata auxRand,
        uint64[] calldata pub
    ) external pure override returns (Goldilocks.Fp2[] memory r) {
        r = new Goldilocks.Fp2[](35); // 34 main + 1 aux, declared order

        // [0..12] RPO round, gated by hash_flag (periodic[0]); ARK1=periodic[1..13], ARK2=periodic[13..25]
        {
            Goldilocks.Fp2[12] memory cur12;
            Goldilocks.Fp2[12] memory nxt12;
            Goldilocks.Fp2[12] memory a1;
            Goldilocks.Fp2[12] memory a2;
            Goldilocks.Fp2[12] memory res12;
            for (uint256 i = 0; i < 12; i++) {
                cur12[i] = mainCur[i];
                nxt12[i] = mainNxt[i];
                a1[i] = periodic[1 + i];
                a2[i] = periodic[13 + i];
            }
            res12 = RpoConstraints.enforceRound(res12, cur12, nxt12, a1, a2, periodic[0]);
            for (uint256 i = 0; i < 12; i++) r[i] = res12[i];
        }

        // [12..24] merge gadget: active on not(hash_flag)·not(f_break) rows
        Goldilocks.Fp2 memory mergeActive = _mul(_not(periodic[0]), _not(periodic[28]));
        Goldilocks.Fp2 memory bit = mainNxt[12];
        Goldilocks.Fp2 memory notBit = _not(bit);
        for (uint256 k = 0; k < 4; k++) {
            r[12 + k] = _mul(mergeActive, _mul(notBit, _sub(mainNxt[4 + k], mainCur[4 + k])));
            r[16 + k] = _mul(mergeActive, _mul(bit, _sub(mainNxt[8 + k], mainCur[4 + k])));
            r[20 + k] = _mul(mergeActive, mainNxt[k]); // is_zero(cap) = cap
        }

        // [24] bit binary · [25] id-carry copy (always enforced)
        r[24] = _isBinary(mainCur[12]);
        r[25] = _sub(mainNxt[13], mainCur[13]);

        // [26] f_bind0 · (id-carry == idNullifier@row0) · [27] f_null · (input idN slot == id-carry)
        r[26] = _mul(periodic[25], _sub(mainCur[13], mainCur[4]));
        r[27] = _mul(periodic[26], _sub(mainNxt[5], mainNxt[13]));

        // [28,29] scalar range check (rc_active = periodic[27])
        r[28] = _mul(periodic[27], _sub(mainNxt[15], _add(_add(mainCur[15], mainCur[15]), mainCur[14])));
        r[29] = _mul(periodic[27], _isBinary(mainCur[14]));

        // [30..34] F1 prevNullifier masking: f_prevbind · (prev_pub − prev_computed + isFirst·prev_computed)
        for (uint256 k = 0; k < 4; k++) {
            Goldilocks.Fp2 memory prevComputed = mainCur[4 + k];
            Goldilocks.Fp2 memory expr = _add(
                _sub(Goldilocks.Fp2(pub[13 + k], 0), prevComputed),
                _mul(mainCur[16], prevComputed)
            );
            r[30 + k] = _mul(periodic[30], expr);
        }

        // [34] aux grand product: f_perm · (z − ∏_{i<N_MAX}(rate_i + γ))
        Goldilocks.Fp2 memory prod = Goldilocks.Fp2(1, 0);
        for (uint256 i = 0; i < N_MAX; i++) {
            prod = _mul(prod, _add(mainCur[4 + i], auxRand[0]));
        }
        r[34] = _mul(periodic[29], _sub(auxCur[0], prod));
    }

    // ---- GF(p^2) constraint helpers (winterfell: are_equal=a−b, is_zero=x, is_binary=x²−x, not=1−x) ----
    function _mul(Goldilocks.Fp2 memory a, Goldilocks.Fp2 memory b)
        private pure returns (Goldilocks.Fp2 memory) { return Goldilocks.extMul(a, b); }
    function _add(Goldilocks.Fp2 memory a, Goldilocks.Fp2 memory b)
        private pure returns (Goldilocks.Fp2 memory) { return Goldilocks.extAdd(a, b); }
    function _sub(Goldilocks.Fp2 memory a, Goldilocks.Fp2 memory b)
        private pure returns (Goldilocks.Fp2 memory) { return Goldilocks.extSub(a, b); }
    function _not(Goldilocks.Fp2 memory a) private pure returns (Goldilocks.Fp2 memory) {
        return Goldilocks.extSub(Goldilocks.Fp2(1, 0), a);
    }
    function _isBinary(Goldilocks.Fp2 memory a) private pure returns (Goldilocks.Fp2 memory) {
        return Goldilocks.extSub(Goldilocks.extSquare(a), a);
    }

    // ---- internals ----
    function _parse(uint64[] calldata pub)
        internal
        pure
        returns (VoteStarkPublicInputs.PublicInputs memory pi)
    {
        require(pub.length == VoteStarkPublicInputs.NUM_INPUTS, "VoteStarkAir: 17 inputs");
        uint64[17] memory e;
        for (uint256 i = 0; i < 17; i++) e[i] = pub[i];
        pi = VoteStarkPublicInputs.fromElements(e);
    }

    function _val(Assertion[] memory a, uint256 k, uint16 seg, uint16 col, uint256 row, uint64 v)
        internal
        pure
        returns (uint256)
    {
        a[k] = Assertion(seg, col, row, Goldilocks.Fp2(v, 0));
        return k + 1;
    }

    function _zero(Assertion[] memory a, uint256 k, uint16 seg, uint16 col, uint256 row)
        internal
        pure
        returns (uint256)
    {
        a[k] = Assertion(seg, col, row, Goldilocks.Fp2(0, 0));
        return k + 1;
    }
}
