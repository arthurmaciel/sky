//! Minimal local crate for the Sky→Rust FFI-surface DCE proof (S4).
//!
//! NOT an author example — a Rust-backend FFI test fixture. Lives under
//! runtime-rust/tests/sky/ per the boundary rule (examples/ is the author's).
//!
//! It exposes MANY public symbols (one "used" fn, nine "unused" fns, plus a
//! struct with public fields + a method). The Sky program calls ONLY
//! `used_one`. With DCE on, the emitted `dcetest_bindings.rs` must contain
//! `used_one`'s wrapper + the preamble, and NONE of the `unused_*` wrappers.
//! With `SKY_DCE=0` it must contain ALL wrappers (full emit) and run
//! identically (D4 equivalence).
//!
//! Struct names are multi-letter (`Widget`) on purpose: the shared FFI
//! generator treats a single-uppercase-letter type as a Go generic type
//! variable, so a 1-letter name would be dropped before it reaches DCE.

/// The single function the Sky program actually calls.
pub fn used_one(x: i64) -> Result<i64, String> {
    Ok(x + 1)
}

// ── Nine never-called functions. Each binds to a real wrapper, so DCE has
// something to drop. They return Result<_, String> so they bind as sync Sky
// Results (the common shape). ───────────────────────────────────────────────

pub fn unused_1(x: i64) -> Result<i64, String> {
    Ok(x * 2)
}

pub fn unused_2(x: i64) -> Result<i64, String> {
    Ok(x - 3)
}

pub fn unused_3(x: i64) -> Result<i64, String> {
    Ok(x * x)
}

pub fn unused_4(s: &str) -> Result<String, String> {
    Ok(format!("{s}!"))
}

pub fn unused_5(x: i64) -> Result<bool, String> {
    Ok(x > 0)
}

pub fn unused_6(a: i64, b: i64) -> Result<i64, String> {
    Ok(a + b)
}

pub fn unused_7(x: i64) -> Result<i64, String> {
    Ok(x.saturating_abs())
}

pub fn unused_8(s: &str) -> Result<i64, String> {
    Ok(s.len() as i64)
}

pub fn unused_9(x: i64) -> Result<i64, String> {
    Ok(x.saturating_neg())
}

/// A struct with public fields + a method — exercises field getters/setters +
/// an instance method, all of which the Sky program leaves unused (so DCE must
/// drop them too).
#[derive(Clone)]
pub struct Widget {
    pub width: i64,
    pub label: String,
}

impl Widget {
    pub fn area(&self) -> Result<i64, String> {
        Ok(self.width * self.width)
    }
}

pub fn make_widget(width: i64, label: &str) -> Result<Widget, String> {
    Ok(Widget {
        width,
        label: label.to_string(),
    })
}
