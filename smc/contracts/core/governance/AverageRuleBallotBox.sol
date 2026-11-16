// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./BaseRuleBallotBox.sol";

/**
 * @title AverageRuleBallotBox
 * @notice Slider rule structure resolved by the MEAN of cast values. Ballot = `[value]`
 *         with `0 <= value <= maxValue`. On-chain tally: a running `sum` (+ the base's
 *         distinct-voter count) → `currentResult.value` = `sum / count` (integer mean).
 *
 *         Config (registerRule): `abi.encode(uint16 maxValue)` (empty / 0 ⇒ default 100).
 *
 *         `quorumMet` is `true` whenever the result is computable (votes exist) — a value
 *         structure has no support bar; a participation floor against the eligible base is
 *         deferred (the box doesn't know the eligible voter count on-chain). Mean is more
 *         manipulation-prone than median; use Median for thresholds where that matters.
 */
contract AverageRuleBallotBox is BaseRuleBallotBox {
    mapping(bytes32 => uint16) public maxValueOf;
    mapping(bytes32 => uint256) public sumValues;

    constructor(
        address voteTokenAddress,
        uint256 _jurisdictionId,
        address _governor,
        address _chainClock,
        uint16 _quorumThresholdBps,
        address trustedForwarder
    ) BaseRuleBallotBox(voteTokenAddress, _jurisdictionId, _governor, _chainClock, _quorumThresholdBps, trustedForwarder) {}

    function structureId() external pure override returns (bytes32) {
        return keccak256("average");
    }

    function _configureRule(bytes32 ruleKey, bytes calldata config) internal override {
        maxValueOf[ruleKey] = _decodeMaxValue(config);
    }

    function _validateBallot(bytes32 ruleKey, uint16[] calldata ballot) internal view override {
        require(ballot.length == 1, "AverageRuleBox: ballot must be a single value");
        require(ballot[0] <= maxValueOf[ruleKey], "AverageRuleBox: value above maximum");
    }

    function _applyVote(bytes32 ruleKey, uint16[] memory prev, uint16[] calldata next) internal override {
        if (prev.length == 1) {
            sumValues[ruleKey] -= prev[0];
        }
        sumValues[ruleKey] += next[0];
    }

    function _resultValue(bytes32 ruleKey, uint256 totalVotes)
        internal
        view
        override
        returns (int256 value, bool quorumMet)
    {
        value = int256(sumValues[ruleKey] / totalVotes); // integer mean
        quorumMet = true;
    }

    function _decodeMaxValue(bytes calldata config) private pure returns (uint16) {
        if (config.length == 0) {
            return 100;
        }
        uint16 maxValue = abi.decode(config, (uint16));
        return maxValue == 0 ? 100 : maxValue;
    }
}
