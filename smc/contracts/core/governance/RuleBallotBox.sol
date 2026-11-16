// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "../interfaces/IVoteToken.sol";

interface IChainClockReaderLegacy {
    function currentTick() external view returns (uint256);
}

/**
 * @title RuleBallotBox
 * @custom:deprecated RETIRED at the prod re-genesis (#343 item 4, Coi-ratified). No longer built by
 *         `JurisdictionFactory` and NOT deployed at the cut — rules are tallied by the B.2 per-structure
 *         family (`BooleanRuleBallotBox` / `MedianRuleBallotBox` / `AverageRuleBallotBox` /
 *         `PluralityRuleBallotBox`) indexed by `JurisdictionRuleRegistry`. Retained only because
 *         `GovernanceThresholds.unit.test.js` exercises its threshold bounds; archive candidate post-cut.
 * @dev Live jurisdiction rule tallies backed by VoteToken ownership.
 *      Every rule vote is changeable and emits transparent tallies so
 *      JurisdictionFactory can stamp the latest rule set into newly printed
 *      ballot boxes. Activation requires meeting the quorum threshold set in
 *      basis points (mirrors the legacy "seconding" process but on-chain).
 */
contract RuleBallotBox {
    uint16 private constant MAX_BPS = 10_000;

    enum Choice {
        None,
        Support,
        Oppose
    }

    struct RuleLedger {
        uint256 support;
        uint256 oppose;
        uint256 lastPublishedTick;
        bytes32 metadataHash;
        bool isActive;
    }

    IVoteToken public immutable voteToken;
    IERC721 private immutable voteTokenNft;
    uint256 public immutable jurisdictionId;

    address public governor;
    address public chainClock;
    uint16 public quorumThresholdBps;

    mapping(bytes32 => RuleLedger) public ledgers;
    mapping(bytes32 => mapping(uint256 => Choice)) public voteByToken;

    event GovernorUpdated(address indexed previousGovernor, address indexed newGovernor);
    event ChainClockUpdated(address indexed previousClock, address indexed newClock);
    event QuorumThresholdUpdated(uint16 previousBps, uint16 newBps);
    event RuleRegistered(bytes32 indexed ruleKey, bytes32 metadataHash);
    event RuleMetadataUpdated(bytes32 indexed ruleKey, bytes32 metadataHash);
    event RuleVoteRecorded(
        bytes32 indexed ruleKey,
        uint256 indexed tokenId,
        Choice choice,
        uint256 supportCount,
        uint256 opposeCount
    );
    event RulePublished(
        bytes32 indexed ruleKey,
        bool active,
        uint256 supportBps,
        uint256 totalVotes,
        uint256 tick
    );

    modifier onlyGovernor() {
        require(msg.sender == governor, "RuleBallotBox: only governor");
        _;
    }

    constructor(
        IVoteToken _voteToken,
        uint256 _jurisdictionId,
        address _governor,
        address _chainClock,
        uint16 _quorumThresholdBps
    ) {
        require(address(_voteToken) != address(0), "RuleBallotBox: vote token required");
        require(_jurisdictionId > 0, "RuleBallotBox: jurisdiction required");
        require(_governor != address(0), "RuleBallotBox: governor required");
        require(_quorumThresholdBps <= MAX_BPS, "RuleBallotBox: threshold too high");
        voteToken = _voteToken;
        voteTokenNft = IERC721(address(_voteToken));
        jurisdictionId = _jurisdictionId;
        governor = _governor;
        chainClock = _chainClock;
        quorumThresholdBps = _quorumThresholdBps == 0 ? 6000 : _quorumThresholdBps;
        emit GovernorUpdated(address(0), _governor);
        emit ChainClockUpdated(address(0), _chainClock);
        emit QuorumThresholdUpdated(0, quorumThresholdBps);
    }

    function updateGovernor(address newGovernor) external onlyGovernor {
        require(newGovernor != address(0), "RuleBallotBox: zero governor");
        emit GovernorUpdated(governor, newGovernor);
        governor = newGovernor;
    }

    function setChainClock(address newClock) external onlyGovernor {
        emit ChainClockUpdated(chainClock, newClock);
        chainClock = newClock;
    }

    function setQuorumThreshold(uint16 newThresholdBps) external onlyGovernor {
        require(newThresholdBps > 0, "RuleBallotBox: threshold required");
        require(newThresholdBps <= MAX_BPS, "RuleBallotBox: threshold too high");
        emit QuorumThresholdUpdated(quorumThresholdBps, newThresholdBps);
        quorumThresholdBps = newThresholdBps;
    }

    function registerRule(bytes32 ruleKey, bytes32 metadataHash) external onlyGovernor {
        require(ruleKey != bytes32(0), "RuleBallotBox: rule key required");
        RuleLedger storage ledger = ledgers[ruleKey];
        if (ledger.metadataHash == bytes32(0)) {
            emit RuleRegistered(ruleKey, metadataHash);
        } else {
            emit RuleMetadataUpdated(ruleKey, metadataHash);
        }
        ledger.metadataHash = metadataHash;
    }

    function submitRuleVote(bytes32 ruleKey, uint256 tokenId, uint8 choiceRaw) external {
        require(choiceRaw <= uint8(Choice.Oppose), "RuleBallotBox: invalid choice");
        _assertEligible(tokenId);
        Choice newChoice = Choice(choiceRaw);
        _applyVote(ruleKey, tokenId, newChoice);
    }

    function publishRule(bytes32 ruleKey, bool activate) external onlyGovernor {
        RuleLedger storage ledger = ledgers[ruleKey];
        require(ledger.metadataHash != bytes32(0), "RuleBallotBox: unknown rule");
        (uint256 supportBps, uint256 totalVotes) = ruleSupportBps(ruleKey);
        if (activate) {
            require(totalVotes > 0, "RuleBallotBox: no votes");
            require(supportBps >= quorumThresholdBps, "RuleBallotBox: quorum not met");
        }
        ledger.isActive = activate;
        ledger.lastPublishedTick = _currentTick();
        emit RulePublished(ruleKey, activate, supportBps, totalVotes, ledger.lastPublishedTick);
    }

    function ruleSupportBps(bytes32 ruleKey) public view returns (uint256 supportBps, uint256 totalVotes) {
        RuleLedger storage ledger = ledgers[ruleKey];
        totalVotes = ledger.support + ledger.oppose;
        if (totalVotes == 0) {
            return (0, 0);
        }
        supportBps = (ledger.support * 10_000) / totalVotes;
    }

    function _applyVote(bytes32 ruleKey, uint256 tokenId, Choice newChoice) internal {
        RuleLedger storage ledger = ledgers[ruleKey];
        require(ledger.metadataHash != bytes32(0), "RuleBallotBox: unknown rule");
        Choice previous = voteByToken[ruleKey][tokenId];
        if (previous == newChoice) {
            return;
        }
        if (previous == Choice.Support) {
            ledger.support -= 1;
        } else if (previous == Choice.Oppose) {
            ledger.oppose -= 1;
        }
        if (newChoice == Choice.Support) {
            ledger.support += 1;
        } else if (newChoice == Choice.Oppose) {
            ledger.oppose += 1;
        }
        voteByToken[ruleKey][tokenId] = newChoice;
        emit RuleVoteRecorded(ruleKey, tokenId, newChoice, ledger.support, ledger.oppose);
    }

    function _assertEligible(uint256 tokenId) internal view {
        require(voteToken.isActive(tokenId), "RuleBallotBox: inactive token");
        require(voteToken.jurisdictionIdOf(tokenId) == jurisdictionId, "RuleBallotBox: wrong jurisdiction");
        require(voteTokenNft.ownerOf(tokenId) == msg.sender, "RuleBallotBox: not token owner");
    }

    function _currentTick() internal view returns (uint256) {
        if (chainClock == address(0)) {
            return block.timestamp;
        }
        return IChainClockReaderLegacy(chainClock).currentTick();
    }
}
