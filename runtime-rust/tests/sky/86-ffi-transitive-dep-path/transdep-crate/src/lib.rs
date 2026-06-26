//! transdep86 — the DIRECT (sky-added) crate for the WALL-B (#75) fixture.
//!
//! NOT an author example — a Rust-backend FFI test fixture (boundary rule:
//! examples/ is the author's; fixtures live under runtime-rust/tests/sky/).
//!
//! Mirrors the firebase shape: `Tag` implements TRAITS from TRANSITIVE deps. The
//! auto-FFI synthesises a UFCS wrapper per trait method into `sky_ffi_generics.rs`
//! — a crate-absolute `<Tag as ::<crate>::<Trait>>::<method>(...)` reference. The
//! generated `sky-out/rust/Cargo.toml` must therefore list each transitive crate
//! (the #75 fix), else E0433 `unresolved crate <crate>`.
//!
//! Two transitive crates exercise the two name shapes:
//!
//!   * `equivalent::Equivalent<str>` — package name == lib identifier (NO
//!     separator). Wrapper: `<Tag as ::equivalent::Equivalent<str>>::equivalent`.
//!     Cargo.toml gains `equivalent = "=<ver>"`.
//!
//!   * `is_even::IsEven` — the DECISIVE WALL-B case: lib identifier `is_even`
//!     (UNDERSCORE) but crates.io package name `is-even` (HYPHEN). Wrapper:
//!     `<Tag as ::is_even::IsEven>::is_even`. Cargo.toml MUST gain the canonical
//!     `is-even = "=1.0.0"` (HYPHEN key + EXACT version from `cargo metadata`),
//!     NOT a `_`→`-` guess, NOT `"*"`. `is_even(&self) -> bool` is a clean
//!     primitive return (no widening/future/private-path wall).
//!
//! Post-#75 the Cargo.toml gains both transitive crates (canonical name + exact
//! version, sourced from the inspector's `cargo metadata` map) and the project
//! cargo-compiles.

use equivalent::Equivalent;
use is_even::IsEven;

/// A simple opaque tag wrapping a key string + a count. Returned by value from
/// its ctor; implements the two transitive crates' traits so a UFCS wrapper is
/// synthesised per trait method. `Clone` so the Sky program can probe it more
/// than once (the auto-FFI clones a by-value receiver per call site).
#[derive(Clone)]
pub struct Tag {
    key: String,
    count: i64,
}

impl Tag {
    /// Opaque ctor — returns the handle by value. `count` seeds the `IsEven`
    /// probe (the Sky test passes an even seed and asserts `is_even == true`).
    pub fn new(key: &str, count: i64) -> Tag {
        Tag { key: key.to_string(), count }
    }
}

/// Implement `equivalent`'s `Equivalent<str>` trait (NO-separator crate name).
/// Wrapper: `<Tag as ::equivalent::Equivalent<str>>::equivalent(&self, &other)`.
/// The probe param is `&str` (Sky `String` → Rust `String`, which is
/// `AsRef<str>` for the wrapper's borrow). Returns whether the key equals it.
impl Equivalent<str> for Tag {
    fn equivalent(&self, other: &str) -> bool {
        self.key == other
    }
}

/// Implement `is-even`'s `IsEven` trait (HYPHEN crate name `is-even`, lib
/// identifier `is_even`). Wrapper: `<Tag as ::is_even::IsEven>::is_even(&self)`.
/// This is the WALL-B decisive reference: the generated Cargo.toml dep KEY must
/// be the canonical HYPHEN package name `is-even` (with the exact locked version),
/// resolved from the inspector's `cargo metadata`. Returns whether `count` is even.
impl IsEven for Tag {
    fn is_even(&self) -> bool {
        self.count.is_even()
    }
}
