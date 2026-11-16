// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IActiveCredentialTallyVerifier {
    function verifyProof(
        uint256[2] calldata pA,
        uint256[2][2] calldata pB,
        uint256[2] calldata pC,
        uint256[7] calldata pubSignals
    ) external view returns (bool);
}

/// @notice Development state adapter for #918's active-credential tally proof.
/// @dev Public signals are ordered exactly as active_credential_tally.circom:
/// active root, standing ballot root, electorate, counted, against, for, abstain.
/// Credential commitments, activity bits and choices never enter calldata.
contract ActiveCredentialTallyRollup {
    struct TallyState {
        uint256 activeCredentialRoot;
        uint256 standingBallotRoot;
        uint64 electorate;
        uint64 counted;
        uint64 againstTotal;
        uint64 forTotal;
        uint64 abstainTotal;
        uint64 epoch;
    }

    IActiveCredentialTallyVerifier public immutable verifier;
    mapping(bytes32 ballotId => TallyState) private tallies;

    event TallyAccepted(
        bytes32 indexed ballotId,
        uint64 indexed epoch,
        uint256 activeCredentialRoot,
        uint256 standingBallotRoot,
        uint64 electorate,
        uint64 counted,
        uint64 againstTotal,
        uint64 forTotal,
        uint64 abstainTotal
    );

    constructor(address verifier_) {
        require(verifier_ != address(0), "ActiveTally: zero verifier");
        verifier = IActiveCredentialTallyVerifier(verifier_);
    }

    function submitTally(
        bytes32 ballotId,
        uint256[2] calldata pA,
        uint256[2][2] calldata pB,
        uint256[2] calldata pC,
        uint256[7] calldata pubSignals
    ) external {
        require(ballotId != bytes32(0), "ActiveTally: zero ballot");
        require(verifier.verifyProof(pA, pB, pC, pubSignals), "ActiveTally: invalid proof");

        TallyState storage previous = tallies[ballotId];
        // Activity may change the effective result, but never standing choices.
        if (previous.epoch != 0) {
            require(pubSignals[1] == previous.standingBallotRoot, "ActiveTally: standing root changed");
        }
        require(pubSignals[2] <= type(uint64).max, "ActiveTally: electorate overflow");
        require(pubSignals[3] <= type(uint64).max, "ActiveTally: counted overflow");
        require(pubSignals[4] <= type(uint64).max, "ActiveTally: against overflow");
        require(pubSignals[5] <= type(uint64).max, "ActiveTally: for overflow");
        require(pubSignals[6] <= type(uint64).max, "ActiveTally: abstain overflow");
        require(pubSignals[3] <= pubSignals[2], "ActiveTally: counted exceeds electorate");
        require(pubSignals[4] + pubSignals[5] + pubSignals[6] == pubSignals[3], "ActiveTally: totals mismatch");

        uint64 nextEpoch = previous.epoch + 1;
        tallies[ballotId] = TallyState({
            activeCredentialRoot: pubSignals[0],
            standingBallotRoot: pubSignals[1],
            electorate: uint64(pubSignals[2]),
            counted: uint64(pubSignals[3]),
            againstTotal: uint64(pubSignals[4]),
            forTotal: uint64(pubSignals[5]),
            abstainTotal: uint64(pubSignals[6]),
            epoch: nextEpoch
        });
        emit TallyAccepted(
            ballotId, nextEpoch, pubSignals[0], pubSignals[1], uint64(pubSignals[2]),
            uint64(pubSignals[3]), uint64(pubSignals[4]), uint64(pubSignals[5]), uint64(pubSignals[6])
        );
    }

    function tally(bytes32 ballotId) external view returns (TallyState memory) {
        return tallies[ballotId];
    }
}
