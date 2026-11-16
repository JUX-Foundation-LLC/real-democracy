// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title CheckpointRegistry
 * @dev Minimal event-only registry that anchors backend-generated Merkle
 *      checkpoints on-chain. Each anchor carries its SUBJECT IDENTITY
 *      (subjectType, subjectId, jurisdictionId) so the full set of anchored
 *      checkpoints is enumerable and the ChainClock global-completeness aggregate
 *      is **reconstructable from chain** — the property that makes "no ballotbox
 *      was censored" provable rather than backend-trusted
 *      (vote/docs/CHAINCLOCK_STANDUP.md §2, AUDITABILITY_AND_RETENTION.md §4.1).
 *      Full + smartphone validators subscribe to `CheckpointAnchored` and verify
 *      roots independently without trusting the backend DB.
 *
 *      S2a (the keystone foundation): before this, the event carried only
 *      `proposalId`, so non-proposal subjects (ruleset / tag_registry / show) were
 *      indistinguishable on-chain and an all-ballotbox aggregate could not be
 *      rebuilt from chain. Now every anchor is subject-typed.
 */
contract CheckpointRegistry {
    address public owner;

    /// Canonical subject-type tags = keccak of the subjectType string. Callers may
    /// pass any bytes32; these are the system's known kinds (mirror the backend's
    /// chain-checkpoint subjectType values).
    bytes32 public constant SUBJECT_PROPOSAL     = keccak256("proposal");
    bytes32 public constant SUBJECT_RULESET      = keccak256("ruleset");
    bytes32 public constant SUBJECT_TAG_REGISTRY = keccak256("tag_registry");
    bytes32 public constant SUBJECT_SHOW         = keccak256("show");

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /// Subject-aware checkpoint anchor. `(subjectType, subjectId)` identify the
    /// ballotbox/subject; `jurisdictionId` scopes it. The ChainClock aggregate is
    /// rebuilt by reading these events and taking the latest per `(subjectType,
    /// subjectId)`.
    event CheckpointAnchored(
        uint256 indexed checkpointId,
        bytes32 indexed subjectType,
        uint256 indexed jurisdictionId,
        uint256 subjectId,
        bytes32 root,
        uint256 leafCount,
        bytes32 metadataHash,
        address operator,
        uint256 timestamp
    );

    modifier onlyOwner() {
        require(msg.sender == owner, "CheckpointRegistry: only owner");
        _;
    }

    constructor() {
        owner = msg.sender;
        emit OwnershipTransferred(address(0), owner);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "CheckpointRegistry: zero owner");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    /// Canonical subject-aware anchor.
    function anchorCheckpoint(
        uint256 checkpointId,
        bytes32 subjectType,
        uint256 subjectId,
        uint256 jurisdictionId,
        bytes32 root,
        uint256 leafCount,
        bytes32 metadataHash
    ) external onlyOwner {
        _anchor(checkpointId, subjectType, subjectId, jurisdictionId, root, leafCount, metadataHash);
    }

    /// Back-compat: the proposal anchor path. Records a proposal checkpoint under
    /// the canonical subject scheme (`subjectType = SUBJECT_PROPOSAL`,
    /// `subjectId = proposalId`, `jurisdictionId = 0`). Existing callers that pass
    /// the 5-arg `(checkpointId, proposalId, root, leafCount, metadataHash)`
    /// resolve here.
    function anchorCheckpoint(
        uint256 checkpointId,
        uint256 proposalId,
        bytes32 root,
        uint256 leafCount,
        bytes32 metadataHash
    ) external onlyOwner {
        require(proposalId > 0, "CheckpointRegistry: proposal id required");
        _anchor(checkpointId, SUBJECT_PROPOSAL, proposalId, 0, root, leafCount, metadataHash);
    }

    function _anchor(
        uint256 checkpointId,
        bytes32 subjectType,
        uint256 subjectId,
        uint256 jurisdictionId,
        bytes32 root,
        uint256 leafCount,
        bytes32 metadataHash
    ) internal {
        require(checkpointId > 0, "CheckpointRegistry: checkpoint id required");
        require(subjectType != bytes32(0), "CheckpointRegistry: subject type required");
        require(subjectId > 0, "CheckpointRegistry: subject id required");
        require(root != bytes32(0), "CheckpointRegistry: zero root");

        emit CheckpointAnchored(
            checkpointId,
            subjectType,
            jurisdictionId,
            subjectId,
            root,
            leafCount,
            metadataHash,
            msg.sender,
            block.timestamp
        );
    }

    /// The canonical aggregate leaf for one checkpoint. The off-chain ChainClock
    /// aggregate builder AND any third-party auditor MUST use this exact encoding,
    /// so an independently-rebuilt aggregate root matches byte-for-byte
    /// (CHAINCLOCK_STANDUP §2). `keccak256(abi.encode(...))` here equals
    /// ethers `keccak256(defaultAbiCoder.encode([...]))` off-chain.
    function checkpointLeaf(
        bytes32 subjectType,
        uint256 subjectId,
        uint256 jurisdictionId,
        bytes32 root,
        uint256 leafCount
    ) external pure returns (bytes32) {
        return keccak256(abi.encode(subjectType, subjectId, jurisdictionId, root, leafCount));
    }

    receive() external payable {
        revert("CheckpointRegistry: does not accept ETH");
    }

    fallback() external payable {
        revert("CheckpointRegistry: does not accept ETH");
    }
}
