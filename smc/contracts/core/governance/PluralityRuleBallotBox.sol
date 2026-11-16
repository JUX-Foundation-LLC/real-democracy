// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./BaseRuleBallotBox.sol";

/**
 * @title PluralityRuleBallotBox
 * @notice Pick-one rule structure. Ballot = `[choice]` with `choice < choiceCount`.
 *         On-chain tally: per-choice counts → `currentResult.value` = the winning choice
 *         index (the one with the most votes). Ties resolve to the LOWEST index
 *         (deterministic, documented).
 *
 *         Config (registerRule): `abi.encode(uint16 choiceCount)` — required, must be > 1.
 *         `quorumMet` is `true` when a result is computable (votes exist); a "winner needs
 *         a majority" rule is a consumer concern, not enforced here.
 */
contract PluralityRuleBallotBox is BaseRuleBallotBox {
    /// G2 (audit S10): bound `choiceCount` so `_resultValue`'s argmax loop (run on every vote + by
    /// the executor) can't be turned into a gas-DoS. 256 candidates is far beyond any real ballot.
    uint16 public constant MAX_CHOICE_COUNT = 256;

    mapping(bytes32 => uint16) public choiceCountOf;
    // ruleKey => choice => count
    mapping(bytes32 => mapping(uint16 => uint256)) public choiceVotes;

    constructor(
        address voteTokenAddress,
        uint256 _jurisdictionId,
        address _governor,
        address _chainClock,
        uint16 _quorumThresholdBps,
        address trustedForwarder
    ) BaseRuleBallotBox(voteTokenAddress, _jurisdictionId, _governor, _chainClock, _quorumThresholdBps, trustedForwarder) {}

    function structureId() external pure override returns (bytes32) {
        return keccak256("plurality");
    }

    function _configureRule(bytes32 ruleKey, bytes calldata config) internal override {
        require(config.length > 0, "PluralityRuleBox: choiceCount required");
        uint16 choiceCount = abi.decode(config, (uint16));
        require(choiceCount > 1 && choiceCount <= MAX_CHOICE_COUNT, "PluralityRuleBox: choiceCount out of range");
        choiceCountOf[ruleKey] = choiceCount;
    }

    function _validateBallot(bytes32 ruleKey, uint16[] calldata ballot) internal view override {
        require(ballot.length == 1, "PluralityRuleBox: ballot must be a single choice");
        require(ballot[0] < choiceCountOf[ruleKey], "PluralityRuleBox: choice out of range");
    }

    function _applyVote(bytes32 ruleKey, uint16[] memory prev, uint16[] calldata next) internal override {
        if (prev.length == 1) {
            choiceVotes[ruleKey][prev[0]] -= 1;
        }
        choiceVotes[ruleKey][next[0]] += 1;
    }

    function _resultValue(bytes32 ruleKey, uint256 /* totalVotes */)
        internal
        view
        override
        returns (int256 value, bool quorumMet)
    {
        uint16 count = choiceCountOf[ruleKey];
        uint16 winner = 0;
        uint256 best = choiceVotes[ruleKey][0];
        for (uint16 c = 1; c < count; c++) {
            uint256 votesForC = choiceVotes[ruleKey][c];
            if (votesForC > best) {
                // strict > keeps ties on the LOWEST index
                best = votesForC;
                winner = c;
            }
        }
        value = int256(uint256(winner));
        quorumMet = true;
    }
}
