//! Minimal local crate exercising the Sky→Rust WIDE-INT truncation fix (task #16).
//!
//! NOT an author example — a Rust-backend FFI test fixture. Lives under
//! runtime-rust/tests/sky/ per the boundary rule (examples/ is the author's).
//!
//! Two symmetric coercion sites are under test:
//!
//!   READ side (translateRustRet) — a fn / method returning a type WIDER than
//!   i64 (`u64`, `usize`) must SATURATE into i64 range, never sign-flip. The
//!   classic regression: `u64::MAX as i64 == -1`. After the fix `big()`'s
//!   `u64::MAX` saturates to `i64::MAX` (9223372036854775807).
//!
//!   WRITE side (field setter gate) — a struct field NARROWER than i64
//!   (`small: i32`) or WIDER than i64 (`big: u64`) must NOT get a setter (a Sky
//!   i64 assigned in would truncate/reinterpret). The `i64` field `ok` keeps its
//!   setter (lossless receive). u64 fields are dropped wholesale (getter + setter)
//!   by the pre-existing closed-set gate; the i32 field keeps its GETTER (widening
//!   read is lossless) but loses its SETTER under the new gate.
//!
//! Struct name is multi-letter on purpose: the shared FFI generator treats a
//! single-uppercase-letter type as a Go generic type variable (`shouldSkipFn`),
//! so a `W` type would be dropped. `Wide` is safe.

/// READ-side saturation witness: returns a `u64` ABOVE `i64::MAX`. A bare
/// `as i64` would yield `-1`; the saturating coercion clamps to `i64::MAX`.
/// Takes a dummy `seed` so the binding is a normal 1-arg call (sidesteps the
/// zero-arg calling-convention limitation #7 in the fixture's Sky source).
pub fn big(_seed: i64) -> Result<u64, String> {
    Ok(u64::MAX)
}

/// READ-side `usize` method witness with a small in-range value — must read
/// back exactly (saturation is a no-op below the clamp).
#[derive(Clone)]
pub struct Counter {
    pub n: i64,
}

impl Counter {
    pub fn count(&self) -> Result<usize, String> {
        Ok(7usize)
    }
}

pub fn make_counter(n: i64) -> Result<Counter, String> {
    Ok(Counter { n })
}

/// WRITE-side gate witness. Three int fields across the lossless-receive
/// boundary:
///   • `small: i32` — getter YES (widening read), setter NO (narrowing write).
///   • `big:   u64` — getter NO + setter NO (dropped wholesale by the closed-set
///                    gate; a u64 can't widen losslessly into Sky i64 either way).
///   • `ok:    i64` — getter YES + setter YES (exact-width, lossless both ways).
#[derive(Clone)]
pub struct Wide {
    pub small: i32,
    pub big: u64,
    pub ok: i64,
}

pub fn make_wide(small: i32, big: u64, ok: i64) -> Result<Wide, String> {
    Ok(Wide { small, big, ok })
}
