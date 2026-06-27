#![allow(dead_code)]
//! WALL-K (#92) crate C — the UNIQUE concrete impl of the external `Walker` trait.
//! Analog of the async-stripe FACADE's `impl StripeClient for Client`. The impl block
//! + the concrete `Boots` Self are crate-local; the trait is EXTERNAL (crate B). WALL-G's
//! mirror keys this into the global XC index by Walker's canonical path; WALL-K resolves
//! a `T: Walker` bound in the method crate (A) to `Boots` via that key.
use walk_trait::Walker;
#[derive(Debug)]
pub struct BootErr;
#[derive(Clone)]
pub struct Boots;
impl Boots {
    pub fn new() -> Boots { Boots }
}
impl Default for Boots {
    fn default() -> Boots { Boots::new() }
}
impl Walker for Boots {
    type Err = BootErr;
    fn step(&self) -> String { "boots".to_string() }
}
