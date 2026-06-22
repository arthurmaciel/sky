//! Minimal local crate exercising Sky→Rust MULTI-FIELD enum-variant payload
//! EXTRACTORS (task #18 — completes S3, which only emitted extractors for
//! SINGLE-field variants).
//!
//! NOT an author example — a Rust-backend FFI test fixture. Lives under
//! runtime-rust/tests/sky/ per the boundary rule (examples/ is the author's).
//!
//! S3 emitted `<v>_as_variant : E -> Maybe T` ONLY for a variant with EXACTLY
//! ONE closed-set field. Multi-field variants (`V(A,B)`, `V{a,b}`) were tag-only.
//! This fixture witnesses the PER-FIELD generalisation: a ≥2-field variant emits
//! one extractor per closed-set field
//!   • tuple  `V(A, B)`   → `<v>_0_as_variant : E -> Maybe A`,
//!                          `<v>_1_as_variant : E -> Maybe B`
//!   • struct `V{a, b}`   → `<v>_a_as_variant : E -> Maybe A`,
//!                          `<v>_b_as_variant : E -> Maybe B`
//!   • mixed  `Mix(i64, NoClone)` → ONLY field 0 (`mix_0_as_variant`); the
//!                          non-Clone/non-closed field 1 gets no extractor.
//!
//! Type name is multi-letter on purpose: the shared FFI generator treats a
//! single-uppercase-letter type as a Go generic type variable.

/// A non-Clone, non-closed-set payload type — makes field 1 of `Mix` ineligible
/// for an extractor while its sibling field 0 (`i64`) still gets one.
pub struct NoClone {
    pub x: i64,
}

/// Witnesses the multi-field extractor shapes:
///   • `Pair(i64, String)`   — multi-field TUPLE  → `pair_0_as_variant : Maybe Int`
///                                                  `pair_1_as_variant : Maybe String`
///   • `Rect { w: i64, h: i64 }` — multi-field STRUCT → `rect_w_as_variant : Maybe Int`
///                                                  `rect_h_as_variant : Maybe Int`
///   • `Mix(i64, NoClone)`   — mixed eligibility   → `mix_0_as_variant : Maybe Int`
///                                                  ONLY (field 1 ineligible)
///   • `Empty`               — unit variant (forces the >1-variant wildcard so
///                                            every extractor's `_ => Nothing`
///                                            arm is reachable + correct)
pub enum Geo {
    Pair(i64, String),
    Rect { w: i64, h: i64 },
    Mix(i64, NoClone),
    Empty,
}

// ── Constructors the Sky side calls. The multi-field tuple/struct ctors already
// bind from S3 (every field of Pair/Rect is closed-set), so the Sky source can
// construct each value via the auto-generated `*_new_variant` ctor. `Mix`'s
// ctor does NOT bind (NoClone is non-closed), so the crate supplies a Mix value.
pub fn make_mix(n: i64) -> Result<Geo, String> {
    Ok(Geo::Mix(n, NoClone { x: n * 10 }))
}
