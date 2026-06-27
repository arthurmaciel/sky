#![allow(dead_code)]
//! WALL-K (#92) crate A — the METHOD crate. Analog of async-stripe-core's
//! `impl CreateCustomer { async fn send<C: StripeClient>(&self, c: &C) -> Result<.., C::Err> }`.
//! The bound trait `Walker` is EXTERNAL to THIS crate (defined in crate B); the unique impl
//! is in a THIRD crate (C). The 3-crate triangle WALL-K must close: `T: Walker` resolves to
//! `walk_impl::Boots` via the global XC index keyed by Walker's canonical path. The `T::Err`
//! error slot (newly reachable — guardian B3) must flow through sky_error_from_foreign.
use walk_trait::Walker;
#[derive(Clone)]
pub struct Trip {
    name: String,
}
impl Trip {
    pub fn new(name: String) -> Trip {
        Trip { name }
    }
    /// Inherent async generic-Walker method — the real-stripe send shape with an EXTERNAL
    /// trait bound. `T: Walker` (external) + `T::Err` (cross-crate assoc error).
    pub async fn go<T: Walker>(&self, w: &T) -> Result<String, T::Err> {
        Ok(format!("trip:{}:{}", self.name, w.step()))
    }
}
