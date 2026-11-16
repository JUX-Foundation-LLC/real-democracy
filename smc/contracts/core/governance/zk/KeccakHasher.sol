// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./IHasher.sol";

/**
 * @title KeccakHasher
 * @notice A keccak-256 `IHasher` for the EVM-native GAS BASELINE and STRUCTURAL tests.
 *         keccak has an EVM opcode, so this measures the verifier's "everything except the
 *         Blake3 cost" and provides the ~2M-gas reference point the spec (§4) cites — but it
 *         is NOT byte-compatible with the Blake3-committed prover, so it will NOT accept real
 *         vote_stark proofs. Production uses {Blake3PrecompileHasher}.
 *
 *         (If the team ever chooses the keccak-commitment prover variant — VERIFIER_NOTES §1
 *         option 2, for a pure-Solidity host with no precompile — re-pinning the prover to
 *         keccak makes THIS adapter the production one. Same input layout either way.)
 */
contract KeccakHasher is IHasher {
    function hasherId() external pure override returns (bytes32) {
        return keccak256("keccak-baseline");
    }

    function hashBytes(bytes calldata data) external pure override returns (bytes32) {
        return keccak256(data);
    }

    function merge(bytes32 a, bytes32 b) external pure override returns (bytes32) {
        return keccak256(bytes.concat(a, b));
    }

    function hashElements(uint64[] calldata elements) external pure override returns (bytes32) {
        bytes memory pre = new bytes(elements.length * 8);
        for (uint256 i = 0; i < elements.length; i++) {
            uint64 v = elements[i];
            uint256 off = i * 8;
            for (uint256 j = 0; j < 8; j++) {
                pre[off + j] = bytes1(uint8(v >> (8 * j))); // little-endian, matches Blake3 adapter
            }
        }
        return keccak256(pre);
    }
}
