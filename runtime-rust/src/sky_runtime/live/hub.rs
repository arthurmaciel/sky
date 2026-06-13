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

use super::super::core::{ok_res, str_err, SkyResult, SkyTask};
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sqlx::{Row, SqlitePool};
use std::collections::HashMap;

/// Default per-table read cap (Go `hub/bridge.go` uses 200 for logs/metrics).
const LOG_LIMIT: i64 = 200;

/// The console's `LogFilter` shape (serde-mirrors `StateLogFilter`). Kernels
/// take the filter generic `F: Serialize`, re-serialize it, and decode into
/// this — so the runtime never names the project-generated `StateLogFilter`.
#[derive(Deserialize, Default)]
#[allow(non_snake_case)]
struct HubLogFilter {
    #[serde(default)]
    query: String,
    #[serde(default)]
    session: String,
    #[serde(default)]
    showDebug: bool,
    #[serde(default)]
    showInfo: bool,
    #[serde(default)]
    showWarn: bool,
    #[serde(default)]
    showError: bool,
}

/// Re-serialize any `F: Serialize` filter into `HubLogFilter`; a shape mismatch
/// degrades to the default (no filtering) — never a panic. Mirrors the Go
/// bridge's `json.Unmarshal` of the forwarded filter.
fn decode_filter<F: Serialize>(filter: F) -> HubLogFilter {
    serde_json::to_value(filter)
        .ok()
        .and_then(|v| serde_json::from_value(v).ok())
        .unwrap_or_default()
}

/// The store applies an `=` level filter, so only "exactly one level toggled"
/// is expressible; zero or 2+ → no filter. Mirror of Go `pickSingleLevel`.
fn pick_single_level(f: &HubLogFilter) -> Option<&'static str> {
    let mut chosen = None;
    let mut count = 0;
    for (on, name) in [
        (f.showDebug, "debug"),
        (f.showInfo, "info"),
        (f.showWarn, "warn"),
        (f.showError, "error"),
    ] {
        if on {
            count += 1;
            chosen = Some(name);
        }
    }
    if count == 1 {
        chosen
    } else {
        None
    }
}

/// Parse the `attrs` JSON column into a string→string map; any non-object /
/// parse failure → empty map (graceful, total).
fn parse_attrs(raw: &str) -> HashMap<String, String> {
    serde_json::from_str(raw).unwrap_or_default()
}

/// Build the `LogEntry`-shaped JSON array (Go `toHubLogRow` + the client-side
/// query/session filters in `QueryLogsJSON`). `service` empty → no service
/// scoping. Returns an empty array on any open/SQL failure.
async fn read_logs_value(db_path: &str, service: &str, filter: HubLogFilter) -> Value {
    let Some(pool) = open_spill(db_path).await else {
        return Value::Array(vec![]);
    };
    let mut sql = String::from(
        "SELECT service_name, time, level, message, trace_id, span_id, attrs \
         FROM telemetry_log WHERE 1=1",
    );
    let level = pick_single_level(&filter);
    if !service.is_empty() {
        sql.push_str(" AND service_name = ?");
    }
    if level.is_some() {
        sql.push_str(" AND level = ?");
    }
    sql.push_str(" ORDER BY time DESC, id DESC LIMIT ?");

    let mut q = sqlx::query(&sql);
    if !service.is_empty() {
        q = q.bind(service);
    }
    if let Some(lv) = level {
        q = q.bind(lv);
    }
    q = q.bind(LOG_LIMIT);

    let rows = match q.fetch_all(&pool).await {
        Ok(r) => r,
        Err(e) => {
            eprintln!("[sky.hub] readLogs: {e}");
            return Value::Array(vec![]);
        }
    };

    let ql = filter.query.to_lowercase();
    let mut out = Vec::with_capacity(rows.len());
    for r in &rows {
        let service_name: String = r.try_get("service_name").unwrap_or_default();
        let message: String = r.try_get("message").unwrap_or_default();
        let attrs = parse_attrs(&r.try_get::<String, _>("attrs").unwrap_or_default());

        // Client-side free-text filter: lower-substring of message | service.
        if !ql.is_empty()
            && !message.to_lowercase().contains(&ql)
            && !service_name.to_lowercase().contains(&ql)
        {
            continue;
        }
        // Client-side session filter.
        if !filter.session.is_empty()
            && attrs.get("session_id").map(String::as_str) != Some(filter.session.as_str())
        {
            continue;
        }
        let attr = |k: &str| attrs.get(k).cloned().unwrap_or_default();
        out.push(json!({
            "time": r.try_get::<String, _>("time").unwrap_or_default(),
            "level": r.try_get::<String, _>("level").unwrap_or_default(),
            "message": message,
            "subapp": service_name,
            "reqId": attr("req_id"),
            "sessionId": attr("session_id"),
            "userLabel": attr("user_label"),
            "route": attr("route"),
            "status": 0.0,
            "latencyMs": 0.0,
        }));
    }
    Value::Array(out)
}

/// `Hub_readLogs : String -> LogFilter -> Task Error (List LogEntry)`.
pub fn hub_read_logs<E, A, F>(db_path: String, filter: F) -> SkyTask<E, A>
where
    E: Send + From<String> + 'static,
    A: DeserializeOwned + Send + 'static,
    F: Serialize + Send + 'static,
{
    Box::pin(async move {
        let f = decode_filter(filter);
        let arr = read_logs_value(&db_path, "", f).await;
        decode_rows(arr)
    })
}

/// `Hub_readFilteredLogs : String -> String -> LogFilter -> Task Error (List LogEntry)`.
pub fn hub_read_filtered_logs<E, A, F>(db_path: String, service: String, filter: F) -> SkyTask<E, A>
where
    E: Send + From<String> + 'static,
    A: DeserializeOwned + Send + 'static,
    F: Serialize + Send + 'static,
{
    Box::pin(async move {
        let f = decode_filter(filter);
        let arr = read_logs_value(&db_path, &service, f).await;
        decode_rows(arr)
    })
}

/// Deserialize a built `Value` into the project-generated record type `A`. A
/// decode miss degrades to the type's `serde` default via an empty array /
/// object — but since the kernel OWNS the Value shape it always matches, so the
/// `Err` arm is unreachable in practice; it still returns `Ok` of the
/// empty-array decode rather than surfacing an error (total, no panic).
fn decode_rows<E, A>(arr: Value) -> SkyResult<E, A>
where
    E: From<String>,
    A: DeserializeOwned,
{
    match serde_json::from_value::<A>(arr) {
        Ok(a) => ok_res(a),
        Err(e) => {
            eprintln!("[sky.hub] decode_rows: {e}");
            // Fall back to decoding an empty array (List records) — if A is not
            // a list this also fails, in which case surface a structured Err
            // (the value system models it; never a panic).
            match serde_json::from_value::<A>(Value::Array(vec![])) {
                Ok(a) => ok_res(a),
                Err(_) => SkyResult::Err(str_err(&format!("hub.decode: {e}"))),
            }
        }
    }
}

const METRIC_LIMIT: i64 = 200;
const TRACE_LIMIT: i64 = 100;
const ERROR_LIMIT: i64 = 500;

/// Build the `MetricRow`-shaped JSON array (Go `QueryMetricsJSON`). `labels` is
/// the attrs map rendered `k=v, k=v` (keys sorted for stable output); `sum`/
/// `count` are 0 (the spill doesn't carry histogram aggregates yet).
async fn read_metrics_value(db_path: &str, service: &str) -> Value {
    let Some(pool) = open_spill(db_path).await else {
        return Value::Array(vec![]);
    };
    let mut sql = String::from(
        "SELECT name, type, value, attrs FROM telemetry_metric WHERE 1=1",
    );
    if !service.is_empty() {
        sql.push_str(" AND service_name = ?");
    }
    sql.push_str(" ORDER BY time DESC, id DESC LIMIT ?");
    let mut q = sqlx::query(&sql);
    if !service.is_empty() {
        q = q.bind(service);
    }
    let rows = match q.bind(METRIC_LIMIT).fetch_all(&pool).await {
        Ok(r) => r,
        Err(e) => {
            eprintln!("[sky.hub] readMetrics: {e}");
            return Value::Array(vec![]);
        }
    };
    let mut out = Vec::with_capacity(rows.len());
    for r in &rows {
        let attrs = parse_attrs(&r.try_get::<String, _>("attrs").unwrap_or_default());
        let mut keys: Vec<&String> = attrs.keys().collect();
        keys.sort();
        let labels = keys
            .iter()
            .map(|k| format!("{k}={}", attrs.get(*k).map(String::as_str).unwrap_or("")))
            .collect::<Vec<_>>()
            .join(", ");
        out.push(json!({
            "name": r.try_get::<String, _>("name").unwrap_or_default(),
            "typ": r.try_get::<String, _>("type").unwrap_or_default(),
            "labels": labels,
            "value": r.try_get::<f64, _>("value").unwrap_or(0.0),
            "sum": 0.0,
            "count": 0.0,
        }));
    }
    Value::Array(out)
}

/// Milliseconds between two RFC3339 timestamps; 0 when either is empty or
/// unparseable (total — never panics). Mirrors Go's zero-guarded `Sub`.
fn duration_ms(start: &str, end: &str) -> f64 {
    if start.is_empty() || end.is_empty() {
        return 0.0;
    }
    match (
        chrono::DateTime::parse_from_rfc3339(start),
        chrono::DateTime::parse_from_rfc3339(end),
    ) {
        (Ok(s), Ok(e)) => (e - s).num_milliseconds() as f64,
        _ => 0.0,
    }
}

/// Build the `TraceRow`-shaped JSON array (Go `QuerySpansJSON`). `kind`=service,
/// `durationMs` from start/end, `status` from attrs.
async fn read_traces_value(db_path: &str, service: &str) -> Value {
    let Some(pool) = open_spill(db_path).await else {
        return Value::Array(vec![]);
    };
    let mut sql = String::from(
        "SELECT service_name, name, trace_id, span_id, parent_id, start_time, end_time, attrs \
         FROM telemetry_span WHERE 1=1",
    );
    if !service.is_empty() {
        sql.push_str(" AND service_name = ?");
    }
    sql.push_str(" ORDER BY time DESC, id DESC LIMIT ?");
    let mut q = sqlx::query(&sql);
    if !service.is_empty() {
        q = q.bind(service);
    }
    let rows = match q.bind(TRACE_LIMIT).fetch_all(&pool).await {
        Ok(r) => r,
        Err(e) => {
            eprintln!("[sky.hub] readTraces: {e}");
            return Value::Array(vec![]);
        }
    };
    let mut out = Vec::with_capacity(rows.len());
    for r in &rows {
        let start: String = r.try_get("start_time").unwrap_or_default();
        let end: String = r.try_get("end_time").unwrap_or_default();
        let attrs = parse_attrs(&r.try_get::<String, _>("attrs").unwrap_or_default());
        out.push(json!({
            "traceId": r.try_get::<String, _>("trace_id").unwrap_or_default(),
            "spanId": r.try_get::<String, _>("span_id").unwrap_or_default(),
            "parentId": r.try_get::<String, _>("parent_id").unwrap_or_default(),
            "name": r.try_get::<String, _>("name").unwrap_or_default(),
            "kind": r.try_get::<String, _>("service_name").unwrap_or_default(),
            "startTime": start.clone(),
            "durationMs": duration_ms(&start, &end),
            "status": attrs.get("status").cloned().unwrap_or_default(),
        }));
    }
    Value::Array(out)
}

/// Build the `ErrorRow`-shaped JSON array (Go `QueryErrorsJSON`): error-level
/// logs grouped by message → `{count, message}`, descending by count for a
/// stable, useful order.
async fn read_errors_value(db_path: &str, service: &str) -> Value {
    let Some(pool) = open_spill(db_path).await else {
        return Value::Array(vec![]);
    };
    let mut sql = String::from(
        "SELECT message FROM telemetry_log WHERE level = 'error'",
    );
    if !service.is_empty() {
        sql.push_str(" AND service_name = ?");
    }
    sql.push_str(" ORDER BY time DESC, id DESC LIMIT ?");
    let mut q = sqlx::query(&sql);
    if !service.is_empty() {
        q = q.bind(service);
    }
    let rows = match q.bind(ERROR_LIMIT).fetch_all(&pool).await {
        Ok(r) => r,
        Err(e) => {
            eprintln!("[sky.hub] readErrors: {e}");
            return Value::Array(vec![]);
        }
    };
    let mut counts: HashMap<String, i64> = HashMap::new();
    for r in &rows {
        let msg: String = r.try_get("message").unwrap_or_default();
        *counts.entry(msg).or_insert(0) += 1;
    }
    let mut pairs: Vec<(String, i64)> = counts.into_iter().collect();
    pairs.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
    let out = pairs
        .into_iter()
        .map(|(message, count)| json!({ "count": count, "message": message }))
        .collect();
    Value::Array(out)
}

/// `Hub_readMetrics : String -> Task Error (List MetricRow)`.
pub fn hub_read_metrics<E, A>(db_path: String) -> SkyTask<E, A>
where
    E: Send + From<String> + 'static,
    A: DeserializeOwned + Send + 'static,
{
    Box::pin(async move { decode_rows(read_metrics_value(&db_path, "").await) })
}

/// `Hub_readFilteredMetrics : String -> String -> Task Error (List MetricRow)`.
pub fn hub_read_filtered_metrics<E, A>(db_path: String, service: String) -> SkyTask<E, A>
where
    E: Send + From<String> + 'static,
    A: DeserializeOwned + Send + 'static,
{
    Box::pin(async move { decode_rows(read_metrics_value(&db_path, &service).await) })
}

/// `Hub_readTraces : String -> Task Error (List TraceRow)`.
pub fn hub_read_traces<E, A>(db_path: String) -> SkyTask<E, A>
where
    E: Send + From<String> + 'static,
    A: DeserializeOwned + Send + 'static,
{
    Box::pin(async move { decode_rows(read_traces_value(&db_path, "").await) })
}

/// `Hub_readFilteredTraces : String -> String -> Task Error (List TraceRow)`.
pub fn hub_read_filtered_traces<E, A>(db_path: String, service: String) -> SkyTask<E, A>
where
    E: Send + From<String> + 'static,
    A: DeserializeOwned + Send + 'static,
{
    Box::pin(async move { decode_rows(read_traces_value(&db_path, &service).await) })
}

/// `Hub_readErrors : String -> Task Error (List ErrorRow)`.
pub fn hub_read_errors<E, A>(db_path: String) -> SkyTask<E, A>
where
    E: Send + From<String> + 'static,
    A: DeserializeOwned + Send + 'static,
{
    Box::pin(async move { decode_rows(read_errors_value(&db_path, "").await) })
}

/// `Hub_readFilteredErrors : String -> String -> Task Error (List ErrorRow)`.
pub fn hub_read_filtered_errors<E, A>(db_path: String, service: String) -> SkyTask<E, A>
where
    E: Send + From<String> + 'static,
    A: DeserializeOwned + Send + 'static,
{
    Box::pin(async move { decode_rows(read_errors_value(&db_path, &service).await) })
}

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

    #[derive(serde::Serialize)]
    #[allow(non_snake_case)]
    struct TestFilter {
        query: String,
        session: String,
        showDebug: bool,
        showInfo: bool,
        showWarn: bool,
        showError: bool,
    }
    impl TestFilter {
        fn none() -> Self {
            Self { query: String::new(), session: String::new(),
                   showDebug: false, showInfo: false, showWarn: false, showError: false }
        }
    }

    #[tokio::test]
    async fn read_logs_maps_attrs_and_filters_level() {
        let path = std::env::temp_dir()
            .join(format!("hub-logs-{}.db", std::process::id()))
            .to_string_lossy()
            .to_string();
        let _ = std::fs::remove_file(&path);
        let pool = seed(&path).await;
        for (lvl, msg, attrs) in [
            ("info", "hello", r#"{"req_id":"r1","session_id":"s1","route":"/a"}"#),
            ("error", "boom", r#"{"req_id":"r2","route":"/b"}"#),
        ] {
            sqlx::query(
                "INSERT INTO telemetry_log (service_name, time, level, message, attrs) \
                 VALUES ('svc', '2026-01-01T00:00:00Z', ?, ?, ?)",
            )
            .bind(lvl).bind(msg).bind(attrs)
            .execute(&pool).await.unwrap();
        }
        // showError only → exactly-one-level → just the error row.
        let f = TestFilter { showError: true, ..TestFilter::none() };
        let res: SkyResult<String, Vec<Value>> = hub_read_logs(path.clone(), f).await;
        match res {
            SkyResult::Ok(rows) => {
                assert_eq!(rows.len(), 1);
                assert_eq!(rows[0]["message"], "boom");
                assert_eq!(rows[0]["reqId"], "r2");
                assert_eq!(rows[0]["route"], "/b");
                assert_eq!(rows[0]["subapp"], "svc");
            }
            SkyResult::Err(_) => panic!("expected Ok"),
        }
        // Free-text query "hello" → only the info row (no level filter).
        let f2 = TestFilter { query: "hello".to_string(), ..TestFilter::none() };
        let res2: SkyResult<String, Vec<Value>> = hub_read_logs(path.clone(), f2).await;
        match res2 {
            SkyResult::Ok(rows) => {
                assert_eq!(rows.len(), 1);
                assert_eq!(rows[0]["sessionId"], "s1");
            }
            SkyResult::Err(_) => panic!("expected Ok"),
        }
        let _ = std::fs::remove_file(&path);
    }

    #[tokio::test]
    async fn filtered_logs_scopes_to_service() {
        let path = std::env::temp_dir()
            .join(format!("hub-flogs-{}.db", std::process::id()))
            .to_string_lossy()
            .to_string();
        let _ = std::fs::remove_file(&path);
        let pool = seed(&path).await;
        for svc in ["alpha", "beta"] {
            sqlx::query(
                "INSERT INTO telemetry_log (service_name, time, level, message, attrs) \
                 VALUES (?, '2026-01-01T00:00:00Z', 'info', 'm', '{}')",
            )
            .bind(svc).execute(&pool).await.unwrap();
        }
        let res: SkyResult<String, Vec<Value>> =
            hub_read_filtered_logs(path.clone(), "alpha".to_string(), TestFilter::none()).await;
        match res {
            SkyResult::Ok(rows) => {
                assert_eq!(rows.len(), 1);
                assert_eq!(rows[0]["subapp"], "alpha");
            }
            SkyResult::Err(_) => panic!("expected Ok"),
        }
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn duration_ms_total_and_guarded() {
        assert_eq!(duration_ms("", "2026-01-01T00:00:01Z"), 0.0);
        assert_eq!(duration_ms("nonsense", "alsobad"), 0.0);
        assert_eq!(
            duration_ms("2026-01-01T00:00:00Z", "2026-01-01T00:00:00.250Z"),
            250.0
        );
    }

    #[tokio::test]
    async fn read_metrics_joins_sorted_labels() {
        let path = std::env::temp_dir()
            .join(format!("hub-met-{}.db", std::process::id()))
            .to_string_lossy().to_string();
        let _ = std::fs::remove_file(&path);
        let pool = seed(&path).await;
        sqlx::query(
            "INSERT INTO telemetry_metric (service_name, time, name, type, value, attrs) \
             VALUES ('svc', '2026-01-01T00:00:00Z', 'reqs', 'counter', 5.0, ?)",
        )
        .bind(r#"{"zone":"eu","app":"web"}"#)
        .execute(&pool).await.unwrap();
        let res: SkyResult<String, Vec<Value>> = hub_read_metrics(path.clone()).await;
        match res {
            SkyResult::Ok(rows) => {
                assert_eq!(rows.len(), 1);
                assert_eq!(rows[0]["name"], "reqs");
                assert_eq!(rows[0]["typ"], "counter");
                assert_eq!(rows[0]["value"], 5.0);
                assert_eq!(rows[0]["labels"], "app=web, zone=eu"); // sorted keys
            }
            SkyResult::Err(_) => panic!("expected Ok"),
        }
        let _ = std::fs::remove_file(&path);
    }

    #[tokio::test]
    async fn read_traces_computes_duration() {
        let path = std::env::temp_dir()
            .join(format!("hub-tr-{}.db", std::process::id()))
            .to_string_lossy().to_string();
        let _ = std::fs::remove_file(&path);
        let pool = seed(&path).await;
        sqlx::query(
            "INSERT INTO telemetry_span (service_name, time, name, trace_id, span_id, \
             parent_id, start_time, end_time, attrs) VALUES \
             ('svc', '2026-01-01T00:00:00Z', 'GET /', 't1', 's1', '', \
              '2026-01-01T00:00:00Z', '2026-01-01T00:00:00.100Z', ?)",
        )
        .bind(r#"{"status":"ok"}"#)
        .execute(&pool).await.unwrap();
        let res: SkyResult<String, Vec<Value>> = hub_read_traces(path.clone()).await;
        match res {
            SkyResult::Ok(rows) => {
                assert_eq!(rows.len(), 1);
                assert_eq!(rows[0]["traceId"], "t1");
                assert_eq!(rows[0]["kind"], "svc");
                assert_eq!(rows[0]["durationMs"], 100.0);
                assert_eq!(rows[0]["status"], "ok");
            }
            SkyResult::Err(_) => panic!("expected Ok"),
        }
        let _ = std::fs::remove_file(&path);
    }

    #[tokio::test]
    async fn read_errors_groups_by_message() {
        let path = std::env::temp_dir()
            .join(format!("hub-err-{}.db", std::process::id()))
            .to_string_lossy().to_string();
        let _ = std::fs::remove_file(&path);
        let pool = seed(&path).await;
        for msg in ["boom", "boom", "split"] {
            sqlx::query(
                "INSERT INTO telemetry_log (service_name, time, level, message, attrs) \
                 VALUES ('svc', '2026-01-01T00:00:00Z', 'error', ?, '{}')",
            )
            .bind(msg).execute(&pool).await.unwrap();
        }
        let res: SkyResult<String, Vec<Value>> = hub_read_errors(path.clone()).await;
        match res {
            SkyResult::Ok(rows) => {
                assert_eq!(rows.len(), 2);
                // descending by count → "boom" (2) first.
                assert_eq!(rows[0]["message"], "boom");
                assert_eq!(rows[0]["count"], 2);
                assert_eq!(rows[1]["message"], "split");
                assert_eq!(rows[1]["count"], 1);
            }
            SkyResult::Err(_) => panic!("expected Ok"),
        }
        let _ = std::fs::remove_file(&path);
    }
}
