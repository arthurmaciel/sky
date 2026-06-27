#![allow(dead_code)]

//! 94-ffi-inherent-self-output: WALL-J Stage 1 (#91) — isolate the inherent-method
//! `<Self as ForeignTrait>::Output` return projection (sync, non-generic, one crate).
//!
//! Mirrors the real async-stripe shape `impl CreateCustomer { fn send(&self) ->
//! <Self as StripeRequest>::Output }` + `impl StripeRequest for CreateCustomer {
//! type Output = Customer }` — minus async and the cross-crate client generic
//! (those layer on in Stages 2/3). The inherent `out` returns
//! `<Self as LocalTrait>::Output`; the inspector must resolve `Self` → the concrete
//! `Thing` and `<Thing as LocalTrait>::Output` → `Payload` via the SIBLING
//! `impl LocalTrait for Thing` block (a DIFFERENT impl than the inherent one).
//!
//! POSITIVE: Thing::new("seed").out() → Payload → "out:seed".

/// The associated-output trait (the `StripeRequest` analog). Crate-local.
pub trait LocalTrait {
    type Output;
}

/// The concrete response (the `Customer` analog).
#[derive(Clone)]
pub struct Payload {
    msg: String,
}

impl Payload {
    pub fn shown(&self) -> String {
        self.msg.clone()
    }
}

/// The request/resource (the `CreateCustomer` analog). Concrete Self for `out`.
#[derive(Clone)]
pub struct Thing {
    seed: String,
}

impl Thing {
    pub fn new(seed: String) -> Thing {
        Thing { seed }
    }

    /// INHERENT, sync, non-generic — returns `<Self as LocalTrait>::Output`. The
    /// projection resolves to `Payload` ONLY via the sibling `impl LocalTrait for
    /// Thing` below. WALL-J must (a) resolve `Self` → `Thing`, (b) read the sibling
    /// impl's `type Output = Payload`.
    pub fn out(&self) -> <Self as LocalTrait>::Output {
        Payload { msg: format!("out:{}", self.seed) }
    }
}

/// The SIBLING trait impl — a DIFFERENT block from the inherent `impl Thing`. Its
/// `type Output = Payload` is what `<Self as LocalTrait>::Output` must resolve to.
impl LocalTrait for Thing {
    type Output = Payload;
}
