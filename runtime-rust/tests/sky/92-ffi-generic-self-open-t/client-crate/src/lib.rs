#![allow(dead_code)]

//! client-crate — the async-stripe-facade analog for WALL-H (#87). The UNIQUE concrete
//! `Wire`/`BlockingWire` clients (WALL-G resolves `C: Wire` → `RealClient`), plus the
//! concrete response type `Resp` (impls req-crate's `Decode`). `Resp` is what a real
//! `T` resolves to once WALL-I's producer fixes it; here Sky fixes `T = Resp` at the call.

use req_crate::{BlockingWire, Decode, Wire};

/// The concrete error type (assoc-type Err of the clients). Debug per the foreign-error
/// boundary (guardian B8 / #83).
#[derive(Debug)]
pub struct ClientErr;

/// The UNIQUE async client (the `stripe::hyper::client::Client` analog). Unit struct →
/// trivially Send + Sync.
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

impl Wire for RealClient {
    type Err = ClientErr;
    fn wire_tag(&self) -> String {
        "real".to_string()
    }
}

/// The UNIQUE blocking client (the `stripe::hyper::blocking::Client` analog).
#[derive(Clone)]
pub struct BlockingClient;

impl BlockingClient {
    pub fn new() -> BlockingClient {
        BlockingClient
    }
}

impl Default for BlockingClient {
    fn default() -> BlockingClient {
        BlockingClient::new()
    }
}

impl BlockingWire for BlockingClient {
    type Err = ClientErr;
    fn wire_tag(&self) -> String {
        "block".to_string()
    }
}

/// The concrete response type (the per-resource `Output` analog). Sky fixes
/// `Customizable<T>`'s `T = Resp` at the `send` call. `Send + 'static` (unit-ish struct)
/// so the async `send` future is Send (guardian B4/B5).
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
