// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title MockBlake3Precompile
 * @notice Stand-in for the Besu native-Blake3 precompile, for testing {Blake3PrecompileHasher}'s
 *         PLUMBING (element/digest serialization + staticcall + 32-byte return), NOT Blake3
 *         correctness. It returns `keccak256(preimage)` — so a Blake3PrecompileHasher pointed at
 *         this mock produces the SAME digest as {KeccakHasher} for identical inputs, which lets
 *         the tests prove the two adapters share one canonical preimage layout. The real
 *         precompile returns a true Blake3-256 digest (see VERIFIER_IMPL_NOTES).
 */
contract MockBlake3Precompile {
    /// Echoes the precompile ABI: input = raw preimage (calldata), output = 32-byte digest.
    fallback(bytes calldata input) external returns (bytes memory) {
        return abi.encodePacked(keccak256(input));
    }
}
