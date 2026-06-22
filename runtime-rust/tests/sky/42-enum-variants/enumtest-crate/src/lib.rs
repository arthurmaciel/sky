//! Minimal local crate exercising Sky→Rust ENUM-VARIANT binding (S3).
//!
//! NOT an author example — a Rust-backend FFI test fixture. Lives under
//! runtime-rust/tests/sky/ per the boundary rule (examples/ is the author's).
//!
//! A foreign enum binds as an OPAQUE handle (`::enumtest::Shape`) with TOTAL
//! accessors: unit/tuple/struct variant CONSTRUCTORS, a TAG accessor, and
//! single-field payload EXTRACTORS. NEVER lowered to a Sky ADT.
//!
//! Type names are multi-letter on purpose: the shared FFI generator treats a
//! single-uppercase-letter type as a Go generic type variable, so `E`/`S` would
//! be dropped. Real crates (Stripe `Currency`, …) never hit this.

/// A non-Clone, non-closed-set payload type — makes any variant carrying it
/// tag-only (no ctor, no extractor), but the variant is still tag-reachable.
pub struct NoClone {
    pub x: i64,
}

/// Witnesses every S3 variant shape:
///   • `Unit`              — unit variant   → ctor `()->Shape`, tag "Unit"
///   • `Tup(i64)`          — single tuple   → ctor + tag + extractor (Maybe Int)
///   • `Strukt { w: i64 }` — single struct  → ctor + tag + extractor (Maybe Int)
///   • `Multi(i64, String)`— multi-field    → ctor (both fields closed) + tag,
///                                            NO extractor (R6 multi-field skip)
///   • `Tagged(NoClone)`   — non-closed     → NO ctor, NO extractor; TAG-ONLY
///                                            (drives the R3 wildcard)
pub enum Shape {
    Unit,
    Tup(i64),
    Strukt { w: i64 },
    Multi(i64, String),
    Tagged(NoClone),
}

/// A `#[non_exhaustive]` enum with a `#[non_exhaustive]` variant. External code
/// (Sky) CANNOT construct it (E0639), so NO ctor is emitted for any variant.
/// The tag accessor IS emitted but MUST carry a `_ => "<unknown>"` wildcard
/// (R2/R3) — both the enum-level and variant-level non_exhaustive force it.
/// A crate-local ctor fn lets the Sky side obtain a value to read `tag` from.
#[non_exhaustive]
pub enum Mode {
    #[non_exhaustive]
    A,
    B(i64),
}

/// Generic enum — SKIPPED entirely in S3 (R7/E7: monomorphisation out of
/// scope). No bindings of any kind should be emitted for it.
pub enum Wrapper<T> {
    Carries(T),
}

/// Zero-variant (uninhabited) enum — SKIPPED (R4): no tag accessor.
pub enum Never {}

/// Single-variant EXHAUSTIVE enum — the extractor's `match { Solo::Only(x) =>
/// Just(x) }` is ALREADY total, so NO `_ => Nothing` wildcard must be emitted
/// (else clippy `unreachable_patterns`). Proves the extractor's precise wildcard
/// gating (F2).
pub enum Solo {
    Only(i64),
}

/// Keyword-named variant + keyword-named struct-variant field. rustdoc reports
/// these idents WITHOUT the `r#` prefix, so the codegen must raw-escape them
/// (`::enumtest::Kw::r#move`, `r#type: …`) — else the emitted Rust is
/// unparseable (E0762). Proves keyword raw-escaping (F1).
pub enum Kw {
    #[allow(non_camel_case_types)]
    r#move(i64),
    Fields {
        r#type: i64,
    },
}

pub fn make_solo(n: i64) -> Result<Solo, String> {
    Ok(Solo::Only(n))
}

// ── Constructors the Sky side calls (return Result for the FFI surface) ──

pub fn make_unit() -> Result<Shape, String> {
    Ok(Shape::Unit)
}

/// A Mode value the Sky side can read `tag` from — Sky can't construct a
/// non_exhaustive enum itself, so the crate provides this.
pub fn make_mode_b(n: i64) -> Result<Mode, String> {
    Ok(Mode::B(n))
}

pub fn make_mode_a() -> Result<Mode, String> {
    Ok(Mode::A)
}
