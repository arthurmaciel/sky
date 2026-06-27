#![allow(dead_code)]
//! #82 — numeric param-width coercion (SATURATING) on the regular inherent path.
//! Sky `Int`(i64)/`Float`(f64) → foreign `usize`/`u32`/`f32` params, clamped into
//! the target's range (NEVER a silent `as` wraparound — CLAUDE.md "no silent numeric
//! coercion"; the param-side sibling of the #16 return saturation). The projected
//! (trait default-method / UFCS) numeric path is a separate emitter — tracked apart.
#[derive(Clone)]
pub struct Calc {
    base: i64,
}
impl Calc {
    pub fn new(base: i64) -> Calc {
        Calc { base }
    }
    /// Multiple numeric widths in one inherent method: usize + u32 + f32.
    pub fn widen(&self, n: usize, w: u32, x: f32) -> i64 {
        self.base + n as i64 + w as i64 + x as i64
    }
    /// Round-trips a u32 param — proves SATURATION: a Sky Int > u32::MAX clamps to
    /// u32::MAX (4294967295), never wraps to a small value.
    pub fn echo_u32(&self, w: u32) -> i64 {
        w as i64
    }
}

/// #94 — an enum VARIANT carrying `Vec<u32>`. The inspector fail-closes a
/// *narrowing field setter* (`setter_narrowing` drop), so the reachable
/// Vec<numeric> truncation site is the ENUM CTOR (`ctorArgOwned`), which gates on
/// closed-set eligibility (u32 ∈ closed set), NOT losslessness. The auto ctor
/// writes a Sky `List Int` (Vec<i64>) into `Vec<u32>`; each element must SATURATE
/// per-element (5_000_000_000 → 4294967295), never wrap (the banned `x as u32`).
#[derive(Clone)]
pub enum Pack {
    Nums(Vec<u32>),
    Empty,
}
impl Pack {
    /// Sum the (saturated) elements back as i64 so Sky can read the round-trip.
    pub fn total(&self) -> i64 {
        match self {
            Pack::Nums(v) => v.iter().map(|&x| x as i64).sum(),
            Pack::Empty => 0,
        }
    }
}
