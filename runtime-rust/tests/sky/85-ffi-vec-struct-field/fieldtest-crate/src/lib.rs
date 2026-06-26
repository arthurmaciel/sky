//! WALL-A fixture: a foreign struct with a `Vec<StructType>` field. Exercises
//! the field GETTER + SETTER for a `Vec<Inner>` field where `Inner` is a bound
//! Clone-opaque struct — the case that previously collapsed the setter param
//! type to `Vec<String>` (E0308 at cargo build).
//!
//! NOT an author example — a Rust-backend FFI test fixture under
//! runtime-rust/tests/sky/ per the boundary rule.
//!
//! Struct names are multi-letter on purpose (a single-uppercase-letter type is
//! treated as a Go generic type variable by the shared FFI generator).

/// A bound Clone-opaque element struct. Has a ctor (`make_inner`) and a `pub n`
/// field with get/set — so Sky can BUILD an `Inner` and a `List Inner`.
#[derive(Clone)]
pub struct Inner {
    pub n: i64,
}

pub fn make_inner(n: i64) -> Result<Inner, String> {
    Ok(Inner { n })
}

/// The WALL-A struct. `items: Vec<Inner>` is the previously-broken case;
/// `tags: Vec<String>` is the no-regress primitive-elem case.
#[derive(Clone)]
pub struct Outer {
    pub items: Vec<Inner>,
    pub tags: Vec<String>,
}

pub fn make_outer() -> Result<Outer, String> {
    Ok(Outer {
        items: vec![Inner { n: 1 }, Inner { n: 2 }],
        tags: vec!["a".to_string(), "b".to_string()],
    })
}

/// NEGATIVE proof: a `Vec<NonClone>` field. `NonClone` is NOT Clone, so the
/// inspector must DROP both accessors for `bad`. There must be no
/// `bad_set_field` / `bad_field` binding — and certainly no `Vec<String>`
/// setter masquerading for it.
pub struct NonClone {
    pub x: i32,
}

pub struct Bag {
    pub bad: Vec<NonClone>,
}

pub fn make_bag() -> Result<Bag, String> {
    Ok(Bag { bad: vec![NonClone { x: 1 }] })
}
