//! Iterators-FFI hand-stub crate (epic #30). Dependency-free. Exercises the two
//! v1 iterator-PARAM shapes plus the return-position NEGATIVE that must DROP:
//!
//!   * `sum_all<I: IntoIterator<Item=i64>>`  — a `Vec<i64>` IS `IntoIterator`,
//!     so the arg passes DIRECTLY (no adapter).
//!   * `count_iter<I: Iterator<Item=i64>>`   — a `Vec` is not itself an
//!     `Iterator`, so the call site passes `arg.into_iter()` (the `Iter` kind).
//!   * `evens() -> impl IntoIterator<Item=i64>` — a RETURN-position iterator
//!     trait. It must NOT bind (latent E0308 / undecidable finiteness, [C-R]);
//!     it is ABSENT from the kernel.json so the Sky side cannot call it.

/// by-value IntoIterator param — the Vec passes directly.
pub fn sum_all<I: IntoIterator<Item = i64>>(xs: I) -> i64 {
    xs.into_iter().sum()
}

/// by-value Iterator param — the call site must `.into_iter()` the Vec first.
pub fn count_iter<I: Iterator<Item = i64>>(it: I) -> i64 {
    it.count() as i64
}

/// RETURN-position `impl IntoIterator` — the NEGATIVE row. Must be DROPPED by
/// the inspector (the wrapper would be `-> Vec<i64>` over an `impl IntoIterator`
/// body — a latent E0308). Present in the crate so the drop is exercised, but
/// ABSENT from the hand-stub kernel.json.
pub fn evens() -> impl IntoIterator<Item = i64> {
    vec![2, 4, 6]
}
