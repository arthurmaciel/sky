//! 87-ffi-private-module-path: WALL-C fixture for Sky #76.
//!
//! NOT an author example — a Rust-backend FFI test fixture (lives under
//! runtime-rust/tests/sky/ per the boundary; examples/ is the author's).
//!
//! Reproduces the E0603 `module X is private` class: rustdoc's `doc["paths"]`
//! records a type's DEFINITION path through PRIVATE internal modules, and the
//! inspector emitted that verbatim. cargo then rejects the private segments.
//!
//! Confirmed firebase shapes mirrored here:
//!   * `std::collections::HashMap`  — rustdoc def path `std::collections::hash::
//!     map::HashMap` (private `hash::map`). Public re-export: `std::collections::
//!     HashMap`.
//!   * `http::HeaderMap`            — rustdoc def path `http::header::map::
//!     HeaderMap` (private `header::map`). Public re-export: `http::HeaderMap`.
//!   * `http::Extensions`           — rustdoc def path `http::extensions::
//!     Extensions` (private `extensions`). Public re-export: `http::Extensions`.
//!
//! Each free fn returns the offending type by value. The generated wrapper must
//! emit the PUBLIC path (no private-module segment) → cargo-clean (no E0603).
//! For external NON-std crates whose public re-export the inspector cannot
//! resolve without the dep's own rustdoc, the wrapper is FAIL-CLOSED DROPPED
//! (a dropped wrapper is sound; a private-module-path emission is NOT).

use std::collections::HashMap;

/// STD case. rustdoc def path runs through the private `hash::map` module; the
/// wrapper must emit `std::collections::HashMap` (or drop), never the private
/// `std::collections::hash::map::HashMap` form. Returns an opaque-to-Sky value.
pub fn make_map() -> HashMap<String, String> {
    let mut m = HashMap::new();
    m.insert("k".to_string(), "v".to_string());
    m
}

/// STD case via the OPAQUE-RECEIVER method-param position — this is the path
/// that routes through `type_to_typeref`'s `resolved_path` arm (NOT the
/// free-fn container Dict-detour). `Store` is an opaque handle; `.merge` takes a
/// `HashMap<String,String>` by value. The wrapper sig for that param renders the
/// EXTERNAL type's full path from `doc["paths"]` (the rustdoc DEFINITION path
/// `std::collections::hash::map::HashMap`, through the PRIVATE `hash::map`
/// module). Pre-fix → `::std::collections::hash::map::HashMap<String,String>` →
/// cargo E0603. The fix normalizes to the PUBLIC `::std::collections::HashMap`.
pub struct Store {
    n: i64,
}

impl Store {
    pub fn new() -> Store {
        Store { n: 0 }
    }

    /// Opaque-receiver method taking a HashMap by value → forces the Ctor render
    /// of the external `HashMap` type in the wrapper sig.
    pub fn merge(&self, extra: HashMap<String, String>) -> i64 {
        self.n + extra.len() as i64
    }
}

impl Default for Store {
    fn default() -> Self {
        Store::new()
    }
}

/// http NON-std case: `HeaderMap` def path runs through private `header::map`.
pub fn make_headers() -> http::HeaderMap {
    http::HeaderMap::new()
}

/// http NON-std case: `Extensions` def path runs through private `extensions`.
pub fn make_extensions() -> http::Extensions {
    http::Extensions::new()
}
