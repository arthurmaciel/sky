//! Minimal local crate exercising Sky→Rust struct FIELD SETTERS (S2).
//!
//! NOT an author example — a Rust-backend FFI test fixture. Lives under
//! runtime-rust/tests/sky/ per the boundary rule (examples/ is the author's).
//!
//! Struct names are multi-letter on purpose: the shared FFI generator treats a
//! single-uppercase-letter type as a Go generic type variable (`shouldSkipFn`),
//! so `P`/`Q` would be dropped. Real crates never hit this.

/// Public fields across the closed eligible set: `i64` Copy, `String`,
/// `Option<i64>` (nullable), `Vec<i64>` (list). The setters produce a NEW
/// `Box3` with one field replaced (immutable update).
#[derive(Clone)]
pub struct Box3 {
    pub w: i64,
    pub label: String,
    pub maybe_n: Option<i64>,
    pub tags: Vec<i64>,
}

pub fn make_box3(w: i64, label: &str) -> Result<Box3, String> {
    Ok(Box3 { w, label: label.to_string(), maybe_n: None, tags: vec![1, 2] })
}

/// FOUR-WAY C2 witness: a `pub id` field, an `id()` method, plus the
/// auto-synthesized field GETTER and field SETTER on the same struct must all
/// bind to four NON-colliding Sky names:
///   • `id_field_from_item`      (getter)
///   • `id_set_field_from_item`  (setter)
///   • `id_from_item`            (method)
///   • the `id` field projection itself drives both accessors.
#[derive(Clone)]
pub struct Item {
    pub id: i64,
}

impl Item {
    /// Same name as the `id` field — must coexist with field get + set.
    pub fn id(&self) -> Result<i64, String> {
        Ok(self.id * 10)
    }
}

pub fn make_item(id: i64) -> Result<Item, String> {
    Ok(Item { id })
}

/// C1 (wide-int) + C3 (doc-hidden) + char proof. `good` (i32) is eligible for
/// both get + set; `glyph` (char) is now eligible (S2 maps char↔Char); `wide`
/// (u64) is DROPPED as value-non-preserving into Sky Int — NO getter, NO setter;
/// `secret` is `#[doc(hidden)]` and must NEVER surface either accessor.
#[derive(Clone)]
pub struct Rec {
    pub good: i32,
    pub glyph: char,
    #[doc(hidden)]
    pub secret: i64,
    pub wide: u64,
}

pub fn make_rec(good: i32, glyph: char) -> Result<Rec, String> {
    Ok(Rec { good, glyph, secret: 99, wide: 7 })
}

/// C5 opaque-Clone proof. A field whose type is a crate-local opaque struct is
/// eligible (get + set) ONLY if that struct derives `Clone` (`Inner`); a
/// non-`Clone` opaque field (`NoClone`) must be DROPPED for both accessors.
#[derive(Clone)]
pub struct Inner {
    pub tag: i32,
}

pub struct NoClone {
    pub x: i32,
}

// Holder is NOT Clone (it holds a non-Clone `NoClone`), and the Sky program
// reads each receiver linearly, so the call-site never needs to clone it.
pub struct Holder {
    pub good_inner: Inner, // eligible — `Inner` derives Clone
    pub bad_inner: NoClone, // DROPPED — `NoClone` is not Clone
}

pub fn make_holder(tag: i32) -> Result<Holder, String> {
    Ok(Holder {
        good_inner: Inner { tag },
        bad_inner: NoClone { x: tag },
    })
}
