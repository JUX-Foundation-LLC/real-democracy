// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// Minimal ICapabilityGate stub for tests: returns a configurable allow/deny for hasCapability.
contract MockCapabilityGate {
    bool public allow;

    function setAllow(bool a) external {
        allow = a;
    }

    function hasCapability(uint256, bytes32, bytes32) external view returns (bool) {
        return allow;
    }
}
