#![allow(dead_code, unused_imports, async_fn_in_trait)]

//! 81-ffi-serde-ref: Sky WALL 3a-&I (#65) — extend the WALL-3a (#59) serde-mono
//! to ALSO admit a `&T` SERIALIZE (INPUT) param via owned-clone-at-boundary.
//!
//! The firestore shape: `create_obj<T: Serialize>(&self, obj: &T)` /
//! `update_obj<T: Serialize>(&self, obj: &T)`.  WALL-3a (#59, shipped) admits a
//! serde param ONLY in OWNED positions (by-value / owned-return / inside
//! Result/Vec/Option); the census marks `&T` INADMISSIBLE.  This wall extends
//! the census to admit a NON-MUT `&T` SERIALIZE INPUT: the wrapper deserialises
//! the Sky JSON String → an OWNED `serde_json::Value` local (`sv_j`) and passes
//! `&sv_j` (a reference to the owned local — lives for the call, sound).
//!
//! NOT an author example — a Rust-backend FFI test fixture.  Lives under
//! `runtime-rust/tests/sky/` per the boundary rule.
//!
//! POSITIVE (must BIND end-to-end, async serde-ref + owned control):
//!   Db::new()                                    inherent ctor → opaque handle
//!   <Db as Repo>::create_obj<T: Serialize + Send + Sync>(&self, obj: &T)
//!       &T Serialize INPUT → NEW admission → reduce T = Value → wrapper takes a
//!       Sky JSON String, passes `&sv_j` to the host.
//!   <Db as Repo>::put_obj<T: Serialize + Send>(&self, obj: T)
//!       OWNED control (WALL-3a #59 by-value param path — must still bind).
//!
//! NEGATIVE (must DROP — absent from bindings, crate MUST still compile):
//!   <Db as Repo>::bad_mutref<T: Serialize + Send>(&self, o: &mut T)
//!       &mut T → census STAYS inadmissible → DROP (can't hand a Sky String as a
//!       mutable borrow of a to-be-serialised value; the host could mutate it).
//!   <Db as Repo>::bad_local<T: Serialize + Local + Send>(&self, o: &T)
//!       sibling crate-local unmodellable bound (`Local`) → not all-serde → the
//!       param stays a tyvar → BoundCrossImpl / classify DROPS the method.

use serde::de::DeserializeOwned;
use serde::Serialize;

/// Crate-local marker trait — an UNMODELLABLE sibling bound for the negative.
pub trait Local {}

/// POSITIVE: the opaque handle.  Holds a single `u8`; Send + Sync trivially.
/// Clone so the Sky runtime can thread it into more than one trait-method call.
#[derive(Clone)]
pub struct Db {
    _tag: u8,
}

impl Db {
    /// Inherent ctor — an opaque foreign receiver needs a producer.
    pub fn new() -> Db {
        Db { _tag: 0 }
    }
}

/// POSITIVE: the async serde trait (the firestore `create_obj`/`update_obj`
/// shape — a `&T: Serialize` INPUT).
pub trait Repo {
    /// &T Serialize INPUT → NEW WALL 3a-&I admission → reduce → JSON String in.
    /// (firestore `create_obj<T: Serialize>(&self, obj: &T)`.)
    async fn create_obj<T: Serialize + Send + Sync>(&self, obj: &T) -> Result<(), String>;

    /// OWNED CONTROL: by-value Serialize param (WALL-3a #59 path — still binds).
    async fn put_obj<T: Serialize + Send>(&self, obj: T) -> Result<(), String>;

    /// NEGATIVE: &mut T → census STAYS inadmissible → DROP.
    async fn bad_mutref<T: Serialize + Send>(&self, o: &mut T) -> Result<(), String>;

    /// NEGATIVE: sibling crate-local unmodellable bound → not all-serde → DROP.
    async fn bad_local<T: Serialize + Local + Send>(&self, o: &T) -> Result<(), String>;
}

impl Repo for Db {
    async fn create_obj<T: Serialize + Send + Sync>(&self, obj: &T) -> Result<(), String> {
        // Round-trips through serde to PROVE obj deserialised correctly on the
        // way in (the Sky String → Value → &Value boundary); body trivial.
        let _ = serde_json::to_string(obj).map_err(|e| format!("{e:?}"))?;
        Ok(())
    }

    async fn put_obj<T: Serialize + Send>(&self, obj: T) -> Result<(), String> {
        let _ = serde_json::to_string(&obj).map_err(|e| format!("{e:?}"))?;
        Ok(())
    }

    async fn bad_mutref<T: Serialize + Send>(&self, _o: &mut T) -> Result<(), String> {
        Ok(())
    }

    async fn bad_local<T: Serialize + Local + Send>(&self, _o: &T) -> Result<(), String> {
        Ok(())
    }
}
