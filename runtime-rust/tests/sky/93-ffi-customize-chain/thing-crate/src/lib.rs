#![allow(dead_code)]

//! 93-ffi-customize-chain: WALL-I (#88) — the stripe `.customize()` PRODUCER chain that
//! makes WALL-H's `send` usable. Single crate (orphan rule + the real stripe product-crate
//! layout: resource + its `StripeRequest` impl + the response type co-locate).
//!
//! Mirrors `CreateCustomer::new(..).customize().send(&client)`:
//!   * `WireReq` = the `StripeRequest` analog — a trait with `type Output` + a PROVIDED
//!     `customize(self) -> Customizable<Self::Output>`.
//!   * `CreateThing` = the `CreateCustomer` analog — a resource request, `impl WireReq`
//!     with `type Output = Resp`. WALL-I must project `customize` onto this concrete Self
//!     (WALL-F machinery) with `Self::Output` resolved to `Resp`, yielding a CONCRETE
//!     `Customizable<Resp>` (the genuine open-T producer: T arrives via the assoc type,
//!     NOT a unique-impl T-mono).
//!   * `send` (WALL-H) binds on the resulting `Customizable<Resp>`.
//!
//! POSITIVE: CreateThing::new "seed" → customize() → Customizable<Resp> →
//!           send(&client) → Resp → "decoded:seed".
//!
//! NOT an author example — a Rust-backend FFI fixture under `runtime-rust/tests/sky/`.

use std::marker::PhantomData;

pub trait Decode {
    fn decode(wire: &str) -> Self;
    fn shown(&self) -> String;
}

/// The concrete response (the `Customer` analog). UNIQUE `Decode` impl in this crate, so a
/// `Customizable<T>`'s `T: Decode` also mono's to it — but the chain's concrete
/// `Customizable<Resp>` arrives via `customize()`'s `Self::Output`, the WALL-I path.
pub struct Resp {
    msg: String,
}

impl Resp {
    pub fn shown(&self) -> String {
        self.msg.clone()
    }
}

impl Decode for Resp {
    fn decode(wire: &str) -> Resp {
        Resp { msg: format!("decoded:{wire}") }
    }
    fn shown(&self) -> String {
        self.msg.clone()
    }
}

/// The client trait (StripeClient analog) with an assoc-type Err. Unique impl below.
pub trait Wire: Send + Sync + 'static {
    type Err: std::fmt::Debug;
    fn wire_tag(&self) -> String;
}

#[derive(Debug)]
pub struct WireErr;

/// The UNIQUE concrete client → `C: Wire` mono's to it.
#[derive(Clone)]
pub struct LocalClient;

impl LocalClient {
    pub fn new() -> LocalClient {
        LocalClient
    }
}

impl Default for LocalClient {
    fn default() -> LocalClient {
        LocalClient::new()
    }
}

impl Wire for LocalClient {
    type Err = WireErr;
    fn wire_tag(&self) -> String {
        "local".to_string()
    }
}

/// The customizable request (CustomizableStripeRequest analog). Conditionally-Send-on-T.
pub struct Customizable<T> {
    wire: String,
    _pd: PhantomData<T>,
}

impl<T: Decode> Customizable<T> {
    pub fn new(wire: String) -> Customizable<T> {
        Customizable { wire, _pd: PhantomData }
    }

    /// The async generic-Self open-T `send` (WALL-H). Binds on `Customizable<Resp>`.
    pub async fn send<C: Wire>(self, c: &C) -> Result<T, C::Err> {
        let _ = c.wire_tag();
        Ok(T::decode(&self.wire))
    }
}

/// The `StripeRequest` analog — a trait with an associated `Output` response type and a
/// PROVIDED `customize()` returning `Customizable<Self::Output>` (the stripe `.customize()`
/// producer shape). WALL-I projects this onto the concrete `CreateThing` (WALL-F) with
/// `Self::Output` resolved to `Resp`.
pub trait WireReq {
    type Output: Decode;
    fn payload(&self) -> String;
    /// PROVIDED method — body on the trait def; returns the concrete `Customizable<Output>`.
    fn customize(self) -> Customizable<Self::Output>
    where
        Self: Sized,
    {
        Customizable::new(self.payload())
    }
}

/// The resource request (CreateCustomer analog). Concrete Self for `customize`; `Output = Resp`.
pub struct CreateThing {
    seed: String,
}

impl CreateThing {
    pub fn new(seed: String) -> CreateThing {
        CreateThing { seed }
    }
}

impl WireReq for CreateThing {
    type Output = Resp;
    fn payload(&self) -> String {
        self.seed.clone()
    }
}
