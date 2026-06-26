/// COLLISION (C2): Dual is reachable BOTH as `nested_glob_crate::vis::Dual`
/// (via `pub mod vis`) AND as `nested_glob_crate::Dual` (via `pub use vis::*`).
/// insert_shorter must pick the shorter path. cargo build proves the path resolves.
pub struct Dual {
    pub d: i64,
}

impl Dual {
    pub fn new(d: i64) -> Dual {
        Dual { d }
    }

    pub fn get_d(&self) -> i64 {
        self.d
    }
}
