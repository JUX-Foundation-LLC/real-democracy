// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./Goldilocks.sol";

/**
 * @title VoteStarkPublicInputs
 * @notice The 17 public field elements of the `vote_stark` circuit, their exact wire
 *         ordering (the transcript seed is `hash(context ‖ these)` — order is consensus-
 *         critical), and the bounds-checks the audit hands the verifier (the circuit does
 *         NOT enforce these; see vote/zk/vote_stark/VERIFIER_NOTES §2/§6 and
 *         ZK_STARK_AUDIT findings F2/F3/F8):
 *
 *           - `voteMode ∈ {0,1}`                         (F3 — the AIR treats any value ≠ 1
 *                                                         as scalar; reject non-binary)
 *           - ranked (`voteMode==1`): `1 ≤ choiceCount ≤ N_MAX`  (F2/F8 — the circuit clamps
 *                                                         N silently; reject out-of-range)
 *           - scalar (`voteMode==0`): `choiceCount == 0` (the prover emits 0 for scalar)
 *           - every element canonical (`< p`)            (reject non-canonical encodings)
 *           - scalar `voteChoice` per-ballot `maxValue`  (F5 — NOT enforced here; the
 *                                                         calling ballotbox must clamp, see
 *                                                         `requireScalarMax`)
 *
 *         The element order mirrors `vote_stark::PublicInputs::to_elements()` (scheme.rs):
 *           [0..4]  merkleRoot          (RPO digest, little-endian element order)
 *           [4]     externalNullifier
 *           [5]     revision
 *           [6]     voteMode
 *           [7]     choiceCount (N)
 *           [8]     voteChoice
 *           [9..13] nullifierHash       (RPO digest)
 *           [13..17] prevNullifierHash  (RPO digest; 0 on first cast)
 */
library VoteStarkPublicInputs {
    /// Ranked `N_MAX` — must equal `vote_stark::scheme::N_MAX`.
    uint64 internal constant N_MAX = 8;
    uint256 internal constant NUM_INPUTS = 17;

    struct PublicInputs {
        uint64[4] merkleRoot;
        uint64 externalNullifier;
        uint64 revision;
        uint64 voteMode;
        uint64 choiceCount;
        uint64 voteChoice;
        uint64[4] nullifierHash;
        uint64[4] prevNullifierHash;
    }

    /// Flatten to the exact 17-element transcript order.
    function toElements(PublicInputs memory pi) internal pure returns (uint64[17] memory e) {
        e[0] = pi.merkleRoot[0];
        e[1] = pi.merkleRoot[1];
        e[2] = pi.merkleRoot[2];
        e[3] = pi.merkleRoot[3];
        e[4] = pi.externalNullifier;
        e[5] = pi.revision;
        e[6] = pi.voteMode;
        e[7] = pi.choiceCount;
        e[8] = pi.voteChoice;
        e[9] = pi.nullifierHash[0];
        e[10] = pi.nullifierHash[1];
        e[11] = pi.nullifierHash[2];
        e[12] = pi.nullifierHash[3];
        e[13] = pi.prevNullifierHash[0];
        e[14] = pi.prevNullifierHash[1];
        e[15] = pi.prevNullifierHash[2];
        e[16] = pi.prevNullifierHash[3];
    }

    /// Parse from the flat 17-element wire form (e.g. as decoded from calldata / a fixture).
    function fromElements(uint64[17] memory e) internal pure returns (PublicInputs memory pi) {
        pi.merkleRoot = [e[0], e[1], e[2], e[3]];
        pi.externalNullifier = e[4];
        pi.revision = e[5];
        pi.voteMode = e[6];
        pi.choiceCount = e[7];
        pi.voteChoice = e[8];
        pi.nullifierHash = [e[9], e[10], e[11], e[12]];
        pi.prevNullifierHash = [e[13], e[14], e[15], e[16]];
    }

    /// The audit bounds-checks (F2/F3/F8) + canonical-encoding check. Reverts on violation —
    /// this is the clean rejection the audit requires (the verifier must reject, not abort,
    /// and never silently treat an out-of-spec input as valid). uint64 typing already bounds
    /// each element to 2^64; `isValid` additionally rejects the `[p, 2^64)` non-canonical gap.
    function validate(PublicInputs memory pi) internal pure {
        uint64[17] memory e = toElements(pi);
        for (uint256 i = 0; i < NUM_INPUTS; i++) {
            require(Goldilocks.isValid(e[i]), "VotePI: non-canonical element");
        }
        require(pi.voteMode == 0 || pi.voteMode == 1, "VotePI: voteMode not in {0,1}"); // F3
        if (pi.voteMode == 1) {
            // ranked — F2/F8: N in [1, N_MAX]
            require(pi.choiceCount >= 1 && pi.choiceCount <= N_MAX, "VotePI: choiceCount out of range");
        } else {
            // scalar — the prover emits choiceCount == 0
            require(pi.choiceCount == 0, "VotePI: scalar choiceCount must be 0");
        }
    }

    /// F5 — per-ballot scalar `maxValue` clamp. NOT part of the circuit (it enforces only the
    /// fixed `[0, 2^16)`); the calling ballotbox knows its ballot's real range and MUST call
    /// this for scalar votes. No-op for ranked (voteChoice is a ranking commitment, not a value).
    function requireScalarMax(PublicInputs memory pi, uint64 maxValue) internal pure {
        if (pi.voteMode == 0) {
            require(pi.voteChoice <= maxValue, "VotePI: scalar voteChoice exceeds ballot maxValue");
        }
    }
}
