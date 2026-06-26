#![allow(dead_code, unused_imports, async_fn_in_trait)]

//! 83-ffi-mixed-generic-turbofish: Sky WALL 4 stretch (#72) — a method with TWO
//! generics where EACH is reduced/monomorphised by a DIFFERENT mechanism, so the
//! UFCS method-level turbofish must name a concrete for EVERY generic in
//! declaration order, not just the serde one.
//!
//! The exact firestore `FirestoreCrudSupport::get_obj` shape:
//!
//!   fn get_obj<T: DeserializeOwned + Send, S: AsRef<str> + Send>(
//!       &self, id: S) -> Result<T, String>
//!
//!   * T  — DeserializeOwned (serde)  → WALL-3a (#59) reduced to serde_json::Value
//!   * S  — AsRef<str>       (string) → WALL-2  (#58) mono'd to String
//!
//! BOTH are removed from the Sky-visible generic `order`, so the wrapper's path
//! `type_args` is empty.  But the Rust method STILL declares `<T, S>`, so the
//! method-level turbofish must be `::<serde_json::Value, String>` — a concrete
//! per generic in DECLARATION ORDER.  Pre-#72 the emitter hardcoded a single
//! `::<serde_json::Value>` → `E0107 method takes 2 generic arguments but 1 was
//! supplied`.
//!
//! Every method is a CONCRETE-Self TRAIT method so it routes through the
//! parametric/UFCS stub path (where the turbofish lives) — NOT the inherent
//! monomorphic `parse_fn_item` path (a separate mechanism, out of #72 scope).
//!
//! NOT an author example — a Rust-backend FFI test fixture.  Lives under
//! `runtime-rust/tests/sky/` per the boundary rule (examples/ is the author's).
//!
//! POSITIVE (must BIND + the wrapper must cargo-COMPILE — the E0107 gone):
//!   Db::new()                                          inherent ctor → opaque
//!   <Db as Repo>::get_obj<T: DeserializeOwned + Send, S: AsRef<str> + Send>(
//!       &self, id: S) -> Result<T, String>
//!       async-trait desugar + T→Value (serde return) + S→String (AsRef id).
//!       Sky surface: `Db -> String -> Task Error String` (id: String, JSON out).
//!   <Db as Repo>::pick<A: Serialize + Send, B: AsRef<str> + Send,
//!                      C: DeserializeOwned + Send>(&self, key: B, payload: A)
//!       -> Result<C, String>
//!       THREE-generic control (serde-in + AsRef + serde-out) → the turbofish
//!       must name THREE concretes in order: `::<serde_json::Value, String,
//!       serde_json::Value>`.
//!   <Db as SyncRepo>::get_obj_sync<T: DeserializeOwned, S: AsRef<str>>(
//!       &self, id: S) -> Result<T, String>
//!       SYNC concrete-Self trait control — same two-mechanism mix, no
//!       async-trait. Proves the turbofish fix is independent of the async path.

use async_trait::async_trait;
use serde::de::DeserializeOwned;
use serde::Serialize;

/// POSITIVE: the opaque handle.  `Clone + Send + Sync` (firestore `FirestoreDb`
/// is too) so the async receiver Send gate (C1c) proves Send.
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

/// POSITIVE: the `#[async_trait]` trait (the firestore CRUD shape).
#[async_trait]
pub trait Repo {
    /// The firestore `get_obj` keystone — TWO generics, each reduced by a
    /// DIFFERENT mechanism.  `#[async_trait]`-desugared → recognise the future
    /// box, force is_async, AND emit `::<serde_json::Value, String>`.
    async fn get_obj<T: DeserializeOwned + Send, S: AsRef<str> + Send>(
        &self,
        id: S,
    ) -> Result<T, String>;

    /// THREE-generic control: a Serialize INPUT (A→Value), an AsRef key
    /// (B→String), AND a DeserializeOwned OUTPUT (C→Value).  The turbofish must
    /// name THREE concretes in declaration order.
    async fn pick<A: Serialize + Send, B: AsRef<str> + Send, C: DeserializeOwned + Send>(
        &self,
        key: B,
        payload: A,
    ) -> Result<C, String>;
}

/// POSITIVE: a PLAIN (non-async) concrete-Self trait — the SYNC control. Routes
/// through the SAME parametric/UFCS path as the async trait above (a concrete-Self
/// trait method is `take_parametric`), so it exercises the turbofish fix on the
/// sync arm.
pub trait SyncRepo {
    /// SYNC two-mechanism mix: `T: DeserializeOwned` (serde → Value) AND
    /// `S: AsRef<str>` (mono → String). serde-FIRST decl order.
    fn get_obj_sync<T: DeserializeOwned, S: AsRef<str>>(&self, id: S) -> Result<T, String>;

    /// MONO-FIRST decl order: `S: AsRef<str>` (mono → String) declared BEFORE
    /// `T: DeserializeOwned` (serde → Value). The turbofish MUST be
    /// `::<String, serde_json::Value>` (declaration order), NOT serde-always-first
    /// `::<serde_json::Value, String>`. Discriminates decl-order from a
    /// transposition/sort bug (guardian-required coverage).
    fn get_rev<S: AsRef<str>, T: DeserializeOwned>(&self, id: S) -> Result<T, String>;
}

#[async_trait]
impl Repo for Db {
    async fn get_obj<T: DeserializeOwned + Send, S: AsRef<str> + Send>(
        &self,
        id: S,
    ) -> Result<T, String> {
        // Build a tiny JSON object keyed on the id, deserialise to T; the wrapper
        // re-serialises to the Sky JSON String the caller decodes.
        let json = format!("{{\"id\":{:?}}}", id.as_ref());
        serde_json::from_str::<T>(&json).map_err(|e| format!("{e:?}"))
    }

    async fn pick<A: Serialize + Send, B: AsRef<str> + Send, C: DeserializeOwned + Send>(
        &self,
        key: B,
        payload: A,
    ) -> Result<C, String> {
        let payload_json = serde_json::to_string(&payload).map_err(|e| format!("{e:?}"))?;
        let json = format!("{{\"key\":{:?},\"payload\":{}}}", key.as_ref(), payload_json);
        serde_json::from_str::<C>(&json).map_err(|e| format!("{e:?}"))
    }
}

impl SyncRepo for Db {
    fn get_obj_sync<T: DeserializeOwned, S: AsRef<str>>(&self, id: S) -> Result<T, String> {
        let json = format!("{{\"id\":{:?}}}", id.as_ref());
        serde_json::from_str::<T>(&json).map_err(|e| format!("{e:?}"))
    }

    fn get_rev<S: AsRef<str>, T: DeserializeOwned>(&self, id: S) -> Result<T, String> {
        let json = format!("{{\"id\":{:?}}}", id.as_ref());
        serde_json::from_str::<T>(&json).map_err(|e| format!("{e:?}"))
    }
}
