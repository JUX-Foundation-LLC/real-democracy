// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// ICapabilityGate stub that allows exactly ONE capability key — so a test can prove a box gates on
/// the specific permit it should (e.g. PERMIT_ROLE_VOTING / PERMIT_TAG_VOTING / PERMIT_INITIATIVE_VOTING,
/// not PERMIT_RULE_VOTING). View-only (the gate is staticcalled from the box's view assertion).
contract MockPermitGate {
    bytes32 public immutable allowed;

    constructor(bytes32 _allowed) {
        allowed = _allowed;
    }

    function hasCapability(uint256, bytes32, bytes32 capability) external view returns (bool) {
        return capability == allowed;
    }
}
