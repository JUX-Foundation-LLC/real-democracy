// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./Goldilocks.sol";

/**
 * @title VoteStarkPeriodic
 * @notice Evaluates the vote_stark AIR's 31 periodic columns at the OOD point z — byte-exact with
 *         winter-verifier's `evaluate_constraints` (`eval(periodic_poly_i, z^(trace_len/period_i))`,
 *         see evaluator.rs). Two regimes (vote/zk/vote_stark/src/air.rs `get_periodic_column_*`):
 *
 *           - cols 0..25  period-8 (hash_flag + ARK1[12] + ARK2[12]); DENSE → baked 8-coeff polys,
 *             Horner-evaluated at y8 = z^32 (num_cycles = 256/8). Coeffs are dumped from the AIR's
 *             own `get_periodic_column_polys()` (periodic_ref.rs), low→high degree, 8 LE bytes each.
 *           - cols 25..31 period-256 selectors (f_bind0, f_null, rc_active, f_break, f_perm,
 *             f_prevbind); SPARSE (≤16 nonzero rows each) → evaluated via the barycentric-over-
 *             subgroup formula on the nonzero rows only, at y256 = z (num_cycles = 1):
 *
 *               P(y) = ((y^N − 1)/N) · Σ_{i : v_i=1} ω^i / (y − ω^i),   N = 256
 *
 *         `ω` is winterfell's exact 256-th root of unity, and the barycentric formula was asserted
 *         EQUAL to winterfell's `eval` in Rust (periodic_ref.rs) before this port. (For a
 *         transcript-drawn OOD z, y = z^num_cycles is never a subgroup root, so `y − ω^i ≠ 0`; that
 *         coincidence is the one unreachable input where barycentric would differ from coeff-Horner.)
 */
library VoteStarkPeriodic {
    uint256 internal constant NUM_PERIODIC = 31;
    uint256 internal constant PERIOD8_COLS = 25; // hash_flag + 12×ARK1 + 12×ARK2
    uint64 internal constant OMEGA256 = 4404853092538523347; // BaseElement::get_root_of_unity(8)

    /// 25 period-8 polynomials × 8 base coeffs (low→high degree) × 8 LE bytes, column-major.
    /// Dumped from `air.get_periodic_column_polys()` by `examples/periodic_ref.rs`.
    bytes internal constant COEFFS8 =
        hex"010000e0ffffff1f0100e0fffeffffff01000000ffdfffff21000000dfffffff01000020ffffffdf00002000000000000000000000200000e0ffffff1f000000156b65d95c0be59a7a0bbc323c0ab1bbbb96fb21c854b28949cc465b15ea26ec1fa17b1c8cc99021f1371dab90acc18e8ff03b2400a9ee03528d09eb8ceaa8cf3e2bcea24ee1043d6de07d6a6e9822c845961a6a266b82f41467f7c72794fce4c2a95ed4e611377de09710f2eea5177a4ea448cb45458513a7bf458eed570a713822320580133cb1756b86bb5770d73ce7f0f158a8f54193660da18a238b16d05c0421a9ac1af8850fb5df1acfdc950e56b4f89eb5e7b2f313006233ea8f7c1d669f7b34ed93be0cb4cbfbc65b51e38ce23cd6f26ed3fb02b2ab028a2b482b5b81e5ed8454946707aea1a5c9c504c711cd3c1bea8fd7aab29464626e7836da3d66168d30230b45a2fba66aed9aa8260750cb92661843fbefdc15537d4cb17d96de3d2044085621fa969f90953397c3bde567eec71af58556645cc54530ab5a1a2f85158ce74c513c5db1e26f863757754000cf4058e5346c6f1fe65d7959352caaf1add68d3ed3f74c34077f0f63f710963af5737b6d41c707f8274e4d9dc2c17138b50ec6e439abf7dbd57c40c66f425c4c8c6dc300eef9fc069be345d11a156a847f178b75882f61f326429b6b24019e5f026f8d0ea5981900715f57e569c425e36f341752eef5e9521c655c845f2984a9e43441857d249754e887bc05c7f957f2158360b69086e3b665279eb624271bcc4d1fa72b5aec9a6c656c3bcbc95640f4d903833e9bb52f045ac82ba3a2ff8c72afba705e92449e722310a2f26f13745b9d71019cb84ffdcac80da9107019e1a821eb73a5f7fb8fe91b0a50a1d517432605544a26c3bb095547e7ddc5118e590e41bca0d4d58c6fbe41c9ed94c34eb2903e9ce873052b7ed62113478d998db2d8d7d8af58fd179e1eeeb2333bd3bd5f3733a8ee56b6600a4408eb3fa745b1c0281ffeda5e2669abe746aa49c05a58058e1f7d6d5d731be1df5a07df3d64996cd226e70866d3f1f8bdcb3e01491c0b04e9e9a1754b5a72131b758626656a2a044230a518548014fe3cc69505fec15540de0541a671ac090102f2c9968c022e9fbaafbf319ea396fc13d4905ddbd111ad1ea87297a26ef37b5b108fa1ebc67f97d057a781cb9649519c7ba09a00ff809f4f96d1fb7025917342b0e6f7056080cf8427529a34738c522714287b0a9278c1a1eeb42b2e90aa73ddf16cd2da74693f7fed3e6b06c84efa046b41ed6217198fad940b0b2d22f1603500c3480a4f315469d1c6015721e18a297e94ea018e54c6370047a9a4db5788298daa23fc07fd64cc564c9d034ae81506027651f863ac180af5589f07c52447c83730af4fe67e620aea1458b16cb25d788ca9886ab40a99b252906d01385494fb5e2a52a6ef485be031a0608d44e6a8595590f75fb5baa4a5d5812f5b0a27ea1ba3f833af88b4809530527622c6b20ce250c93b060cf98ec9a12d75e17c0f855ee9c1a7ee14aae75a8526cecd42d7a07d17780bf9c339a6480666ab2e10fb9602adb83c075d7ec51934ea27376dbc4ec15daa0a12f6be88bf2d9c2843a1ba198aa3646d5a9795c19d85990f2bedb8cf42b117f54665c66bab528d5f6c9b731e69ef7641f939af6f9e183453d9dfce5d7bb027b3cbefdf4f45caf02c8261173d4b7e9d51de0c4da8672ffe07a5a63d19acb7eacc2c390327b975652544fe2deec06ab413e5ccbb236c8bb01195d76d2b33e0be01b16fd15a5301c5679fb385da45eacbb440b472c6c31885227d9101fbf434f30b51f04be55618ee143e9fe302ad1d475bc464d3a2fc5371d725b0fbb127789e54f137942dd319ac812ced4298862a9e630e4c29656fb47fc7a19b9b46da187f55e68d2afdf0564c27a6625d399a781c6580df0ca014dce8e18c8a53b3a069689181ac4d1b1a72f89e87aad9851ecae68fd69676607e85b975fcc8fc19c72801578c9c450291e6802a74958f304eb5d76e81cfc7e0cbd9a5cf8af65054a9bf8a45325b9d22365212f8f926f33f54268f3ba2a5f460e6d5d7595b4fea8eaf9920c4930e8373f5bb62c5e86bb31f1c42977a43b624a24d29a210996f644926002ec3c6ebf9eae892d710058f7123c70886b2d6a7e271f6f0861f68c915a304ef0d9abd5c8b6f008f8e75ffc1850d04d19d6139c3cd4d25c52a9c9919096f41a3c385fc1473";

    function evaluate(Goldilocks.Fp2 memory z) internal pure returns (Goldilocks.Fp2[] memory out) {
        out = new Goldilocks.Fp2[](NUM_PERIODIC);
        bytes memory coeffs = COEFFS8;

        // period-8 columns: Horner over baked coeffs at y8 = z^32.
        Goldilocks.Fp2 memory y8 = _pow2k(z, 5);
        for (uint256 c = 0; c < PERIOD8_COLS; c++) {
            out[c] = _horner8(coeffs, c, y8);
        }

        // period-256 selectors: sparse barycentric at y256 = z.
        Goldilocks.Fp2 memory pref =
            Goldilocks.extMulBase(Goldilocks.extSub(_pow2k(z, 8), Goldilocks.Fp2(1, 0)), Goldilocks.inv(256));
        out[25] = _selector(z, pref, _rows1(0)); // f_bind0
        out[26] = _selector(z, pref, _rows2(175, 191)); // f_null
        out[27] = _selector(z, pref, _rowsRange16()); // rc_active (rows 0..15)
        out[28] = _selector(z, pref, _rows3(175, 183, 191)); // f_break
        out[29] = _selector(z, pref, _rows1(184)); // f_perm
        out[30] = _selector(z, pref, _rows1(199)); // f_prevbind
    }

    function _selector(Goldilocks.Fp2 memory y, Goldilocks.Fp2 memory pref, uint16[] memory rows)
        private
        pure
        returns (Goldilocks.Fp2 memory)
    {
        Goldilocks.Fp2 memory acc = Goldilocks.Fp2(0, 0);
        for (uint256 k = 0; k < rows.length; k++) {
            uint64 wi = Goldilocks.pow(OMEGA256, rows[k]); // ω^i
            Goldilocks.Fp2 memory denomInv =
                Goldilocks.extInv(Goldilocks.extSub(y, Goldilocks.Fp2(wi, 0)));
            acc = Goldilocks.extAdd(acc, Goldilocks.extMulBase(denomInv, wi));
        }
        return Goldilocks.extMul(pref, acc);
    }

    function _horner8(bytes memory coeffs, uint256 c, Goldilocks.Fp2 memory y)
        private
        pure
        returns (Goldilocks.Fp2 memory acc)
    {
        acc = Goldilocks.Fp2(0, 0);
        uint256 base = c * 64;
        for (uint256 j = 0; j < 8; j++) {
            uint64 coeff = _u64(coeffs, base + (7 - j) * 8); // high degree first
            acc = Goldilocks.extAdd(Goldilocks.extMul(acc, y), Goldilocks.Fp2(coeff, 0));
        }
    }

    function _u64(bytes memory d, uint256 off) private pure returns (uint64 v) {
        for (uint256 i = 0; i < 8; i++) v |= uint64(uint8(d[off + i])) << (8 * uint64(i));
    }

    function _pow2k(Goldilocks.Fp2 memory x, uint256 k) private pure returns (Goldilocks.Fp2 memory) {
        for (uint256 i = 0; i < k; i++) x = Goldilocks.extSquare(x);
        return x;
    }

    function _rows1(uint16 a) private pure returns (uint16[] memory r) {
        r = new uint16[](1);
        r[0] = a;
    }

    function _rows2(uint16 a, uint16 b) private pure returns (uint16[] memory r) {
        r = new uint16[](2);
        r[0] = a;
        r[1] = b;
    }

    function _rows3(uint16 a, uint16 b, uint16 c) private pure returns (uint16[] memory r) {
        r = new uint16[](3);
        r[0] = a;
        r[1] = b;
        r[2] = c;
    }

    function _rowsRange16() private pure returns (uint16[] memory r) {
        r = new uint16[](16);
        for (uint16 i = 0; i < 16; i++) r[i] = i;
    }
}
