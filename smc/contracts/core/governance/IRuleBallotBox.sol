// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IRuleBallotBox
 * @notice The uniform surface every per-structure rule ballotbox implements (B.2).
 *         A jurisdiction binds each Rule to ONE structure-contract (boolean / average /
 *         median / plurality / …) via the RuleBallotBoxRegistry. Callers — the tag/rule
 *         watcher, the frontend, and other contracts — read every structure the same way
 *         through `currentResult`, and detect the contract via ERC-165 + `structureId`.
 *
 *         `ballot` is a uint16[] interpreted by the structure:
 *           boolean   : [0]=oppose, [1]=support
 *           average   : [value]   0 <= value <= maxValue
 *           median    : [value]   0 <= value <= maxValue
 *           plurality : [choice]  choice < choiceCount
 *         Votes are changeable: a token's latest ballot always counts, and the running
 *         on-chain tally is kept exact (re-vote decrements the prior contribution).
 */
interface IRuleBallotBox {
    /// Emitted when a rule is first registered on this box.
    event RuleRegistered(bytes32 indexed ruleKey, bytes32 metadataHash);
    /// Emitted when a rule's metadata or structure config is updated.
    event RuleConfigUpdated(bytes32 indexed ruleKey, bytes32 metadataHash);
    /// Emitted on every (changeable) vote — the structure reports its fresh result.
    event RuleVoteCast(
        bytes32 indexed ruleKey,
        uint256 indexed tokenId,
        uint16[] ballot,
        int256 result,
        uint256 totalVotes
    );

    /**
     * @notice Register a rule on this structure-box. `config` is structure-specific,
     *         abi-decoded by the implementation (e.g. plurality choiceCount, slider
     *         maxValue). Governance-gated.
     */
    function registerRule(bytes32 ruleKey, bytes32 metadataHash, bytes calldata config) external;

    /**
     * @notice Cast or move a rule ballot. Base checks eligibility + changeability; the
     *         structure validates `ballot` against its config and updates the tally.
     */
    function castVote(bytes32 ruleKey, uint256 tokenId, uint16[] calldata ballot) external;

    /**
     * @notice The canonical on-chain read, uniform across structures.
     * @return value     the structure's result — boolean: support in bps (0..10000);
     *                   average/median: the resolved value; plurality: winning choice index.
     *                   Returns 0 when there are no votes (callers check `totalVotes`).
     * @return totalVotes distinct tokens currently counted for this rule.
     * @return quorumMet  whether participation/support meets the box's quorum bar.
     */
    function currentResult(bytes32 ruleKey)
        external
        view
        returns (int256 value, uint256 totalVotes, bool quorumMet);

    /// @notice Identifies the structure, e.g. keccak256("boolean") — for off-chain routing.
    function structureId() external view returns (bytes32);

    /// @notice The per-jurisdiction scope this box is pinned to.
    function jurisdictionId() external view returns (uint256);
}
