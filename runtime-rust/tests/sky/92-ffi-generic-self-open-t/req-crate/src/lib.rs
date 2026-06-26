#![allow(dead_code)]

//! 92-ffi-generic-self-open-t: WALL-H (#87) — generic-Self open-T `send` (the stripe
//! `CustomizableStripeRequest<T>::send<C: StripeClient>` shape, minimised).
//!
//! Mirrors async-stripe-client-core impl block 332:
//!   * `Wire` = the `StripeClient` analog — a trait with an ASSOC-TYPE Err.
//!   * `Decode` = the `miniserde::Deserialize` analog — an EXTERNAL decode bound (so the
//!     B1 canonical-path allowlist + crate-local veto are exercised; defined here, the
//!     binding `Customizable<T>` is generic over `T: Decode`).
//!   * `Customizable<T>` = `CustomizableStripeRequest<T>`, CONDITIONALLY-Send-on-T
//!     (`PhantomData<T>` — guardian B5: an unconditionally-Send Self would be a false
//!     green on the spawn's `Customizable<T>: Send` obligation).
//!   * `send<C: Wire>(self, c: &C) -> Result<T, C::Err>` — async, generic-Self (open T),
//!     generic-C (WALL-G mono), assoc-type Err. `send_blocking` — the sync sibling.
//!
//! NO concrete `Customizable<Resp>` is constructed in THIS crate — matching client-core,
//! where the concrete response only arrives via `.customize()` (WALL-I). The open T is
//! the WALL-H target: thread it through the wrapper with its `Decode` bound preserved.
//!
//! NOT an author example — a Rust-backend FFI fixture under `runtime-rust/tests/sky/`.

use std::marker::PhantomData;

/// The decode bound (miniserde::Deserialize analog). EXTERNAL-to-the-impl decode trait:
/// `Customizable<T>` is generic over `T: Decode`. Provides a from-wire ctor so `send` can
/// synthesise a `T` without a network (the fixture's stand-in for deserialization).
pub trait Decode {
    fn decode(wire: &str) -> Self;
    fn shown(&self) -> String;
}

/// The `StripeClient` analog — a trait with an ASSOC-TYPE Err (mirrors
/// `<C as StripeClient>::Err`). `: Send + Sync + 'static` so a future capturing `&C` is
/// Send (the async `send` path). Unique impl lives in the sibling client-crate.
pub trait Wire: Send + Sync + 'static {
    type Err: std::fmt::Debug;
    fn wire_tag(&self) -> String;
}

/// The blocking-client analog (sync `send_blocking`).
pub trait BlockingWire {
    type Err: std::fmt::Debug;
    fn wire_tag(&self) -> String;
}

/// `CustomizableStripeRequest<T>` analog. CONDITIONALLY-Send-on-T via `PhantomData<T>`
/// (B5). Carries the wire payload `send` decodes into a `T`.
pub struct Customizable<T> {
    wire: String,
    _pd: PhantomData<T>,
}

/// GENERIC ctor (no concrete instantiation) — keeps `T` open in the rustdoc, matching
/// client-core (the concrete `T` only arrives via the WALL-I producer). The Sky side
/// fixes `T` at the call.
impl<T: Decode> Customizable<T> {
    pub fn new(wire: String) -> Customizable<T> {
        Customizable { wire, _pd: PhantomData }
    }

    /// THE async generic-Self open-T method. `self` by value; `C: Wire` (WALL-G mono);
    /// returns `Result<T, C::Err>` (Ok = the decoded response T; Err = the assoc type).
    pub async fn send<C: Wire>(self, c: &C) -> Result<T, C::Err> {
        let _ = c.wire_tag();
        Ok(T::decode(&self.wire))
    }

    /// The sync sibling — binds as a plain Sky `Result` (no Task), `C: BlockingWire`.
    pub fn send_blocking<C: BlockingWire>(self, c: &C) -> Result<T, C::Err> {
        let _ = c.wire_tag();
        Ok(T::decode(&self.wire))
    }
}
