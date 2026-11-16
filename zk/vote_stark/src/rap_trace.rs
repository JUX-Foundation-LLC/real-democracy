//! A minimal aux-segment-capable execution trace (a RAP trace table).
//!
//! Winterfell's built-in `TraceTable` is single-segment; the ranked permutation
//! argument needs ONE auxiliary column (the grand-product accumulator) built from a
//! Fiat-Shamir challenge drawn AFTER the main trace is committed. This is a trimmed
//! copy of winterfell's `examples/rescue_raps/custom_trace_table.rs`, fixed to one aux
//! column and one aux random element.

use winterfell::{math::StarkField, matrix::ColMatrix, EvaluationFrame, Trace, TraceInfo};

/// Width of the auxiliary segment (the single grand-product column).
pub const AUX_WIDTH: usize = 1;
/// Number of random elements the verifier draws for the aux segment (the challenge γ).
pub const NUM_AUX_RAND: usize = 1;

pub struct RapTraceTable<B: StarkField> {
    info: TraceInfo,
    trace: ColMatrix<B>,
}

impl<B: StarkField> RapTraceTable<B> {
    /// Create a blank trace of `width` main columns and `length` rows (+ the fixed aux
    /// segment). Memory is allocated but not initialized; fill with [`fill`](Self::fill).
    pub fn new(width: usize, length: usize) -> Self {
        assert!(width > 0, "trace must have at least one column");
        assert!(width <= TraceInfo::MAX_TRACE_WIDTH, "trace too wide");
        assert!(length >= TraceInfo::MIN_TRACE_LENGTH, "trace too short");
        assert!(
            length.is_power_of_two(),
            "trace length must be a power of 2"
        );
        let columns = (0..width).map(|_| vec![B::ZERO; length]).collect();
        Self {
            info: TraceInfo::new_multi_segment(width, AUX_WIDTH, NUM_AUX_RAND, length, vec![]),
            trace: ColMatrix::new(columns),
        }
    }

    /// Build a trace directly from column-major data.
    pub fn init(columns: Vec<Vec<B>>) -> Self {
        assert!(!columns.is_empty(), "trace must have at least one column");
        let width = columns.len();
        let length = columns[0].len();
        assert!(width <= TraceInfo::MAX_TRACE_WIDTH, "trace too wide");
        assert!(length >= TraceInfo::MIN_TRACE_LENGTH, "trace too short");
        assert!(
            length.is_power_of_two(),
            "trace length must be a power of 2"
        );
        assert!(columns.iter().all(|c| c.len() == length), "ragged columns");
        Self {
            info: TraceInfo::new_multi_segment(width, AUX_WIDTH, NUM_AUX_RAND, length, vec![]),
            trace: ColMatrix::new(columns),
        }
    }

    /// Fill the trace: `init` sets row 0, `update(i, state)` advances row `i` → `i+1`.
    pub fn fill<I, U>(&mut self, init: I, update: U)
    where
        I: Fn(&mut [B]),
        U: Fn(usize, &mut [B]),
    {
        let mut state = vec![B::ZERO; self.info.main_trace_width()];
        init(&mut state);
        self.update_row(0, &state);
        for i in 0..self.info.length() - 1 {
            update(i, &mut state);
            self.update_row(i + 1, &state);
        }
    }

    pub fn update_row(&mut self, step: usize, state: &[B]) {
        self.trace.update_row(step, state);
    }

    pub fn width(&self) -> usize {
        self.info.main_trace_width()
    }

    pub fn get(&self, column: usize, step: usize) -> B {
        self.trace.get(column, step)
    }

    pub fn read_row_into(&self, step: usize, target: &mut [B]) {
        self.trace.read_row_into(step, target);
    }
}

impl<B: StarkField> Trace for RapTraceTable<B> {
    type BaseField = B;

    fn info(&self) -> &TraceInfo {
        &self.info
    }

    fn read_main_frame(&self, row_idx: usize, frame: &mut EvaluationFrame<Self::BaseField>) {
        let next_row_idx = (row_idx + 1) % self.info.length();
        self.trace.read_row_into(row_idx, frame.current_mut());
        self.trace.read_row_into(next_row_idx, frame.next_mut());
    }

    fn main_segment(&self) -> &ColMatrix<B> {
        &self.trace
    }
}
