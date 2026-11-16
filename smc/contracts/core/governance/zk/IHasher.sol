// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IHasher
 * @notice The STARK's commitment/transcript hash, behind a pluggable interface so the
 *         LOCKED Blake3-256 choice (VERIFIER_NOTES §1) can be served by a cheap **Besu
 *         native-Blake3 precompile** in production and a Solidity/mock impl in the interim,
 *         with NO change to the verifier. Blake3 has no EVM opcode, so this indirection is
 *         the host swap point (spec §4: "Solidity-FRI → precompile is an additive swap").
 *
 *         Three operations cover everything Winterfell's verifier needs:
 *           - `hashElements` : `Blake3_256::hash_elements` — hash a sequence of Goldilocks
 *             field elements (each serialized canonically little-endian, 8 bytes). Used for
 *             leaf hashing and the public-coin element draws.
 *           - `merge`        : `Blake3_256::merge([a,b])` — two-to-one over a pair of 32-byte
 *             digests (Merkle internal nodes, transcript reseed of a single digest pair).
 *           - `hashBytes`    : raw Blake3 of an arbitrary byte string (transcript seeding).
 *
 *         Digest = 32 bytes (Winterfell `ByteDigest<32>`). Implementations MUST be
 *         byte-exact with `winter-crypto 0.13.1`'s `Blake3_256` for real proofs to verify;
 *         the keccak adapter is a structural/gas baseline only (NOT proof-accepting).
 */
interface IHasher {
    function hashElements(uint64[] calldata elements) external view returns (bytes32);

    function merge(bytes32 a, bytes32 b) external view returns (bytes32);

    function hashBytes(bytes calldata data) external view returns (bytes32);

    /// Identifies the implementation for on-chain assertions / off-chain routing,
    /// e.g. keccak256("blake3-precompile") or keccak256("keccak-baseline").
    function hasherId() external pure returns (bytes32);
}
