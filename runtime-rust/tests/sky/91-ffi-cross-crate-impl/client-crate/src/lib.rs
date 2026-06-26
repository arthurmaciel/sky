#![allow(dead_code)]

//! client-crate — the `async-stripe` facade analog for WALL-G (#84). Provides the
//! ONE concrete `RealClient` and the UNIQUE `impl Wire for RealClient`. Pairs with
//! the sibling `wire-crate` (which defines `Wire` + the `Req::op<C: Wire>` method
//! but holds no impl), exactly like the facade holds `impl StripeClient for Client`
//! while `send<C: StripeClient>` lives in client-core.

use wire_crate::Wire;

/// The unique concrete client (the `stripe::hyper::client::Client` analog). `Clone`
/// so it threads through the FFI boundary as a clone-opaque; trivially Send + Sync.
#[derive(Clone)]
pub struct RealClient;

impl RealClient {
    /// Inherent ctor — Sky mints a `RealClient` to pass into `Req::op`.
    pub fn new() -> RealClient {
        RealClient
    }
}

impl Default for RealClient {
    fn default() -> RealClient {
        RealClient::new()
    }
}

/// THE unique cross-crate impl. WALL-G's global canonical-path index keys this under
/// `wire_crate::Wire` (the same canonical path `Req::op`'s `C: Wire` bound resolves
/// to), making `op`'s `C` monomorphize to `client_crate::RealClient`.
impl Wire for RealClient {
    fn tag(&self) -> String {
        "real".to_string()
    }
}
