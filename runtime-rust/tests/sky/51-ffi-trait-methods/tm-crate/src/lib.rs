//! #21 hand-stub crate — trait methods on a CONCRETE foreign type, called via
//! UFCS (`<Circle as Scale>::method(&recv, …)`). Dependency-free. Exercises:
//!   * a NON-generic trait method (`Area::area`),
//!   * a generic trait method whose bound is genuinely load-bearing
//!     (`Scale::scaled<T: Ord>` — the modellable-5 row that binds ONLY because
//!     the inspector unions the trait-def bound; here the impl restates it),
//!   * an associated-type method that RESOLVES (`Pair::first -> Self::A`,
//!     `type A = i64`),
//!   * a `Display` impl (the `to_string` bridge — NOT a `fmt` UFCS binding).
//! Plus NEGATIVE rows the inspector must DROP (present for completeness; absent
//! from the hand-stub kernel.json): a blanket `impl<T> Blanket for T`, and an
//! assoc-type method whose assoc the impl never binds.

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
// The bound `T: Ord` lives on the trait definition AND is restated on the impl
// (Rust requires the restate). The inspector binds it by UNIONing the trait-def
// generics — a row that would emit a bare `<T>` (→ E0277) without Q2-A. `Ord` is
// a modellable-5 trait, so the Sky tyvar survives as `<T: Ord>` and the method
// binds (vs an `Into<f64>`-style resolve-bound, which the parametric path drops).
pub trait Scale {
    fn scaled_by<T: Ord>(&self, k: T, floor: T) -> f64;
}

impl Scale for Circle {
    fn scaled_by<T: Ord>(&self, k: T, floor: T) -> f64 {
        // `T: Ord` is load-bearing: pick the larger of k/floor as the multiplier
        // "rank", then scale the radius by it. (We map the rank to a small float
        // so the Sky side gets a deterministic number.)
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

// ── NEGATIVE rows — the inspector must DROP these ───────────────────────
// A blanket impl over a generic Self (`impl<T> Blanket for T`) → the Self is a
// type-var, not a concrete named type → `trait-method-generic-self`.
pub trait Blanket {
    fn describe(&self) -> i64;
}

impl<T> Blanket for T {
    fn describe(&self) -> i64 {
        0
    }
}

// An assoc-type method whose assoc the impl does NOT bind concretely cannot be
// constructed in safe Rust (the impl must bind `type B`), so the unbound case is
// exercised at the inspector unit-test level (`test_assoc_type_unbound_drops`);
// here we only ship the resolvable `Pair` row above.

// A trait impl on a MONOMORPHIC INSTANTIATION of a generic struct
// (`impl Area for Holder<i64>`). The Self carries no free type-var yet is
// parametric — the inspector must DROP it `trait-method-generic-self`, because
// the receiver-base strip would lose the `<i64>` (→ E0107 cargo-fail). Verified
// by `test_self_is_concrete_named` (the `Pair<i64>` → !concrete assertion);
// absent from the hand-stub kernel.json.
pub struct Holder<T> {
    pub v: T,
}

impl Area for Holder<i64> {
    fn area(&self) -> f64 {
        self.v as f64
    }
}
