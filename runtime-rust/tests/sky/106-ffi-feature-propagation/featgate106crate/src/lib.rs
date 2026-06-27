//! 106 fixture crate — feature propagation (#100 Part B).
//!
//! `base_value` is always present; `extra_value` exists ONLY under the `extra`
//! Cargo feature. The Sky→Rust FFI inspector auto-injects `extra` (no `full`
//! feature on this crate ⇒ #89 enables all features for max API visibility), so
//! it binds BOTH. The generated project's `[dependencies]` line must then enable
//! `extra` too — that is exactly what Part B feature propagation does. Without it
//! the auto-bound `extra_value` wrapper references a fn that does not exist in the
//! default-feature build ⇒ cargo-fail (E0425).

/// Always available (default features). One arg keeps the binding arity ≥ 1.
pub fn base_value(seed: i64) -> i64 {
    seed + 10
}

/// Feature-gated: present only when `extra` is enabled.
#[cfg(feature = "extra")]
pub fn extra_value(seed: i64) -> i64 {
    seed + 42
}
