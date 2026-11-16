// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./Goldilocks.sol";
import "./IHasher.sol";
import "./IStarkAir.sol";
import "./ProofReader.sol";
import "./Transcript.sol";

/**
 * @title StarkVerifier
 * @notice Generic Winterfell-0.13.1 FRI verifier core over Goldilocks/Blake3. ALL circuit
 *         specifics live behind {IStarkAir} — including the public-input gate (AUDIT V3) — and the
 *         hash behind {IHasher}; this contract holds no vote_stark knowledge, so a future circuit
 *         reuses it by supplying its own `IStarkAir` (spec §8, one-genesis). The protocol is the
 *         RAP-aware sequence in VERIFIER_NOTES §5 / `winter-verifier 0.13.1`.
 *
 *         Trust model (AUDIT V2 — deployment is trusted setup):
 *           • {hasher} and {air} are immutable but deployer-supplied; the canonical deployment
 *             MUST use the audited AIR and a genuine Blake3 precompile (attest with
 *             `Blake3PrecompileHasher.selfTest`).
 *           • The soundness `ProofOptions` are PINNED verifier-side at construction (immutables)
 *             and cross-checked against `air.proofParams()` at deploy — so the §3 gate's reference
 *             is the DEPLOYER's pinned set, not the circuit-supplied AIR's self-declaration (this
 *             closes the "malicious AIR declares weak params" circularity the audit flagged).
 *
 *         ── Phase 1 status (foundation) ──
 *         IMPLEMENTED + tested: the public-input gate (`air.validatePublicInputs`); the §3
 *         `ProofOptions` gate WIRED INTO `verify()` by parsing the proof's `Context` (AUDIT V7);
 *         the byte reader, field/extension math, the pluggable Blake3 host, the generic-AIR
 *         boundary. SCAFFOLD (fixture-driven — see VERIFIER_IMPL_NOTES): the rest of proof
 *         deserialization, the `DefaultRandomCoin` transcript + grinding, Merkle openings, DEEP +
 *         OOD eval, FRI folding/queries. `verify` runs the implemented gates then reverts at the
 *         FRI core, so it can NEVER be mistaken for accepting a proof it has not actually checked.
 */
contract StarkVerifier {
    IHasher public immutable hasher; // the pluggable Blake3 host (precompile in prod)
    IStarkAir public immutable air; // the circuit being verified (vote_stark here)

    // AUDIT V2 — the soundness ProofOptions, pinned verifier-side (the §3 reference set).
    uint8 public immutable expBlowup;
    uint16 public immutable expNumQueries;
    uint8 public immutable expGrinding;
    uint8 public immutable expExtDegree;
    uint8 public immutable expFriFolding;
    uint16 public immutable expFriRemainderMaxDegree;

    constructor(address hasherAddress, address airAddress, IStarkAir.ProofParams memory expected) {
        require(hasherAddress != address(0) && airAddress != address(0), "StarkVerifier: zero dep");
        hasher = IHasher(hasherAddress);
        air = IStarkAir(airAddress);

        // pin the deployer-declared soundness params (immutable, cannot be swapped post-deploy)
        expBlowup = expected.blowupFactor;
        expNumQueries = expected.numQueries;
        expGrinding = expected.grindingBits;
        expExtDegree = expected.fieldExtensionDegree;
        expFriFolding = expected.friFoldingFactor;
        expFriRemainderMaxDegree = expected.friRemainderMaxDegree;

        // V2: the circuit-supplied AIR must AGREE with the deployer's pinned params, so it cannot
        // smuggle in weaker soundness options than the deployer vouched for.
        IStarkAir.ProofParams memory ap = air.proofParams();
        require(
            ap.blowupFactor == expected.blowupFactor &&
                ap.numQueries == expected.numQueries &&
                ap.grindingBits == expected.grindingBits &&
                ap.fieldExtensionDegree == expected.fieldExtensionDegree &&
                ap.friFoldingFactor == expected.friFoldingFactor &&
                ap.friRemainderMaxDegree == expected.friRemainderMaxDegree,
            "StarkVerifier: AIR params != pinned"
        );
        // this core is Goldilocks GF(p^2) specific (the field of {Goldilocks}); reject other ext.
        require(expected.fieldExtensionDegree == 2, "StarkVerifier: only quadratic ext");
    }

    /// AUDIT V3 — the public-input gate, delegated to the AIR (generic; no vote_stark codec here).
    /// A wrapping contract (AnonymousVoteVerifier successor) calls this before trusting any vote,
    /// regardless of the FRI-core status.
    function checkPublicInputs(uint64[] calldata publicInputs) public view {
        air.validatePublicInputs(publicInputs);
    }

    /// §3 gate against the verifier-side PINNED params (AUDIT V2) — NOT the AIR's self-declaration.
    /// `AcceptableOptions::OptionSet([pinned])` on-chain: any deviation is rejected.
    function requireAcceptableOptions(
        uint8 blowup,
        uint16 numQueries,
        uint8 grinding,
        uint8 extDegree,
        uint8 friFolding,
        uint16 friRemainderMaxDegree
    ) public view {
        require(blowup == expBlowup, "StarkVerifier: blowup");
        require(numQueries == expNumQueries, "StarkVerifier: numQueries");
        require(grinding == expGrinding, "StarkVerifier: grinding");
        require(extDegree == expExtDegree, "StarkVerifier: extension");
        require(friFolding == expFriFolding, "StarkVerifier: friFolding");
        require(friRemainderMaxDegree == expFriRemainderMaxDegree, "StarkVerifier: friRemainder");
    }

    /**
     * @notice Parse the `ProofOptions` out of a Winterfell-0.13.1 proof's `Context` header, and
     *         cross-check the proof's declared trace shape + field against the AIR (AUDIT V7; the
     *         §3.1 layout fixed in AUDIT V1). The `Context` front is (winter-air 0.13.1
     *         `Serializable`, little-endian):
     *           TraceInfo:   main_width(u8) aux_width(u8) num_aux_rands(u8) log2(trace_len)(u8)
     *                        trace_meta_len(u16) trace_meta(bytes)
     *           modulus:     field_modulus_len(u8) field_modulus(bytes)
     *           ProofOptions:num_queries(u8) blowup(u8) grinding(u8) field_extension(u8)
     *                        fri_folding(u8) fri_remainder_max_degree(u8)
     *                        batching_constraints(u8) batching_deep(u8) num_partitions(u8) hash_rate(u8)
     *         Confirmed against the real emitted proof (see VERIFIER_IMPL_NOTES §3.1). The byte
     *         reader is bounds-checked, so a short/truncated proof reverts here, never misparses.
     */
    /// Parsed `Context`: the 8 `context.to_elements()` (the seed prefix), the constraint-coeff
    /// draw count (`num_constraints` = num_transition + num_assertions), the §3 ProofOptions, and
    /// the cursor offset at the END of the Context (= start of `num_unique_queries`).
    struct ContextData {
        uint64[8] elems;
        uint64 numConstraints;
        uint256 endOffset;
        uint8 blowup;
        uint16 numQueries;
        uint8 grinding;
        uint8 extDegree;
        uint8 friFolding;
        uint16 friRemainderMaxDegree;
    }

    /// Parse the whole `Context` (winter-air 0.13.1) into `context.to_elements()` form + the §3
    /// options + `num_constraints`, with the generic trace-shape/field cross-checks against the AIR.
    /// Element order mirrors `Context::to_elements`: [traceLayout, traceLen, modHi, modLo,
    /// num_constraints, optionsPacked, grinding, num_queries].
    function _parseContext(bytes calldata proof) internal view returns (ContextData memory cd) {
        ProofReader.Cursor memory c = ProofReader.Cursor(0);
        IStarkAir.AirParams memory ap = air.airParams();

        // TraceInfo: main_width, aux_width, num_aux_rands, log2(trace_len) — bound to the AIR.
        uint8 mainWidth = ProofReader.readU8(proof, c);
        uint8 auxWidth = ProofReader.readU8(proof, c);
        uint8 auxRands = ProofReader.readU8(proof, c);
        uint8 log2Len = ProofReader.readU8(proof, c);
        require(mainWidth == ap.mainWidth, "StarkVerifier: trace main width");
        require(auxWidth == ap.auxWidth, "StarkVerifier: trace aux width");
        require(auxRands == ap.numAuxRandElements, "StarkVerifier: aux rand count");
        require(uint256(1) << log2Len == ap.traceLength, "StarkVerifier: trace length");
        // AUDIT C2: `context.to_elements()` would append trace_meta chunks; this builder assumes
        // empty trace_meta (true for vote_stark). Reject non-empty rather than mis-seed silently.
        uint16 metaLen = ProofReader.readU16LE(proof, c);
        require(metaLen == 0, "StarkVerifier: trace_meta unsupported");

        // TraceInfo::to_elements packing: main<<? | num_aux_segments | (aux_width | num_aux_rands).
        uint64 numAuxSegs = auxWidth > 0 ? 1 : 0;
        uint64 traceLayout = mainWidth;
        traceLayout = (traceLayout << 8) | numAuxSegs;
        if (numAuxSegs == 1) {
            traceLayout = (traceLayout << 8) | auxWidth;
            traceLayout = (traceLayout << 8) | auxRands;
        }
        cd.elems[0] = traceLayout;
        cd.elems[1] = uint64(uint256(1) << log2Len); // trace length

        // field modulus — Goldilocks (8 LE bytes == p); to_elements splits it into two halves via
        // from_bytes_with_padding: modHi = LE(bytes[0..4]), modLo = LE(bytes[4..8]).
        uint8 modLen = ProofReader.readU8(proof, c);
        require(modLen == 8, "StarkVerifier: field modulus size");
        uint64 modulus = ProofReader.readU64LE(proof, c);
        require(uint256(modulus) == Goldilocks.P, "StarkVerifier: not Goldilocks");
        cd.elems[2] = modulus & 0xFFFFFFFF; // low half (first 4 LE bytes)
        cd.elems[3] = modulus >> 32; // high half (last 4 LE bytes)

        // ProofOptions (10 bytes; the §3 soundness set + batching/partition).
        cd.numQueries = ProofReader.readU8(proof, c);
        cd.blowup = ProofReader.readU8(proof, c);
        cd.grinding = ProofReader.readU8(proof, c);
        cd.extDegree = ProofReader.readU8(proof, c);
        cd.friFolding = ProofReader.readU8(proof, c);
        cd.friRemainderMaxDegree = ProofReader.readU8(proof, c);
        ProofReader.readU8(proof, c); // batching_constraints
        ProofReader.readU8(proof, c); // batching_deep
        ProofReader.readU8(proof, c); // partition_options.num_partitions
        ProofReader.readU8(proof, c); // partition_options.hash_rate

        // num_constraints (variable-length usize) — also the constraint-coeff draw count.
        cd.numConstraints = ProofReader.readUsizeVar(proof, c);

        // options.to_elements packing: ext<<24 | friFold<<16 | friRem<<8 | blowup, then grinding, queries.
        cd.elems[4] = cd.numConstraints;
        cd.elems[5] = (uint64(cd.extDegree) << 24) | (uint64(cd.friFolding) << 16)
            | (uint64(cd.friRemainderMaxDegree) << 8) | uint64(cd.blowup);
        cd.elems[6] = cd.grinding;
        cd.elems[7] = cd.numQueries;

        cd.endOffset = c.offset;
    }

    /// The §3 options as parsed from the proof's Context (thin wrapper over {_parseContext}).
    function parseProofOptions(bytes calldata proof)
        public
        view
        returns (
            uint8 blowup,
            uint16 numQueries,
            uint8 grinding,
            uint8 extDegree,
            uint8 friFolding,
            uint16 friRemainderMaxDegree
        )
    {
        ContextData memory cd = _parseContext(proof);
        return (cd.blowup, cd.numQueries, cd.grinding, cd.extDegree, cd.friFolding, cd.friRemainderMaxDegree);
    }

    /// `context.to_elements()` for the proof — the 8-element seed prefix (for testing/inspection).
    function contextToElements(bytes calldata proof) external view returns (uint64[8] memory) {
        return _parseContext(proof).elems;
    }

    /// The 25 transcript seed elements `context.to_elements() ‖ public_inputs`.
    function _seedElements(uint64[8] memory ctx, uint64[] calldata pub)
        internal
        pure
        returns (uint64[] memory s)
    {
        s = new uint64[](8 + pub.length);
        for (uint256 i = 0; i < 8; i++) s[i] = ctx[i];
        for (uint256 i = 0; i < pub.length; i++) s[8 + i] = pub[i];
    }

    /// The initial public-coin seed for the proof — `hash_elements(context.to_elements ‖ pub)`.
    function initialSeed(bytes calldata proof, uint64[] calldata publicInputs)
        external
        view
        returns (bytes32)
    {
        ContextData memory cd = _parseContext(proof);
        return Transcript.init(hasher, _seedElements(cd.elems, publicInputs)).seed;
    }

    /// Read the trace + constraint commitments at the start of the post-Context section:
    /// `num_unique_queries(u8) ‖ commitments_len(u16) ‖ main_root ‖ aux_root ‖ constraint_root ‖ …`.
    function _readEarlyCommitments(bytes calldata proof, uint256 contextEnd)
        internal
        pure
        returns (bytes32 mainRoot, bytes32 auxRoot, bytes32 constraintRoot)
    {
        ProofReader.Cursor memory c = ProofReader.Cursor(contextEnd);
        ProofReader.readU8(proof, c); // num_unique_queries
        ProofReader.readU16LE(proof, c); // commitments byte length (Commitments is u16-len-prefixed)
        mainRoot = ProofReader.readDigest(proof, c);
        auxRoot = ProofReader.readDigest(proof, c);
        constraintRoot = ProofReader.readDigest(proof, c);
    }

    /**
     * @notice Re-derive the public-coin challenges through the OOD point, byte-exact vs winterfell:
     *         seed → reseed(main) → draw γ (RAP aux rand) → reseed(aux) → draw `num_constraints`
     *         composition coeffs → reseed(constraint) → draw z. Returns the seed, γ, and z. This is
     *         the real Fiat-Shamir path the FRI core continues from (the coeffs are drawn to advance
     *         the coin; their values are consumed by the not-yet-built constraint/DEEP steps).
     */
    function deriveChallengesThroughZ(bytes calldata proof, uint64[] calldata publicInputs)
        public
        view
        returns (bytes32 seed, Goldilocks.Fp2 memory gamma, Goldilocks.Fp2 memory z)
    {
        ContextData memory cd = _parseContext(proof);
        IStarkAir.AirParams memory ap = air.airParams();

        // AUDIT C1: the coeff count is RECOMPUTED from the AIR, not trusted from the proof's
        // num_constraints (which a malicious proof could under-state to leave constraints
        // unenforced). Assert the proof's value matches BEFORE seeding (it feeds the seed via
        // context.to_elements), then draw the AIR-authoritative count.
        uint256 coeffCount = air.constraintCompositionCoeffCount(publicInputs);
        require(cd.numConstraints == coeffCount, "StarkVerifier: num_constraints mismatch");

        Transcript.State memory st = Transcript.init(hasher, _seedElements(cd.elems, publicInputs));
        seed = st.seed;

        (bytes32 mainRoot, bytes32 auxRoot, bytes32 constraintRoot) =
            _readEarlyCommitments(proof, cd.endOffset);

        Transcript.reseed(hasher, st, mainRoot);
        // AUDIT C2: draw numAuxRand RAP elements (not a hardcoded 1); keep the first as γ.
        Goldilocks.Fp2[] memory rap = Transcript.drawElements(hasher, st, ap.numAuxRandElements);
        gamma = rap[0];
        Transcript.reseed(hasher, st, auxRoot);
        Transcript.drawElements(hasher, st, coeffCount); // constraint composition coeffs
        Transcript.reseed(hasher, st, constraintRoot);
        z = Transcript.drawElement(hasher, st); // OOD point
    }

    /// Read ALL commitments at the post-Context section: `num_unique_queries(u8) ‖
    /// commitments_len(u16) ‖ trace_roots(numTraceSegments) ‖ constraint_root ‖ fri_roots(rest)`.
    /// `fri_roots` count (num FRI layers + 1 remainder) is derived from the blob length.
    function _readCommitments(bytes calldata proof, uint256 contextEnd, uint256 numTraceSegments)
        internal
        pure
        returns (
            bytes32 mainRoot,
            bytes32 auxRoot,
            bytes32 constraintRoot,
            bytes32[] memory friRoots,
            uint256 afterOffset
        )
    {
        ProofReader.Cursor memory c = ProofReader.Cursor(contextEnd);
        ProofReader.readU8(proof, c); // num_unique_queries
        uint16 clen = ProofReader.readU16LE(proof, c);
        require(clen % 32 == 0, "StarkVerifier: commitments size");
        uint256 numDigests = uint256(clen) / 32;
        require(numDigests > numTraceSegments + 1, "StarkVerifier: too few commitments");
        require(numTraceSegments == 2, "StarkVerifier: expected main+aux segments");
        mainRoot = ProofReader.readDigest(proof, c);
        auxRoot = ProofReader.readDigest(proof, c);
        constraintRoot = ProofReader.readDigest(proof, c);
        uint256 friCount = numDigests - (numTraceSegments + 1);
        friRoots = new bytes32[](friCount);
        for (uint256 i = 0; i < friCount; i++) friRoots[i] = ProofReader.readDigest(proof, c);
        afterOffset = c.offset;
    }

    /// Skip one `Queries` (`Vec<u8> values ‖ Vec<u8> opening_proof`, each varint-length-prefixed).
    function _skipQueries(bytes calldata proof, ProofReader.Cursor memory c) internal pure {
        ProofReader.readBytes(proof, c, ProofReader.readUsizeVar(proof, c)); // values
        ProofReader.readBytes(proof, c, ProofReader.readUsizeVar(proof, c)); // opening_proof
    }

    /// Advance past `trace_queries(×numTraceSegments)` + `constraint_queries` to the OOD frame.
    function _skipToOod(bytes calldata proof, uint256 afterCommit, uint256 numTraceSegments)
        internal
        pure
        returns (uint256)
    {
        ProofReader.Cursor memory c = ProofReader.Cursor(afterCommit);
        for (uint256 i = 0; i < numTraceSegments; i++) _skipQueries(proof, c);
        _skipQueries(proof, c); // constraint_queries
        return c.offset;
    }

    /// Read the OOD frame and return `merge_ood_evaluations` as flat base limbs (the preimage of
    /// the OOD reseed hash) + the derived `num_quotients`. Layout: each blob is
    /// `u16 len ‖ u8 frame_size(2) ‖ E elements` (E = two 8-LE base limbs). Merge order is
    /// `trace_current ‖ quotient_current ‖ trace_next ‖ quotient_next`.
    function _readOodEvals(bytes calldata proof, uint256 oodOffset)
        internal
        pure
        returns (uint64[] memory limbs, uint256 numQuotients)
    {
        ProofReader.Cursor memory c = ProofReader.Cursor(oodOffset);

        uint16 traceLen = ProofReader.readU16LE(proof, c);
        require(ProofReader.readU8(proof, c) == 2, "StarkVerifier: ood trace frame");
        uint256 traceLimbs = (uint256(traceLen) - 1) / 8; // total base limbs in trace blob
        uint64[] memory tl = new uint64[](traceLimbs);
        for (uint256 i = 0; i < traceLimbs; i++) tl[i] = ProofReader.readU64LE(proof, c);

        uint16 quotLen = ProofReader.readU16LE(proof, c);
        require(ProofReader.readU8(proof, c) == 2, "StarkVerifier: ood quot frame");
        uint256 quotLimbs = (uint256(quotLen) - 1) / 8;
        uint64[] memory ql = new uint64[](quotLimbs);
        for (uint256 i = 0; i < quotLimbs; i++) ql[i] = ProofReader.readU64LE(proof, c);

        numQuotients = (quotLimbs / 2) / 2; // quotLimbs = num_quotients * 2 rows * 2 limbs
        uint256 traceHalf = traceLimbs / 2; // current-row limb count
        uint256 quotHalf = quotLimbs / 2;

        limbs = new uint64[](traceLimbs + quotLimbs);
        uint256 k = 0;
        for (uint256 i = 0; i < traceHalf; i++) limbs[k++] = tl[i]; // trace current
        for (uint256 i = 0; i < quotHalf; i++) limbs[k++] = ql[i]; // quotient current
        for (uint256 i = traceHalf; i < traceLimbs; i++) limbs[k++] = tl[i]; // trace next
        for (uint256 i = quotHalf; i < quotLimbs; i++) limbs[k++] = ql[i]; // quotient next
    }

    /**
     * @notice Re-derive the FULL public-coin challenge chain through the FRI commit phase + the
     *         grinding check + the query positions — byte-exact vs winterfell. Returns the OOD point
     *         z, the FRI layer αs, and the query positions (raw `draw_integers`, pre sort/dedup).
     *         After this point the verifier draws nothing more from the coin; everything left is
     *         the verification MATH (constraint eval, Merkle openings, DEEP, FRI folding).
     */
    function deriveQueryPositions(bytes calldata proof, uint64[] calldata publicInputs)
        public
        view
        returns (Goldilocks.Fp2 memory z, Goldilocks.Fp2[] memory alphas, uint64[] memory positions)
    {
        ContextData memory cd = _parseContext(proof);
        IStarkAir.AirParams memory ap = air.airParams();
        uint256 numTraceSegments = ap.auxWidth > 0 ? 2 : 1;

        // AUDIT C1: coeff count from the AIR (not the proof's num_constraints); assert BEFORE seeding.
        uint256 coeffCount = air.constraintCompositionCoeffCount(publicInputs);
        require(cd.numConstraints == coeffCount, "StarkVerifier: num_constraints mismatch");

        Transcript.State memory st = Transcript.init(hasher, _seedElements(cd.elems, publicInputs));

        (
            bytes32 mainRoot,
            bytes32 auxRoot,
            bytes32 constraintRoot,
            bytes32[] memory friRoots,
            uint256 afterCommit
        ) = _readCommitments(proof, cd.endOffset, numTraceSegments);

        Transcript.reseed(hasher, st, mainRoot);
        Transcript.drawElements(hasher, st, ap.numAuxRandElements); // AUDIT C2: RAP γ's (not hardcoded 1)
        Transcript.reseed(hasher, st, auxRoot);
        Transcript.drawElements(hasher, st, coeffCount); // constraint composition coeffs
        Transcript.reseed(hasher, st, constraintRoot);
        z = Transcript.drawElement(hasher, st); // OOD point

        uint256 oodOffset = _skipToOod(proof, afterCommit, numTraceSegments);
        (uint64[] memory oodLimbs, uint256 numQuotients) = _readOodEvals(proof, oodOffset);
        Transcript.reseed(hasher, st, hasher.hashElements(oodLimbs)); // OOD reseed

        // DEEP coefficients: trace_width + num_constraint_composition_columns draws.
        Transcript.drawElements(hasher, st, uint256(ap.mainWidth) + uint256(ap.auxWidth) + numQuotients);

        // FRI commit phase: per layer (and the remainder) reseed + draw α.
        alphas = new Goldilocks.Fp2[](friRoots.length);
        for (uint256 i = 0; i < friRoots.length; i++) {
            Transcript.reseed(hasher, st, friRoots[i]);
            alphas[i] = Transcript.drawElement(hasher, st);
        }

        // proof-of-work: pow_nonce is the proof's final 8 bytes; verify the grinding factor.
        ProofReader.Cursor memory pc = ProofReader.Cursor(proof.length - 8);
        uint64 powNonce = ProofReader.readU64LE(proof, pc);
        require(
            Transcript.checkLeadingZeros(hasher, st, powNonce) >= cd.grinding,
            "StarkVerifier: insufficient grinding"
        );

        // query positions over the LDE domain (raw; the verifier sorts + dedups afterward).
        uint256 lde = uint256(ap.traceLength) * uint256(cd.blowup);
        positions = Transcript.drawIntegers(hasher, st, cd.numQueries, lde, powNonce);
    }

    /**
     * @notice Verify a STARK proof against its public inputs (generic; vote_stark via the AIR).
     * @dev Runs the implemented gates, then the FRI core. Phase 1: the FRI core reverts, so this
     *      does not yet return. Order (VERIFIER_NOTES §5), each step mapped to its module:
     *        0. gate: air.validatePublicInputs(pub) [V3]; parse Context options ⇒
     *           requireAcceptableOptions(pinned) [V7/V2]
     *        1. seed coin = hasher.hashBytes(context ‖ publicInputs)           [IHasher]
     *        2. read main-trace commitment; reseed                              [ProofReader + IHasher]
     *        3. draw γ (numAuxRand); read aux-trace commitment; reseed          [RAP — §5.3]
     *        4. draw constraint coeffs; read constraint commitment; reseed
     *        5. draw OOD z; read OOD frames + constraint evals; reseed;
     *           air.evaluateTransition(...) + air.boundaryAssertions(...) ⇒ check == committed
     *        6. draw DEEP coeffs; verify grinding nonce; draw query positions
     *        7. per query: verify main/aux/constraint Merkle openings; DEEP-compose [IHasher Merkle]
     *        8. FRI: layer commitments + folding + remainder                    [FRI core]
     */
    function verify(bytes calldata proof, uint64[] calldata publicInputs)
        external
        view
        returns (bool)
    {
        // -- gate 1: public inputs, behind the AIR boundary (V3) --
        checkPublicInputs(publicInputs);

        require(proof.length > 0, "StarkVerifier: empty proof");

        // -- gate 2: Context parsed from the proof; options checked vs the pinned set (V7 + V2) --
        ContextData memory cd = _parseContext(proof);
        requireAcceptableOptions(
            cd.blowup, cd.numQueries, cd.grinding, cd.extDegree, cd.friFolding, cd.friRemainderMaxDegree
        );

        // -- Fiat-Shamir through the OOD point (part 2): seed → γ → z, byte-exact vs winterfell --
        deriveChallengesThroughZ(proof, publicInputs);

        // -- FRI core (post-OOD: OOD constraint eval, DEEP, Merkle openings, FRI) — pending --
        revert("StarkVerifier: FRI core pending post-OOD (DEEP/Merkle/FRI - see VERIFIER_IMPL_NOTES)");
    }
}
