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
