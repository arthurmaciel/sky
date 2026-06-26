/// TWO-level private-module type — WALL 1 target.
/// Reachable: crate root → inner (private) → deep (private) → Sup
pub struct Sup {
    pub y: i64,
}

impl Sup {
    pub fn new(y: i64) -> Sup {
        Sup { y }
    }

    pub fn get_y(&self) -> i64 {
        self.y
    }
}

/// NEGATIVE (C1): pub(crate) visibility — NOT publicly reachable from outside
/// the crate. Must NOT appear in REACHABLE_PATHS. If the inspector registers it,
/// the generated wrapper will try to use the crate-private path → E0603 on
/// cargo build, proving the C1 violation.
pub(crate) struct Hidden {
    pub h: i64,
}

#[allow(dead_code)]
impl Hidden {
    pub(crate) fn new(h: i64) -> Hidden {
        Hidden { h }
    }
}
