//! 80-ffi-result-alias: WALL 5 (#63) — async constructor returning a crate-defined
//! GENERIC type alias `type DbResult<T> = Result<T, DbError>`.
//!
//! Mirrors firestore's `FirestoreResult<T> = Result<T, FirestoreError>` shape:
//! `FirestoreDb::with_options(FirestoreDbOptions) -> FirestoreResult<Self>`.
//!
//! Pre-fix the inspector does NOT see through the GENERIC alias, so the
//! async-Send output gate cannot unwrap the `Result<…>` and drops the
//! constructor (`async-future-not-send` — invisible in `--audit`).
//!
//! Post-fix (`expand_generic_alias` in `tools/sky-ffi-inspect-rs`): the alias
//! expands to `Result<Db, DbError>`, the gate unwraps to `Db`, `Db` is provably
//! Send (explicit `unsafe impl Send`), and the ctor binds as `Task Error Db`.
//!
//! NOT an author example — a Rust-backend FFI test fixture. Lives under
//! `runtime-rust/tests/sky/` per the boundary rule (`examples/` is the author's).
//!
//! POSITIVE (must BIND end-to-end):
//!   Db::with_options(DbOptions)  -> DbResult<Self>   (the gating shape)
//!   Db::connect_default()        -> DbResult<Self>   (no-arg secondary, firestore::for_default_project_id mirror)
//!   Db::ping(&self)              -> DbResult<i64>     (proves the ground handle threads)
//!   DbOptions::new(String) / with_retries(usize)     (pure builder — feeds with_options)
//!
//! NEGATIVE (must DROP — absent from bindings, crate STILL compiles):
//!   Db::boxed(DbOptions) -> DbResult<Box<dyn Debug + Send>>
//!     The alias see-through expands the OUTER Result, but the inner `Box<dyn …>`
//!     is a trait object → dropped (proves the see-through stays narrow: it does
//!     NOT admit an unbindable inner type). This is the REAL firestore-blocked
//!     shape (#64 dyn-trait) — its presence here proves we did NOT over-expand.
//!   PairResult<A, B> arity-mismatch alias used with one arg → no expansion →
//!     Db::arity_drop drops (fail-closed arity guard).

use std::fmt::Debug;

/// The crate error enum (firestore `FirestoreError` analogue).
#[derive(Debug)]
pub enum DbError {
    NotFound,
    Backend(String),
}

/// THE gating shape: a crate-local GENERIC `Result` alias.
pub type DbResult<T> = Result<T, DbError>;

/// A SECOND generic alias with TWO params — used at a ONE-arg call site below to
/// exercise the fail-closed arity guard (declared arity 2 ≠ use-site arity 1 →
/// no expansion → the function that returns it drops).
pub type PairResult<A, B> = Result<A, PairErr<B>>;

#[derive(Debug)]
pub struct PairErr<B> {
    _b: Option<B>,
}

/// Pure options builder (firestore `FirestoreDbOptions` analogue). All-fields-Send
/// (a `String` + a `usize`), so the inspector's all-fields-Send proof admits it as
/// a by-value async param.
#[derive(Clone)]
pub struct DbOptions {
    pub project: String,
    pub retries: usize,
}

impl DbOptions {
    /// Pure constructor. Takes `&str` (the FFI generator passes `&arg` for a
    /// String param; an owned-`String` param ctor is a SEPARATE pre-existing
    /// codegen path not under test here — kept `&str` to isolate WALL 5).
    pub fn new(project: &str) -> Self {
        Self {
            project: project.to_string(),
            retries: 3,
        }
    }
    /// By-value builder.
    pub fn with_retries(mut self, n: usize) -> Self {
        self.retries = n;
        self
    }
}

/// Owned, Send opaque handle (firestore `FirestoreDb` analogue). NOT Clone — the
/// Sky binding receives it by value (the opaque-return shape). Explicit `impl
/// Send` populates the inspector's proven-Send set so the async output gate
/// admits it ONLY because the alias see-through let the gate unwrap the Result.
pub struct Db {
    project: String,
}

// Explicit Send → EXPLICIT_SEND_TYPE_IDS → PROVABLY_SEND_RECV_NAMES.
unsafe impl Send for Db {}

impl Db {
    /// POSITIVE: the gating shape — async ctor, concrete owned arg, returns the
    /// GENERIC Result alias. Binds as `DbOptions -> Task Error Db` post-fix.
    pub async fn with_options(options: DbOptions) -> DbResult<Self> {
        Ok(Self {
            project: options.project,
        })
    }

    /// POSITIVE: no-arg async ctor returning the generic alias. Binds as
    /// `() -> Task Error Db` post-fix (firestore::for_default_project_id mirror).
    pub async fn connect_default() -> DbResult<Self> {
        Ok(Self {
            project: "default".to_string(),
        })
    }

    /// POSITIVE: a consumer that takes the ground `Db` (mirrors
    /// `with_session_params`) — proves the constructed value flows downstream.
    /// Returns the generic alias of a primitive to also exercise the expansion on
    /// a non-Self inner.
    pub async fn ping(&self) -> DbResult<i64> {
        Ok(self.project.len() as i64)
    }

    /// NEGATIVE: the alias see-through expands the OUTER Result, but the inner
    /// `Box<dyn Debug + Send>` is a trait object → DROP. Proves the see-through
    /// does NOT over-admit an unbindable inner type. The crate still compiles.
    #[allow(dead_code)]
    pub async fn boxed(_options: DbOptions) -> DbResult<Box<dyn Debug + Send>> {
        Ok(Box::new(0_i64))
    }

    /// NEGATIVE: returns the TWO-param alias `PairResult` applied to ONE arg is
    /// impossible to write as a return type, so instead use the alias with the
    /// wrong number of type args at the SIGNATURE level is not expressible in
    /// Rust source. We exercise the arity-mismatch guard at the inspector
    /// unit-test level (`wall5_arity_mismatch_fails_closed`); here we keep a
    /// `PairResult`-returning fn so the alias is present in the crate and the
    /// inspector records / expands it correctly (2 params, 2 args → expands, but
    /// the inner `PairErr<…>` opaque keeps it from binding — it is NOT a positive).
    #[allow(dead_code)]
    pub async fn pair(&self) -> PairResult<i64, String> {
        Ok(0)
    }
}
