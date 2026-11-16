// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title Blake3LookupMock
 * @notice A Blake3 "precompile" backed by a precomputed table of (keccak256(preimage) → genuine
 *         Blake3 digest) pairs, captured from winterfell's REAL `Blake3_256` by the Rust reference
 *         (`transcript_ref.rs`). It lets the Solidity {Transcript} run with TRUE Blake3 outputs on
 *         Hardhat (which has no Blake3 opcode). A preimage the table doesn't contain reverts — so
 *         if the Solidity transcript computes a WRONG preimage (algorithm bug), the test fails
 *         loudly rather than silently passing on a fake digest.
 */
contract Blake3LookupMock {
    mapping(bytes32 => bytes32) private digestOf; // keccak256(preimage) => blake3 digest
    mapping(bytes32 => bool) private known;

    constructor(bytes32[] memory preimageKeys, bytes32[] memory digests) {
        require(preimageKeys.length == digests.length, "Blake3LookupMock: length");
        for (uint256 i = 0; i < preimageKeys.length; i++) {
            digestOf[preimageKeys[i]] = digests[i];
            known[preimageKeys[i]] = true;
        }
    }

    fallback(bytes calldata input) external returns (bytes memory) {
        bytes32 k = keccak256(input);
        require(known[k], "Blake3LookupMock: unknown preimage (transcript computed a wrong preimage)");
        return abi.encodePacked(digestOf[k]);
    }
}
