// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./BaseRuleBallotBox.sol";

/**
 * @title InitiativeBallotBox
 * @notice ANONYMOUS, WINDOW-FINALIZED on-chain vote for **Initiatives** — on-chain, window-finalized
 *         legislative texts that do NOT morph once settled (unlike a Rule, which is a continuous
 *         standing tally). Rides the shared `BaseRuleBallotBox` anonymous spine: zk membership proof +
 *         rotating nullifier, **proof-system-agnostic** (Groth16 now, zk-STARK at the cut). WHO votes
 *         YAY/NAY is anonymous; only the SUBJECT (the initiative) is public.
 *
 *         Each initiative is a boolean support/oppose tally open ONLY during its
 *         `[votingStart, votingEnd]` wall-clock window; after the window `finalize()` LOCKS the result
 *         immutably — `passed` when support ≥ the initiative's pass threshold. Re-votes (change
 *         YAY↔NAY) are allowed while the window is open (the base's exact re-vote lifecycle); the box
 *         is sealed once finalized. Gated by `PERMIT_INITIATIVE_VOTING`.
 *
 *         Replaces the legacy `ProposalManager`/`ProposalBallotBox` on-chain vote (which stored
 *         `tokenVoteChoice[tokenId]` PUBLICLY — not anonymous). One box per jurisdiction; each
 *         initiative is a subject key.
 */
contract InitiativeBallotBox is BaseRuleBallotBox {
    struct Tally {
        uint256 support;
        uint256 oppose;
    }
    mapping(bytes32 => Tally) public tallies;

    struct Initiative {
        uint256 votingStart;
        uint256 votingEnd;
        uint16 passThresholdBps;
        bool finalized;
        bool passed;
        bool exists;
    }
    mapping(bytes32 => Initiative) public initiatives;

    event InitiativeRegistered(
        bytes32 indexed key,
        bytes32 metadataHash,
        uint256 votingStart,
        uint256 votingEnd,
        uint16 passThresholdBps
    );
    event InitiativeFinalized(bytes32 indexed key, bool passed, uint256 supportBps, uint256 totalVotes, uint256 tick);

    constructor(
        address voteTokenAddress,
        uint256 _jurisdictionId,
        address _governor,
        address _chainClock,
        uint16 _defaultPassThresholdBps,
        address trustedForwarder
    )
        BaseRuleBallotBox(voteTokenAddress, _jurisdictionId, _governor, _chainClock, _defaultPassThresholdBps, trustedForwarder)
    {}

    function structureId() external pure override returns (bytes32) {
        return keccak256("initiative_pass");
    }

    /// Initiative voting requires PERMIT_INITIATIVE_VOTING — NOT PERMIT_RULE_VOTING (the base default).
    function _votingCapability() internal pure override returns (bytes32) {
        return Capabilities.PERMIT_INITIATIVE_VOTING;
    }

    /// INFO-2 (#310): accurate capability-denied message for this box.
    function _votingDeniedMessage() internal pure override returns (string memory) {
        return "InitBox: initiative voting not permitted";
    }

    /// #310 HIGH-1: initiative votes are anonymous-only — close the transparent tokenId path by
    /// construction. Self-enforcing default, not a deploy-script flip that could be skipped.
    function _transparentVotingDisabledByDefault() internal pure override returns (bool) {
        return true;
    }

    /// Open a window-finalized initiative. Governor-only. Register-once (an initiative does not morph);
    /// anonymous votes flow once the governor binds its scope via `setRuleExternalNullifier`.
    function registerInitiative(
        bytes32 key,
        bytes32 metadataHash,
        uint256 votingStart,
        uint256 votingEnd,
        uint16 passThresholdBps
    ) external onlyGovernor {
        require(key != bytes32(0), "InitBox: key required");
        require(votingEnd > votingStart, "InitBox: bad window");
        require(passThresholdBps > 0 && passThresholdBps <= MAX_BPS, "InitBox: bad threshold");
        Initiative storage ini = initiatives[key];
        require(!ini.exists, "InitBox: already registered");
        ini.votingStart = votingStart;
        ini.votingEnd = votingEnd;
        ini.passThresholdBps = passThresholdBps;
        ini.exists = true;

        // Register the subject as a votable key in the base (no structure config).
        RuleMeta storage m = ruleMeta[key];
        m.metadataHash = metadataHash;
        m.exists = true;
        emit RuleRegistered(key, metadataHash);
        emit InitiativeRegistered(key, metadataHash, votingStart, votingEnd, passThresholdBps);
    }

    /// Finalize after the window closes: lock the result immutably. Permissionless — the outcome is
    /// deterministic from the on-chain tally, no trust. Settles `passed` = support ≥ pass threshold.
    function finalize(bytes32 key) external {
        Initiative storage ini = initiatives[key];
        require(ini.exists, "InitBox: unknown initiative");
        require(!ini.finalized, "InitBox: already finalized");
        require(block.timestamp > ini.votingEnd, "InitBox: window still open");
        (int256 supportBps, uint256 total, ) = currentResult(key);
        bool passed = total > 0 && uint256(supportBps) >= ini.passThresholdBps;
        ini.finalized = true;
        ini.passed = passed;
        emit InitiativeFinalized(key, passed, uint256(supportBps), total, _currentTick());
    }

    // ── boolean support/oppose tally + window enforcement ──────────────────────────────────────
    function _configureRule(bytes32, bytes calldata) internal pure override {
        // initiatives carry no structure-specific config (YAY/NAY)
    }

    function _validateBallot(bytes32 key, uint16[] calldata ballot) internal view override {
        Initiative storage ini = initiatives[key];
        require(ini.exists, "InitBox: unknown initiative");
        require(!ini.finalized, "InitBox: finalized");
        require(block.timestamp >= ini.votingStart && block.timestamp <= ini.votingEnd, "InitBox: outside voting window");
        require(ballot.length == 1 && ballot[0] <= 1, "InitBox: ballot must be [0] or [1]");
    }

    function _applyVote(bytes32 key, uint16[] memory prev, uint16[] calldata next) internal override {
        Tally storage t = tallies[key];
        if (prev.length == 1) {
            if (prev[0] == 1) t.support -= 1;
            else t.oppose -= 1;
        }
        if (next[0] == 1) t.support += 1;
        else t.oppose += 1;
    }

    function _resultValue(bytes32 key, uint256 totalVotes)
        internal
        view
        override
        returns (int256 value, bool quorumMet)
    {
        uint256 supportBps = (tallies[key].support * uint256(MAX_BPS)) / totalVotes;
        value = int256(supportBps);
        quorumMet = supportBps >= initiatives[key].passThresholdBps;
    }
}
