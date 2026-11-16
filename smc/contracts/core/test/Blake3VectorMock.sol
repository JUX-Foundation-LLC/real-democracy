// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title Blake3VectorMock
 * @notice Test stand-in that behaves as a GENUINE Blake3 precompile FOR THE TWO self-test probe
 *         inputs only (returns the winter-crypto digests), and as a non-Blake3 hasher otherwise.
 *         Lets {Blake3PrecompileHasher.selfTest} be exercised on its accept path without a real
 *         Blake3 precompile. The keccak-only {MockBlake3Precompile} exercises the reject path.
 */
contract Blake3VectorMock {
    bytes internal constant V1_INPUT = hex"766f74655f737461726b2f626c616b65332d73656c66746573742f31";
    bytes32 internal constant V1_DIGEST =
        0x5bf24c6533eec6d067537146257711832917a5030a68e7eeea39b6728632c2d0;
    bytes internal constant V2_INPUT =
        hex"766f74655f737461726b2f626c616b65332d73656c66746573742f32207365636f6e642070726f626520736f2061206d6f636b2063616e6e6f7420706173732077697468206f6e6520636f6e7374616e74";
    bytes32 internal constant V2_DIGEST =
        0x6c60b47b43b5caf762ad64d4356baee24d9239ea55fb01b6239a1109793a88ae;

    fallback(bytes calldata input) external returns (bytes memory) {
        bytes32 k = keccak256(input);
        if (k == keccak256(V1_INPUT)) return abi.encodePacked(V1_DIGEST);
        if (k == keccak256(V2_INPUT)) return abi.encodePacked(V2_DIGEST);
        return abi.encodePacked(keccak256(input)); // genuine for the probes only
    }
}
