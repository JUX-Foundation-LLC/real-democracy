//! Rescue-Prime Optimized (RPO256) over the Goldilocks field, re-expressed for use
//! inside a Winterfell AIR.
//!
//! Why re-express instead of just calling `miden-crypto`? An AIR must evaluate the
//! permutation's *round function* symbolically over an arbitrary field-extension
//! element `E` (the constraint-evaluation field). `miden_crypto::Rpo256` only operates
//! on the base field. So we carry the exact RPO constants (lifted verbatim from
//! `miden-crypto` v0.19.8) and provide:
//!   * [`permutation`] — the native permutation, used to fill the execution trace and
//!     compute reference digests (uses the inverse S-box, like miden).
//!   * [`enforce_round`] — the degree-7 algebraic constraint for one RPO round, used
//!     by the AIR (forward S-box only — see the identity in its docs).
//!
//! `tests/rpo_vs_miden.rs` proves this module is byte-identical to
//! `miden_crypto::hash::rpo::Rpo256`. THAT equality is what lets the off-chain
//! ballotbox DB and the on-chain verifier agree byte-for-byte on every commitment,
//! Merkle root, and nullifier.
//!
//! Parameters (locked): field = Goldilocks p = 2^64 − 2^32 + 1; state width 12;
//! rate 8 (elements 4..12); capacity 4 (elements 0..4); digest 4 (elements 4..8);
//! 7 rounds; S-box exponent α = 7.

use winterfell::math::{fields::f64::BaseElement as Felt, FieldElement};

// PARAMETERS
// ================================================================================================

pub const STATE_WIDTH: usize = 12;
pub const NUM_ROUNDS: usize = 7;
pub const RATE_START: usize = 4; // rate occupies state[4..12]
pub const DIGEST_START: usize = 4; // digest read from state[4..8]
pub const DIGEST_SIZE: usize = 4;

/// S-box exponent.
pub const ALPHA: u64 = 7;
/// Inverse S-box exponent: ALPHA^{-1} mod (p-1).
pub const INV_ALPHA: u64 = 10540996611094048183;

/// A Word is the 4-element RPO digest (and a Merkle node / packed input).
pub type Word = [Felt; DIGEST_SIZE];

pub const ZERO_WORD: Word = [Felt::ZERO; DIGEST_SIZE];

/// First row of the RPO MDS matrix. The full 12×12 matrix is a left-circulant of
/// this row: `MDS[i][j] = MDS_ROW0[(j + 12 - i) % 12]` (verified byte-exact against
/// miden-crypto's `MDS` constant by the test suite).
pub const MDS_ROW0: [u64; STATE_WIDTH] = [7, 23, 8, 26, 13, 10, 9, 7, 6, 22, 21, 8];

/// Round constants for the first half of each RPO round (verbatim from miden-crypto).
pub const ARK1: [[u64; STATE_WIDTH]; NUM_ROUNDS] = [
    [
        5789762306288267392,
        6522564764413701783,
        17809893479458208203,
        107145243989736508,
        6388978042437517382,
        15844067734406016715,
        9975000513555218239,
        3344984123768313364,
        9959189626657347191,
        12960773468763563665,
        9602914297752488475,
        16657542370200465908,
    ],
    [
        12987190162843096997,
        653957632802705281,
        4441654670647621225,
        4038207883745915761,
        5613464648874830118,
        13222989726778338773,
        3037761201230264149,
        16683759727265180203,
        8337364536491240715,
        3227397518293416448,
        8110510111539674682,
        2872078294163232137,
    ],
    [
        18072785500942327487,
        6200974112677013481,
        17682092219085884187,
        10599526828986756440,
        975003873302957338,
        8264241093196931281,
        10065763900435475170,
        2181131744534710197,
        6317303992309418647,
        1401440938888741532,
        8884468225181997494,
        13066900325715521532,
    ],
    [
        5674685213610121970,
        5759084860419474071,
        13943282657648897737,
        1352748651966375394,
        17110913224029905221,
        1003883795902368422,
        4141870621881018291,
        8121410972417424656,
        14300518605864919529,
        13712227150607670181,
        17021852944633065291,
        6252096473787587650,
    ],
    [
        4887609836208846458,
        3027115137917284492,
        9595098600469470675,
        10528569829048484079,
        7864689113198939815,
        17533723827845969040,
        5781638039037710951,
        17024078752430719006,
        109659393484013511,
        7158933660534805869,
        2955076958026921730,
        7433723648458773977,
    ],
    [
        16308865189192447297,
        11977192855656444890,
        12532242556065780287,
        14594890931430968898,
        7291784239689209784,
        5514718540551361949,
        10025733853830934803,
        7293794580341021693,
        6728552937464861756,
        6332385040983343262,
        13277683694236792804,
        2600778905124452676,
    ],
    [
        7123075680859040534,
        1034205548717903090,
        7717824418247931797,
        3019070937878604058,
        11403792746066867460,
        10280580802233112374,
        337153209462421218,
        13333398568519923717,
        3596153696935337464,
        8104208463525993784,
        14345062289456085693,
        17036731477169661256,
    ],
];

/// Round constants for the second half of each RPO round (verbatim from miden-crypto).
pub const ARK2: [[u64; STATE_WIDTH]; NUM_ROUNDS] = [
    [
        6077062762357204287,
        15277620170502011191,
        5358738125714196705,
        14233283787297595718,
        13792579614346651365,
        11614812331536767105,
        14871063686742261166,
        10148237148793043499,
        4457428952329675767,
        15590786458219172475,
        10063319113072092615,
        14200078843431360086,
    ],
    [
        6202948458916099932,
        17690140365333231091,
        3595001575307484651,
        373995945117666487,
        1235734395091296013,
        14172757457833931602,
        707573103686350224,
        15453217512188187135,
        219777875004506018,
        17876696346199469008,
        17731621626449383378,
        2897136237748376248,
    ],
    [
        8023374565629191455,
        15013690343205953430,
        4485500052507912973,
        12489737547229155153,
        9500452585969030576,
        2054001340201038870,
        12420704059284934186,
        355990932618543755,
        9071225051243523860,
        12766199826003448536,
        9045979173463556963,
        12934431667190679898,
    ],
    [
        18389244934624494276,
        16731736864863925227,
        4440209734760478192,
        17208448209698888938,
        8739495587021565984,
        17000774922218161967,
        13533282547195532087,
        525402848358706231,
        16987541523062161972,
        5466806524462797102,
        14512769585918244983,
        10973956031244051118,
    ],
    [
        6982293561042362913,
        14065426295947720331,
        16451845770444974180,
        7139138592091306727,
        9012006439959783127,
        14619614108529063361,
        1394813199588124371,
        4635111139507788575,
        16217473952264203365,
        10782018226466330683,
        6844229992533662050,
        7446486531695178711,
    ],
    [
        3736792340494631448,
        577852220195055341,
        6689998335515779805,
        13886063479078013492,
        14358505101923202168,
        7744142531772274164,
        16135070735728404443,
        12290902521256031137,
        12059913662657709804,
        16456018495793751911,
        4571485474751953524,
        17200392109565783176,
    ],
    [
        17130398059294018733,
        519782857322261988,
        9625384390925085478,
        1664893052631119222,
        7629576092524553570,
        3485239601103661425,
        9755891797164033838,
        15218148195153269027,
        16460604813734957368,
        9643968136937729763,
        3611348709641382851,
        18256379591337759196,
    ],
];

// PERIODIC-COLUMN HELPERS
// ================================================================================================

/// ARK1 round constants as Goldilocks field elements (row-per-round).
pub fn ark1_felt() -> [[Felt; STATE_WIDTH]; NUM_ROUNDS] {
    let mut out = [[Felt::ZERO; STATE_WIDTH]; NUM_ROUNDS];
    for r in 0..NUM_ROUNDS {
        for i in 0..STATE_WIDTH {
            out[r][i] = Felt::new(ARK1[r][i]);
        }
    }
    out
}

/// ARK2 round constants as Goldilocks field elements (row-per-round).
pub fn ark2_felt() -> [[Felt; STATE_WIDTH]; NUM_ROUNDS] {
    let mut out = [[Felt::ZERO; STATE_WIDTH]; NUM_ROUNDS];
    for r in 0..NUM_ROUNDS {
        for i in 0..STATE_WIDTH {
            out[r][i] = Felt::new(ARK2[r][i]);
        }
    }
    out
}

// SYMBOLIC ROUND PRIMITIVES (generic over the constraint-evaluation field E)
// ================================================================================================

/// x^7 via 3 multiplications (degree 7). Used for the S-box in both the native
/// permutation and the AIR constraint.
#[inline(always)]
pub fn pow7<E: FieldElement>(x: E) -> E {
    let x2 = x * x;
    let x4 = x2 * x2;
    x4 * x2 * x
}

/// Apply the RPO MDS matrix (12×12 left-circulant) to a state, generic over E.
#[inline(always)]
pub fn apply_mds<E: FieldElement + From<Felt>>(state: &[E; STATE_WIDTH]) -> [E; STATE_WIDTH] {
    let mut out = [E::ZERO; STATE_WIDTH];
    for i in 0..STATE_WIDTH {
        let mut acc = E::ZERO;
        for j in 0..STATE_WIDTH {
            let c = E::from(Felt::new(MDS_ROW0[(j + STATE_WIDTH - i) % STATE_WIDTH]));
            acc += c * state[j];
        }
        out[i] = acc;
    }
    out
}

/// Enforce ONE RPO round as a degree-7 transition constraint, accumulating into
/// `result[0..12]` (gated by `flag`).
///
/// The native round is `next = invsbox(MDS·sbox(MDS·cur + ARK1) + ARK2)`. The inverse
/// S-box is degree (p-1)/7 — far too high for an AIR. We instead apply the S-box to
/// both sides:
///
/// ```text
///   sbox(next) = MDS·sbox(MDS·cur + ARK1) + ARK2
/// ```
///
/// which is degree 7 on both sides. Rearranged, the per-element constraint is:
///
/// ```text
///   next_i^7 - ARK2_i - ( MDS · (MDS·cur + ARK1)^7 )_i  ==  0
/// ```
#[allow(clippy::too_many_arguments)]
pub fn enforce_round<E: FieldElement + From<Felt>>(
    result: &mut [E],
    current: &[E],
    next: &[E],
    ark1: &[E],
    ark2: &[E],
    flag: E,
) {
    // a = MDS·cur
    let mut cur = [E::ZERO; STATE_WIDTH];
    cur.copy_from_slice(&current[..STATE_WIDTH]);
    let a = apply_mds(&cur);

    // c = sbox(MDS·cur + ARK1)
    let mut c = [E::ZERO; STATE_WIDTH];
    for i in 0..STATE_WIDTH {
        c[i] = pow7(a[i] + ark1[i]);
    }

    // d = MDS·c
    let d = apply_mds(&c);

    // constraint: sbox(next) - ARK2 - d == 0
    for i in 0..STATE_WIDTH {
        let lhs = pow7(next[i]) - ark2[i] - d[i];
        result[i] += flag * lhs;
    }
}

// NATIVE PERMUTATION + SPONGE (base field only) — matches miden-crypto exactly
// ================================================================================================

/// Apply a SINGLE RPO round `r` to the state (one trace step). Used to fill the
/// execution trace row-by-row so each row sits on a round boundary.
pub fn round(state: &mut [Felt; STATE_WIDTH], r: usize) {
    let ark1 = ark1_felt();
    let ark2 = ark2_felt();
    // first half: state = sbox(MDS·state + ARK1)
    let a = apply_mds(state);
    for i in 0..STATE_WIDTH {
        state[i] = (a[i] + ark1[r][i]).exp7();
    }
    // second half: state = invsbox(MDS·state + ARK2)
    let a = apply_mds(state);
    for i in 0..STATE_WIDTH {
        state[i] = (a[i] + ark2[r][i]).exp(INV_ALPHA);
    }
}

/// The native RPO permutation (7 rounds), identical to `miden_crypto::Rpo256`.
pub fn permutation(state: &mut [Felt; STATE_WIDTH]) {
    for r in 0..NUM_ROUNDS {
        round(state, r);
    }
}

/// RPO `merge`: hash two 4-element words into one (the Merkle-node hash). Identical to
/// `miden_crypto::Rpo256::merge`: rate = left‖right (state[4..12]), capacity = 0,
/// permute, output = state[4..8].
pub fn merge(left: &Word, right: &Word) -> Word {
    let mut state = [Felt::ZERO; STATE_WIDTH];
    state[RATE_START..RATE_START + DIGEST_SIZE].copy_from_slice(left);
    state[RATE_START + DIGEST_SIZE..STATE_WIDTH].copy_from_slice(right);
    permutation(&mut state);
    let mut out = ZERO_WORD;
    out.copy_from_slice(&state[DIGEST_START..DIGEST_START + DIGEST_SIZE]);
    out
}

/// Pack up to 4 scalars into a Word (zero-padded), the leading-slot convention used by
/// this circuit for hashing small tuples (e.g. `(idNullifier, idTrapdoor)`).
pub fn pack(elems: &[Felt]) -> Word {
    let mut w = ZERO_WORD;
    for (i, &e) in elems.iter().enumerate().take(DIGEST_SIZE) {
        w[i] = e;
    }
    w
}
