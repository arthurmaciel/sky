#![allow(dead_code)]
//! 104-ffi-owned-query-builder: WALL 6 (#68) — the firestore OWNED query path.
//!
//! Mirrors the EXACT real firestore 0.49 query shape (verified from rustdoc):
//!   FirestoreQueryParams::new(FirestoreQueryCollection) -> Self
//!   FirestoreQueryParams::with_limit(self, u32) -> Self        (owned by-value builder)
//!   <FirestoreDb as FirestoreQuerySupport>::query_obj(&self, FirestoreQueryParams)
//!       -> async Result<Vec<T>, _>                              (#[async_trait], OWNED in/out)
//!
//! This is the SOUND circumvention of the borrowed-builder limitation (guardian
//! ruling 2026-06-27, WALL-6 design gate): the firestore fluent API
//! (`db.fluent().select()…query()`) is pure sugar over this OWNED params-struct
//! API. Every capability the borrowing fluent chain provides is reachable here
//! with ZERO unsafe. So we DON'T bind the borrow — we bind the owned API it is
//! sugar over.
//!
//! NOT an author example — a Rust-backend FFI test fixture. Lives under
//! runtime-rust/tests/sky/ per the boundary rule (examples/ is the author's).
//!
//! POSITIVE (must BIND + run end-to-end):
//!   Collection::new(String) -> Collection                       owned ctor
//!   QueryParams::new(Collection) -> QueryParams                 owned ctor (Collection arg)
//!   QueryParams::with_limit(self, u32) -> QueryParams           owned by-value builder
//!   QueryParams::with_name_prefix(self, String) -> QueryParams  owned by-value builder
//!   Db::new() -> Db                                             opaque Clone+Send handle
//!   <Db as Query>::run_query(&self, QueryParams)               #[async_trait], owned Vec out
//!       -> Result<Vec<String>, String>
//!
//! NEGATIVE (WALL 6 — must DROP, reason=lifetime; crate MUST still compile):
//!   Db::fluent(&self) -> QueryBuilder<'_>      borrowing fluent entry → drop
//!   QueryBuilder::limit / QueryBuilder::run    every method carries 'a → drop
//!   The dropped capability is fully covered by the owned run_query path above.

use async_trait::async_trait;

/// Owned collection selector (mirrors FirestoreQueryCollection, here a String).
#[derive(Clone)]
pub struct Collection {
    pub id: String,
}

impl Collection {
    pub fn new(id: String) -> Collection {
        Collection { id }
    }
}

/// Owned query spec (mirrors FirestoreQueryParams): an owned ctor + by-value
/// `with_*` builders, every field owned. NO lifetime anywhere → binds.
#[derive(Clone)]
pub struct QueryParams {
    pub collection: Collection,
    pub limit: Option<u32>,
    pub name_prefix: Option<String>,
}

impl QueryParams {
    /// Owned ctor taking the (owned) collection — the FirestoreQueryParams::new shape.
    pub fn new(collection: Collection) -> QueryParams {
        QueryParams {
            collection,
            limit: None,
            name_prefix: None,
        }
    }

    /// Owned by-value builder (FirestoreQueryParams::with_limit shape).
    pub fn with_limit(mut self, n: u32) -> QueryParams {
        self.limit = Some(n);
        self
    }

    /// Owned by-value builder (FirestoreQueryParams::with_* shape, String field).
    pub fn with_name_prefix(mut self, prefix: String) -> QueryParams {
        self.name_prefix = Some(prefix);
        self
    }
}

/// Opaque Clone+Send db handle (FirestoreDb is Clone+Send+Sync, Arc-backed).
#[derive(Clone)]
pub struct Db {
    rows: Vec<String>,
}

impl Db {
    /// Inherent ctor — an opaque foreign receiver needs a producer.
    pub fn new() -> Db {
        Db {
            rows: vec![
                "alice".to_string(),
                "amy".to_string(),
                "bob".to_string(),
                "carol".to_string(),
            ],
        }
    }

    /// NEGATIVE (WALL 6): the borrowing fluent entry. Returns a builder that
    /// BORROWS `&'a self` → `has_lifetime` true → `touches_lifetime` drops it.
    /// Capability covered by the owned `run_query` path. MUST be ABSENT from
    /// bindings; the crate MUST still compile.
    pub fn fluent(&self) -> QueryBuilder<'_> {
        QueryBuilder {
            db: self,
            limit: None,
        }
    }
}

/// NEGATIVE: a borrowing fluent builder. Every method's `self`/return carries
/// `'a` → all drop (reason=lifetime). This is the shape the guardian ruled is
/// NOT sound to auto-bind (foreign covariance unverifiable at codegen).
pub struct QueryBuilder<'a> {
    db: &'a Db,
    limit: Option<u32>,
}

impl<'a> QueryBuilder<'a> {
    pub fn limit(mut self, n: u32) -> QueryBuilder<'a> {
        self.limit = Some(n);
        self
    }

    pub async fn run(self) -> Result<Vec<String>, String> {
        Ok(self.db.rows.clone())
    }
}

/// POSITIVE: the OWNED query path — the firestore `FirestoreQuerySupport` shape.
/// `#[async_trait]` (WALL 4 desugar) + owned `QueryParams` param + owned Vec out.
#[async_trait]
pub trait Query {
    async fn run_query(&self, params: QueryParams) -> Result<Vec<String>, String>;
}

#[async_trait]
impl Query for Db {
    async fn run_query(&self, params: QueryParams) -> Result<Vec<String>, String> {
        let mut out: Vec<String> = self
            .rows
            .iter()
            .filter(|r| match &params.name_prefix {
                Some(p) => r.starts_with(p.as_str()),
                None => true,
            })
            .cloned()
            .collect();
        if let Some(n) = params.limit {
            out.truncate(n as usize);
        }
        Ok(out)
    }
}
