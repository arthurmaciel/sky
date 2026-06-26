#![allow(dead_code, unused_imports)]

//! 82-ffi-async-trait: Sky WALL 4 (#64) — recognise the `#[async_trait]` proc-
//! macro desugar and route it through the existing #44 async→Task machinery.
//!
//! UNLIKE 79/81 (which use the NATIVE `async fn` in trait — `header.is_async =
//! true`, already bound), this crate uses the `#[async_trait]` PROC-MACRO. The
//! macro rewrites every `async fn m(..) -> T` into a PLAIN (non-async)
//! `fn m(..) -> Pin<Box<dyn Future<Output = T> + Send + 'async_trait>>`. The
//! rustdoc `header.is_async` is therefore `false` and the return is a `dyn_trait`
//! object — pre-WALL-4 BOTH the #26 dyn-trait gate AND the parametric path's
//! `type_to_typeref` dropped it (`not-bindable: dyn_trait`). This is the actual
//! firestore CRUD shape (`FirestoreCrudSupport::create_obj` / `get_obj` / …),
//! which firestore desugars via `#[async_trait]`.
//!
//! NOT an author example — a Rust-backend FFI test fixture.  Lives under
//! `runtime-rust/tests/sky/` per the boundary rule (examples/ is the author's).
//!
//! POSITIVE (must BIND end-to-end as `Task`):
//!   Db::new()                                          inherent ctor → opaque
//!   <Db as Repo>::op(&self, x: String) -> Result<i64,String>
//!       #[async_trait]-desugared → recognise the future box, extract
//!       Output=Result<i64,String>, force is_async → Task String Int.
//!   <Db as Repo>::put<T: Serialize + Send + Sync>(&self, obj: &T) -> Result<(),String>
//!       PROVES the keystone COMPOSES with #65 serde-&I: the desugar lifts the
//!       async box AND the `&T` Serialize INPUT reduces to a Sky JSON String.
//!
//! NEGATIVE (must DROP — absent from bindings, crate MUST still compile):
//!   <Db as Repo>::non_future(&self) -> Pin<Box<dyn SomeOtherTrait + Send>>
//!       principal trait is NOT core::future::Future → stays the dyn-trait drop.
//!   <Db as Repo>::not_send(&self) -> Pin<Box<dyn Future<Output=i64>>>  (no Send)
//!       a Future WITHOUT +Send → drop `async-future-not-send` (a multi-thread
//!       tokio Task spawn needs `Output: Send`; binding it would be E0277).

use async_trait::async_trait;
use serde::Serialize;
use std::future::Future;
use std::pin::Pin;

/// A crate-local NON-Future trait for Negative A — a genuine `dyn Trait` object
/// that must STAY dropped (its principal trait is not `core::future::Future`).
pub trait SomeOtherTrait: Send {
    fn tag(&self) -> i64;
}

/// POSITIVE: the opaque handle.  `Clone + Send + Sync` (firestore `FirestoreDb`
/// is too) so the async receiver Send gate (C1c) proves Send and the runtime can
/// thread it into more than one trait-method call.
#[derive(Clone)]
pub struct Db {
    _tag: u8,
}

impl SomeOtherTrait for Db {
    fn tag(&self) -> i64 {
        self._tag as i64
    }
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
    /// Plain async method → desugars to `-> Pin<Box<dyn Future<Output =
    /// Result<i64,String>> + Send + 'async_trait>>`.  Must bind as `Task String Int`.
    async fn op(&self, x: String) -> Result<i64, String>;

    /// COMPOSITION proof: #65 `&T` serde INPUT + the async-trait desugar together.
    /// Desugars the async box AND reduces `&T: Serialize` → a Sky JSON String.
    async fn put<T: Serialize + Send + Sync>(&self, obj: &T) -> Result<(), String>;

    /// NEGATIVE A — a PLAIN (non-async) method returning a genuine non-Future dyn
    /// object.  Principal trait is `SomeOtherTrait`, NOT `core::future::Future` →
    /// `async_trait_future_output` returns `None` → stays the dyn-trait drop.
    fn non_future(&self) -> Pin<Box<dyn SomeOtherTrait + Send>>;

    /// NEGATIVE C — a PLAIN method returning a `Future` WITHOUT `+ Send`.  The
    /// canonical-Future gate matches but the Send gate (C3) does not →
    /// `async_trait_future_output` returns `None` → drop `async-future-not-send`.
    fn not_send(&self) -> Pin<Box<dyn Future<Output = i64>>>;
}

#[async_trait]
impl Repo for Db {
    async fn op(&self, x: String) -> Result<i64, String> {
        // Return the input string's length as the i64 result — proves the async
        // desugar threaded the String param and the i64 Output end-to-end.
        Ok(x.len() as i64)
    }

    async fn put<T: Serialize + Send + Sync>(&self, obj: &T) -> Result<(), String> {
        // Round-trips through serde to PROVE obj deserialised correctly on the
        // way in (the Sky JSON String → Value → &Value boundary).
        let _ = serde_json::to_string(obj).map_err(|e| format!("{e:?}"))?;
        Ok(())
    }

    fn non_future(&self) -> Pin<Box<dyn SomeOtherTrait + Send>> {
        Box::pin(self.clone())
    }

    fn not_send(&self) -> Pin<Box<dyn Future<Output = i64>>> {
        Box::pin(async { 1_i64 })
    }
}
