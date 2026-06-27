#![allow(dead_code)]

//! 95-ffi-inherent-self-output-async: WALL-J Stage 2+3 (#91) — the real async-stripe
//! `send` shape, single-crate. Mirrors `impl CreateCustomer { async fn send<C:
//! StripeClient>(&self, c: &C) -> Result<<Self as StripeRequest>::Output, C::Err> }`
//! + `impl StripeRequest for CreateCustomer { type Output = Customer }`, but with the
//! client trait UNIQUELY impl'd IN-crate so `C` resolves via the #52 unique-impl
//! monomorphizer (the cross-crate case = Stage 4, real stripe, via --manifest+WALL-G).
//!
//! Exercises the FULL composition: WALL-J Self::Output projection (Ok payload) +
//! de-async + async→sync bridge + #52 `C: LocalClient` mono + the `C::Err` error
//! slot (→ SkyError, B1) + `&self` async-Send. POSITIVE: send runs "sent:seed".

use std::fmt::Debug;

/// The client trait (StripeClient analog) with an assoc `Err`. Unique impl below.
pub trait LocalClient: Send + Sync + 'static {
    type Err: Debug;
    fn tag(&self) -> String;
}

#[derive(Debug)]
pub struct ClientErr;

/// The UNIQUE concrete client → `C: LocalClient` mono's to it (#52).
#[derive(Clone)]
pub struct RealClient;

impl RealClient {
    pub fn new() -> RealClient {
        RealClient
    }
}

impl Default for RealClient {
    fn default() -> RealClient {
        RealClient::new()
    }
}

impl LocalClient for RealClient {
    type Err = ClientErr;
    fn tag(&self) -> String {
        "real".to_string()
    }
}

/// The request trait (StripeRequest analog) — associated `Output` response type.
pub trait Req {
    type Output;
}

/// The concrete response (Customer analog).
#[derive(Clone)]
pub struct Resp {
    msg: String,
}

impl Resp {
    pub fn shown(&self) -> String {
        self.msg.clone()
    }
}

/// The request/resource (CreateCustomer analog). Concrete Self for `send`.
#[derive(Clone)]
pub struct CreateReq {
    seed: String,
}

impl CreateReq {
    pub fn new(seed: String) -> CreateReq {
        CreateReq { seed }
    }

    /// INHERENT async generic-client `send` — the exact real-stripe shape:
    /// `async fn send<C: Client>(&self, c: &C) -> Result<<Self as Req>::Output, C::Err>`.
    /// WALL-J resolves `<Self as Req>::Output` → `Resp` (Ok payload); #52 monomorphizes
    /// `C` → `RealClient`; `C::Err` → SkyError; `&self` owned-copy + async-Send.
    pub async fn send<C: LocalClient>(&self, c: &C) -> Result<<Self as Req>::Output, C::Err> {
        let _ = c.tag();
        Ok(Resp { msg: format!("sent:{}", self.seed) })
    }
}

impl Req for CreateReq {
    type Output = Resp;
}
