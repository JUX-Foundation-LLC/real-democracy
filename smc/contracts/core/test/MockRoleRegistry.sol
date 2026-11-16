// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// Records the last grant/revoke the RoleBallotBox published, for assertions.
contract MockRoleRegistry {
    uint256 public lastJurisdiction;
    bytes32 public lastVoterId;
    uint256 public lastRoleId;
    bool public lastWasGrant;
    uint256 public grantCount;
    uint256 public revokeCount;

    function grantRoles(uint256 jurisdictionId, bytes32 voterId, uint256[] calldata roleIds) external {
        lastJurisdiction = jurisdictionId;
        lastVoterId = voterId;
        lastRoleId = roleIds.length > 0 ? roleIds[0] : 0;
        lastWasGrant = true;
        grantCount += 1;
    }

    function revokeRoles(uint256 jurisdictionId, bytes32 voterId, uint256[] calldata roleIds) external {
        lastJurisdiction = jurisdictionId;
        lastVoterId = voterId;
        lastRoleId = roleIds.length > 0 ? roleIds[0] : 0;
        lastWasGrant = false;
        revokeCount += 1;
    }
}
