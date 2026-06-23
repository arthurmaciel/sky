//! #31 REAL-INSPECTOR crate — trait methods on a CONCRETE foreign type, bound
//! end-to-end by the ACTUAL inspector (`cargo +nightly rustdoc` JSON), NOT a
//! hand stub. Every trait-impl method here carries rustdoc `visibility:"default"`
//! (a trait method inherits the trait's visibility), so before the #31
//! relaxation EVERY row dropped at the method-level `is_public` gate and the
//! inspector was inert on real crates. This crate is the proof the relaxation
//! makes the binding flow.
//!
//! POSITIVE rows (the inspector MUST emit, called from Main.sky):
//!   * `Area::area`            — NON-generic trait method (UFCS).
//!   * `Scale::scaled_by<T:Ord>` — generic trait method, bound on the trait DEF
//!                                 + restated bare on the impl (Q2-A union).
//!   * `Pair::first -> Self::A`  — associated-type method that RESOLVES (A=i64).
//!
//! NEGATIVE rows (the inspector MUST DROP — proven by the build NOT cargo-failing
//! on a bad emit, plus the inspector unit tests):
//!   * `impl Display for Label` — the `to_string` bridge, NEVER a `fmt` UFCS.
//!   * `impl<T> Blanket for T`   — blanket/generic Self → trait-method-generic-self.
//!   * `impl Area for Holder<i64>` — monomorphic-instantiation Self → generic-self.
//!   * `impl Hidden for Circle` where `Hidden` is `pub(crate)` — the trait has no
//!     reachable public path → trait-method-trait-unreachable. THIS is the C-1
//!     row the hand stub can't exercise: a wrong emit here is a `None`-qualifier
//!     inherent call → E0603/E0599 cargo-fail at the generated bindings.

// ── (1) NON-generic trait method ────────────────────────────────────────
pub trait Area {
    fn area(&self) -> f64;
}

#[derive(Clone)]
pub struct Circle {
    pub r: f64,
}

impl Circle {
    /// Inherent constructor so the Sky side can MAKE a `Circle` to call the
    /// trait methods on (an opaque foreign receiver needs a producer).
    pub fn new(r: f64) -> Circle {
        Circle { r }
    }
}

impl Area for Circle {
    fn area(&self) -> f64 {
        3.14_f64 * self.r * self.r
    }
}

// ── (2) GENERIC trait method, bound on the trait DEF (constraint 12) ─────
pub trait Scale {
    fn scaled_by<T: Ord>(&self, k: T, floor: T) -> f64;
}

impl Scale for Circle {
    fn scaled_by<T: Ord>(&self, k: T, floor: T) -> f64 {
        let bigger = if k >= floor { 1 } else { 0 };
        self.r * (2.0_f64 + bigger as f64)
    }
}

// ── (3) Associated-type method that RESOLVES ────────────────────────────
pub trait Pair {
    type A;
    fn first(&self) -> Self::A;
}

impl Pair for Circle {
    type A = i64;
    fn first(&self) -> i64 {
        7
    }
}

// ── (4) Display impl — the to_string bridge, NOT a fmt UFCS binding ──────
pub struct Label {
    pub text: &'static str,
}

impl std::fmt::Display for Label {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "label:{}", self.text)
    }
}

impl Label {
    pub fn greeting() -> Label {
        Label { text: "hi" }
    }
}

// ── NEGATIVE: blanket impl over a generic Self → trait-method-generic-self ─
pub trait Blanket {
    fn describe(&self) -> i64;
}

impl<T> Blanket for T {
    fn describe(&self) -> i64 {
        0
    }
}

// ── NEGATIVE: monomorphic-instantiation Self → trait-method-generic-self ──
pub struct Holder<T> {
    pub v: T,
}

impl Area for Holder<i64> {
    fn area(&self) -> f64 {
        self.v as f64
    }
}

// ── NEGATIVE (C-1): a `pub(crate)` trait on a PUBLIC Self ────────────────
// `Hidden` is pub(crate) → its rustdoc id has NO reachable public path. The
// inspector must DROP `hush` with `trait-method-trait-unreachable`, NEVER emit a
// `<Circle as Hidden>::hush` / inherent `Circle::hush` call: `Hidden` is not
// nameable from the generated bindings crate → E0603/E0599. The build succeeding
// (no such symbol in the generated bindings) is the proof.
pub(crate) trait Hidden {
    fn hush(&self) -> i64;
}

impl Hidden for Circle {
    fn hush(&self) -> i64 {
        // referenced internally so the impl isn't dead-code-eliminated
        (self.r as i64) + 1
    }
}

/// Internal use so `Hidden::hush` is live in the crate (not pruned by rustc),
/// keeping the pub(crate)-trait row in the rustdoc the inspector reads.
pub fn _internal_uses_hidden(c: &Circle) -> i64 {
    c.hush()
}
