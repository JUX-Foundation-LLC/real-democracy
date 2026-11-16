// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title Goldilocks
 * @notice Arithmetic in the Goldilocks field `p = 2^64 - 2^32 + 1` and its quadratic
 *         extension `GF(p^2)`, matching `winter-math 0.13.1`'s `f64::BaseElement` and
 *         `QuadExtension<BaseElement>` BYTE-FOR-BYTE (this is the field the audited
 *         `vote_stark` circuit + Winterfell prover use; see vote/zk/vote_stark/rpo.rs and
 *         VERIFIER_NOTES §3).
 *
 *         Base-field reduction is free: `p < 2^64 < 2^256`, and any product of two
 *         canonical elements is `< 2^128 < 2^512`, so the EVM's native `mulmod`/`addmod`
 *         (512-bit intermediates) reduce mod `p` exactly. Elements are kept canonical
 *         (`< p`) on the way in and out.
 *
 *         GF(p^2) uses the irreducible `x^2 - x + 2` (so `β^2 = β - 2`), exactly as
 *         winter-math's `impl ExtensibleField<2> for BaseElement`:
 *           mul:  out0 = a0·b0 - 2·a1·b1 ; out1 = (a0+a1)(b0+b1) - a0·b0
 *           sq :  out0 = a0² - 2·a1²      ; out1 = 2·a0·a1 + a1²
 *           frob: (x0 + x1, -x1)
 *         Inversion via the norm: x · frob(x) = (x0²+x0·x1+2·x1², 0) ∈ base.
 */
library Goldilocks {
    /// The Goldilocks prime `2^64 - 2^32 + 1`.
    uint256 internal constant P = 0xFFFFFFFF00000001;

    // --------------------------------------------------------------------- base field
    function add(uint64 a, uint64 b) internal pure returns (uint64) {
        return uint64(addmod(a, b, P));
    }

    // AUDIT V5 (fail-safe): `sub`/`neg` compute `P - b` / `P - a`, which underflow-REVERT
    // (Solidity 0.8 checked math) on a non-canonical `b`/`a` ∈ [p, 2^64). This is fail-safe
    // (revert, never a wrong field value). The implemented layer only feeds canonical elements
    // (public inputs are `isValid`-gated; field ops stay reduced); the FRI core MUST likewise
    // hand only reduced elements to `sub`/`neg` (or pre-reduce) so legitimate proofs never
    // spuriously revert.
    function sub(uint64 a, uint64 b) internal pure returns (uint64) {
        // a - b (mod p); `P - b` is safe because b < P.
        return uint64(addmod(a, P - b, P));
    }

    function mul(uint64 a, uint64 b) internal pure returns (uint64) {
        return uint64(mulmod(a, b, P));
    }

    function dbl(uint64 a) internal pure returns (uint64) {
        return uint64(addmod(a, a, P));
    }

    function neg(uint64 a) internal pure returns (uint64) {
        return a == 0 ? 0 : uint64(P - a);
    }

    function square(uint64 a) internal pure returns (uint64) {
        return uint64(mulmod(a, a, P));
    }

    /// `a^e` by square-and-multiply.
    function pow(uint64 a, uint256 e) internal pure returns (uint64 r) {
        r = 1;
        uint256 base = a;
        while (e != 0) {
            if (e & 1 == 1) r = uint64(mulmod(r, base, P));
            base = mulmod(base, base, P);
            e >>= 1;
        }
    }

    /// Multiplicative inverse via Fermat: `a^(p-2)`. Reverts on 0.
    function inv(uint64 a) internal pure returns (uint64) {
        require(a != 0, "Goldilocks: inverse of zero");
        return pow(a, P - 2);
    }

    /// True iff `v` is a canonical field element (`< p`). Public inputs / proof elements
    /// must satisfy this (a malicious non-canonical encoding is rejected).
    function isValid(uint256 v) internal pure returns (bool) {
        return v < P;
    }

    function exp7(uint64 a) internal pure returns (uint64) {
        // x^7 = x^4 · x^2 · x  (the RPO S-box; degree 7)
        uint256 x2 = mulmod(a, a, P);
        uint256 x4 = mulmod(x2, x2, P);
        return uint64(mulmod(mulmod(x4, x2, P), a, P));
    }

    // ----------------------------------------------------------------- GF(p^2) (Fp2)
    struct Fp2 {
        uint64 a0;
        uint64 a1;
    }

    function fromBase(uint64 x) internal pure returns (Fp2 memory) {
        return Fp2(x, 0);
    }

    function extAdd(Fp2 memory a, Fp2 memory b) internal pure returns (Fp2 memory) {
        return Fp2(add(a.a0, b.a0), add(a.a1, b.a1));
    }

    function extSub(Fp2 memory a, Fp2 memory b) internal pure returns (Fp2 memory) {
        return Fp2(sub(a.a0, b.a0), sub(a.a1, b.a1));
    }

    function extMul(Fp2 memory a, Fp2 memory b) internal pure returns (Fp2 memory) {
        uint64 a0b0 = mul(a.a0, b.a0);
        uint64 a1b1 = mul(a.a1, b.a1);
        uint64 out0 = sub(a0b0, dbl(a1b1)); // a0·b0 - 2·a1·b1
        uint64 out1 = sub(mul(add(a.a0, a.a1), add(b.a0, b.a1)), a0b0);
        return Fp2(out0, out1);
    }

    function extSquare(Fp2 memory a) internal pure returns (Fp2 memory) {
        uint64 a1sq = square(a.a1);
        uint64 out0 = sub(square(a.a0), dbl(a1sq));
        uint64 out1 = add(dbl(mul(a.a0, a.a1)), a1sq);
        return Fp2(out0, out1);
    }

    /// Multiply an Fp2 element by a base element.
    function extMulBase(Fp2 memory a, uint64 b) internal pure returns (Fp2 memory) {
        return Fp2(mul(a.a0, b), mul(a.a1, b));
    }

    /// Frobenius `x -> x^p = (x0 + x1, -x1)`.
    function frobenius(Fp2 memory x) internal pure returns (Fp2 memory) {
        return Fp2(add(x.a0, x.a1), neg(x.a1));
    }

    /// Inverse via the norm: `1/x = frob(x) / norm`, `norm = x0² + x0·x1 + 2·x1²`.
    function extInv(Fp2 memory x) internal pure returns (Fp2 memory) {
        uint64 norm = add(add(square(x.a0), mul(x.a0, x.a1)), dbl(square(x.a1)));
        uint64 ninv = inv(norm);
        Fp2 memory f = frobenius(x);
        return Fp2(mul(f.a0, ninv), mul(f.a1, ninv));
    }
}
