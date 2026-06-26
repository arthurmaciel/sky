#![allow(dead_code)]

//! 91-ffi-cross-crate-impl: Sky WALL-G (#84) — the stripe `send<C: StripeClient>`
//! shape, minimised to isolate the CROSS-CRATE concrete-impl monomorphization.
//!
//! This crate (`wire-crate`, the `async-stripe-client-core` analog) DEFINES the
//! `Wire` trait and a concrete `Req` carrying `fn op<C: Wire>(&self, c: &C)`. It has
//! **ZERO `impl Wire for _`** of its own — exactly like client-core defines
//! `StripeClient` + `send` but holds no concrete client. The unique
//! `impl Wire for RealClient` lives in the SIBLING `client-crate` (the
//! `async-stripe` facade analog).
//!
//! NOT an author example — a Rust-backend FFI fixture under `runtime-rust/tests/sky/`.
//!
//! POSITIVE (must BIND + cargo-compile + RUN, once WALL-G lands):
//!   Req::new(String) -> Req                            inherent concrete ctor.
//!   Req::op<C: Wire>(&self, c: &C) -> String           the cross-crate-param method.
//!     The `C: Wire` bound has NO impl in this crate; WALL-G resolves it to the
//!     UNIQUE cross-crate `impl Wire for RealClient` (in client-crate) and emits a
//!     wrapper referencing `client_crate::RealClient`.
//!     Sky surface: `Req -> RealClient -> String`. Returns "<tag>:<name>" = "real:hi".
//!
//! PRE-WALL-G (the RED state this fixture asserts against): `op` drops as
//! `trait-bounded-param-ambiguous` (0 in-crate impls) → no `op` wrapper → the Sky
//! call to it is an unknown binding → `sky build` fails.

/// The cross-crate trait (the `StripeClient` analog). `: Send + Sync + 'static` so a
/// future capturing a `&RealClient` is provably Send (keeps the eventual async
/// `send` path — WALL-H — unblocked; here `op` is sync to isolate WALL-G).
pub trait Wire: Send + Sync + 'static {
    fn tag(&self) -> String;
}

/// The concrete request type (the `CustomizableStripeRequest` analog, but NON-generic
/// — generic-Self is WALL-H). Carries a payload the method threads back out.
pub struct Req {
    name: String,
}

impl Req {
    /// Inherent concrete ctor — binds today via the ordinary path.
    pub fn new(name: String) -> Req {
        Req { name }
    }

    /// THE cross-crate-param method. `C: Wire` is bounded by a trait this crate
    /// defines but never impls; the unique impl is in `client-crate`. WALL-G must
    /// monomorphize `C` to that cross-crate concrete and reference its public path.
    pub fn op<C: Wire>(&self, c: &C) -> String {
        format!("{}:{}", c.tag(), self.name)
    }
}
