// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../governance/zk/RpoConstraints.sol";
import "../governance/zk/Goldilocks.sol";

/// Test harness for {RpoConstraints}: takes/returns the 12 GF(p^2) state elements as flat
/// `uint64[24]` (a0,a1 interleaved) so the JS tests can pass the Rust-emitted vectors directly.
contract RpoConstraintsHarness {
    function _toFp2(uint64[24] memory f) internal pure returns (Goldilocks.Fp2[12] memory s) {
        for (uint256 i = 0; i < 12; i++) s[i] = Goldilocks.Fp2(f[2 * i], f[2 * i + 1]);
    }

    function _toFlat(Goldilocks.Fp2[12] memory s) internal pure returns (uint64[24] memory f) {
        for (uint256 i = 0; i < 12; i++) {
            f[2 * i] = s[i].a0;
            f[2 * i + 1] = s[i].a1;
        }
    }

    function applyMds(uint64[24] calldata state) external pure returns (uint64[24] memory) {
        return _toFlat(RpoConstraints.applyMds(_toFp2(state)));
    }

    function pow7(uint64[2] calldata x) external pure returns (uint64[2] memory r) {
        Goldilocks.Fp2 memory y = RpoConstraints.pow7(Goldilocks.Fp2(x[0], x[1]));
        r[0] = y.a0;
        r[1] = y.a1;
    }

    function enforceRound(
        uint64[24] calldata result,
        uint64[24] calldata current,
        uint64[24] calldata next,
        uint64[24] calldata ark1,
        uint64[24] calldata ark2,
        uint64[2] calldata flag
    ) external pure returns (uint64[24] memory) {
        return _toFlat(
            RpoConstraints.enforceRound(
                _toFp2(result),
                _toFp2(current),
                _toFp2(next),
                _toFp2(ark1),
                _toFp2(ark2),
                Goldilocks.Fp2(flag[0], flag[1])
            )
        );
    }
}
