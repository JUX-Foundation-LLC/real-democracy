// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// Minimal IRoleCatalogView stub: configurable isActiveRole for RoleBallotBox tests.
contract MockRoleCatalog {
    mapping(uint256 => mapping(uint256 => bool)) private _active;

    function setActiveRole(uint256 jurisdictionId, uint256 roleId, bool active) external {
        _active[jurisdictionId][roleId] = active;
    }

    function isActiveRole(uint256 jurisdictionId, uint256 roleId) external view returns (bool) {
        return _active[jurisdictionId][roleId];
    }
}
