#![allow(dead_code)]
//! #95 C6 NEGATIVE: a projected (trait-method) NESTED numeric must NOT be
//! admitted+coerced (codegen covers only top-level scalar). `pick` takes
//! `Option<usize>` (nested numeric); `scale` takes a top-level `u32` (the #95
//! happy path). C6 requires `pick` to behave SAFELY (drop, never a cargo-fail
//! wrapper) while `scale` binds + saturates.
#[derive(Clone)]
pub struct Calc {
    base: i64,
}
impl Calc {
    pub fn new(base: i64) -> Calc {
        Calc { base }
    }
}
pub trait Ops {
    fn pick(&self, n: Option<usize>) -> i64;
    fn scale(&self, w: u32) -> i64;
}
impl Ops for Calc {
    fn pick(&self, n: Option<usize>) -> i64 {
        self.base + n.map(|x| x as i64).unwrap_or(0)
    }
    fn scale(&self, w: u32) -> i64 {
        self.base + w as i64
    }
}
