// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title MockAnonymousVoteVerifier
 * @notice Test double for AnonymousVoteVerifier that keeps the REAL ballot-policy
 *         bookkeeping (root registration, one-time nullifier spend, rotating
 *         prev-head chaining) but skips the Groth16 pairing check — so revision
 *         chains can be exercised in unit tests without generating real proofs.
 *
 *         Used by BaseRuleBallotBoxRevisionRecovery.unit.test.js to reproduce the
 *         2026-07-02 prod failure mode: a chain whose rev-0 was spent OUTSIDE the
 *         box (verifier-direct) and whose rev-1 arrives at the box as a revision.
 */
contract MockAnonymousVoteVerifier {
    mapping(uint256 => uint256) public ballotRoot;
    mapping(uint256 => mapping(uint256 => bool)) public nullifierSpent;
    mapping(uint256 => mapping(uint256 => bool)) public nullifierHead;

    function registerBallotRoot(uint256 externalNullifier, uint256 merkleRoot) external {
        require(merkleRoot != 0, "AnonymousVoteVerifier: invalid root");
        ballotRoot[externalNullifier] = merkleRoot;
    }

    function castAnonymousVote(
        uint256[2] calldata,
        uint256[2][2] calldata,
        uint256[2] calldata,
        uint256 merkleRoot,
        uint256 externalNullifier,
        uint256, /* voteChoice */
        uint256 nullifierHash,
        uint256 prevNullifierHash
    ) external {
        require(ballotRoot[externalNullifier] == merkleRoot, "AnonymousVoteVerifier: unknown ballot root");
        require(!nullifierSpent[externalNullifier][nullifierHash], "AnonymousVoteVerifier: nullifier already spent");
        if (prevNullifierHash != 0) {
            require(
                nullifierHead[externalNullifier][prevNullifierHash],
                "AnonymousVoteVerifier: prev nullifier is not the live head"
            );
            nullifierHead[externalNullifier][prevNullifierHash] = false;
        }
        // (Groth16 verifyProof intentionally skipped — mock.)
        nullifierSpent[externalNullifier][nullifierHash] = true;
        nullifierHead[externalNullifier][nullifierHash] = true;
    }

    function isNullifierSpent(uint256 externalNullifier, uint256 nullifierHash) external view returns (bool) {
        return nullifierSpent[externalNullifier][nullifierHash];
    }

    function isLiveHead(uint256 externalNullifier, uint256 nullifierHash) external view returns (bool) {
        return nullifierHead[externalNullifier][nullifierHash];
    }
}
