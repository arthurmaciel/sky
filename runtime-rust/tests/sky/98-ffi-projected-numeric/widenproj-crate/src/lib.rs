#![allow(dead_code)]
//! #95 — numeric coercion on the PROJECTED/UFCS path. `widen` is a TRAIT method
//! (not inherent), so it routes through the generic-wrapper / UFCS emitter
//! (`synthesiseGenericWrapper`), the LAST FFI emit path to gain saturating
//! numeric coercion. Params usize/u32/f32 (Sky Int/Float → foreign width,
//! SATURATING — never a silent `as` wraparound); a `usize` RETURN widens to Sky
//! Int (saturating). Pre-#95 the inspector fail-closed-dropped such methods
//! because the projected emitter coerced neither side.
#[derive(Clone)]
pub struct Calc {
    base: i64,
}
impl Calc {
    pub fn new(base: i64) -> Calc {
        Calc { base }
    }
}

/// A trait method → the call carries a `traitQualifier` → the UFCS/projected
/// emit path (distinct from Calc's inherent methods).
pub trait Widen {
    fn widen(&self, n: usize, w: u32, x: f32) -> usize;
}
impl Widen for Calc {
    fn widen(&self, n: usize, w: u32, x: f32) -> usize {
        // base + n + w + x, as usize (saturating-ish for the demo).
        (self.base.max(0) as usize) + n + (w as usize) + (x as usize)
    }
}
