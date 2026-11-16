// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./IRuleBallotBox.sol";

interface IShadowRuleRegistry {
    function jurisdictionGovernor(uint256 jurisdictionId) external view returns (address);
    function ruleBox(uint256 jurisdictionId, bytes32 ruleKey) external view returns (address);
    function activateReprojectedRuleBox(
        uint256 jurisdictionId,
        bytes32 ruleKey,
        address expectedCurrent,
        address box
    ) external;
}

/**
 * @notice Audit/fail-closed coordinator for custodial Rule vote reprojection (#917).
 * A jurisdiction governor authorizes this coordinator once and appoints preparation operators.
 * Operators may prepare a shadow; after that, activation is permissionless but fail-closed.
 * This keeps routine electorate maintenance fire-and-forget without granting operators arbitrary
 * registry authority. The current box remains authoritative until every invariant is checked.
 */
contract RuleShadowReprojectionCoordinator {
    struct Stage {
        uint256 jurisdictionId;
        bytes32 ruleKey;
        address sourceBox;
        address shadowBox;
        uint64 sourceCheckpoint;
        bytes32 electorateDigest;
        bytes32 sourceStateDigest;
        bytes32 replayDigest;
        int256 expectedValue;
        uint256 expectedTotalVotes;
        bool expectedQuorumMet;
        bool cancelled;
        bool activated;
    }

    IShadowRuleRegistry public immutable registry;
    uint256 public stageCount;
    mapping(uint256 => mapping(address => bool)) public operator;
    mapping(uint256 => Stage) public stages;

    event OperatorUpdated(uint256 indexed jurisdictionId, address indexed operator, bool allowed);
    event ReprojectionStaged(
        uint256 indexed stageId,
        uint256 indexed jurisdictionId,
        bytes32 indexed ruleKey,
        address sourceBox,
        address shadowBox,
        uint64 sourceCheckpoint,
        bytes32 electorateDigest,
        bytes32 sourceStateDigest,
        bytes32 replayDigest,
        bytes32 expectedResultDigest
    );
    event ReprojectionCancelled(uint256 indexed stageId);
    event ReprojectionActivated(uint256 indexed stageId, bytes32 activationDigest);

    constructor(address registryAddress) {
        require(registryAddress != address(0), "Reprojection: registry required");
        registry = IShadowRuleRegistry(registryAddress);
    }

    modifier onlyGovernor(uint256 jurisdictionId) {
        require(msg.sender == registry.jurisdictionGovernor(jurisdictionId), "Reprojection: only jurisdiction governor");
        _;
    }

    function setOperator(uint256 jurisdictionId, address account, bool allowed) external onlyGovernor(jurisdictionId) {
        require(account != address(0), "Reprojection: operator required");
        operator[jurisdictionId][account] = allowed;
        emit OperatorUpdated(jurisdictionId, account, allowed);
    }

    function stage(
        uint256 jurisdictionId,
        bytes32 ruleKey,
        address shadowBox,
        uint64 sourceCheckpoint,
        bytes32 electorateDigest,
        bytes32 sourceStateDigest,
        bytes32 replayDigest,
        int256 expectedValue,
        uint256 expectedTotalVotes,
        bool expectedQuorumMet
    ) external returns (uint256 stageId) {
        address gov = registry.jurisdictionGovernor(jurisdictionId);
        require(msg.sender == gov || operator[jurisdictionId][msg.sender], "Reprojection: not operator");
        require(sourceCheckpoint > 0, "Reprojection: checkpoint required");
        require(electorateDigest != bytes32(0), "Reprojection: electorate digest required");
        require(sourceStateDigest != bytes32(0), "Reprojection: source digest required");
        require(replayDigest != bytes32(0), "Reprojection: replay digest required");

        address sourceBox = registry.ruleBox(jurisdictionId, ruleKey);
        require(sourceBox != address(0), "Reprojection: source not bound");
        require(shadowBox != address(0) && shadowBox != sourceBox, "Reprojection: invalid shadow");
        require(IRuleBallotBox(shadowBox).jurisdictionId() == jurisdictionId, "Reprojection: jurisdiction mismatch");
        require(IRuleBallotBox(sourceBox).structureId() == IRuleBallotBox(shadowBox).structureId(),
            "Reprojection: structure mismatch");

        stageId = ++stageCount;
        stages[stageId] = Stage(
            jurisdictionId, ruleKey, sourceBox, shadowBox, sourceCheckpoint,
            electorateDigest, sourceStateDigest, replayDigest,
            expectedValue, expectedTotalVotes, expectedQuorumMet, false, false
        );
        emit ReprojectionStaged(
            stageId, jurisdictionId, ruleKey, sourceBox, shadowBox, sourceCheckpoint,
            electorateDigest, sourceStateDigest, replayDigest,
            keccak256(abi.encode(expectedValue, expectedTotalVotes, expectedQuorumMet))
        );
    }

    function cancel(uint256 stageId) external {
        Stage storage s = stages[stageId];
        require(s.sourceBox != address(0), "Reprojection: unknown stage");
        require(msg.sender == registry.jurisdictionGovernor(s.jurisdictionId), "Reprojection: only jurisdiction governor");
        require(!s.activated, "Reprojection: already activated");
        s.cancelled = true;
        emit ReprojectionCancelled(stageId);
    }

    function activate(uint256 stageId) external {
        Stage storage s = stages[stageId];
        require(s.sourceBox != address(0), "Reprojection: unknown stage");
        require(!s.cancelled && !s.activated, "Reprojection: stage closed");
        require(registry.ruleBox(s.jurisdictionId, s.ruleKey) == s.sourceBox, "Reprojection: source changed");
        require(IRuleBallotBox(s.shadowBox).jurisdictionId() == s.jurisdictionId, "Reprojection: jurisdiction changed");
        require(IRuleBallotBox(s.sourceBox).structureId() == IRuleBallotBox(s.shadowBox).structureId(),
            "Reprojection: structure changed");
        (int256 value, uint256 totalVotes, bool quorumMet) = IRuleBallotBox(s.shadowBox).currentResult(s.ruleKey);
        require(
            value == s.expectedValue && totalVotes == s.expectedTotalVotes && quorumMet == s.expectedQuorumMet,
            "Reprojection: tally mismatch"
        );

        // Set before the external call; any revert rolls this back with the registry update.
        s.activated = true;
        registry.activateReprojectedRuleBox(s.jurisdictionId, s.ruleKey, s.sourceBox, s.shadowBox);
        emit ReprojectionActivated(stageId, keccak256(abi.encode(
            s.electorateDigest, s.sourceStateDigest, s.replayDigest,
            value, totalVotes, quorumMet, block.number
        )));
    }
}
