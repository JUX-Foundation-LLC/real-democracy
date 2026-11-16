//! Small constraint-evaluation helpers (mirrors winterfell's `examples/utils`).

use winterfell::math::FieldElement;

/// Returns zero only when `a == b`.
#[inline(always)]
pub fn are_equal<E: FieldElement>(a: E, b: E) -> E {
    a - b
}

/// Returns zero only when `a == 0`.
#[inline(always)]
pub fn is_zero<E: FieldElement>(a: E) -> E {
    a
}

/// Returns zero only when `a` is 0 or 1.
#[inline(always)]
pub fn is_binary<E: FieldElement>(a: E) -> E {
    a * a - a
}

/// `1 - a` (logical NOT for a binary value).
#[inline(always)]
pub fn not<E: FieldElement>(a: E) -> E {
    E::ONE - a
}

/// Aggregate `flag * value` into `result[index]` (constraint accumulation).
pub trait EvaluationResult<E> {
    fn agg_constraint(&mut self, index: usize, flag: E, value: E);
}

impl<E: FieldElement> EvaluationResult<E> for [E] {
    #[inline(always)]
    fn agg_constraint(&mut self, index: usize, flag: E, value: E) {
        self[index] += flag * value;
    }
}
