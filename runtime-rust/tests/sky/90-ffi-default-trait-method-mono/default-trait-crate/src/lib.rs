#![allow(dead_code)]

//! 90-ffi-default-trait-method-mono: Sky WALL-F (#81) — the firebase
//! `FirebaseAuthService` shape, minimised. A trait with DEFAULT-body RPITIT async
//! methods, impl'd for a GENERIC Self whose param is bounded by a UNIQUE-impl
//! crate-local trait, plus an inherent ctor returning the CONCRETE Self.
//!
//! WALL-F binds it via: (a) monomorphize the impl-generic Self `Handle<C>` →
//! `Handle<RealClient>` (the unique `impl Client for RealClient`); (b) project the
//! trait's DEFAULT methods (which live on the trait DEF, never under the impl);
//! recognise the RPITIT `-> impl Future + Send` return; prove the receiver Send via
//! the `: Send` supertrait; exempt the `Result` error slot from nameability.
//!
//! NOT an author example — a Rust-backend FFI fixture under `runtime-rust/tests/sky/`.
//!
//! POSITIVE (must BIND + cargo-compile + RUN):
//!   Handle::make() -> Handle<RealClient>                 inherent concrete ctor.
//!   <Handle<RealClient> as Svc<RealClient>>::op(&self, x: String)
//!       -> impl Future<Output = Result<String, MyErr>> + Send   DEFAULT + RPITIT.
//!       Sky surface: `Handle -> String -> Task Error String`. Returns "real:hi".
//!
//! NEGATIVE (must DROP — fail-closed, no wrapper):
//!   op_nosend  — RPITIT WITHOUT `+ Send` → `async-future-not-send`.
//!   op_extra   — a default method with `where C: Extra` and `RealClient: !Extra`
//!                → `trait-method-default-where-unsatisfied` (invariant A).
//!   op_count   — a default method with a `usize` param the parametric wrapper
//!                can't coerce → fail-closed drop (the `list_users` analog).

use std::future::Future;

/// The UNIQUE-impl crate-local trait (the `ApiHttpClient` analog). `: Send + Sync`
/// so a `Handle<RealClient>` built from it is provably Send.
pub trait Client: Send + Sync + 'static {
    fn tag(&self) -> String;
}

/// The ONE concrete impl → `Client` monomorphizes to `RealClient` unambiguously.
#[derive(Clone)]
pub struct RealClient;

impl Client for RealClient {
    fn tag(&self) -> String {
        "real".to_string()
    }
}

/// A marker the concrete `RealClient` does NOT implement — drives the where-gate
/// negative (`op_extra`).
pub trait Extra {}

/// The crate-local error (the `Report` analog, but nameable). Maps to SkyError at
/// the FFI boundary via Debug/Display (the wrapper uses `{e:?}` — real errors like
/// error-stack `Report` derive Debug).
#[derive(Debug)]
pub struct MyErr;

impl std::fmt::Display for MyErr {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "my error")
    }
}

/// The generic-Self handle (the `FirebaseAuth<ApiHttpClientT>` analog).
pub struct Handle<C> {
    client: C,
}

/// Inherent ctor returning the CONCRETE `Handle<RealClient>` (the `App::auth`
/// analog — the entry the Sky user actually holds).
impl Handle<RealClient> {
    pub fn make() -> Handle<RealClient> {
        Handle { client: RealClient }
    }
}

/// The trait carrying DEFAULT-body RPITIT methods (the `FirebaseAuthService` shape).
/// `: Send + Sync` supertrait → every impl's `Self: Send` (receiver-Send proof).
pub trait Svc<C: Client>: Send + Sync + 'static {
    /// Required accessor (provided by the impl).
    fn raw(&self) -> &C;

    /// POSITIVE — the keystone DEFAULT + RPITIT method. Must project + bind on
    /// `Handle<RealClient>` and run.
    fn op(&self, x: String) -> impl Future<Output = Result<String, MyErr>> + Send {
        let t = self.raw().tag();
        async move { Ok(format!("{t}:{x}")) }
    }

    /// NEGATIVE — RPITIT WITHOUT `+ Send` → drop `async-future-not-send`.
    fn op_nosend(&self, x: String) -> impl Future<Output = Result<String, MyErr>> {
        async move { Ok(x) }
    }

    /// NEGATIVE — a `where C: Extra` bound the concrete `RealClient` does NOT
    /// satisfy → drop `trait-method-default-where-unsatisfied` (invariant A).
    fn op_extra(&self, x: String) -> impl Future<Output = Result<String, MyErr>> + Send
    where
        C: Extra,
    {
        async move { Ok(x) }
    }

    /// NEGATIVE — a `usize` param the parametric wrapper can't coerce → fail-closed
    /// drop (the `list_users` analog).
    fn op_count(&self, n: usize) -> impl Future<Output = Result<String, MyErr>> + Send {
        async move { Ok(format!("{n}")) }
    }
}

/// The GENERIC-Self trait impl. Provides ONLY the required `raw`; `op`/`op_nosend`/
/// `op_extra`/`op_count` are inherited DEFAULTS on the trait DEF.
impl<C: Client> Svc<C> for Handle<C> {
    fn raw(&self) -> &C {
        &self.client
    }
}
