//! sky-firestore-shim — REAL `firestore` 0.49-backed surface for the skyshop-rs
//! Sky→Rust port (Stage 2).
//!
//! This is the FULL FFI surface the app's `Lib/Db.sky` needs. Each public fn is
//! a TOTAL `fn(..) -> Result<_, String>` the Sky auto-FFI binds as a synchronous
//! Sky `Result` (D1), with the D3 flat shape:
//!
//!   * single doc  → `Result<HashMap<String,String>, String>`  (Sky: `Result String (Dict String String)`)
//!   * query rows  → `Result<Vec<HashMap<String,String>>, String>` (Sky: `Result String (List (Dict String String))`)
//!
//! ERROR-SLOT WRINKLE: the Sky side discards the `Err` payload (`Err _ ->`).
//! "Document not found" is therefore signalled IN the Ok payload via a
//! `"_status"` key (`"ok"` | `"not_found"`), NOT in the error string. Real
//! firestore failures go through `Err(String)` and the firestore error `Display`
//! is embedded verbatim so `Lib/Db.sky`'s `wrapDbError` keeps string-matching
//! PermissionDenied / NotFound.
//!
//! All `&str` params (Sky passes `&arg`); owned internally. Rows are flat
//! `HashMap<String,String>` — firestore's serde bridge round-trips a map of
//! string values losslessly, which is exactly the D3 flat-row shape.
//!
//! ASYNC BRIDGE: the `firestore` crate is async (tokio). Each op builds a future
//! and drives it to completion on a dedicated current-thread tokio runtime that
//! lives on a spawned OS thread — the same pattern as
//! `runtime-rust/src/sky_runtime/task.rs::block_on`. `.join()` converts any
//! internal panic into an `Err(String)` so NO panic escapes the FFI boundary.
//!
//! NO panic / NO unwrap reachable: every `.await?` / parse maps to `Err(String)`.

use std::collections::HashMap;
use std::future::Future;

use firestore::select_filter_builder::FirestoreQueryFilterBuilder;
use firestore::{
    FirestoreDb, FirestoreDbOptions, FirestoreQueryDirection, FirestoreQueryFilter,
};
use gcloud_sdk::{Source, Token, TokenSourceType};

/// Project id from the environment, defaulting to the dev project. The
/// `firestore` crate honours `FIRESTORE_EMULATOR_HOST` automatically (verified
/// against firestore-0.49 `src/db/mod.rs` `GOOGLE_FIRESTORE_EMULATOR_HOST_ENV`),
/// so pointing at the emulator needs no extra wiring here.
fn project_id() -> String {
    std::env::var("FIRESTORE_PROJECT_ID")
        .or_else(|_| std::env::var("GOOGLE_CLOUD_PROJECT"))
        .unwrap_or_else(|_| "sky-skyshop-dev".to_string())
}

/// Drive an async firestore future to completion on a dedicated current-thread
/// tokio runtime, off the calling thread. A panic inside the future (or runtime)
/// is caught by `.join()` and mapped to `Err(String)` — nothing escapes.
///
/// Pattern mirrors `runtime-rust/src/sky_runtime/task.rs::block_on`.
fn block_on<T, F>(fut: F) -> Result<T, String>
where
    T: Send + 'static,
    F: Future<Output = Result<T, String>> + Send + 'static,
{
    let join = std::thread::spawn(move || {
        let rt = match tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
        {
            Ok(r) => r,
            Err(e) => return Err(format!("tokio runtime init failed: {e}")),
        };
        rt.block_on(fut)
    })
    .join();

    match join {
        Ok(r) => r,
        Err(_) => Err("firestore shim: async task panicked".to_string()),
    }
}

/// A no-op token source for the Firestore emulator. The emulator does not
/// validate credentials, but firestore 0.49 still *constructs* a token source
/// eagerly (`new()` → `TokenSourceType::Default` → ADC lookup), which fails in a
/// credential-free environment. When `FIRESTORE_EMULATOR_HOST` is set we hand it
/// this constant dummy bearer token instead, so the client builds without ADC.
struct EmulatorTokenSource;

#[async_trait::async_trait]
impl Source for EmulatorTokenSource {
    async fn token(&self) -> gcloud_sdk::error::Result<Token> {
        Ok(Token::new(
            "Bearer".to_string(),
            "owner".into(),
            chrono::Utc::now() + chrono::Duration::hours(24),
        ))
    }
}

/// Connect to Firestore (emulator-aware). The error `Display` is embedded so the
/// Sky `wrapDbError` matcher keeps classifying PermissionDenied / NotFound.
///
/// Real GCP path: `TokenSourceType::Default` (Application Default Credentials).
/// Emulator path (`FIRESTORE_EMULATOR_HOST` set): a no-op `ExternalSource` token
/// so no ADC is required. The emulator host itself is picked up automatically by
/// the firestore crate.
/// Dev-mode gate, mirroring Sky's production gate (`ENV` then `SKY_ENV`;
/// anything other than unset / `dev` / `development` / `local` ⇒ production).
/// The emulator path hands the client a constant dummy bearer and talks to an
/// unauthenticated emulator, so it MUST be refused outside dev — a leaked
/// `FIRESTORE_EMULATOR_HOST` in production would otherwise silently route all
/// reads/writes at an emulator with no access control. Defence-in-depth.
fn is_dev() -> bool {
    let env = std::env::var("ENV")
        .or_else(|_| std::env::var("SKY_ENV"))
        .unwrap_or_default();
    matches!(env.as_str(), "" | "dev" | "development" | "local")
}

async fn connect() -> Result<FirestoreDb, String> {
    let options = FirestoreDbOptions::new(project_id());
    let result = if std::env::var("FIRESTORE_EMULATOR_HOST").is_ok() {
        if !is_dev() {
            return Err("firestore: emulator path refused outside dev \
                        (ENV/SKY_ENV must be unset, dev, development, or local)"
                .to_string());
        }
        FirestoreDb::with_options_token_source(
            options,
            gcloud_sdk::GCP_DEFAULT_SCOPES.clone(),
            TokenSourceType::ExternalSource(Box::new(EmulatorTokenSource)),
        )
        .await
    } else {
        FirestoreDb::with_options(options).await
    };
    result.map_err(|e| format!("firestore connect failed: {e}"))
}

/// `not_found`-tagged empty row — the Ok payload carries the absence flag so the
/// Sky side never has to read the (unusable) `Err` slot for "no such doc".
fn not_found_row() -> HashMap<String, String> {
    let mut m = HashMap::new();
    m.insert("_status".to_string(), "not_found".to_string());
    m
}

/// Tag a fetched flat row with `_status=ok` (D3 convention) and return it.
fn ok_row(mut row: HashMap<String, String>) -> HashMap<String, String> {
    row.insert("_status".to_string(), "ok".to_string());
    row
}

/// Map a Sky `op` string to a firestore field-filter for the given field/value.
/// Defaults to equality for any unrecognised op (the stub only ever did `==`).
/// Returns `None` when the builder produces no filter (firestore's field-expr
/// helpers return `Option`); callers treat `None` as "no constraint".
fn build_filter(
    q: &FirestoreQueryFilterBuilder,
    field: &str,
    op: &str,
    value: &str,
) -> Option<FirestoreQueryFilter> {
    let f = q.field(field);
    match op {
        "!=" | "neq" => f.not_equal(value),
        "<" | "lt" => f.less_than(value),
        "<=" | "lte" => f.less_than_or_equal(value),
        ">" | "gt" => f.greater_than(value),
        ">=" | "gte" => f.greater_than_or_equal(value),
        // "==" / "eq" / anything else → equality
        _ => f.equal(value),
    }
}

// ──────────────────────────────────────────────────────────────────────────
// PUBLIC FFI SURFACE — signatures byte-identical to the Stage-1 stub.
// ──────────────────────────────────────────────────────────────────────────

/// `fs_get_doc(collection, id) -> Result<HashMap<String,String>, String>`
/// Sky: `Result String (Dict String String)`.
/// Absence → `_status="not_found"` in the Ok payload (NOT the Err slot).
pub fn fs_get_doc(collection: &str, id: &str) -> Result<HashMap<String, String>, String> {
    let collection = collection.to_string();
    let id = id.to_string();
    block_on(async move {
        let db = connect().await?;
        let doc: Option<HashMap<String, String>> = db
            .fluent()
            .select()
            .by_id_in(&collection)
            .obj::<HashMap<String, String>>()
            .one(&id)
            .await
            .map_err(|e| format!("fs_get_doc {collection}/{id} failed: {e}"))?;
        Ok(match doc {
            Some(row) => ok_row(row),
            None => not_found_row(),
        })
    })
}

/// `fs_set_doc(collection, id, fields_json) -> Result<String, String>`
/// Sky: `Result String String`. Returns the doc id on success. Upsert semantics
/// (create-or-replace) via firestore's `update` builder, which does not require
/// the document to pre-exist. `fields_json` is a flat `{"k":"v",...}` object (D3).
pub fn fs_set_doc(collection: &str, id: &str, fields_json: &str) -> Result<String, String> {
    let collection = collection.to_string();
    let id = id.to_string();
    let fields: HashMap<String, String> =
        serde_json::from_str(fields_json).map_err(|e| format!("bad fields_json: {e}"))?;
    block_on(async move {
        let db = connect().await?;
        db.fluent()
            .update()
            .in_col(&collection)
            .document_id(&id)
            .object(&fields)
            .execute::<HashMap<String, String>>()
            .await
            .map_err(|e| format!("fs_set_doc {collection}/{id} failed: {e}"))?;
        Ok(id)
    })
}

/// `fs_delete_doc(collection, id) -> Result<String, String>`
/// Sky: `Result String String`. Returns the deleted id. Deleting a missing doc
/// is a no-op success in Firestore (no NotFound), so this only errors on a real
/// transport / permission failure.
pub fn fs_delete_doc(collection: &str, id: &str) -> Result<String, String> {
    let collection = collection.to_string();
    let id = id.to_string();
    block_on(async move {
        let db = connect().await?;
        db.fluent()
            .delete()
            .from(&collection)
            .document_id(&id)
            .execute()
            .await
            .map_err(|e| format!("fs_delete_doc {collection}/{id} failed: {e}"))?;
        Ok(id)
    })
}

/// `fs_query(collection) -> Result<Vec<HashMap<String,String>>, String>`
/// Sky: `Result String (List (Dict String String))`. Materializes all docs in
/// the collection as flat rows (each tagged `_status=ok`).
pub fn fs_query(collection: &str) -> Result<Vec<HashMap<String, String>>, String> {
    let collection = collection.to_string();
    block_on(async move {
        let db = connect().await?;
        let rows: Vec<HashMap<String, String>> = db
            .fluent()
            .select()
            .from(collection.as_str())
            .obj::<HashMap<String, String>>()
            .query()
            .await
            .map_err(|e| format!("fs_query {collection} failed: {e}"))?;
        Ok(rows.into_iter().map(ok_row).collect())
    })
}

/// `fs_query_where(collection, field, op, value) -> Result<Vec<HashMap<String,String>>, String>`
/// Sky: `Result String (List (Dict String String))`. Single field filter.
pub fn fs_query_where(
    collection: &str,
    field: &str,
    op: &str,
    value: &str,
) -> Result<Vec<HashMap<String, String>>, String> {
    let collection = collection.to_string();
    let field = field.to_string();
    let op = op.to_string();
    let value = value.to_string();
    block_on(async move {
        let db = connect().await?;
        let rows: Vec<HashMap<String, String>> = db
            .fluent()
            .select()
            .from(collection.as_str())
            .filter(|q| build_filter(&q, &field, &op, &value))
            .obj::<HashMap<String, String>>()
            .query()
            .await
            .map_err(|e| format!("fs_query_where {collection} failed: {e}"))?;
        Ok(rows.into_iter().map(ok_row).collect())
    })
}

/// `fs_query_where_order(collection, field, op, value, order_field, dir) -> Result<Vec<HashMap<String,String>>, String>`
/// Sky: `Result String (List (Dict String String))`. Single field filter + a
/// server-side order on `order_field` (`dir` = "desc" → Descending, else
/// Ascending). Note: Firestore requires `order_field` to be indexed; the
/// emulator is permissive.
pub fn fs_query_where_order(
    collection: &str,
    field: &str,
    op: &str,
    value: &str,
    order_field: &str,
    dir: &str,
) -> Result<Vec<HashMap<String, String>>, String> {
    let collection = collection.to_string();
    let field = field.to_string();
    let op = op.to_string();
    let value = value.to_string();
    let order_field = order_field.to_string();
    let direction = if dir == "desc" {
        FirestoreQueryDirection::Descending
    } else {
        FirestoreQueryDirection::Ascending
    };
    block_on(async move {
        let db = connect().await?;
        let rows: Vec<HashMap<String, String>> = db
            .fluent()
            .select()
            .from(collection.as_str())
            .filter(|q| build_filter(&q, &field, &op, &value))
            .order_by([(order_field.clone(), direction)])
            .obj::<HashMap<String, String>>()
            .query()
            .await
            .map_err(|e| format!("fs_query_where_order {collection} failed: {e}"))?;
        Ok(rows.into_iter().map(ok_row).collect())
    })
}
