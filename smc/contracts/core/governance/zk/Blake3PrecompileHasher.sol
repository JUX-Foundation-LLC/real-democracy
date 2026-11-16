// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./IHasher.sol";

/**
 * @title Blake3PrecompileHasher
 * @notice Production `IHasher`: routes every Blake3-256 call to a **Besu native-Blake3
 *         precompile** at a configurable address (spec §4 — the "clean form"; native-speed,
 *         tiny fixed gas on `vote_besu`). The precompile is the host's; this adapter pins
 *         the canonical input encoding the verifier relies on.
 *
 *         Precompile ABI (the host MUST implement this exactly — see VERIFIER_IMPL_NOTES):
 *           input  = the raw bytes to Blake3-hash (already in Winterfell's serialization)
 *           output = 32-byte Blake3-256 digest
 *         i.e. `digest = staticcall(precompile, preimage)[0..32]`. `hashElements`/`merge`
 *         assemble Winterfell's preimage (canonical LE field-element bytes / digest pair)
 *         then call the precompile, so a future precompile change touches only this file.
 *
 *         NOTE (Phase 1): the element/merge preimage layout below mirrors winter-crypto's
 *         `Blake3_256` and MUST be confirmed byte-for-byte against emitted proof fixtures
 *         before this is trusted (the FRI core that consumes these digests is still being
 *         brought up — see VERIFIER_IMPL_NOTES "remaining work").
 *
 *         AUDIT V2 (deployment trust). The configured address is trusted to compute genuine
 *         Blake3; `hasherId()` is a self-asserted label, not a proof. {selfTest} attests the
 *         precompile against winter-crypto-0.13.1 Blake3 vectors (emitted by
 *         `emit_verifier_fixtures.rs`). The canonical deployment MUST call `selfTest()` and
 *         assert true before trusting this hasher (it is part of the trusted setup).
 */
contract Blake3PrecompileHasher is IHasher {
    /// The Besu native-Blake3 precompile address (configured per chain).
    address public immutable precompile;

    // ---- V2 attestation vectors (winter-crypto 0.13.1 Blake3_256; see emit_verifier_fixtures.rs).
    // Two distinct probes so a precompile that returns a single constant cannot pass.
    bytes internal constant SELFTEST1_INPUT = hex"766f74655f737461726b2f626c616b65332d73656c66746573742f31";
    bytes32 internal constant SELFTEST1_DIGEST =
        0x5bf24c6533eec6d067537146257711832917a5030a68e7eeea39b6728632c2d0;
    bytes internal constant SELFTEST2_INPUT =
        hex"766f74655f737461726b2f626c616b65332d73656c66746573742f32207365636f6e642070726f626520736f2061206d6f636b2063616e6e6f7420706173732077697468206f6e6520636f6e7374616e74";
    bytes32 internal constant SELFTEST2_DIGEST =
        0x6c60b47b43b5caf762ad64d4356baee24d9239ea55fb01b6239a1109793a88ae;

    constructor(address precompileAddress) {
        require(precompileAddress != address(0), "Blake3: precompile required");
        precompile = precompileAddress;
    }

    /// Attest that the configured precompile computes genuine winter-crypto Blake3-256, by
    /// hashing two known inputs and matching the emitted digests (V2). Reverts only if the
    /// precompile call itself fails; otherwise returns whether BOTH probes matched. The
    /// deploy/governance flow MUST require `selfTest() == true` before this hasher is trusted.
    function selfTest() external view returns (bool) {
        return _blake3(SELFTEST1_INPUT) == SELFTEST1_DIGEST
            && _blake3(SELFTEST2_INPUT) == SELFTEST2_DIGEST;
    }

    function hasherId() external pure override returns (bytes32) {
        return keccak256("blake3-precompile");
    }

    function hashBytes(bytes calldata data) external view override returns (bytes32) {
        return _blake3(data);
    }

    function merge(bytes32 a, bytes32 b) external view override returns (bytes32) {
        return _blake3(bytes.concat(a, b));
    }

    function hashElements(uint64[] calldata elements) external view override returns (bytes32) {
        // Winterfell serializes each Goldilocks element as 8 canonical little-endian bytes.
        bytes memory pre = new bytes(elements.length * 8);
        for (uint256 i = 0; i < elements.length; i++) {
            uint64 v = elements[i];
            uint256 off = i * 8;
            for (uint256 j = 0; j < 8; j++) {
                pre[off + j] = bytes1(uint8(v >> (8 * j))); // little-endian
            }
        }
        return _blake3(pre);
    }

    function _blake3(bytes memory preimage) internal view returns (bytes32 out) {
        (bool ok, bytes memory ret) = precompile.staticcall(preimage);
        require(ok && ret.length == 32, "Blake3: precompile call failed");
        out = abi.decode(ret, (bytes32));
    }
}
