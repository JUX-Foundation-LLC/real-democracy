// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./Goldilocks.sol";

/**
 * @title IStarkAir
 * @notice The GENERIC-AIR boundary (spec §8, the one-genesis insurance). The FRI verifier
 *         core ({StarkVerifier}) is circuit-AGNOSTIC — it verifies any Winterfell 0.13.1
 *         STARK over Goldilocks/Blake3 — and learns everything circuit-specific through this
 *         interface. A future circuit (the aggregate; ranked extensions) reuses the SAME
 *         verifier by supplying its own `IStarkAir`; no new verifier contract.
 *
 *         All field math is Goldilocks; OOD / FRI / DEEP values live in the quadratic
 *         extension `GF(p^2)` (`Goldilocks.Fp2`). The core supplies the out-of-domain (OOD)
 *         evaluation frame (current+next rows of the main and aux trace at the OOD point z),
 *         the periodic-column values at z, and the verifier-drawn random elements; the AIR
 *         returns the transition-constraint evaluations and the boundary-assertion data the
 *         core needs to form the DEEP composition and check it against the committed value.
 */
interface IStarkAir {
    /// Static AIR parameters the core needs to drive deserialization + the DEEP/FRI math.
    struct AirParams {
        uint256 traceLength; // e.g. 256
        uint16 mainWidth; // e.g. 17
        uint16 auxWidth; // e.g. 1
        uint16 numAuxRandElements; // e.g. 1 (the permutation γ)
        uint16 numMainConstraints; // e.g. 34
        uint16 numAuxConstraints; // e.g. 1
        uint8 numPeriodicColumns; // e.g. 31
    }

    /// The exact `ProofOptions` the verifier accepts (anything else is rejected — §3).
    struct ProofParams {
        uint8 blowupFactor; // 16
        uint16 numQueries; // 96
        uint8 grindingBits; // 20
        uint8 fieldExtensionDegree; // 2 (quadratic)
        uint8 friFoldingFactor; // 4
        uint16 friRemainderMaxDegree; // 31
    }

    /// A boundary assertion: `column`'s value at `row` must equal `value` (in GF(p^2)).
    struct Assertion {
        uint16 segment; // 0 = main, 1 = aux
        uint16 column;
        uint256 row;
        Goldilocks.Fp2 value;
    }

    function airParams() external pure returns (AirParams memory);

    function proofParams() external pure returns (ProofParams memory);

    /// Validate the public inputs against the circuit's wire format + bounds (AUDIT V3 — the
    /// per-circuit public-input gate lives BEHIND this boundary, not in the generic core, so the
    /// core stays circuit-agnostic). The AIR owns its element count and its bounds; it MUST
    /// revert on any out-of-spec input. Length-checks `publicInputs` itself. For `vote_stark`
    /// this enforces the audit residuals (voteMode∈{0,1}, ranked N∈[1,N_MAX], scalar N==0,
    /// canonicality — F2/F3/F8/S10/S11). The generic verifier calls this before trusting a vote.
    function validatePublicInputs(uint64[] calldata publicInputs) external pure;

    /// The number of constraint-composition coefficients the verifier must draw =
    /// `num_transition_constraints + num_assertions`, RECOMPUTED from the AIR (AUDIT C1 — the count
    /// is authoritative from the circuit, NOT trusted from `proof.context.num_constraints`, which a
    /// malicious proof could under-state to leave constraints unenforced). Depends on the public
    /// inputs because the boundary-assertion count is voteMode/N-dependent.
    function constraintCompositionCoeffCount(uint64[] calldata publicInputs)
        external
        pure
        returns (uint256);

    /// Periodic-column values at the OOD point z (the core interpolates none itself; the AIR
    /// owns the period arrays and evaluates them at z). Length == `numPeriodicColumns`.
    function periodicValuesAt(Goldilocks.Fp2 calldata z)
        external
        view
        returns (Goldilocks.Fp2[] memory values);

    /// Evaluate ALL transition constraints (main ‖ aux) at the OOD frame. Returns
    /// `numMainConstraints + numAuxConstraints` evaluations in GF(p^2), in declared order —
    /// the core multiplies by the composition coefficients and divides by the transition
    /// divisor. `publicInputs` is the flat element wire form (the AIR reads public values it
    /// needs, e.g. prevNullifierHash for the masking constraint).
    function evaluateTransition(
        Goldilocks.Fp2[] calldata mainCurrent,
        Goldilocks.Fp2[] calldata mainNext,
        Goldilocks.Fp2[] calldata auxCurrent,
        Goldilocks.Fp2[] calldata auxNext,
        Goldilocks.Fp2[] calldata periodicAtZ,
        Goldilocks.Fp2[] calldata auxRandElements,
        uint64[] calldata publicInputs
    ) external view returns (Goldilocks.Fp2[] memory evaluations);

    /// The boundary assertions for these public inputs (count depends on voteMode/N — §4).
    function boundaryAssertions(uint64[] calldata publicInputs)
        external
        view
        returns (Assertion[] memory);
}
