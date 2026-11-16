// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./Capabilities.sol";

interface IRoleCatalogCaps {
    function roleHasCapability(uint256 jurisdictionId, uint256 roleId, bytes32 capability) external view returns (bool);
}

interface IRoleRegistryRoles {
    function rolesOf(uint256 jurisdictionId, bytes32 voterId) external view returns (uint256[] memory);
}

/**
 * @title CapabilityRegistry
 * @notice The single on-chain resolver: "may voter V in jurisdiction J perform capability C?"
 *         Every governance action contract (ballotboxes, proposal manager, tag box, delegation,
 *         …) gates through this, so self-custody users and third-party clients are permissioned
 *         IDENTICALLY to the first-party backend — the chain is the source of truth.
 *
 *         Resolution (permissive by default):
 *           hasCapability = the reserved `voter` base role (Capabilities.VOTER_ROLE_ID) has C
 *                           OR any role the voter explicitly holds has C.
 *         The voter base role is seeded with ALL permits → every active VoteToken holder can do
 *         everything by default; a jurisdiction RESTRICTS by voting a capability off its voter
 *         role, and ELEVATES by granting roles that carry capabilities the base lacks.
 *
 *         This contract holds no policy of its own — it reads RoleCatalog (role → capabilities)
 *         and JurisdictionRoleRegistry (voter → roles), both governed on-chain via RoleBallotBox.
 *         Membership/eligibility (active token, ownership) is the CALLER's check; this only
 *         answers the permission question.
 */
contract CapabilityRegistry {
    IRoleCatalogCaps public roleCatalog;
    IRoleRegistryRoles public roleRegistry;
    address public governor;

    event SourcesUpdated(address indexed roleCatalog, address indexed roleRegistry);
    event GovernorUpdated(address indexed previousGovernor, address indexed newGovernor);

    error NotGovernor();
    error ZeroGovernor();

    constructor(address roleCatalogAddress, address roleRegistryAddress, address governorAddress) {
        require(governorAddress != address(0), "CapReg: governor required");
        roleCatalog = IRoleCatalogCaps(roleCatalogAddress);
        roleRegistry = IRoleRegistryRoles(roleRegistryAddress);
        governor = governorAddress;
        emit SourcesUpdated(roleCatalogAddress, roleRegistryAddress);
        emit GovernorUpdated(address(0), governorAddress);
    }

    modifier onlyGovernor() {
        if (msg.sender != governor) revert NotGovernor();
        _;
    }

    function setSources(address roleCatalogAddress, address roleRegistryAddress) external onlyGovernor {
        roleCatalog = IRoleCatalogCaps(roleCatalogAddress);
        roleRegistry = IRoleRegistryRoles(roleRegistryAddress);
        emit SourcesUpdated(roleCatalogAddress, roleRegistryAddress);
    }

    function setGovernor(address newGovernor) external onlyGovernor {
        if (newGovernor == address(0)) revert ZeroGovernor();
        emit GovernorUpdated(governor, newGovernor);
        governor = newGovernor;
    }

    /**
     * @notice May voter `voterId` in jurisdiction `jurisdictionId` perform `capability`?
     *         Permissive base (the voter role) OR any explicitly-held role grants it.
     */
    function hasCapability(uint256 jurisdictionId, bytes32 voterId, bytes32 capability)
        public
        view
        returns (bool)
    {
        // implicit base: the reserved voter role applies to every member (no per-member grant)
        if (roleCatalog.roleHasCapability(jurisdictionId, Capabilities.VOTER_ROLE_ID, capability)) {
            return true;
        }
        // explicit elevated roles
        uint256[] memory roles = roleRegistry.rolesOf(jurisdictionId, voterId);
        for (uint256 i = 0; i < roles.length; i++) {
            if (roleCatalog.roleHasCapability(jurisdictionId, roles[i], capability)) {
                return true;
            }
        }
        return false;
    }

    /// Revert unless the voter has the capability — the gate action contracts call.
    function requireCapability(uint256 jurisdictionId, bytes32 voterId, bytes32 capability) external view {
        require(hasCapability(jurisdictionId, voterId, capability), "CapReg: capability denied");
    }
}
