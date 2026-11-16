// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

interface IVoteTokenRuleView {
    function isActive(uint256 tokenId) external view returns (bool);
    function jurisdictionIdOf(uint256 tokenId) external view returns (uint256);
}

/**
 * @title RuleValueBallotBox
 * @custom:deprecated RETIRED at the prod re-genesis — superseded by the B.2 per-structure
 *         rule-ballotbox family (`BooleanRuleBallotBox` / `MedianRuleBallotBox` /
 *         `AverageRuleBallotBox` / `PluralityRuleBallotBox` bound through
 *         `RuleBallotBoxRegistry`; see `docs/B2_BALLOTBOX_FAMILY.md`). This single
 *         multiplexed value box is NOT deployed by the canonical pipeline
 *         (`scripts/lib/deploy-pipeline.sh`) — only the off-path `deploy_rule_value_boxes.js`
 *         references it. No contract imports it. Do NOT build on it; kept for reference until
 *         the post-cut `archive/` move (see `docs/BALLOTBOX_REGISTRY_AND_TAG_TRACKING.md §3`).
 * @notice Never-closing, jurisdiction-scoped ballot box for VALUE rules —
 *         the living dials of a jurisdiction (quorum thresholds, voting
 *         windows, payout splits, …). One movable ballot per VoteToken per
 *         rule; resolution (mean/majority/mode/instant-runoff) is computed
 *         off-chain from the on-chain ballots and anchored via checkpoints,
 *         keeping the chain light while every individual ballot stays
 *         independently verifiable.
 *
 *         Ballot encoding: `uint16[] voteValue`, interpreted by the rule's
 *         registered valueType:
 *           BOOLEAN  (1): [0] = nay, [1] = yay
 *           SLIDER   (2): [n] where 0 <= n <= maxValue (averaged off-chain)
 *           PLURALITY(3): [choiceIndex] where choiceIndex < choiceCount
 *           RANKED   (4): [first, second, …] unique choice indexes in
 *                         preference order (instant-runoff off-chain)
 *         Type codes >= 100 are open for future structures (cardinal,
 *         majority judgement, …): ballots are length/maxValue-bounded but
 *         otherwise uninterpreted by the contract, so new voting styles can
 *         ship without redeploying the box.
 */
contract RuleValueBallotBox {
    uint8 public constant TYPE_BOOLEAN = 1;
    uint8 public constant TYPE_SLIDER = 2;
    uint8 public constant TYPE_PLURALITY = 3;
    uint8 public constant TYPE_RANKED = 4;
    uint8 public constant TYPE_CUSTOM_BASE = 100;

    struct RuleConfig {
        uint8 valueType;
        uint16 choiceCount; // PLURALITY/RANKED: number of choices
        uint16 maxValue;    // SLIDER/custom: inclusive value ceiling
        uint16 maxLength;   // custom types: ballot length ceiling
        bytes32 metadataHash;
        bool exists;
    }

    struct Ballot {
        uint16[] voteValue;
        uint64 castAt;
        uint32 revision;
    }

    IVoteTokenRuleView public immutable voteToken;
    IERC721 private immutable voteTokenNft;
    uint256 public immutable jurisdictionId;
    address public governor;

    mapping(bytes32 => RuleConfig) public rules;
    mapping(bytes32 => mapping(uint256 => Ballot)) private _ballots;
    mapping(bytes32 => uint256) public ballotCount; // distinct tokens that ever voted

    event GovernorUpdated(address indexed previousGovernor, address indexed newGovernor);
    event RuleRegistered(bytes32 indexed ruleKey, uint8 valueType, uint16 choiceCount, uint16 maxValue, bytes32 metadataHash);
    event RuleConfigUpdated(bytes32 indexed ruleKey, uint8 valueType, uint16 choiceCount, uint16 maxValue, bytes32 metadataHash);
    event RuleValueVoteCast(
        bytes32 indexed ruleKey,
        uint256 indexed tokenId,
        uint16[] voteValue,
        uint32 revision
    );

    modifier onlyGovernor() {
        require(msg.sender == governor, "RuleValueBallotBox: only governor");
        _;
    }

    constructor(address voteTokenAddress, uint256 _jurisdictionId, address _governor) {
        require(voteTokenAddress != address(0), "RuleValueBallotBox: vote token required");
        require(_jurisdictionId > 0, "RuleValueBallotBox: jurisdiction required");
        require(_governor != address(0), "RuleValueBallotBox: governor required");
        voteToken = IVoteTokenRuleView(voteTokenAddress);
        voteTokenNft = IERC721(voteTokenAddress);
        jurisdictionId = _jurisdictionId;
        governor = _governor;
        emit GovernorUpdated(address(0), _governor);
    }

    function updateGovernor(address newGovernor) external onlyGovernor {
        require(newGovernor != address(0), "RuleValueBallotBox: zero governor");
        emit GovernorUpdated(governor, newGovernor);
        governor = newGovernor;
    }

    function registerRule(
        bytes32 ruleKey,
        uint8 valueType,
        uint16 choiceCount,
        uint16 maxValue,
        uint16 maxLength,
        bytes32 metadataHash
    ) external onlyGovernor {
        require(ruleKey != bytes32(0), "RuleValueBallotBox: rule key required");
        require(
            valueType == TYPE_BOOLEAN || valueType == TYPE_SLIDER || valueType == TYPE_PLURALITY
                || valueType == TYPE_RANKED || valueType >= TYPE_CUSTOM_BASE,
            "RuleValueBallotBox: unknown value type"
        );
        if (valueType == TYPE_PLURALITY || valueType == TYPE_RANKED) {
            require(choiceCount > 1, "RuleValueBallotBox: choices required");
        }

        bool existed = rules[ruleKey].exists;
        rules[ruleKey] = RuleConfig({
            valueType: valueType,
            choiceCount: choiceCount,
            maxValue: maxValue == 0 ? 100 : maxValue,
            maxLength: maxLength == 0 ? 32 : maxLength,
            metadataHash: metadataHash,
            exists: true
        });

        if (existed) {
            emit RuleConfigUpdated(ruleKey, valueType, choiceCount, maxValue, metadataHash);
        } else {
            emit RuleRegistered(ruleKey, valueType, choiceCount, maxValue, metadataHash);
        }
    }

    /**
     * @notice Cast or move a rule ballot. The box never closes: a token's
     *         latest ballot always counts, with full revision history in
     *         the event stream for auditors.
     */
    function castRuleVote(bytes32 ruleKey, uint256 tokenId, uint16[] calldata voteValue) external {
        RuleConfig storage config = rules[ruleKey];
        require(config.exists, "RuleValueBallotBox: unknown rule");
        _assertEligible(tokenId);
        _validateBallot(config, voteValue);

        Ballot storage ballot = _ballots[ruleKey][tokenId];
        if (ballot.revision == 0) {
            ballotCount[ruleKey] += 1;
        }
        ballot.voteValue = voteValue;
        ballot.castAt = uint64(block.timestamp);
        ballot.revision += 1;

        emit RuleValueVoteCast(ruleKey, tokenId, voteValue, ballot.revision);
    }

    function getBallot(bytes32 ruleKey, uint256 tokenId)
        external
        view
        returns (uint16[] memory voteValue, uint64 castAt, uint32 revision)
    {
        Ballot storage ballot = _ballots[ruleKey][tokenId];
        return (ballot.voteValue, ballot.castAt, ballot.revision);
    }

    function _validateBallot(RuleConfig storage config, uint16[] calldata voteValue) private view {
        require(voteValue.length > 0, "RuleValueBallotBox: empty ballot");

        if (config.valueType == TYPE_BOOLEAN) {
            require(voteValue.length == 1 && voteValue[0] <= 1, "RuleValueBallotBox: boolean ballot must be [0] or [1]");
        } else if (config.valueType == TYPE_SLIDER) {
            require(voteValue.length == 1, "RuleValueBallotBox: slider ballot must be a single value");
            require(voteValue[0] <= config.maxValue, "RuleValueBallotBox: slider value above maximum");
        } else if (config.valueType == TYPE_PLURALITY) {
            require(voteValue.length == 1, "RuleValueBallotBox: plurality ballot must be a single choice");
            require(voteValue[0] < config.choiceCount, "RuleValueBallotBox: choice out of range");
        } else if (config.valueType == TYPE_RANKED) {
            require(voteValue.length <= config.choiceCount, "RuleValueBallotBox: too many rankings");
            // choices must be in range and unique (choiceCount is small, so
            // the O(n^2) scan stays cheap)
            for (uint256 i = 0; i < voteValue.length; i++) {
                require(voteValue[i] < config.choiceCount, "RuleValueBallotBox: ranked choice out of range");
                for (uint256 j = i + 1; j < voteValue.length; j++) {
                    require(voteValue[i] != voteValue[j], "RuleValueBallotBox: duplicate ranked choice");
                }
            }
        } else {
            // Custom/future types: bound size and magnitude, interpret off-chain.
            require(voteValue.length <= config.maxLength, "RuleValueBallotBox: ballot too long");
            for (uint256 i = 0; i < voteValue.length; i++) {
                require(voteValue[i] <= config.maxValue, "RuleValueBallotBox: value above maximum");
            }
        }
    }

    function _assertEligible(uint256 tokenId) private view {
        require(voteToken.isActive(tokenId), "RuleValueBallotBox: inactive token");
        require(voteToken.jurisdictionIdOf(tokenId) == jurisdictionId, "RuleValueBallotBox: wrong jurisdiction");
        require(voteTokenNft.ownerOf(tokenId) == msg.sender, "RuleValueBallotBox: not token owner");
    }
}
