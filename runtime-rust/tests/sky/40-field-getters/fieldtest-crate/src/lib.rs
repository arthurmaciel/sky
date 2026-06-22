//! Minimal local crate exercising Sky→Rust struct FIELD GETTERS (S1).
//!
//! NOT an author example — a Rust-backend FFI test fixture. Lives under
//! runtime-rust/tests/sky/ per the boundary rule (examples/ is the author's).
//!
//! Struct names are multi-letter on purpose: the shared FFI generator treats a
//! single-uppercase-letter type as a Go generic type variable (`shouldSkipFn`),
//! so `P`/`Q`/`R` would be dropped. Real crates (CheckoutSession, …) never hit
//! this; the fixture uses `Point`/`Counter`/`Rec` to mirror reality.

/// Two public fields, both in the S1 closed type set (`i64` Copy, `String`).
#[derive(Clone)]
pub struct Point {
    pub n: i64,
    pub label: String,
}

pub fn make_point(n: i64, label: &str) -> Result<Point, String> {
    Ok(Point { n, label: label.to_string() })
}

/// SAME-NAMED field and method (C2 proof). `Counter::fresh` returns `Counter`
/// by value so the instance method `id()` survives the inspector's
/// by-value-Sized gate.
#[derive(Clone)]
pub struct Counter {
    pub id: i64,
}

impl Counter {
    pub fn fresh() -> Counter {
        Counter { id: 0 }
    }

    /// Same name as the `id` field — must coexist with the field getter.
    pub fn id(&self) -> Result<i64, String> {
        Ok(self.id * 10)
    }
}

pub fn make_counter(id: i64) -> Result<Counter, String> {
    Ok(Counter { id })
}

/// C1 (wide-int) + C3 (doc-hidden) proof. `good` (i32) is eligible; `wide`
/// (u64) is DROPPED as value-non-preserving into Sky Int; `secret` is
/// `#[doc(hidden)]` and must NEVER surface a getter.
#[derive(Clone)]
pub struct Rec {
    pub good: i32,
    #[doc(hidden)]
    pub secret: i64,
    pub wide: u64,
}

pub fn make_rec(good: i32) -> Result<Rec, String> {
    Ok(Rec { good, secret: 99, wide: 7 })
}

/// C5 opaque-Clone proof. A field whose type is a crate-local opaque struct is
/// getter-eligible ONLY if that struct derives `Clone` (`Inner`); a non-`Clone`
/// opaque field (`NoClone`) must be DROPPED.
#[derive(Clone)]
pub struct Inner {
    pub tag: i32,
}

pub struct NoClone {
    pub x: i32,
}

// Holder is NOT Clone (it holds a non-Clone `NoClone`), and the Sky program
// reads it exactly once, so the call-site never needs to clone it.
pub struct Holder {
    pub good_inner: Inner, // eligible — `Inner` derives Clone
    pub bad_inner: NoClone, // DROPPED — `NoClone` is not Clone
}

pub fn make_holder(tag: i32) -> Result<Holder, String> {
    Ok(Holder {
        good_inner: Inner { tag },
        bad_inner: NoClone { x: tag },
    })
}
