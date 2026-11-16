// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title DelegationManager
 * @custom:deprecated NOT deployed at the re-genesis (#343 item 5). This V2 event-only delegation surface
 *         is off the canonical pipeline (`scripts/lib/deploy-pipeline.sh`); the ratified open
 *         delegate-vote model uses `governance/PublicDelegateVoteRegistry`, so no separate delegation
 *         manager is needed. Kept for reference; archive candidate post-cut.
 * @dev Minimal on-chain surface for delegation bookkeeping that preserves
 *      privacy by design: sensitive mapping is kept off-chain in the backend.
 *
 * Policy summary (recommended):
 * - The authoritative delegation mapping lives in the backend DB (private).
 * - On-chain we provide two opt-in surfaces:
 *    1) Public opt-in: delegators may publicly register a delegation (optInDelegate)
 *       — this emits an event and is intentionally explicit and public.
 *    2) Owner-audit event: the backend (owner) can emit an audit event that
 *       records a delegation commitment (a hash) without revealing identities.
 *       The delegator can later prove preimage off-chain if necessary.
 * - We avoid storing per-delegator mappings on-chain to reduce privacy leaks.
 *
 * Rationale: storing delegations on-chain makes them public forever and
 * contradicts the project's privacy constraint. This contract therefore
 * focuses on auditable events and optional public opt-in where the user
 * explicitly chooses to reveal the mapping on-chain.
 */

contract DelegationManager {
    // Simple owner - set at deploy time and usable by backend deployer
    address public owner;

    modifier onlyOwner() {
        require(msg.sender == owner, "DelegationManager: only owner");
        _;
    }

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // Public opt-in events (explicit public delegation)
    event DelegationOptIn(
        address indexed delegator,
        address indexed delegate,
        uint256 indexed tagId,
        uint256 jurisdictionId,
        uint256 timestamp
    );

    event DelegationRevokedOptIn(
        address indexed delegator,
        address indexed delegate,
        uint256 indexed tagId,
        uint256 jurisdictionId,
        uint256 timestamp
    );

    // Owner-only audit event: reports a commitment (hash) instead of raw identity
    // delegationHash = keccak256(abi.encodePacked(delegator, tagId, jurisdictionId, nonce))
    event DelegationAudit(
        bytes32 indexed delegationHash,
        uint256 indexed tagId,
        uint256 jurisdictionId,
        address reporter,
        uint256 timestamp
    );

    constructor() {
        owner = msg.sender;
        emit OwnershipTransferred(address(0), owner);
    }

    /**
     * @dev Transfer ownership (useful to hand over to multisig / deployment manager)
     */
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "DelegationManager: zero owner");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    // ================= Public opt-in API =================

    /**
     * @dev Delegator explicitly opts-in to make a delegation public on-chain.
     * Emits `DelegationOptIn` which is a permanent public record. This should
     * only be used when the delegator understands the privacy implications.
     */
    function optInDelegate(address delegate, uint256 tagId, uint256 jurisdictionId) external {
        require(delegate != address(0), "DelegationManager: invalid delegate");
        require(delegate != msg.sender, "DelegationManager: cannot delegate to self");

        emit DelegationOptIn(msg.sender, delegate, tagId, jurisdictionId, block.timestamp);
    }

    /**
     * @dev Delegator revokes a previously public opt-in delegation.
     * Emits `DelegationRevokedOptIn` for audit.
     */
    function revokeOptIn(address delegate, uint256 tagId, uint256 jurisdictionId) external {
        emit DelegationRevokedOptIn(msg.sender, delegate, tagId, jurisdictionId, block.timestamp);
    }

    // ================ Owner audit API ====================

    /**
     * @dev Emit an audit record as the trusted backend. The payload contains
     * a delegationHash rather than explicit public addresses to preserve
     * privacy. The backend should only call this with caution and when an
     * auditable historical record is required.
     *
     * delegationHash SHOULD be produced off-chain using a scheme that allows
     * the delegator to later prove preimage (if desired), e.g.
     * keccak256(abi.encodePacked(delegator,tagId,jurisdictionId,nonce)).
     */
    function emitDelegationAudit(bytes32 delegationHash, uint256 tagId, uint256 jurisdictionId) external onlyOwner {
        require(delegationHash != bytes32(0), "DelegationManager: zero hash");
        emit DelegationAudit(delegationHash, tagId, jurisdictionId, msg.sender, block.timestamp);
    }

    // ================ Convenience helpers ====================

    // Fallbacks: prevent accidental ETH transfers
    receive() external payable {
        revert("DelegationManager: does not accept ETH");
    }

    fallback() external payable {
        revert("DelegationManager: does not accept ETH");
    }
}
