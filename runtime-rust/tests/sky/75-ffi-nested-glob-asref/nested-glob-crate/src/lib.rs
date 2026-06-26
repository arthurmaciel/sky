// 75-ffi-nested-glob-asref: WALL 1 proof fixture.
//
// WALL 1: types reachable ONLY through nested private-module glob chain:
//   crate root (pub) → mod inner (private) → pub use inner::*
//   → inner/mod.rs: mod deep (private) → pub use deep::*
//   → deep.rs: pub struct Sup  (TWO levels — the WALL 1 target)
//
// COLLISION (C2): vis::Dual reachable BOTH via pub mod vis + pub use vis::*
//   so it's in REACHABLE_PATHS at TWO candidate paths; insert_shorter wins.
//
// NEGATIVE (C1): inner/deep.rs pub(crate) struct Hidden must NOT bind.
//   If it does, the wrapper emits an E0603 path → cargo-fail proves the bug.

mod inner;
pub use inner::*;

pub mod vis;
pub use vis::*;
