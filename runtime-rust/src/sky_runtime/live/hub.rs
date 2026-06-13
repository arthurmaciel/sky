//! Hub read-side kernels — the bundled console's data plane on Rust.
//!
//! The console (`sky-bundled/console`) is itself a `Sky.Live` app; its
//! `HubStore.sky` declares twelve `Ffi.kernel "Hub_read*"` bindings that the
//! Rust codegen lowers to the `hub_*` functions in this module. Each reads the
//! SQLite telemetry **spill** (`SKY_CONSOLE_HUB_DB` / the `dbPath` arg, written
//! by the #69 dual-write) and returns the console's typed `State*` record shape.
//!
//! ## Why generic over the return type
//!
//! The `State*` records (`StateOverview`, `StateLogEntry`, …) are *project-
//! generated* — the runtime crate cannot name them. So every kernel is generic
//! over `A: DeserializeOwned`: it builds a `serde_json::Value` whose keys match
//! the record's (camelCase, serde-default) field names and `from_value::<A>`s it.
//! The call sites in the generated `hub_store.rs` infer `A` from the concretely-
//! typed `StateStore` fields — no turbofish, no `Any`, no downcast.
//!
//! ## No panic vectors (the Rust backend's reason to exist)
//!
//! A missing/unreadable spill file, a SQL error, or a JSON-decode miss degrades
//! to an **empty result** plus a structured `warn` — never `?`-into-panic, never
//! `unwrap`/`expect`/indexing. This mirrors Go's `getHubStore() == nil → Ok([])`
//! path (`runtime-go/rt/hub/bridge.go`). The kernel owns both the SELECT and the
//! `Value` shape, so a producer/consumer schema mismatch cannot arise.
//!
//! Ground truth (read-only): `runtime-go/rt/hub/store.go` (schema + queries) and
//! `runtime-go/rt/hub/bridge.go` (row → console-record field derivation).

use super::super::core::{ok_res, SkyTask};
use sqlx::{Row, SqlitePool};

/// Open the telemetry spill read-only. `None` (never an error) when the path is
/// empty or the file can't be opened — callers map that to an empty result so a
/// fresh/absent DB renders as "no telemetry yet", exactly like the Go bridge.
async fn open_spill(db_path: &str) -> Option<SqlitePool> {
    if db_path.is_empty() {
        return None;
    }
    // `mode=ro` — the console is a pure reader; D (#69) owns writes. A missing
    // file fails to connect → None → empty result (no panic, no surfaced error).
    let url = format!("sqlite:{db_path}?mode=ro");
    match SqlitePool::connect(&url).await {
        Ok(pool) => Some(pool),
        Err(e) => {
            eprintln!("[sky.hub] open_spill {db_path}: {e}");
            None
        }
    }
}

/// `Hub_listServices : String -> Task Error (List String)` — distinct
/// service_name across all three telemetry tables, sorted. Go ref:
/// `hub/store.go:676` (`Services`).
pub fn hub_list_services<E: Send + From<String> + 'static>(
    db_path: String,
) -> SkyTask<E, Vec<String>> {
    Box::pin(async move {
        let Some(pool) = open_spill(&db_path).await else {
            return ok_res(Vec::new());
        };
        let sql = "SELECT service_name FROM telemetry_log \
                   UNION SELECT service_name FROM telemetry_metric \
                   UNION SELECT service_name FROM telemetry_span \
                   ORDER BY service_name";
        match sqlx::query(sql).fetch_all(&pool).await {
            Ok(rows) => {
                let mut out = Vec::with_capacity(rows.len());
                for r in &rows {
                    let s: String = r.try_get("service_name").unwrap_or_default();
                    if !s.is_empty() {
                        out.push(s);
                    }
                }
                ok_res(out)
            }
            Err(e) => {
                eprintln!("[sky.hub] listServices: {e}");
                ok_res(Vec::new())
            }
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use super::super::super::core::SkyResult;

    async fn seed(path: &str) -> SqlitePool {
        let pool = SqlitePool::connect(&format!("sqlite:{path}?mode=rwc"))
            .await
            .expect("create temp spill");
        sqlx::query(
            "CREATE TABLE telemetry_log (id INTEGER PRIMARY KEY, service_name TEXT, \
             time TEXT, level TEXT, message TEXT, trace_id TEXT, span_id TEXT, attrs TEXT)",
        )
        .execute(&pool)
        .await
        .unwrap();
        sqlx::query(
            "CREATE TABLE telemetry_metric (id INTEGER PRIMARY KEY, service_name TEXT, \
             time TEXT, name TEXT, type TEXT, value REAL, attrs TEXT)",
        )
        .execute(&pool)
        .await
        .unwrap();
        sqlx::query(
            "CREATE TABLE telemetry_span (id INTEGER PRIMARY KEY, service_name TEXT, \
             time TEXT, name TEXT, trace_id TEXT, span_id TEXT, parent_id TEXT, \
             start_time TEXT, end_time TEXT, attrs TEXT)",
        )
        .execute(&pool)
        .await
        .unwrap();
        pool
    }

    #[tokio::test]
    async fn list_services_distinct_sorted() {
        let dir = std::env::temp_dir().join(format!("hub-svc-{}.db", std::process::id()));
        let path = dir.to_string_lossy().to_string();
        let _ = std::fs::remove_file(&path);
        let pool = seed(&path).await;
        for (tbl, svc) in [("telemetry_log", "b"), ("telemetry_log", "a"), ("telemetry_span", "a")] {
            sqlx::query(&format!(
                "INSERT INTO {tbl} (service_name, time) VALUES (?, '2026-01-01T00:00:00Z')"
            ))
            .bind(svc)
            .execute(&pool)
            .await
            .unwrap();
        }
        let res: SkyResult<String, Vec<String>> = hub_list_services(path.clone()).await;
        match res {
            SkyResult::Ok(v) => assert_eq!(v, vec!["a".to_string(), "b".to_string()]),
            SkyResult::Err(_) => panic!("expected Ok"),
        }
        let _ = std::fs::remove_file(&path);
    }

    #[tokio::test]
    async fn missing_db_is_empty_not_error() {
        let res: SkyResult<String, Vec<String>> =
            hub_list_services("/nonexistent/path/to.db".to_string()).await;
        match res {
            SkyResult::Ok(v) => assert!(v.is_empty()),
            SkyResult::Err(_) => panic!("missing DB must degrade to empty, not error"),
        }
    }

    #[tokio::test]
    async fn empty_path_is_empty() {
        let res: SkyResult<String, Vec<String>> = hub_list_services(String::new()).await;
        assert!(matches!(res, SkyResult::Ok(v) if v.is_empty()));
    }
}
