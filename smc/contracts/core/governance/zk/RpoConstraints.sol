// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./Goldilocks.sol";

/**
 * @title RpoConstraints
 * @notice The Rescue-Prime-Optimized (RPO) round constraint over `GF(p^2)` — the cryptographic core
 *         of vote_stark's transition system (the bulk of the 34 main constraints are RPO rounds).
 *         Ported BYTE-EXACT from `vote/zk/vote_stark/src/rpo.rs` (`apply_mds`, `pow7`,
 *         `enforce_round`), validated against the circuit's own code (`rpo_round_ref.rs`).
 *
 *         The native round is `next = invsbox(MDS·sbox(MDS·cur + ARK1) + ARK2)`. The inverse S-box
 *         is degree `(p-1)/7` — unusable in an AIR — so the S-box is applied to BOTH sides, giving
 *         the degree-7 per-element constraint
 *
 *             next_i^7 - ARK2_i - ( MDS · (MDS·cur + ARK1)^7 )_i  ==  0
 *
 *         accumulated into `result[0..12]`, gated by `flag` (a periodic selector). `current`/`next`
 *         are the OOD trace frame's RPO state columns; `ark1`/`ark2`/`flag` are periodic-column
 *         values at the OOD point. The MDS matrix is 12×12 LEFT-CIRCULANT, defined by one row.
 */
library RpoConstraints {
    uint256 internal constant STATE_WIDTH = 12;

    /// The first row of the circulant RPO MDS matrix (rpo.rs `MDS_ROW0`).
    function _mdsRow0() private pure returns (uint64[12] memory) {
        return [uint64(7), 23, 8, 26, 13, 10, 9, 7, 6, 22, 21, 8];
    }

    /// `apply_mds`: `out[i] = Σ_j MDS_ROW0[(j + W - i) mod W] · state[j]` (left-circulant).
    function applyMds(Goldilocks.Fp2[12] memory state)
        internal
        pure
        returns (Goldilocks.Fp2[12] memory out)
    {
        uint64[12] memory m = _mdsRow0();
        for (uint256 i = 0; i < STATE_WIDTH; i++) {
            Goldilocks.Fp2 memory acc = Goldilocks.Fp2(0, 0);
            for (uint256 j = 0; j < STATE_WIDTH; j++) {
                uint64 c = m[(j + STATE_WIDTH - i) % STATE_WIDTH];
                acc = Goldilocks.extAdd(acc, Goldilocks.extMulBase(state[j], c));
            }
            out[i] = acc;
        }
    }

    /// The degree-7 RPO S-box `x^7` over GF(p^2): `x^4 · x^2 · x`.
    function pow7(Goldilocks.Fp2 memory x) internal pure returns (Goldilocks.Fp2 memory) {
        Goldilocks.Fp2 memory x2 = Goldilocks.extSquare(x);
        Goldilocks.Fp2 memory x4 = Goldilocks.extSquare(x2);
        return Goldilocks.extMul(Goldilocks.extMul(x4, x2), x);
    }

    /// Enforce one RPO round, ACCUMULATING into `result` (gated by `flag`); mirrors
    /// `rpo.rs::enforce_round`. Returns the updated `result`.
    function enforceRound(
        Goldilocks.Fp2[12] memory result,
        Goldilocks.Fp2[12] memory current,
        Goldilocks.Fp2[12] memory next,
        Goldilocks.Fp2[12] memory ark1,
        Goldilocks.Fp2[12] memory ark2,
        Goldilocks.Fp2 memory flag
    ) internal pure returns (Goldilocks.Fp2[12] memory) {
        // a = MDS·cur
        Goldilocks.Fp2[12] memory a = applyMds(current);

        // c = sbox(MDS·cur + ARK1)
        Goldilocks.Fp2[12] memory c;
        for (uint256 i = 0; i < STATE_WIDTH; i++) {
            c[i] = pow7(Goldilocks.extAdd(a[i], ark1[i]));
        }

        // d = MDS·c
        Goldilocks.Fp2[12] memory d = applyMds(c);

        // result[i] += flag · ( next_i^7 - ARK2_i - d_i )
        for (uint256 i = 0; i < STATE_WIDTH; i++) {
            Goldilocks.Fp2 memory lhs =
                Goldilocks.extSub(Goldilocks.extSub(pow7(next[i]), ark2[i]), d[i]);
            result[i] = Goldilocks.extAdd(result[i], Goldilocks.extMul(flag, lhs));
        }
        return result;
    }
}
