// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./BaseRuleBallotBox.sol";

/**
 * @title MedianRuleBallotBox
 * @notice Slider rule structure resolved by the MEDIAN of cast values — manipulation-
 *         resistant (an extreme vote can't drag the result the way it drags a mean), so
 *         it's the recommended structure for thresholds. Ballot = `[value]`,
 *         `0 <= value <= maxValue`.
 *
 *         On-chain tally without sorting: a per-value histogram (`hist[value] = count`),
 *         cheap because values are bounded. `currentResult.value` = the lower median —
 *         the `(count+1)/2`-th smallest value — found by walking the histogram to the
 *         median position (O(maxValue), no sort). For odd counts this is the exact middle;
 *         for even counts it's the lower of the two central values (deterministic).
 *
 *         Config (registerRule): `abi.encode(uint16 maxValue)` (empty / 0 ⇒ default 100).
 *         `quorumMet` is `true` when a result is computable (see AverageRuleBallotBox).
 */
contract MedianRuleBallotBox is BaseRuleBallotBox {
    mapping(bytes32 => uint16) public maxValueOf;
    // ruleKey => value => count
    mapping(bytes32 => mapping(uint16 => uint256)) public hist;

    constructor(
        address voteTokenAddress,
        uint256 _jurisdictionId,
        address _governor,
        address _chainClock,
        uint16 _quorumThresholdBps,
        address trustedForwarder
    ) BaseRuleBallotBox(voteTokenAddress, _jurisdictionId, _governor, _chainClock, _quorumThresholdBps, trustedForwarder) {}

    function structureId() external pure override returns (bytes32) {
        return keccak256("median");
    }

    function _configureRule(bytes32 ruleKey, bytes calldata config) internal override {
        maxValueOf[ruleKey] = _decodeMaxValue(config);
    }

    function _validateBallot(bytes32 ruleKey, uint16[] calldata ballot) internal view override {
        require(ballot.length == 1, "MedianRuleBox: ballot must be a single value");
        require(ballot[0] <= maxValueOf[ruleKey], "MedianRuleBox: value above maximum");
    }

    function _applyVote(bytes32 ruleKey, uint16[] memory prev, uint16[] calldata next) internal override {
        if (prev.length == 1) {
            hist[ruleKey][prev[0]] -= 1; // exact decrement of the prior contribution
        }
        hist[ruleKey][next[0]] += 1;
    }

    function _resultValue(bytes32 ruleKey, uint256 totalVotes)
        internal
        view
        override
        returns (int256 value, bool quorumMet)
    {
        // Walk the histogram to the median position. target = ceil-free lower-median index.
        uint256 target = (totalVotes + 1) / 2;
        uint256 cumulative = 0;
        uint16 max = maxValueOf[ruleKey];
        for (uint16 v = 0; ; v++) {
            cumulative += hist[ruleKey][v];
            if (cumulative >= target) {
                return (int256(uint256(v)), true);
            }
            if (v == max) {
                // Defensive: counts are exact, so we always cross `target` at or before max.
                return (int256(uint256(max)), true);
            }
        }
    }

    function _decodeMaxValue(bytes calldata config) private pure returns (uint16) {
        if (config.length == 0) {
            return 100;
        }
        uint16 maxValue = abi.decode(config, (uint16));
        return maxValue == 0 ? 100 : maxValue;
    }
}
