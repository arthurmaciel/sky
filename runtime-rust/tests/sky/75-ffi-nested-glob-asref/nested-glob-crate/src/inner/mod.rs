mod deep;
pub use deep::*;

/// One-level private-module type (control: already works pre-fix).
pub struct Inner {
    pub x: i64,
}

impl Inner {
    pub fn new(x: i64) -> Inner {
        Inner { x }
    }

    pub fn get_x(&self) -> i64 {
        self.x
    }
}
