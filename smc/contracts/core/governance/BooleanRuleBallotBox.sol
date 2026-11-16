// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./BaseRuleBallotBox.sol";

/**
 * @title BooleanRuleBallotBox
 * @notice Yes/No rule structure. Ballot = `[0]` (oppose) or `[1]` (support).
 *         On-chain tally: support / oppose counts → `currentResult.value` = support in
 *         basis points (0..10000). `quorumMet` when support bps ≥ the box quorum.
 */
contract BooleanRuleBallotBox is BaseRuleBallotBox {
    struct Tally {
        uint256 support;
        uint256 oppose;
    }

    mapping(bytes32 => Tally) public tallies;

    constructor(
        address voteTokenAddress,
        uint256 _jurisdictionId,
        address _governor,
        address _chainClock,
        uint16 _quorumThresholdBps,
        address trustedForwarder
    ) BaseRuleBallotBox(voteTokenAddress, _jurisdictionId, _governor, _chainClock, _quorumThresholdBps, trustedForwarder) {}

    function structureId() external pure override returns (bytes32) {
        return keccak256("boolean");
    }

    function _configureRule(bytes32, bytes calldata) internal pure override {
        // boolean has no structure-specific config
    }

    function _validateBallot(bytes32, uint16[] calldata ballot) internal pure override {
        require(ballot.length == 1 && ballot[0] <= 1, "BooleanRuleBox: ballot must be [0] or [1]");
    }

    function _applyVote(bytes32 ruleKey, uint16[] memory prev, uint16[] calldata next) internal override {
        Tally storage t = tallies[ruleKey];
        if (prev.length == 1) {
            if (prev[0] == 1) {
                t.support -= 1;
            } else {
                t.oppose -= 1;
            }
        }
        if (next[0] == 1) {
            t.support += 1;
        } else {
            t.oppose += 1;
        }
    }

    function _resultValue(bytes32 ruleKey, uint256 totalVotes)
        internal
        view
        override
        returns (int256 value, bool quorumMet)
    {
        // totalVotes == support + oppose (every counted token is exactly one of the two).
        uint256 supportBps = (tallies[ruleKey].support * uint256(MAX_BPS)) / totalVotes;
        value = int256(supportBps);
        quorumMet = supportBps >= quorumThresholdBps;
    }
}
