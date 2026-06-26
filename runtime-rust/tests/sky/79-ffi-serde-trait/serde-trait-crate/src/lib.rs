#![allow(dead_code, unused_imports, async_fn_in_trait)]

//! 79-ffi-serde-trait: Sky WALL 3a (#59) — serde Serialize/DeserializeOwned
//! composes with the concrete-Self TRAIT-method (UFCS / parametric-stub) path,
//! AND with async (the actual firestore `FirestoreDb::get_obj` / `create_obj`
//! shape).
//!
//! NOT an author example — a Rust-backend FFI test fixture.  Lives under
//! `runtime-rust/tests/sky/` per the boundary rule (examples/ is the author's).
//!
//! POSITIVE (must BIND end-to-end, async serde round-trip):
//!   Db::new()                       inherent ctor → opaque handle
//!   <Db as Repo>::get_obj<T: DeserializeOwned + Send>(&self) -> Result<T,String>
//!       T appears only in the owned Ok return → admissible → reduce T = Value
//!       → Sky surface returns a JSON String.
//!   <Db as Repo>::put_obj<T: Serialize + Send>(&self, v: T) -> Result<(),String>
//!       T appears only as a by-value param → admissible → reduce T = Value
//!       → Sky surface takes a JSON String.
//!   Db::get_inherent<T: DeserializeOwned>(&self) -> T   (CONTROL — #47 inherent path)
//!
//! NEGATIVE (must DROP — absent from bindings, crate MUST still compile):
//!   <Db as Repo>::bad_ref<T: Serialize + Send>(&self, v: &T)
//!       &T (borrow) → census INADMISSIBLE → DROP.
//!   <Db as Repo>::bad_local<T: Serialize + Local + Send>(&self, v: T)
//!       sibling crate-local unmodellable bound (`Local`) → not all-serde → the
//!       param stays a tyvar → BoundCrossImpl / classify DROPS the whole method.

use serde::de::DeserializeOwned;
use serde::Serialize;

/// Crate-local marker trait — an UNMODELLABLE sibling bound for the negative.
pub trait Local {}

/// POSITIVE: the opaque handle.  Holds a single `u8`; Send + Sync trivially.
/// Clone (firestore `FirestoreDb` is Clone too) so the Sky runtime can thread it
/// into more than one trait-method call (`put_obj` then `get_obj`).
#[derive(Clone)]
pub struct Db {
    _tag: u8,
}

impl Db {
    /// Inherent ctor — an opaque foreign receiver needs a producer.
    pub fn new() -> Db {
        Db { _tag: 0 }
    }

    /// CONTROL (#47 inherent serde): serde-bound generic RETURN on an INHERENT
    /// (SYNC) method.  Must bind via the existing inherent reduction — proves
    /// the trait-path extension does not regress the #47 inherent arm.
    pub fn get_inherent<T: DeserializeOwned>(&self) -> T {
        serde_json::from_str("{\"inherent\":true}")
            .unwrap_or_else(|_| serde_json::from_str("null").unwrap())
    }
}

/// POSITIVE: the async serde trait (the firestore shape).
pub trait Repo {
    /// T only in the owned Ok return → admissible → reduce → JSON String.
    async fn get_obj<T: DeserializeOwned + Send>(&self) -> Result<T, String>;

    /// T only as a by-value param → admissible → reduce → JSON String in.
    async fn put_obj<T: Serialize + Send>(&self, v: T) -> Result<(), String>;

    /// NEGATIVE: &T param → census INADMISSIBLE → DROP.
    async fn bad_ref<T: Serialize + Send>(&self, v: &T) -> Result<(), String>;

    /// NEGATIVE: sibling crate-local unmodellable bound → not all-serde → DROP.
    async fn bad_local<T: Serialize + Local + Send>(&self, v: T) -> Result<(), String>;
}

impl Repo for Db {
    async fn get_obj<T: DeserializeOwned + Send>(&self) -> Result<T, String> {
        // Deserialise a fixed JSON object into the caller's T (= Value after the
        // Sky reduction); the Sky side re-serialises it to a JSON String.
        serde_json::from_str("{\"k\":1}").map_err(|e| format!("{e:?}"))
    }

    async fn put_obj<T: Serialize + Send>(&self, v: T) -> Result<(), String> {
        // Round-trips through serde to PROVE v deserialised correctly on the way
        // in (the Sky String → Value boundary); body is otherwise trivial.
        let _ = serde_json::to_string(&v).map_err(|e| format!("{e:?}"))?;
        Ok(())
    }

    async fn bad_ref<T: Serialize + Send>(&self, _v: &T) -> Result<(), String> {
        Ok(())
    }

    async fn bad_local<T: Serialize + Local + Send>(&self, _v: T) -> Result<(), String> {
        Ok(())
    }
}
