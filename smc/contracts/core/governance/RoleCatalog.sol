// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/**
 * @title RoleCatalog
 * @notice Per-jurisdiction, governable namespace for role identifiers and the
 *         capabilities they confer.
 *
 *         A `roleId` is an arbitrary sparse number whose *meaning* is scoped to a
 *         jurisdiction: (jurisdictionId, roleId) -> { key, name, active } plus a
 *         set of capability keys (bytes32, e.g. keccak256("appoint_staff")).
 *         The same numeric id can mean different things in different
 *         jurisdictions, and the capabilities a role confers are themselves
 *         governable — so role semantics are modular, never "set in stone" on
 *         chain. Human-facing titles ultimately live in the backend; the chain
 *         is the source of truth for *what a role can do*.
 *
 *         Authority is per-jurisdiction: a `jurisdictionGovernor[jid]` (later an
 *         on-chain governance executor) or any CATALOG_ADMIN_ROLE holder (the
 *         backend signer during bootstrap) may edit a jurisdiction's roles.
 */
contract RoleCatalog is AccessControl {
    using EnumerableSet for EnumerableSet.UintSet;
    using EnumerableSet for EnumerableSet.Bytes32Set;

    bytes32 public constant CATALOG_ADMIN_ROLE = keccak256("CATALOG_ADMIN_ROLE");

    struct RoleDef {
        string key;
        string name;
        bytes32 metadataHash; // anchors off-chain plaintext meaning / legal text
        bool active;
        bool exists;
    }

    // jurisdictionId => roleId => definition
    mapping(uint256 => mapping(uint256 => RoleDef)) private _roles;
    // jurisdictionId => set of defined roleIds
    mapping(uint256 => EnumerableSet.UintSet) private _roleIds;
    // jurisdictionId => roleId => capability keys
    mapping(uint256 => mapping(uint256 => EnumerableSet.Bytes32Set)) private _caps;
    // jurisdictionId => governor authorised to edit that jurisdiction's roles
    mapping(uint256 => address) public jurisdictionGovernor;
    // jurisdictionId => human-facing display name (e.g. "Real Democracy", "Chicago").
    // Governable per-jurisdiction metadata; consumed on-chain by VoteToken.tokenURI
    // so the NFT badge can show a name instead of a bare id. Empty = unnamed.
    mapping(uint256 => string) private _jurisdictionName;

    event RoleDefined(uint256 indexed jurisdictionId, uint256 indexed roleId, string key, string name, bytes32 metadataHash);
    event RoleMetadataUpdated(uint256 indexed jurisdictionId, uint256 indexed roleId, bytes32 metadataHash);
    event RoleActiveUpdated(uint256 indexed jurisdictionId, uint256 indexed roleId, bool active);
    // `label` is the plaintext capability name (convention: capability == keccak256(label)).
    event CapabilityAdded(uint256 indexed jurisdictionId, uint256 indexed roleId, bytes32 indexed capability, string label);
    event CapabilityRemoved(uint256 indexed jurisdictionId, uint256 indexed roleId, bytes32 indexed capability);
    event JurisdictionGovernorUpdated(uint256 indexed jurisdictionId, address governor);
    event JurisdictionNameUpdated(uint256 indexed jurisdictionId, string name);

    error RoleIdZero();
    error JurisdictionZero();
    error UnknownRole(uint256 jurisdictionId, uint256 roleId);
    error NotAuthorized(uint256 jurisdictionId, address caller);

    constructor(address admin) {
        address initial = admin == address(0) ? msg.sender : admin;
        _grantRole(DEFAULT_ADMIN_ROLE, initial);
        _grantRole(CATALOG_ADMIN_ROLE, initial);
    }

    modifier canManage(uint256 jurisdictionId) {
        if (
            msg.sender != jurisdictionGovernor[jurisdictionId]
            && !hasRole(CATALOG_ADMIN_ROLE, msg.sender)
        ) {
            revert NotAuthorized(jurisdictionId, msg.sender);
        }
        _;
    }

    function setJurisdictionGovernor(uint256 jurisdictionId, address governor)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        jurisdictionGovernor[jurisdictionId] = governor;
        emit JurisdictionGovernorUpdated(jurisdictionId, governor);
    }

    /// @notice Set a jurisdiction's human-facing display name. Same per-jurisdiction
    ///         authority as roles (governor or catalog admin). Consumed by
    ///         VoteToken.tokenURI; when unset the badge falls back to "Jurisdiction <id>".
    function setJurisdictionName(uint256 jurisdictionId, string calldata name)
        external
        canManage(jurisdictionId)
    {
        if (jurisdictionId == 0) revert JurisdictionZero();
        _jurisdictionName[jurisdictionId] = name;
        emit JurisdictionNameUpdated(jurisdictionId, name);
    }

    /// @notice Define or update a role in a jurisdiction. New roles default active.
    ///         `metadataHash` anchors the off-chain plaintext role meaning/legal text.
    function defineRole(
        uint256 jurisdictionId,
        uint256 roleId,
        string calldata key,
        string calldata name,
        bytes32 metadataHash
    )
        external
        canManage(jurisdictionId)
    {
        if (jurisdictionId == 0) revert JurisdictionZero();
        if (roleId == 0) revert RoleIdZero();
        RoleDef storage def = _roles[jurisdictionId][roleId];
        def.key = key;
        def.name = name;
        def.metadataHash = metadataHash;
        if (!def.exists) {
            def.exists = true;
            def.active = true;
            _roleIds[jurisdictionId].add(roleId);
        }
        emit RoleDefined(jurisdictionId, roleId, key, name, metadataHash);
    }

    function setRoleMetadata(uint256 jurisdictionId, uint256 roleId, bytes32 metadataHash)
        external
        canManage(jurisdictionId)
    {
        RoleDef storage def = _roles[jurisdictionId][roleId];
        if (!def.exists) revert UnknownRole(jurisdictionId, roleId);
        def.metadataHash = metadataHash;
        emit RoleMetadataUpdated(jurisdictionId, roleId, metadataHash);
    }

    function setRoleActive(uint256 jurisdictionId, uint256 roleId, bool active)
        external
        canManage(jurisdictionId)
    {
        RoleDef storage def = _roles[jurisdictionId][roleId];
        if (!def.exists) revert UnknownRole(jurisdictionId, roleId);
        def.active = active;
        emit RoleActiveUpdated(jurisdictionId, roleId, active);
    }

    function addCapability(uint256 jurisdictionId, uint256 roleId, bytes32 capability, string calldata label)
        external
        canManage(jurisdictionId)
    {
        if (!_roles[jurisdictionId][roleId].exists) revert UnknownRole(jurisdictionId, roleId);
        if (_caps[jurisdictionId][roleId].add(capability)) {
            emit CapabilityAdded(jurisdictionId, roleId, capability, label);
        }
    }

    function removeCapability(uint256 jurisdictionId, uint256 roleId, bytes32 capability)
        external
        canManage(jurisdictionId)
    {
        if (_caps[jurisdictionId][roleId].remove(capability)) {
            emit CapabilityRemoved(jurisdictionId, roleId, capability);
        }
    }

    // --- views -------------------------------------------------------------

    function roleExists(uint256 jurisdictionId, uint256 roleId) external view returns (bool) {
        return _roles[jurisdictionId][roleId].exists;
    }

    function isActiveRole(uint256 jurisdictionId, uint256 roleId) external view returns (bool) {
        RoleDef storage def = _roles[jurisdictionId][roleId];
        return def.exists && def.active;
    }

    function roleKey(uint256 jurisdictionId, uint256 roleId) external view returns (string memory) {
        return _roles[jurisdictionId][roleId].key;
    }

    function jurisdictionName(uint256 jurisdictionId) external view returns (string memory) {
        return _jurisdictionName[jurisdictionId];
    }

    function getRole(uint256 jurisdictionId, uint256 roleId)
        external
        view
        returns (string memory key, string memory name, bytes32 metadataHash, bool active, bool exists)
    {
        RoleDef storage def = _roles[jurisdictionId][roleId];
        return (def.key, def.name, def.metadataHash, def.active, def.exists);
    }

    function roleIds(uint256 jurisdictionId) external view returns (uint256[] memory) {
        return _roleIds[jurisdictionId].values();
    }

    function roleHasCapability(uint256 jurisdictionId, uint256 roleId, bytes32 capability)
        external
        view
        returns (bool)
    {
        return _caps[jurisdictionId][roleId].contains(capability);
    }

    function capabilitiesOf(uint256 jurisdictionId, uint256 roleId)
        external
        view
        returns (bytes32[] memory)
    {
        return _caps[jurisdictionId][roleId].values();
    }
}
