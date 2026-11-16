// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

interface IRoleCatalog {
    function isActiveRole(uint256 jurisdictionId, uint256 roleId) external view returns (bool);
}

/**
 * @title JurisdictionRoleRegistry
 * @notice On-chain mirror of the backend's per-jurisdiction role assignments.
 *
 *         Keyed by (jurisdictionId, voterId) — the *stable* identity the
 *         soulbound VoteToken uses (activeTokenByVoterJurisdiction). Roles
 *         therefore survive custody handovers / token reissue. Each subject
 *         holds an enumerable set of catalog roleIds (1 = admin, 15 =
 *         token_guardian, …). Grants/revokes emit indexed events so any indexer
 *         (our voteTokenWatcher, or a third party) can deterministically build a
 *         read-model — e.g. populate user_role_token_bindings.
 *
 *         Grant authority is per-jurisdiction:
 *           - a `jurisdictionGovernor[jid]` (Phase 2: an on-chain RoleGrantExecutor
 *             that applies passed vote outcomes), OR
 *           - any holder of ROLE_MANAGER_ROLE (Phase 0/1: the backend signer).
 *         This lets authority migrate from the backend to democratic governance
 *         per jurisdiction without redeploying — just reassign the governor.
 */
contract JurisdictionRoleRegistry is AccessControl {
    using EnumerableSet for EnumerableSet.UintSet;

    bytes32 public constant ROLE_MANAGER_ROLE = keccak256("ROLE_MANAGER_ROLE");

    IRoleCatalog public immutable catalog;

    // jurisdictionId => voterId => set of roleIds
    mapping(uint256 => mapping(bytes32 => EnumerableSet.UintSet)) private _assigned;
    // jurisdictionId => grant authority (e.g. a vote-outcome executor)
    mapping(uint256 => address) public jurisdictionGovernor;

    // Named with a Jurisdiction* prefix to avoid colliding with AccessControl's
    // inherited RoleGranted/RoleRevoked(bytes32,address,address) events.
    event JurisdictionRoleGranted(
        uint256 indexed jurisdictionId,
        bytes32 indexed voterId,
        uint256 indexed roleId,
        address operator
    );
    event JurisdictionRoleRevoked(
        uint256 indexed jurisdictionId,
        bytes32 indexed voterId,
        uint256 indexed roleId,
        address operator
    );
    event JurisdictionGovernorUpdated(uint256 indexed jurisdictionId, address governor);

    error NotAuthorized(uint256 jurisdictionId, address caller);
    error InactiveRole(uint256 roleId);
    error JurisdictionZero();
    error VoterIdZero();

    constructor(address catalogAddress, address admin) {
        require(catalogAddress != address(0), "catalog required");
        catalog = IRoleCatalog(catalogAddress);
        address initial = admin == address(0) ? msg.sender : admin;
        _grantRole(DEFAULT_ADMIN_ROLE, initial);
        _grantRole(ROLE_MANAGER_ROLE, initial);
    }

    modifier canManage(uint256 jurisdictionId) {
        if (
            msg.sender != jurisdictionGovernor[jurisdictionId]
            && !hasRole(ROLE_MANAGER_ROLE, msg.sender)
        ) {
            revert NotAuthorized(jurisdictionId, msg.sender);
        }
        _;
    }

    /**
     * @notice Hand a jurisdiction's role-grant authority to a governor (Phase 2:
     *         the vote-outcome executor). Until set, ROLE_MANAGER_ROLE applies.
     */
    function setJurisdictionGovernor(uint256 jurisdictionId, address governor)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        jurisdictionGovernor[jurisdictionId] = governor;
        emit JurisdictionGovernorUpdated(jurisdictionId, governor);
    }

    /**
     * @notice Grant one or more catalog roles to (jurisdictionId, voterId).
     *         Idempotent: only newly-added roles emit RoleGranted.
     */
    function grantRoles(uint256 jurisdictionId, bytes32 voterId, uint256[] calldata roleIds)
        external
        canManage(jurisdictionId)
    {
        if (jurisdictionId == 0) revert JurisdictionZero();
        if (voterId == bytes32(0)) revert VoterIdZero();
        EnumerableSet.UintSet storage set = _assigned[jurisdictionId][voterId];
        for (uint256 i = 0; i < roleIds.length; i++) {
            uint256 roleId = roleIds[i];
            if (!catalog.isActiveRole(jurisdictionId, roleId)) revert InactiveRole(roleId);
            if (set.add(roleId)) {
                emit JurisdictionRoleGranted(jurisdictionId, voterId, roleId, msg.sender);
            }
        }
    }

    /**
     * @notice Revoke one or more roles. Idempotent: only removals emit RoleRevoked.
     */
    function revokeRoles(uint256 jurisdictionId, bytes32 voterId, uint256[] calldata roleIds)
        external
        canManage(jurisdictionId)
    {
        EnumerableSet.UintSet storage set = _assigned[jurisdictionId][voterId];
        for (uint256 i = 0; i < roleIds.length; i++) {
            uint256 roleId = roleIds[i];
            if (set.remove(roleId)) {
                emit JurisdictionRoleRevoked(jurisdictionId, voterId, roleId, msg.sender);
            }
        }
    }

    // --- views -------------------------------------------------------------

    function holdsRole(uint256 jurisdictionId, bytes32 voterId, uint256 roleId)
        external
        view
        returns (bool)
    {
        return _assigned[jurisdictionId][voterId].contains(roleId);
    }

    function rolesOf(uint256 jurisdictionId, bytes32 voterId)
        external
        view
        returns (uint256[] memory)
    {
        return _assigned[jurisdictionId][voterId].values();
    }

    function roleCount(uint256 jurisdictionId, bytes32 voterId) external view returns (uint256) {
        return _assigned[jurisdictionId][voterId].length();
    }
}
