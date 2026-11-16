// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../governance/zk/Goldilocks.sol";

/// Test-only harness exposing the {Goldilocks} library externally so its base-field and
/// GF(p^2) arithmetic can be checked against winter-math reference values (the authority).
contract GoldilocksHarness {
    function add(uint64 a, uint64 b) external pure returns (uint64) {
        return Goldilocks.add(a, b);
    }

    function sub(uint64 a, uint64 b) external pure returns (uint64) {
        return Goldilocks.sub(a, b);
    }

    function mul(uint64 a, uint64 b) external pure returns (uint64) {
        return Goldilocks.mul(a, b);
    }

    function pow(uint64 a, uint256 e) external pure returns (uint64) {
        return Goldilocks.pow(a, e);
    }

    function inv(uint64 a) external pure returns (uint64) {
        return Goldilocks.inv(a);
    }

    function exp7(uint64 a) external pure returns (uint64) {
        return Goldilocks.exp7(a);
    }

    function isValid(uint256 v) external pure returns (bool) {
        return Goldilocks.isValid(v);
    }

    function extMul(uint64 a0, uint64 a1, uint64 b0, uint64 b1)
        external
        pure
        returns (uint64, uint64)
    {
        Goldilocks.Fp2 memory r = Goldilocks.extMul(Goldilocks.Fp2(a0, a1), Goldilocks.Fp2(b0, b1));
        return (r.a0, r.a1);
    }

    function extSquare(uint64 a0, uint64 a1) external pure returns (uint64, uint64) {
        Goldilocks.Fp2 memory r = Goldilocks.extSquare(Goldilocks.Fp2(a0, a1));
        return (r.a0, r.a1);
    }

    function extInv(uint64 a0, uint64 a1) external pure returns (uint64, uint64) {
        Goldilocks.Fp2 memory r = Goldilocks.extInv(Goldilocks.Fp2(a0, a1));
        return (r.a0, r.a1);
    }

    function extAdd(uint64 a0, uint64 a1, uint64 b0, uint64 b1)
        external
        pure
        returns (uint64, uint64)
    {
        Goldilocks.Fp2 memory r = Goldilocks.extAdd(Goldilocks.Fp2(a0, a1), Goldilocks.Fp2(b0, b1));
        return (r.a0, r.a1);
    }

    function frobenius(uint64 a0, uint64 a1) external pure returns (uint64, uint64) {
        Goldilocks.Fp2 memory r = Goldilocks.frobenius(Goldilocks.Fp2(a0, a1));
        return (r.a0, r.a1);
    }

    /// round-trip check: x * x^-1 == 1 in GF(p^2)
    function extMulInvIsOne(uint64 a0, uint64 a1) external pure returns (bool) {
        Goldilocks.Fp2 memory x = Goldilocks.Fp2(a0, a1);
        Goldilocks.Fp2 memory r = Goldilocks.extMul(x, Goldilocks.extInv(x));
        return r.a0 == 1 && r.a1 == 0;
    }
}
