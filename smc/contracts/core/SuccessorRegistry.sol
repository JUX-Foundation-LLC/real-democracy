// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title SuccessorRegistry
 * @notice On-chain, queryable pointer linking a retired (disabled/frozen)
 *         VoteToken to the token that superseded it during a custody handover
 *         or key recovery.
 *
 *         VoteToken is already deployed and immutable, so we cannot add a
 *         `successorTokenId` field to its `TokenData` struct. This external
 *         registry provides the same "storage + event" guarantee in a
 *         deployment-compatible way: the handover orchestrator records the
 *         old -> new link here immediately after `handoverCustody` mints the
 *         replacement token. The link is then directly readable on-chain (not
 *         only reconstructable from logs) and forms an unbroken, auditable
 *         chain across any number of successive recoveries.
 *
 *         Authorization is intentionally minimal here. The registry trusts the
 *         RECORDER_ROLE to have already performed the on-chain handover; that
 *         role is granted to the PermissionedCustodian / governance executor,
 *         never to human EOAs. Records are write-once per token: a successor
 *         cannot be silently overwritten, so the historical chain is tamper
 *         evident even to a compromised recorder.
 */
contract SuccessorRegistry is AccessControl {
    /// Role permitted to record handovers. Held by the custody orchestrator
    /// contract(s), never by EOAs.
    bytes32 public constant RECORDER_ROLE = keccak256("RECORDER_ROLE");

    enum HandoverKind {
        Unspecified,
        VoluntaryHandover, // user-initiated self-custody migration
        KeyRecovery        // trusted-authority recovery of a lost key
    }

    struct SuccessorRecord {
        uint256 successorTokenId; // the token that replaced `oldTokenId`
        uint256 jurisdictionId;   // carried over for filtering / scoping
        HandoverKind kind;
        uint64 recordedAt;
        address recordedBy;       // orchestrator that performed the handover
        string reason;            // human-auditable note (e.g. "lost key")
    }

    /// oldTokenId => record describing its successor. successorTokenId == 0
    /// means "no successor recorded" (this token has not been superseded).
    mapping(uint256 => SuccessorRecord) private _records;

    /// Reverse index: successorTokenId => oldTokenId, so the chain can be
    /// walked in either direction.
    mapping(uint256 => uint256) private _predecessorOf;

    event HandoverRecorded(
        uint256 indexed oldTokenId,
        uint256 indexed successorTokenId,
        uint256 indexed jurisdictionId,
        HandoverKind kind,
        address recordedBy,
        string reason
    );

    error SuccessorAlreadyRecorded(uint256 oldTokenId, uint256 existingSuccessor);
    error InvalidTokenId();
    error SelfSuccession();

    constructor(address admin) {
        require(admin != address(0), "SuccessorRegistry: admin required");
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /**
     * @notice Record that `oldTokenId` was superseded by `successorTokenId`.
     * @dev Write-once per `oldTokenId`. Reverts if a successor is already on
     *      record, so an orchestrator (even a compromised one) cannot rewrite
     *      history. Both ids must be non-zero and distinct.
     */
    function recordHandover(
        uint256 oldTokenId,
        uint256 successorTokenId,
        uint256 jurisdictionId,
        HandoverKind kind,
        string calldata reason
    ) external onlyRole(RECORDER_ROLE) {
        if (oldTokenId == 0 || successorTokenId == 0) revert InvalidTokenId();
        if (oldTokenId == successorTokenId) revert SelfSuccession();

        SuccessorRecord storage existing = _records[oldTokenId];
        if (existing.successorTokenId != 0) {
            revert SuccessorAlreadyRecorded(oldTokenId, existing.successorTokenId);
        }

        _records[oldTokenId] = SuccessorRecord({
            successorTokenId: successorTokenId,
            jurisdictionId: jurisdictionId,
            kind: kind,
            recordedAt: uint64(block.timestamp),
            recordedBy: _msgSender(),
            reason: reason
        });
        _predecessorOf[successorTokenId] = oldTokenId;

        emit HandoverRecorded(
            oldTokenId,
            successorTokenId,
            jurisdictionId,
            kind,
            _msgSender(),
            reason
        );
    }

    /// @notice The token that replaced `oldTokenId`, or 0 if none.
    function successorOf(uint256 oldTokenId) external view returns (uint256) {
        return _records[oldTokenId].successorTokenId;
    }

    /// @notice The token that `successorTokenId` replaced, or 0 if none.
    function predecessorOf(uint256 successorTokenId) external view returns (uint256) {
        return _predecessorOf[successorTokenId];
    }

    /// @notice Full record for `oldTokenId`.
    function recordOf(uint256 oldTokenId) external view returns (SuccessorRecord memory) {
        return _records[oldTokenId];
    }

    /**
     * @notice Walk the succession chain forward from `tokenId` to the current,
     *         active terminal token. Bounded by `maxHops` to cap gas; returns
     *         the furthest token reached and whether the terminal was found.
     */
    function latestSuccessor(uint256 tokenId, uint256 maxHops)
        external
        view
        returns (uint256 current, bool terminalReached)
    {
        current = tokenId;
        for (uint256 i = 0; i < maxHops; i++) {
            uint256 next = _records[current].successorTokenId;
            if (next == 0) {
                return (current, true);
            }
            current = next;
        }
        return (current, false);
    }
}
