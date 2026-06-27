#![allow(dead_code)]
//! WALL-K (#92) crate B — the EXTERNAL trait. Analog of stripe_client_core::StripeClient.
//! A transitive dep of BOTH the method crate (A) and the impl crate (C); it is NOT in
//! the inspector --manifest (which carries only A + C), mirroring the real stripe triangle.
use std::fmt::Debug;
pub trait Walker: Send + Sync + 'static {
    type Err: Debug;
    fn step(&self) -> String;
}
