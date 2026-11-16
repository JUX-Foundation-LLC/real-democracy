// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./Goldilocks.sol";
import "./IHasher.sol";

/**
 * @title Transcript
 * @notice Byte-exact Solidity port of winter-crypto-0.13.1 `DefaultRandomCoin<Blake3_256<f64>>`
 *         — the Fiat-Shamir public coin that is the SPINE of the FRI verifier. Every challenge the
 *         verifier draws (γ, constraint coeffs, OOD point z, DEEP coeffs, FRI α's, query positions,
 *         the grinding check) comes from this coin; a single-bit divergence from the prover's coin
 *         either lets a malicious prover grind a forgery or rejects honest proofs. So this is
 *         reproduced EXACTLY (`winter-crypto-0.13.1/src/random/default.rs`), through the pluggable
 *         {IHasher} (Blake3 in production):
 *
 *           state            = (seed: Digest, counter: u64)
 *           new(elems)       : seed = H.hash_elements(elems);            counter = 0
 *           reseed(data)     : seed = H.merge(seed, data);               counter = 0
 *           next()           : counter += 1; return H.merge_with_int(seed, counter)
 *           merge_with_int   = H( seed[32] ‖ value.to_le_bytes()[8] )    (40-byte preimage)
 *           draw<base>()     : loop next(); take bytes[0..8] as u64-LE; accept iff < p
 *           draw<quad>()     : loop next(); bytes[0..8],[8..16] as two u64-LE; accept iff both < p
 *           draw_integers    : seed = merge_with_int(seed, nonce); counter = 0; then per value
 *                              next(); (u64-LE(bytes[0..8]) & (domain-1))   — NO dedup here
 *           check_leading_zeros(v): trailing_zeros( u64-LE( merge_with_int(seed, v)[0..8] ) )
 *
 *         (Note the winter-crypto quirks reproduced verbatim: `check_leading_zeros` actually counts
 *         TRAILING zeros of the LE-interpreted first 8 bytes, and `draw_integers` returns raw,
 *         possibly-duplicate values — the verifier dedups afterwards.)
 */
library Transcript {
    uint256 internal constant P = 0xFFFFFFFF00000001;
    uint256 private constant DRAW_TRIES = 1000; // winter-crypto's retry cap

    struct State {
        bytes32 seed;
        uint64 counter;
    }

    /// `RandomCoin::new(seed)` — seed = H.hash_elements(seed_elements).
    function init(IHasher h, uint64[] memory seedElements) internal view returns (State memory s) {
        s.seed = h.hashElements(seedElements);
        s.counter = 0;
    }

    /// `reseed(data)` — seed = H.merge(seed, data); counter = 0.
    function reseed(IHasher h, State memory s, bytes32 data) internal view {
        s.seed = h.merge(s.seed, data);
        s.counter = 0;
    }

    /// `draw::<BaseField>()` — next pseudo-random canonical base element.
    function drawBaseElement(IHasher h, State memory s) internal view returns (uint64) {
        for (uint256 i = 0; i < DRAW_TRIES; i++) {
            bytes32 d = _next(h, s);
            uint64 v = _u64LE(d, 0);
            if (uint256(v) < P) return v;
        }
        revert("Transcript: draw base exhausted");
    }

    /// `draw::<QuadExtension>()` — next pseudo-random GF(p^2) element (two canonical base limbs).
    function drawElement(IHasher h, State memory s) internal view returns (Goldilocks.Fp2 memory) {
        for (uint256 i = 0; i < DRAW_TRIES; i++) {
            bytes32 d = _next(h, s);
            uint64 a0 = _u64LE(d, 0);
            uint64 a1 = _u64LE(d, 8);
            if (uint256(a0) < P && uint256(a1) < P) return Goldilocks.Fp2(a0, a1);
        }
        revert("Transcript: draw quad exhausted");
    }

    /// `draw::<E>()` for the configured extension (quadratic here) — convenience alias.
    function drawElements(IHasher h, State memory s, uint256 n)
        internal
        view
        returns (Goldilocks.Fp2[] memory out)
    {
        out = new Goldilocks.Fp2[](n);
        for (uint256 i = 0; i < n; i++) out[i] = drawElement(h, s);
    }

    /// `draw_integers(num, domain_size, nonce)` — query positions (raw, may contain duplicates;
    /// the caller sorts + dedups, exactly as the winter verifier does).
    function drawIntegers(
        IHasher h,
        State memory s,
        uint256 num,
        uint256 domainSize,
        uint64 nonce
    ) internal view returns (uint64[] memory out) {
        require(domainSize != 0 && (domainSize & (domainSize - 1)) == 0, "Transcript: domain !pow2");
        require(num < domainSize, "Transcript: num >= domain");
        s.seed = _mergeWithInt(h, s.seed, nonce); // reseed with nonce
        s.counter = 0;
        uint64 mask = uint64(domainSize - 1);
        out = new uint64[](num);
        for (uint256 i = 0; i < num; i++) {
            out[i] = _u64LE(_next(h, s), 0) & mask;
        }
    }

    /// `check_leading_zeros(value)` — does NOT mutate the coin. Returns trailing_zeros of the
    /// u64-LE of the first 8 bytes of merge_with_int(seed, value).
    function checkLeadingZeros(IHasher h, State memory s, uint64 value)
        internal
        view
        returns (uint32)
    {
        bytes32 ns = _mergeWithInt(h, s.seed, value);
        return _trailingZeros(_u64LE(ns, 0));
    }

    // ---- internals ----

    function _next(IHasher h, State memory s) private view returns (bytes32) {
        s.counter += 1;
        return _mergeWithInt(h, s.seed, s.counter);
    }

    /// `Blake3_256::merge_with_int` preimage: seed (32 bytes) ‖ value.to_le_bytes() (8 bytes).
    function _mergeWithInt(IHasher h, bytes32 seed, uint64 value) private view returns (bytes32) {
        bytes memory pre = new bytes(40);
        assembly {
            mstore(add(pre, 32), seed)
        }
        for (uint256 i = 0; i < 8; i++) {
            pre[32 + i] = bytes1(uint8(value >> (8 * i))); // little-endian
        }
        return h.hashBytes(pre);
    }

    /// u64 from 8 little-endian bytes of a digest starting at `off`.
    function _u64LE(bytes32 d, uint256 off) private pure returns (uint64 v) {
        for (uint256 i = 0; i < 8; i++) {
            v |= uint64(uint8(d[off + i])) << (8 * uint64(i));
        }
    }

    /// u64::trailing_zeros (Rust semantics: trailing_zeros(0) == 64).
    function _trailingZeros(uint64 x) private pure returns (uint32 c) {
        if (x == 0) return 64;
        while (x & 1 == 0) {
            c++;
            x >>= 1;
        }
    }
}
