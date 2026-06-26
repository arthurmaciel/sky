#![allow(dead_code)]

//! 89-ffi-static-str-into: Sky WALL-E (#78) — a method param bounded by
//! `Into<&'static str>` is UNSATISFIABLE from a runtime-owned Sky value. A
//! `String` can LEND a borrow (`AsRef<str>`) but can NEVER BECOME a
//! `&'static str` by value — the only `T: Into<&'static str>` is `&'static str`
//! itself, which can't be minted from a runtime owned value. So the inspector
//! must FAIL-CLOSED DROP such a method (emit NO wrapper).
//!
//! Pre-WALL-E `concrete_for_inner_type` saw through `&'static str` → `str` →
//! `String`, so `bound_to_concrete` mono'd `P → String` and the codegen emitted
//! `arg0.build(&arg1)` (arg1: String) → `E0277: &'static str: From<&String>`
//! (the EXACT firebase `ApiUriBuilder::build<PathT: Into<&'static str>>` shape).
//! The fix gates the `Into`/`From` arm: a borrowed-reference target drops.
//!
//! NOT an author example — a Rust-backend FFI test fixture. Lives under
//! `runtime-rust/tests/sky/` per the boundary rule (examples/ is the author's).
//!
//! NEGATIVE (must NOT bind — no `build_from_router` wrapper):
//!   Router::build<P: Into<&'static str>>(&self, path: P) -> String
//!       unsatisfiable from a runtime String → fail-closed drop (the E0277 gone).
//!
//! POSITIVE controls (must BIND + cargo-compile + run — proves no over-drop;
//! AsRef/Into<owned> keep their existing #58/#67 resolution):
//!   Router::new(base: String) -> Router                 owned-String ctor (#67).
//!   Router::tag<S: AsRef<str>>(&self, s: S) -> String   AsRef<str> → String (#58).
//!   Router::label<S: Into<String>>(&self, s: S) -> String
//!       Into<String> — an OWNED target. `String: Into<String>` holds (identity),
//!       so substituting String IS sound — this MUST keep binding. It is the
//!       discriminating control: WALL-E drops Into<&'static str> (borrowed) but
//!       NOT Into<String> (owned).

pub struct Router {
    base: String,
}

impl Router {
    /// POSITIVE — owned `String` ctor (the opaque producer). By-value (#67).
    pub fn new(base: String) -> Router {
        Router { base }
    }

    /// NEGATIVE — the WALL-E target. `P: Into<&'static str>` can never be
    /// satisfied by a runtime Sky `String`; the wrapper must be DROPPED.
    pub fn build<P: Into<&'static str>>(&self, path: P) -> String {
        format!("{}/{}", self.base, path.into())
    }

    /// POSITIVE control — `AsRef<str>` mono's to `String` (#58). Binds + works.
    pub fn tag<S: AsRef<str>>(&self, s: S) -> String {
        format!("{}#{}", self.base, s.as_ref())
    }

    /// POSITIVE control — `Into<String>` (OWNED target) mono's to `String`.
    /// Binds + works. Discriminates owned-Into (sound) from borrowed-Into (dropped).
    pub fn label<S: Into<String>>(&self, s: S) -> String {
        let l: String = s.into();
        format!("{}@{}", self.base, l)
    }
}
