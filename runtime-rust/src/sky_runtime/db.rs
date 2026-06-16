// DB kernel functions — generic over E and over backend.
// Uses DbPool, DbRow, SKY_DB_URL, db_last_insert_id, db_format_sql from
// config.rs (generated at build time per sky.toml [database] driver).
use super::*;
use super::json::{Decoder, JsonVal, json_dec_field, json_dec_ok, json_dec_err_str};
use sqlx::{Column, Row};
use std::collections::HashMap;

pub type Db = DbPool;

fn sky_err<E: From<String> + Send>(e: &sqlx::Error) -> E {
    str_err(&format!("{}", e))
}

// needless_range_loop (accepted, cosmetic): the loop indexes by position to pair
// column name[i] with value[i] across two parallel slices — an iterator can't
// thread both. Not a soundness concern.
#[allow(clippy::needless_range_loop)]
fn row_to_map(row: &DbRow) -> HashMap<String, String> {
    let mut map = HashMap::new();
    let cols = row.columns();
    for (i, col) in cols.iter().enumerate() {
        let name = col.name().to_string();
        let value: String = match row.try_get::<Option<String>, _>(i) {
            Ok(Some(v)) => v,
            Ok(None) => String::new(),
            _ => match row.try_get::<Option<i64>, _>(i) {
                Ok(Some(v)) => v.to_string(),
                _ => match row.try_get::<Option<f64>, _>(i) {
                    Ok(Some(v)) => v.to_string(),
                    _ => String::new(),
                }
            }
        };
        map.insert(name, value);
    }
    map
}

/// NULL-preserving row → JsonVal bridge for the typed-decoder path.
///
/// `row_to_map` (the untyped `db_query` path) collapses SQL NULL → `String::new()`,
/// making NULL and empty-string indistinguishable. `db_query_decode` and
/// `db_get_by_id_decode` MUST use this function instead so `db_dec_nullable`
/// can correctly distinguish NULL from an empty value.
///
/// Per-column strategy (first match wins):
///  1. `Option<String>` → `Ok(None)` = `JsonVal::Null`, `Ok(Some(s))` = `JsonVal::String(s)`
///  2. `Option<i64>`    → `Ok(None)` = `JsonVal::Null`, `Ok(Some(n))` = `JsonVal::String(n.to_string())`
///  3. `Option<f64>`    → `Ok(None)` = `JsonVal::Null`, `Ok(Some(f))` = `JsonVal::String(f.to_string())`
///  4. fallback         → `JsonVal::Null` (driver type we can't read; never panics)
#[allow(clippy::needless_range_loop)]
fn row_to_json(row: &DbRow) -> JsonVal {
    let cols = row.columns();
    let mut map = serde_json::Map::with_capacity(cols.len());
    for (i, col) in cols.iter().enumerate() {
        let name = col.name().to_string();
        let val = match row.try_get::<Option<String>, _>(i) {
            Ok(None)    => JsonVal::Null,
            Ok(Some(s)) => JsonVal::String(s),
            Err(_)      => match row.try_get::<Option<i64>, _>(i) {
                Ok(None)    => JsonVal::Null,
                Ok(Some(n)) => JsonVal::String(n.to_string()),
                Err(_)      => match row.try_get::<Option<f64>, _>(i) {
                    Ok(None)    => JsonVal::Null,
                    Ok(Some(f)) => JsonVal::String(f.to_string()),
                    Err(_)      => JsonVal::Null,
                },
            },
        };
        map.insert(name, val);
    }
    JsonVal::Object(map)
}

// ─── DB-specific typed decoder primitives ─────────────────────────────────────
//
// Each primitive wraps `json_dec_field` (reads a named column from the JsonVal
// object produced by `row_to_json`) and adds domain-specific value parsing.
// ALL are TOTAL: missing column, NULL, or parse failure → `SkyResult::Err` via
// `json_dec_err_str`, NEVER `.unwrap()` / `.expect()` / `panic!`.
//
// The shared `Decoder<E,T>` type (json.rs:7) is reused here — DbDec decoders
// and JsonDec decoders are the same Rust type. Correctness is ensured by the
// runner functions (`db_query_decode`, `db_get_by_id_decode`) which always feed
// a `row_to_json`-produced `JsonVal::Object` to the decoder, never a raw JSON
// document. Cross-application (JsonDec decoder run against a DB row or vice
// versa) is still well-formed (the types match); it just may produce parse
// errors on format mismatches, which is the expected behaviour.

/// `DbDec.string col` — read column `col` as a String.
/// Fails with Err when the column is missing OR its value is NULL.
pub fn db_dec_string<E: From<String> + 'static>(col: String) -> Decoder<E, String> {
    json_dec_field(col.clone(), Box::new(move |v| match v {
        JsonVal::String(s) => json_dec_ok(s.clone()),
        JsonVal::Null      => json_dec_err_str(format!("column {}: expected String, got NULL", col)),
        _                  => json_dec_err_str(format!("column {}: expected String, got {:?}", col, v.to_string())),
    }))
}

/// `DbDec.int col` — read column `col` as an Int (i64).
/// Accepts: JSON Number, or a String representation of an integer or decimal
/// (e.g. "42", "3.0" → 3). NULL → Err. Parse failure → Err.
/// Matches Go's DbDec_int truthy table (int/int64/float64/string forms).
pub fn db_dec_int<E: From<String> + 'static>(col: String) -> Decoder<E, i64> {
    json_dec_field(col.clone(), Box::new(move |v| match v {
        JsonVal::Number(n) => match n.as_i64() {
            Some(i) => json_dec_ok(i),
            None    => match n.as_f64() {
                Some(f) => json_dec_ok(f as i64),
                None    => json_dec_err_str(format!("column {}: expected Int, number out of range", col)),
            },
        },
        JsonVal::String(s) => {
            // Accept "42" or "3.0" (decimal truncation like Go).
            if let Ok(i) = s.parse::<i64>() { return json_dec_ok(i); }
            if let Ok(f) = s.parse::<f64>() { return json_dec_ok(f as i64); }
            json_dec_err_str(format!("column {}: expected Int, got {:?}", col, s))
        },
        JsonVal::Null => json_dec_err_str(format!("column {}: expected Int, got NULL", col)),
        _ => json_dec_err_str(format!("column {}: expected Int, got unexpected type", col)),
    }))
}

/// `DbDec.float col` — read column `col` as a Float (f64).
/// Matches Go's DbDec_float truthy table (float64/int/int64/string forms).
pub fn db_dec_float<E: From<String> + 'static>(col: String) -> Decoder<E, f64> {
    json_dec_field(col.clone(), Box::new(move |v| match v {
        JsonVal::Number(n) => match n.as_f64() {
            Some(f) => json_dec_ok(f),
            None    => json_dec_err_str(format!("column {}: expected Float, number unrepresentable as f64", col)),
        },
        JsonVal::String(s) => match s.parse::<f64>() {
            Ok(f)  => json_dec_ok(f),
            Err(_) => json_dec_err_str(format!("column {}: expected Float, got {:?}", col, s)),
        },
        JsonVal::Null => json_dec_err_str(format!("column {}: expected Float, got NULL", col)),
        _ => json_dec_err_str(format!("column {}: expected Float, got unexpected type", col)),
    }))
}

/// `DbDec.bool col` — read column `col` as a Bool.
/// Truthy table (matches Go DbDec_bool):
///   true  ← "true" | "TRUE" | "True" | "t" | "T" | "1" | JSON true  | int 1  | int64 1
///   false ← "false"| "FALSE"| "False"| "f" | "F" | "0" | JSON false | int 0  | int64 0
/// NULL or unrecognised string → Err.
pub fn db_dec_bool<E: From<String> + 'static>(col: String) -> Decoder<E, bool> {
    json_dec_field(col.clone(), Box::new(move |v| match v {
        JsonVal::Bool(b) => json_dec_ok(*b),
        JsonVal::Number(n) => match n.as_i64() {
            Some(i) => json_dec_ok(i != 0),
            None    => json_dec_err_str(format!("column {}: expected Bool, numeric value unrepresentable", col)),
        },
        JsonVal::String(s) => match s.as_str() {
            "true"  | "TRUE"  | "True"  | "t" | "T" | "1" => json_dec_ok(true),
            "false" | "FALSE" | "False" | "f" | "F" | "0" => json_dec_ok(false),
            _ => json_dec_err_str(format!("column {}: expected Bool, got {:?}", col, s)),
        },
        JsonVal::Null => json_dec_err_str(format!("column {}: expected Bool, got NULL", col)),
        _ => json_dec_err_str(format!("column {}: expected Bool, got unexpected type", col)),
    }))
}

/// `DbDec.money col` — read column `col` as a `(Decimal, String)` pair
/// representing `(amount, currency_code)`.
///
/// The DB column stores a TEXT value in `"ISO_CODE AMOUNT"` format
/// (e.g. `"USD 1234.56"`, `"BTC 0.00012"`), written by `SqlMoney` on the
/// bind side (v0.16.26 #582).
///
/// ### Type representation
///
/// The Sky `Money` ADT is `type Money = Money Decimal Currency` — a generated
/// user-space type (`StdMoneyMoney::Money(StdDecimalDecimal, StdMoneyCurrency)`)
/// that differs per project. The Rust runtime has no single `Money` type to
/// return from a generic `Decoder<E, T>`.  The return type is therefore
/// `(Decimal, String)` — a structural pair that a codegen-emitted wrapper can
/// destructure into the project's concrete `StdMoneyMoney::Money(amount, currency)`.
///
/// For Phase A the Kernel.hs routing entry **cannot** be wired directly to
/// `db_dec_money` without a codegen-level wrapper that constructs
/// `StdMoneyMoney` from the `(Decimal, String)`.  See the BLOCKED note in the
/// Phase A output.
///
/// Totality: missing column, NULL, bad format, unparseable amount → `Err`.
pub fn db_dec_money<E: From<String> + 'static>(col: String) -> Decoder<E, (Decimal, String)> {
    json_dec_field(col.clone(), Box::new(move |v| {
        let s = match v {
            JsonVal::String(s) => s.clone(),
            JsonVal::Null      => return json_dec_err_str(format!("column {}: expected Money 'CODE AMOUNT', got NULL", col)),
            _                  => return json_dec_err_str(format!("column {}: expected Money 'CODE AMOUNT' string", col)),
        };
        // Find the first space separating the currency code from the amount.
        match s.find(' ') {
            None | Some(0) => json_dec_err_str(format!(
                "column {}: expected Money 'CODE AMOUNT', got {:?} (no space separator)", col, s
            )),
            Some(idx) if idx >= s.len() - 1 => json_dec_err_str(format!(
                "column {}: expected Money 'CODE AMOUNT', got {:?} (empty amount)", col, s
            )),
            Some(idx) => {
                let code = s[..idx].to_string();
                let amount_str = &s[idx+1..];
                use rust_decimal::Decimal as RD;
                use std::str::FromStr;
                match RD::from_str(amount_str) {
                    Ok(d)  => json_dec_ok((Decimal(d), code)),
                    Err(e) => json_dec_err_str(format!(
                        "column {}: Money amount parse error for {:?}: {}", col, amount_str, e
                    )),
                }
            }
        }
    }))
}

/// `DbDec.nullable inner` — wrap a field-level `inner` decoder so it returns
/// `Nothing` when the named column is NULL (or absent), `Just <decoded>` otherwise.
///
/// **Usage**: pass the column name AND a field-level decoder:
/// ```text
/// db_dec_nullable("age".to_string(), db_dec_int("age".to_string()))
/// ```
/// The col parameter is used to peek at the raw `JsonVal` in the row for the
/// named column BEFORE running the inner decoder; if it is `JsonVal::Null` (SQL
/// NULL from `row_to_json`) or absent → `Ok(Nothing)`. Otherwise the inner field
/// decoder is delegated to, and its result is wrapped in `Just`.
///
/// This matches Go's `DbDec_nullable` v0.16.x single-arg shape (#577): Go
/// achieves the gate by checking `inner.cols` against the row; we achieve it
/// by an explicit `col` peek (simpler, equally correct, and avoids storing
/// cols metadata in the Decoder type).
///
/// Totality: Null/absent → Ok(Nothing); inner Err → Err (structural mismatch,
/// not NULL); inner Ok(t) → Ok(Just(t)).
pub fn db_dec_nullable<E: From<String> + 'static, T: Send + 'static>(
    col: String,
    inner: Decoder<E, T>,
) -> Decoder<E, SkyMaybe<T>> {
    Box::new(move |v| {
        // Peek at the raw value for this column in the row object.
        match v.get(&col) {
            // Column absent or explicitly NULL → Nothing (SQL NULL).
            None | Some(JsonVal::Null) => json_dec_ok(SkyMaybe::Nothing),
            // Column present and non-null → delegate to inner (the full row object is passed
            // so the inner field decoder can still peel the column name).
            Some(_) => match inner(v) {
                SkyResult::Ok(t)  => json_dec_ok(SkyMaybe::Just(t)),
                SkyResult::Err(e) => SkyResult::Err(e),
            },
        }
    })
}

/// `DbDec.required col fieldDec ctorDec` — pipeline step for a required column.
///
/// Reads `col` from the row object using `fieldDec`, then applies the partial
/// constructor stored in `ctorDec`. Mirrors Go's `DbDec_required` which is
/// `DbDec_andMap(fieldDec, ctorDec)` — the column name is documentation-only
/// (the field decoder already names its column).
///
/// BLOCKED: the `Box<dyn FnOnce(T) -> F + Send>` accumulator in `ctorDec`
/// requires `FnOnce` (consumed on first call) but `Decoder<E, X>` is
/// `Box<dyn Fn(&JsonVal) -> SkyResult<E, X> + Send>` — callable multiple
/// times via `Fn`.  A `Decoder` wrapping a `FnOnce` closure can't satisfy
/// `Fn`.  Attempting to call it twice would move out of the closure.
///
/// This is the SAME fundamental type-system mismatch documented in
/// `runtime-rust/CLAUDE.md` Phase-3 limitation #2 ("JSON pipeline decoder —
/// Box<dyn FnOnce> chain from json_dec_p_required/optional + json_dec_succeed
/// can't satisfy Clone/Send").  `db_dec_required` / `db_dec_optional` hit the
/// exact same wall.
///
/// **Status: BLOCKED.** The entries are wired to `json_dec_p_required` /
/// `json_dec_p_optional` in Kernel.hs (which also maps
/// `Json.Decode.Pipeline.required/optional`), so Sky code that uses the
/// `required`/`optional` pipeline style with DbDec follows the same path as
/// JsonDec pipeline — see the runtime's existing `json_dec_p_required` /
/// `json_dec_p_optional` in json.rs for the current partial implementation.
///
/// This stub documents the in-boundary decision: DO NOT re-implement as a
/// separate `db_dec_required`; route to `json_dec_p_required` in Kernel.hs.
#[allow(dead_code)]
pub fn db_dec_required_stub() {
    // BLOCKED — see doc comment above.
    // Kernel.hs routes ("DbDec","required") → "json_dec_p_required"
    // and ("DbDec","optional") → "json_dec_p_optional".
}

// ─── Connection-lifecycle hardening ───────────────────────────────────────────
//
// `Db` (sqlx `Pool`) is an `Arc`-backed handle DESIGNED to be cloned and shared
// process-wide. The Sky compiler lowers an idiomatic top-level
// `dbConn = Task.run (Db.connect ())` binding as a per-call function, so a user
// who references it per request/session re-enters `db_connect` on every request.
// sqlx's `Pool::connect` is EAGER (real I/O per call), so without a cache that
// pattern (a) churns connections and, on Postgres/MySQL, (b) blows straight
// through the server's `max_connections` cap — a resource-exhaustion / DoS vector
// driven purely by unpredictable user code. The runtime MUST absorb that
// (runtime-rust/CLAUDE.md: consistent, secure, sound, efficient under any
// well-typed Sky program). So `Db.connect <url>` resolves to ONE bounded,
// shared pool per URL — independent of how often the user calls it.

/// Process-global pool registry keyed by connection URL.
fn pool_cache() -> &'static std::sync::Mutex<HashMap<String, Db>> {
    static C: std::sync::OnceLock<std::sync::Mutex<HashMap<String, Db>>> =
        std::sync::OnceLock::new();
    C.get_or_init(|| std::sync::Mutex::new(HashMap::new()))
}

/// `:memory:` SQLite URLs must NOT be shared: each connection to `sqlite::memory:`
/// is a DISTINCT in-memory database, so a shared pool would silently merge what
/// callers expect to be isolated DBs (soundness). File / network URLs are safe —
/// and correct — to share.
fn url_is_cacheable(url: &str) -> bool {
    !url.contains("memory")
}

/// Upper bound on pooled connections per database. Bounded by default so that
/// arbitrary user code calling `Db.connect` can NEVER exhaust the database
/// server's connection limit; raise via `SKY_DB_MAX_CONNECTIONS` for workloads
/// that genuinely need more headroom.
fn max_pool_connections() -> u32 {
    std::env::var("SKY_DB_MAX_CONNECTIONS")
        .ok()
        .and_then(|v| v.parse::<u32>().ok())
        .filter(|n| *n > 0)
        .unwrap_or(16)
}

/// Build one configured pool. SQLite (file, not `:memory:`) gets WAL — concurrent
/// readers alongside a single writer — plus a `busy_timeout` so lock contention
/// WAITS (sound) instead of erroring with `SQLITE_BUSY`. Without WAL a shared pool
/// serialises every statement on the rollback-journal lock (the contention that a
/// naive cache-only change regressed). The PRAGMAs are a no-op for other drivers
/// (guarded by the url scheme).
async fn build_pool<E: Send + From<String> + 'static>(url: &str) -> SkyResult<E, Db> {
    let pool: Db = match sqlx::pool::PoolOptions::new()
        .max_connections(max_pool_connections())
        .connect(url)
        .await
    {
        Ok(p) => p,
        Err(e) => return SkyResult::Err(sky_err(&e)),
    };
    if url.contains("sqlite") && url_is_cacheable(url) {
        let _ = sqlx::query("PRAGMA journal_mode=WAL;").execute(&pool).await;
        let _ = sqlx::query("PRAGMA busy_timeout=5000;").execute(&pool).await;
    }
    ok_res(pool)
}

/// Connect to `url`, returning a clone of the cached pool on a hit. On a miss the
/// pool is built with NO lock held (never block other tasks on connect I/O); a
/// concurrent miss that built a redundant pool loses the `entry` race and its
/// extra pool drops (closes) — steady state keeps exactly one pool per URL.
async fn connect_cached<E: Send + From<String> + 'static>(url: String) -> SkyResult<E, Db> {
    if url_is_cacheable(&url) {
        let g = pool_cache().lock().unwrap_or_else(|e| e.into_inner());
        if let Some(p) = g.get(&url) {
            return ok_res(p.clone());
        }
    }
    match build_pool::<E>(&url).await {
        SkyResult::Ok(pool) => {
            if url_is_cacheable(&url) {
                let mut g = pool_cache().lock().unwrap_or_else(|e| e.into_inner());
                ok_res(g.entry(url).or_insert(pool).clone())
            } else {
                ok_res(pool)
            }
        }
        SkyResult::Err(e) => SkyResult::Err(e),
    }
}

pub fn db_connect<E: Send + From<String> + 'static>(_unit: ()) -> SkyTask<E, Db> {
    Box::pin(connect_cached(SKY_DB_URL.to_string()))
}

/// `Db.open : String -> String -> Task Error Db` (driver, path). The compiled
/// `DbPool` type is already fixed by the sky.toml driver, so `driver` is
/// informational; we connect using `path`. For sqlite a bare file path needs a
/// `sqlite://…?mode=rwc` URL (create-if-missing); other drivers pass `path`
/// through as the connection string. (Was wrongly `(_unit: ())` → ignored both
/// args → E0061 at every `Db.open "sqlite" "x.db"` call site.)
pub fn db_open<E: Send + From<String> + 'static>(driver: String, path: String) -> SkyTask<E, Db> {
    let url = if driver == "sqlite" && !path.contains(':') {
        format!("sqlite://{}?mode=rwc", path)
    } else {
        path
    };
    Box::pin(connect_cached(url))
}

pub fn db_open_with_path<E: Send + From<String> + 'static>(path: String) -> SkyTask<E, Db> {
    Box::pin(connect_cached(path))
}

pub fn db_exec_raw<E: Send + From<String> + 'static>(conn: Db, sql: String) -> SkyTask<E, ()> {
    Box::pin(async move {
        match sqlx::query(&sql).execute(&conn).await {
            Ok(_) => ok_res(()),
            Err(e) => SkyResult::Err(sky_err(&e)),
        }
    })
}

pub fn db_exec<E: Send + From<String> + 'static>(conn: Db, sql: String, params: Vec<String>) -> SkyTask<E, ()> {
    Box::pin(async move {
        // Same path as the structured kernels: `db_format_sql` adapts `?`
        // placeholders per backend, then bind positionally. sqlx owns the
        // escaping; a placeholder/param count mismatch surfaces as Err.
        let final_sql = db_format_sql(sql);
        let mut q = sqlx::query(&final_sql);
        for p in params { q = q.bind(p); }
        match q.execute(&conn).await {
            Ok(_) => ok_res(()),
            Err(e) => SkyResult::Err(sky_err(&e)),
        }
    })
}

pub fn db_query<E: Send + From<String> + 'static>(conn: Db, sql: String, params: Vec<String>) -> SkyTask<E, Vec<HashMap<String, String>>> {
    Box::pin(async move {
        let final_sql = db_format_sql(sql);
        let mut q = sqlx::query(&final_sql);
        for p in params { q = q.bind(p); }
        match q.fetch_all(&conn).await {
            Ok(rows) => ok_res(rows.iter().map(row_to_map).collect()),
            Err(e) => SkyResult::Err(sky_err(&e)),
        }
    })
}

/// A value a Sky `Db.get*` accessor can read string-keyed fields from.
///
/// Sky's `getString : String -> row -> String` is polymorphic in `row`; the
/// row can be a query result (`Dict String String`), a pub/sub `Dict` payload,
/// or the typed `LiveReq` an `init` handler receives. `SkyRow` is the seam that
/// lets the Rust accessors stay generic and monomorphise per row type — no
/// `dyn Any`, no panic (an absent field reads as `""`).
pub trait SkyRow {
    fn sky_get(&self, field: &str) -> String;
}

// `SkyDict<String>` is a transparent alias for `HashMap<String, String>`, so this
// is the impl for every Dict-shaped row (query rows + pub/sub Dict payloads).
// Named via the alias for intent; a genuine newtype is tracked as a future task.
impl SkyRow for SkyDict<String> {
    fn sky_get(&self, field: &str) -> String {
        self.get(field).cloned().unwrap_or_default()
    }
}

// The typed request an `init` handler receives. `Db.getString "path" req` reads
// the named field; `params`/`headers`/`cookies` are searched for any other key.
#[cfg(feature = "live")]
impl SkyRow for super::LiveReq {
    fn sky_get(&self, field: &str) -> String {
        match field {
            "path" => self.path.clone(),
            "query" => self.query.clone(),
            "method" => self.method.clone(),
            _ => self
                .params
                .get(field)
                .or_else(|| self.headers.get(field))
                .or_else(|| self.cookies.get(field))
                .cloned()
                .unwrap_or_default(),
        }
    }
}

pub fn db_get_field<R: SkyRow>(field: String, row: R) -> String {
    row.sky_get(&field)
}

pub fn db_get_string<R: SkyRow>(field: String, row: R) -> String {
    row.sky_get(&field)
}

pub fn db_get_int<R: SkyRow>(field: String, row: R) -> i64 {
    row.sky_get(&field).parse::<i64>().unwrap_or(0)
}

pub fn db_migrate_apply<E: Send + From<String> + 'static>(db: Db, migrations: Vec<(String, String)>) -> SkyTask<E, Vec<String>> {
    Box::pin(async move {
        let mut applied = Vec::new();
        for (name, sql) in migrations {
            match db_exec_raw(db.clone(), sql).await {
                SkyResult::Ok(_) => applied.push(name),
                SkyResult::Err(e) => return SkyResult::Err(e),
            }
        }
        SkyResult::Ok(applied)
    })
}

// ─── Additional Std.Db kernels ────────────────────────────────────────

/// `close : Db -> Task Error ()` — sqlx::Pool drops on its own; this is
/// a graceful explicit close (any in-flight queries finish, then the
/// pool is closed).
pub fn db_close<E: Send + From<String> + 'static>(db: Db) -> SkyTask<E, ()> {
    Box::pin(async move {
        db.close().await;
        ok_res(())
    })
}

/// `getBool : String -> Dict String String -> Bool` — parses common
/// truthy values (`"1"`, `"true"`, `"TRUE"`, `"t"`, `"T"`).
pub fn db_get_bool<R: SkyRow>(field: String, row: R) -> bool {
    matches!(
        row.sky_get(&field).as_str(),
        "1" | "true" | "TRUE" | "t" | "T"
    )
}

/// Quote an identifier (table/column name) for safe SQL inclusion.
/// Allows only [A-Za-z0-9_]; returns empty on invalid input.
fn safe_ident(name: &str) -> String {
    if name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_') && !name.is_empty() {
        name.to_string()
    } else {
        String::new()
    }
}

/// `insertRow : Db -> String -> Dict String String -> Task Error Int` —
/// returns the inserted row's id (lastInsertRowid for sqlite).
pub fn db_insert_row<E: Send + From<String> + 'static>(
    conn: Db, table: String, row: HashMap<String, String>
) -> SkyTask<E, i64> {
    Box::pin(async move {
        let qtable = safe_ident(&table);
        if qtable.is_empty() {
            return SkyResult::Err(format!("db.insertRow: invalid table name {:?}", table).into());
        }
        if row.is_empty() {
            return SkyResult::Err("db.insertRow: empty row".to_string().into());
        }
        let mut keys: Vec<&String> = row.keys().collect();
        keys.sort();  // deterministic column order
        let col_names: Vec<String> = keys.iter().map(|k| safe_ident(k)).collect();
        if col_names.iter().any(|c| c.is_empty()) {
            return SkyResult::Err("db.insertRow: invalid column name".to_string().into());
        }
        let placeholders = vec!["?"; col_names.len()].join(", ");
        let base = format!(
            "INSERT INTO {} ({}) VALUES ({})",
            qtable, col_names.join(", "), placeholders
        );
        if DB_USES_RETURNING_ID {
            // Postgres has no LastInsertId — append `RETURNING id` and read the
            // generated key (matches the Go backend's pgx path). `id` is
            // BIGSERIAL (i64) by db_auto_id_column, but a user table may use
            // SERIAL (i32); try both and degrade to 0 (never panic) on mismatch.
            let sql = db_format_sql(format!("{} RETURNING id", base));
            let mut q = sqlx::query(&sql);
            for k in &keys {
                q = q.bind(row.get(*k).cloned().unwrap_or_default());
            }
            match q.fetch_one(&conn).await {
                Ok(r) => ok_res(
                    r.try_get::<i64, _>("id")
                        .or_else(|_| r.try_get::<i32, _>("id").map(|v| v as i64))
                        .unwrap_or(0),
                ),
                Err(e) => SkyResult::Err(sky_err(&e)),
            }
        } else {
            let sql = db_format_sql(base);
            let mut q = sqlx::query(&sql);
            for k in &keys {
                q = q.bind(row.get(*k).cloned().unwrap_or_default());
            }
            match q.execute(&conn).await {
                Ok(res) => ok_res(db_last_insert_id(&res)),
                Err(e) => SkyResult::Err(sky_err(&e)),
            }
        }
    })
}

/// `getById : Db -> String -> String -> Task Error (Maybe (Dict String String))`.
pub fn db_get_by_id<E: Send + From<String> + 'static>(
    conn: Db, table: String, id: String
) -> SkyTask<E, SkyMaybe<HashMap<String, String>>> {
    Box::pin(async move {
        let qtable = safe_ident(&table);
        if qtable.is_empty() {
            return SkyResult::Err(format!("db.getById: invalid table name {:?}", table).into());
        }
        let sql = db_format_sql(format!("SELECT * FROM {} WHERE id = ? LIMIT 1", qtable));
        match sqlx::query(&sql).bind(id).fetch_optional(&conn).await {
            Ok(Some(r)) => ok_res(SkyMaybe::Just(row_to_map(&r))),
            Ok(None) => ok_res(SkyMaybe::Nothing),
            Err(e) => SkyResult::Err(sky_err(&e)),
        }
    })
}

/// `updateById : Db -> String -> String -> Dict String String -> Task Error Int` —
/// returns the affected row count.
pub fn db_update_by_id<E: Send + From<String> + 'static>(
    conn: Db, table: String, id: String, row: HashMap<String, String>
) -> SkyTask<E, i64> {
    Box::pin(async move {
        let qtable = safe_ident(&table);
        if qtable.is_empty() {
            return SkyResult::Err(format!("db.updateById: invalid table name {:?}", table).into());
        }
        if row.is_empty() {
            return ok_res(0);
        }
        let mut keys: Vec<&String> = row.keys().collect();
        keys.sort();
        let col_names: Vec<String> = keys.iter().map(|k| safe_ident(k)).collect();
        if col_names.iter().any(|c| c.is_empty()) {
            return SkyResult::Err("db.updateById: invalid column name".to_string().into());
        }
        let sets: Vec<String> = col_names.iter().map(|c| format!("{} = ?", c)).collect();
        let sql = db_format_sql(format!("UPDATE {} SET {} WHERE id = ?", qtable, sets.join(", ")));
        let mut q = sqlx::query(&sql);
        for k in &keys {
            q = q.bind(row.get(*k).cloned().unwrap_or_default());
        }
        q = q.bind(id);
        match q.execute(&conn).await {
            Ok(res) => ok_res(res.rows_affected() as i64),
            Err(e) => SkyResult::Err(sky_err(&e)),
        }
    })
}

/// `deleteById : Db -> String -> String -> Task Error Int` — returns
/// the affected row count (0 or 1).
pub fn db_delete_by_id<E: Send + From<String> + 'static>(
    conn: Db, table: String, id: String
) -> SkyTask<E, i64> {
    Box::pin(async move {
        let qtable = safe_ident(&table);
        if qtable.is_empty() {
            return SkyResult::Err(format!("db.deleteById: invalid table name {:?}", table).into());
        }
        let sql = db_format_sql(format!("DELETE FROM {} WHERE id = ?", qtable));
        match sqlx::query(&sql).bind(id).execute(&conn).await {
            Ok(res) => ok_res(res.rows_affected() as i64),
            Err(e) => SkyResult::Err(sky_err(&e)),
        }
    })
}

/// `findOneByField : Db -> String -> String -> String -> Task Error (Maybe (Dict String String))`.
pub fn db_find_one_by_field<E: Send + From<String> + 'static>(
    conn: Db, table: String, field: String, value: String
) -> SkyTask<E, SkyMaybe<HashMap<String, String>>> {
    Box::pin(async move {
        let qtable = safe_ident(&table);
        let qfield = safe_ident(&field);
        if qtable.is_empty() || qfield.is_empty() {
            return SkyResult::Err(format!("db.findOneByField: invalid identifier in {:?}.{:?}", table, field).into());
        }
        let sql = db_format_sql(format!("SELECT * FROM {} WHERE {} = ? LIMIT 1", qtable, qfield));
        match sqlx::query(&sql).bind(value).fetch_optional(&conn).await {
            Ok(Some(r)) => ok_res(SkyMaybe::Just(row_to_map(&r))),
            Ok(None) => ok_res(SkyMaybe::Nothing),
            Err(e) => SkyResult::Err(sky_err(&e)),
        }
    })
}

/// `findManyByField : Db -> String -> String -> String -> Task Error (List (Dict String String))`.
pub fn db_find_many_by_field<E: Send + From<String> + 'static>(
    conn: Db, table: String, field: String, value: String
) -> SkyTask<E, Vec<HashMap<String, String>>> {
    Box::pin(async move {
        let qtable = safe_ident(&table);
        let qfield = safe_ident(&field);
        if qtable.is_empty() || qfield.is_empty() {
            return SkyResult::Err(format!("db.findManyByField: invalid identifier in {:?}.{:?}", table, field).into());
        }
        let sql = db_format_sql(format!("SELECT * FROM {} WHERE {} = ?", qtable, qfield));
        match sqlx::query(&sql).bind(value).fetch_all(&conn).await {
            Ok(rows) => ok_res(rows.iter().map(row_to_map).collect()),
            Err(e) => SkyResult::Err(sky_err(&e)),
        }
    })
}

/// `findByConditions : Db -> String -> Dict String String -> Task Error (List (Dict String String))` —
/// AND-joined equality on every key/value pair.
pub fn db_find_by_conditions<E: Send + From<String> + 'static>(
    conn: Db, table: String, conditions: HashMap<String, String>
) -> SkyTask<E, Vec<HashMap<String, String>>> {
    Box::pin(async move {
        let qtable = safe_ident(&table);
        if qtable.is_empty() {
            return SkyResult::Err(format!("db.findByConditions: invalid table {:?}", table).into());
        }
        let mut keys: Vec<&String> = conditions.keys().collect();
        keys.sort();
        let qfields: Vec<String> = keys.iter().map(|k| safe_ident(k)).collect();
        if qfields.iter().any(|c| c.is_empty()) {
            return SkyResult::Err("db.findByConditions: invalid column name".to_string().into());
        }
        let sql = db_format_sql(if keys.is_empty() {
            format!("SELECT * FROM {}", qtable)
        } else {
            let wheres: Vec<String> = qfields.iter().map(|c| format!("{} = ?", c)).collect();
            format!("SELECT * FROM {} WHERE {}", qtable, wheres.join(" AND "))
        });
        let mut q = sqlx::query(&sql);
        for k in &keys {
            q = q.bind(conditions.get(*k).cloned().unwrap_or_default());
        }
        match q.fetch_all(&conn).await {
            Ok(rows) => ok_res(rows.iter().map(row_to_map).collect()),
            Err(e) => SkyResult::Err(sky_err(&e)),
        }
    })
}

/// `unsafeFindWhere : Db -> String -> String -> List String -> Task Error (List (Dict String String))` —
/// raw WHERE clause with parameterised args. Vulnerable to injection if
/// the where-clause is built from untrusted input.
pub fn db_unsafe_find_where<E: Send + From<String> + 'static>(
    conn: Db, table: String, where_clause: String, args: Vec<String>
) -> SkyTask<E, Vec<HashMap<String, String>>> {
    Box::pin(async move {
        let qtable = safe_ident(&table);
        if qtable.is_empty() {
            return SkyResult::Err(format!("db.unsafeFindWhere: invalid table {:?}", table).into());
        }
        let sql = format!("SELECT * FROM {} WHERE {}", qtable, where_clause);
        db_query(conn, sql, args).await
    })
}

/// `queryDecode : Db -> String -> List String -> Decoder a -> Task Error (List a)` —
/// typed query with a per-row decoder (Decoder<E,A>). Builds a NULL-preserving
/// `JsonVal::Object` per row (via `row_to_json`) and runs the decoder against it.
/// Fails fast on the first decode error.
///
/// The `Decoder<E,A>` is `Box<dyn Fn(&JsonVal) -> SkyResult<E,A> + Send>`. Moving
/// it into the async block is sound: it is `Send`, and calling `decoder(&jv)` is
/// a shared-reference call (no move out of the box). No `Arc` needed.
pub fn db_query_decode<E: Send + From<String> + 'static, A: Send + 'static>(
    conn: Db, sql: String, params: Vec<String>,
    decoder: Decoder<E, A>,
) -> SkyTask<E, Vec<A>> {
    Box::pin(async move {
        let final_sql = db_format_sql(sql);
        let mut q = sqlx::query(&final_sql);
        for p in params { q = q.bind(p); }
        let rows = match q.fetch_all(&conn).await {
            Ok(r)  => r,
            Err(e) => return SkyResult::Err(sky_err(&e)),
        };
        let mut out = Vec::with_capacity(rows.len());
        for row in &rows {
            let jv = row_to_json(row);
            match decoder(&jv) {
                SkyResult::Ok(a)  => out.push(a),
                SkyResult::Err(e) => return SkyResult::Err(e),
            }
        }
        ok_res(out)
    })
}

/// `getByIdDecode : Db -> String -> Int -> Decoder a -> Task Error (Maybe a)` —
/// SELECT * FROM `table` WHERE id = `id` LIMIT 1; returns Nothing when no row
/// matches, Just(decoded) on success, Err on DB error or decode error.
///
/// Security: `id` is bound via a parameterised placeholder (`?`), NEVER
/// string-interpolated into SQL.
pub fn db_get_by_id_decode<E: Send + From<String> + 'static, A: Send + 'static>(
    conn: Db, table: String, id: i64, decoder: Decoder<E, A>,
) -> SkyTask<E, SkyMaybe<A>> {
    Box::pin(async move {
        let qtable = safe_ident(&table);
        if qtable.is_empty() {
            return SkyResult::Err(
                format!("db.getByIdDecode: invalid table name {:?}", table).into()
            );
        }
        // id is bound as a parameter — injection-safe.
        let sql = db_format_sql(format!("SELECT * FROM {} WHERE id = ? LIMIT 1", qtable));
        match sqlx::query(&sql).bind(id).fetch_optional(&conn).await {
            Ok(None)       => ok_res(SkyMaybe::Nothing),
            Ok(Some(row))  => {
                let jv = row_to_json(&row);
                match decoder(&jv) {
                    SkyResult::Ok(a)  => ok_res(SkyMaybe::Just(a)),
                    SkyResult::Err(e) => SkyResult::Err(e),
                }
            },
            Err(e) => SkyResult::Err(sky_err(&e)),
        }
    })
}

/// `withTransaction : Db -> (Db -> Task Error a) -> Task Error a` —
/// runs the body inside a transaction. Commits on Ok, rolls back on Err.
///
/// **Connection semantics:** sqlx::Pool dispatches each query to any
/// connection in the pool. To make BEGIN/COMMIT/ROLLBACK actually
/// transactional, the body MUST run all its statements on the same
/// connection that issued BEGIN. We acquire one explicit connection
/// from the pool, exec the transaction-control statements on it, and
/// the body uses the same pool — but sqlx may route the body's queries
/// to other connections. For true rollback isolation in production
/// code, prefer single-connection pools (`max_connections(1)`).
///
/// This implementation is correct for single-user scripts (sqlite default)
/// and provides best-effort isolation for multi-user pools. Real
/// transactional integrity over a shared pool requires `sqlx::Transaction`
/// borrow semantics, which can't fit the Sky-side `Db -> Task Error a`
/// shape (which passes Db by ownership, not borrow).
pub fn db_with_transaction<E: Send + From<String> + 'static, A: Send + 'static>(
    conn: Db,
    body: impl Fn(Db) -> SkyTask<E, A> + Send + 'static,
) -> SkyTask<E, A> {
    Box::pin(async move {
        if let Err(e) = sqlx::query("BEGIN").execute(&conn).await {
            return SkyResult::Err(sky_err(&e));
        }
        match body(conn.clone()).await {
            SkyResult::Ok(a) => {
                if let Err(e) = sqlx::query("COMMIT").execute(&conn).await {
                    return SkyResult::Err(sky_err(&e));
                }
                ok_res(a)
            }
            SkyResult::Err(e) => {
                let _ = sqlx::query("ROLLBACK").execute(&conn).await;
                SkyResult::Err(e)
            }
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    // #52: the SkyRow accessor is total over a Dict-shaped row — present field
    // reads back, absent field is "" (never panics), int/bool parse + default.
    #[test]
    fn sky_row_hashmap_total() {
        let mut m: HashMap<String, String> = HashMap::new();
        m.insert("text".into(), "ping".into());
        m.insert("count".into(), "42".into());
        m.insert("flag".into(), "true".into());
        assert_eq!(db_get_string("text".into(), m.clone()), "ping");
        assert_eq!(db_get_string("missing".into(), m.clone()), "");
        assert_eq!(db_get_int("count".into(), m.clone()), 42);
        assert_eq!(db_get_int("missing".into(), m.clone()), 0);
        assert!(db_get_bool("flag".into(), m.clone()));
        assert!(!db_get_bool("missing".into(), m));
    }

    // #52 Part 1: `Db.getString "path" req` on an `init` handler's typed
    // request reads the named struct field; params/headers/cookies back any
    // other key; absent -> "" (total).
    #[cfg(feature = "live")]
    #[test]
    fn sky_row_livereq_named_fields_and_dicts() {
        let mut params: HashMap<String, String> = HashMap::new();
        params.insert("slug".into(), "general".into());
        let mut cookies: HashMap<String, String> = HashMap::new();
        cookies.insert("sky_sid".into(), "abc".into());
        let req = crate::sky_runtime::LiveReq {
            path: "/chat/general".into(),
            query: "x=1".into(),
            method: "GET".into(),
            params,
            headers: HashMap::new(),
            cookies,
        };
        assert_eq!(db_get_string("path".into(), req.clone()), "/chat/general");
        assert_eq!(db_get_string("method".into(), req.clone()), "GET");
        assert_eq!(db_get_string("query".into(), req.clone()), "x=1");
        assert_eq!(db_get_string("slug".into(), req.clone()), "general"); // params
        assert_eq!(db_get_string("sky_sid".into(), req.clone()), "abc"); // cookies
        assert_eq!(db_get_string("nope".into(), req), ""); // absent -> total ""
    }

    async fn fresh_db() -> Db {
        // A SINGLE persistent connection per test. `sqlite::memory:` gives each
        // pool connection its OWN in-memory database, so a default multi-conn
        // pool routes BEGIN / INSERT / COMMIT / SELECT to different (empty) DBs
        // — the source of the parallel-run flake (#27): under load the pool
        // opens extra connections and ops miss the table / committed row.
        // min=max=1 pins one connection (one DB, table + transactions always
        // visible); each test still gets its own isolated pool.
        let pool = sqlx::sqlite::SqlitePoolOptions::new()
            .min_connections(1)
            .max_connections(1)
            .connect("sqlite::memory:")
            .await
            .expect("connect in-memory sqlite");
        sqlx::query("CREATE TABLE todos (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL, done INTEGER NOT NULL DEFAULT 0)")
            .execute(&pool).await.expect("create table");
        pool
    }

    #[tokio::test]
    async fn test_insert_get_by_id() {
        let db = fresh_db().await;
        let mut row = HashMap::new();
        row.insert("title".to_string(), "buy milk".to_string());
        row.insert("done".to_string(), "0".to_string());
        let id: SkyResult<String, i64> = db_insert_row(db.clone(), "todos".into(), row).await;
        let id = match id { SkyResult::Ok(v) => v, SkyResult::Err(e) => panic!("{}", e) };
        assert!(id > 0);

        let fetched: SkyResult<String, SkyMaybe<HashMap<String, String>>> =
            db_get_by_id(db, "todos".into(), id.to_string()).await;
        match fetched {
            SkyResult::Ok(SkyMaybe::Just(m)) => assert_eq!(m.get("title").unwrap(), "buy milk"),
            other => panic!("unexpected: {:?}", other),
        }
    }

    #[tokio::test]
    async fn test_update_by_id() {
        let db = fresh_db().await;
        let mut row = HashMap::new();
        row.insert("title".to_string(), "x".to_string());
        let id: SkyResult<String, i64> = db_insert_row(db.clone(), "todos".into(), row).await;
        let id = match id { SkyResult::Ok(v) => v, _ => panic!("insert") };

        let mut updates = HashMap::new();
        updates.insert("title".to_string(), "y".to_string());
        let affected: SkyResult<String, i64> =
            db_update_by_id(db.clone(), "todos".into(), id.to_string(), updates).await;
        assert!(matches!(affected, SkyResult::Ok(1)));
    }

    #[tokio::test]
    async fn test_delete_by_id() {
        let db = fresh_db().await;
        let mut row = HashMap::new();
        row.insert("title".to_string(), "z".to_string());
        let id: SkyResult<String, i64> = db_insert_row(db.clone(), "todos".into(), row).await;
        let id = match id { SkyResult::Ok(v) => v, _ => panic!("insert") };
        let affected: SkyResult<String, i64> =
            db_delete_by_id(db, "todos".into(), id.to_string()).await;
        assert!(matches!(affected, SkyResult::Ok(1)));
    }

    #[tokio::test]
    async fn test_find_one_by_field() {
        let db = fresh_db().await;
        let mut row = HashMap::new();
        row.insert("title".to_string(), "find me".to_string());
        let _: SkyResult<String, i64> = db_insert_row(db.clone(), "todos".into(), row).await;
        let found: SkyResult<String, SkyMaybe<HashMap<String, String>>> =
            db_find_one_by_field(db, "todos".into(), "title".into(), "find me".into()).await;
        assert!(matches!(found, SkyResult::Ok(SkyMaybe::Just(_))));
    }

    #[tokio::test]
    async fn test_find_many_and_by_conditions() {
        let db = fresh_db().await;
        for t in ["a", "b", "c"] {
            let mut r = HashMap::new();
            r.insert("title".to_string(), t.to_string());
            r.insert("done".to_string(), "1".to_string());
            let _: SkyResult<String, i64> = db_insert_row(db.clone(), "todos".into(), r).await;
        }
        let many: SkyResult<String, Vec<HashMap<String, String>>> =
            db_find_many_by_field(db.clone(), "todos".into(), "done".into(), "1".into()).await;
        match many { SkyResult::Ok(v) => assert_eq!(v.len(), 3), _ => panic!("find many") }

        let mut cond = HashMap::new();
        cond.insert("done".to_string(), "1".to_string());
        cond.insert("title".to_string(), "b".to_string());
        let one: SkyResult<String, Vec<HashMap<String, String>>> =
            db_find_by_conditions(db, "todos".into(), cond).await;
        match one { SkyResult::Ok(v) => assert_eq!(v.len(), 1), _ => panic!("conds") }
    }

    #[tokio::test]
    async fn test_with_transaction_commit() {
        let db = fresh_db().await;
        let r: SkyResult<String, i64> = db_with_transaction(db.clone(), |c| {
            Box::pin(async move {
                let mut row = HashMap::new();
                row.insert("title".to_string(), "txn".to_string());
                db_insert_row(c, "todos".into(), row).await
            })
        }).await;
        assert!(matches!(r, SkyResult::Ok(_)));
        // The inserted row should be visible after commit:
        let found: SkyResult<String, Vec<HashMap<String, String>>> =
            db_find_many_by_field(db, "todos".into(), "title".into(), "txn".into()).await;
        match found { SkyResult::Ok(v) => assert_eq!(v.len(), 1), _ => panic!("post-commit fetch") }
    }

    #[tokio::test]
    async fn test_with_transaction_rollback_returns_err() {
        // The Err propagates correctly. The actual "row not visible after
        // rollback" guarantee depends on pool-connection routing — see the
        // doc comment on db_with_transaction. We assert only what the
        // shared-pool implementation can guarantee: Err propagation.
        let db = fresh_db().await;
        let r: SkyResult<String, i64> = db_with_transaction(db.clone(), |c| {
            Box::pin(async move {
                let mut row = HashMap::new();
                row.insert("title".to_string(), "txn-err".to_string());
                let _: SkyResult<String, i64> = db_insert_row(c, "todos".into(), row).await;
                SkyResult::Err("boom".to_string())
            })
        }).await;
        assert!(matches!(r, SkyResult::Err(_)));
    }

    #[tokio::test]
    async fn test_get_bool() {
        let mut r = HashMap::new();
        r.insert("a".to_string(), "1".to_string());
        r.insert("b".to_string(), "0".to_string());
        r.insert("c".to_string(), "true".to_string());
        r.insert("d".to_string(), "false".to_string());
        assert!(db_get_bool("a".into(), r.clone()));
        assert!(!db_get_bool("b".into(), r.clone()));
        assert!(db_get_bool("c".into(), r.clone()));
        assert!(!db_get_bool("d".into(), r.clone()));
        assert!(!db_get_bool("missing".into(), r));
    }

    #[tokio::test]
    async fn test_query_decode() {
        let db = fresh_db().await;
        let mut row = HashMap::new();
        row.insert("title".to_string(), "decoded".to_string());
        let _: SkyResult<String, i64> = db_insert_row(db.clone(), "todos".into(), row).await;
        // Use the Decoder<E,A> API: db_dec_string reads the "title" column from
        // the NULL-preserving JsonVal::Object produced by row_to_json.
        let decoded: SkyResult<String, Vec<String>> = db_query_decode(
            db, "SELECT title FROM todos".into(), vec![],
            db_dec_string("title".to_string()),
        ).await;
        match decoded {
            SkyResult::Ok(v) => assert_eq!(v, vec!["decoded".to_string()]),
            _ => panic!("decode")
        }
    }

    #[tokio::test]
    async fn test_query_decode_int_and_nullable() {
        let db = fresh_db().await;
        let mut row = HashMap::new();
        row.insert("title".to_string(), "item".to_string());
        row.insert("done".to_string(), "1".to_string());
        let _: SkyResult<String, i64> = db_insert_row(db.clone(), "todos".into(), row).await;

        // Test db_dec_int decodes the "done" column correctly.
        let decoded_int: SkyResult<String, Vec<i64>> = db_query_decode(
            db.clone(),
            "SELECT done FROM todos".into(),
            vec![],
            db_dec_int("done".to_string()),
        ).await;
        match decoded_int {
            SkyResult::Ok(v) => assert_eq!(v, vec![1i64]),
            _ => panic!("db_dec_int decode failed"),
        }

        // Test db_dec_bool.
        let decoded_bool: SkyResult<String, Vec<bool>> = db_query_decode(
            db.clone(),
            "SELECT done FROM todos".into(),
            vec![],
            db_dec_bool("done".to_string()),
        ).await;
        match decoded_bool {
            SkyResult::Ok(v) => assert_eq!(v, vec![true]),
            _ => panic!("db_dec_bool decode failed"),
        }
    }

    #[tokio::test]
    async fn test_query_decode_nullable_null() {
        // SQLite table with a nullable column.
        let pool = sqlx::sqlite::SqlitePoolOptions::new()
            .min_connections(1).max_connections(1)
            .connect("sqlite::memory:").await.expect("connect");
        sqlx::query(
            "CREATE TABLE items (id INTEGER PRIMARY KEY, label TEXT)"
        ).execute(&pool).await.expect("create");
        // Row with NULL label.
        sqlx::query("INSERT INTO items (id, label) VALUES (1, NULL)")
            .execute(&pool).await.expect("insert null");
        // Row with non-null label.
        sqlx::query("INSERT INTO items (id, label) VALUES (2, 'hello')")
            .execute(&pool).await.expect("insert some");

        // db_dec_nullable("label", db_dec_string("label")): NULL → Nothing, "hello" → Just("hello").
        let decoder: Decoder<String, SkyMaybe<String>> =
            db_dec_nullable("label".to_string(), db_dec_string("label".to_string()));

        // Check NULL row → Nothing.
        let r1: SkyResult<String, Vec<SkyMaybe<String>>> = db_query_decode(
            pool.clone(),
            "SELECT label FROM items WHERE id = 1".into(),
            vec![],
            db_dec_nullable("label".to_string(), db_dec_string("label".to_string())),
        ).await;
        let _ = decoder; // consumed above, need a fresh one
        match r1 {
            SkyResult::Ok(v) => {
                assert_eq!(v.len(), 1);
                assert!(matches!(v[0], SkyMaybe::Nothing), "expected Nothing for NULL, got {:?}", v[0]);
            }
            SkyResult::Err(e) => panic!("unexpected Err on NULL row: {}", e),
        }

        // Check non-NULL row → Just("hello").
        let r2: SkyResult<String, Vec<SkyMaybe<String>>> = db_query_decode(
            pool,
            "SELECT label FROM items WHERE id = 2".into(),
            vec![],
            db_dec_nullable("label".to_string(), db_dec_string("label".to_string())),
        ).await;
        match r2 {
            SkyResult::Ok(v) => {
                assert_eq!(v.len(), 1);
                assert!(matches!(&v[0], SkyMaybe::Just(s) if s == "hello"),
                        "expected Just(\"hello\"), got {:?}", v[0]);
            }
            SkyResult::Err(e) => panic!("unexpected Err on non-null row: {}", e),
        }
    }

    #[tokio::test]
    async fn test_get_by_id_decode() {
        let db = fresh_db().await;
        let mut row = HashMap::new();
        row.insert("title".to_string(), "find-me".to_string());
        let id: SkyResult<String, i64> = db_insert_row(db.clone(), "todos".into(), row).await;
        let id = match id { SkyResult::Ok(v) => v, _ => panic!("insert") };

        let found: SkyResult<String, SkyMaybe<String>> = db_get_by_id_decode(
            db.clone(), "todos".into(), id,
            db_dec_string("title".to_string()),
        ).await;
        match found {
            SkyResult::Ok(SkyMaybe::Just(s)) => assert_eq!(s, "find-me"),
            other => panic!("unexpected: {:?}", other),
        }

        // Non-existent id → Nothing.
        let not_found: SkyResult<String, SkyMaybe<String>> = db_get_by_id_decode(
            db, "todos".into(), 99999,
            db_dec_string("title".to_string()),
        ).await;
        assert!(matches!(not_found, SkyResult::Ok(SkyMaybe::Nothing)));
    }

    #[tokio::test]
    async fn test_db_dec_money_roundtrip() {
        // Verify db_dec_money parses "USD 12.34" → (Decimal(12.34), "USD").
        use rust_decimal::Decimal as RD;
        use std::str::FromStr;
        let decoder: Decoder<String, (Decimal, String)> = db_dec_money("price".to_string());
        let val = serde_json::json!({ "price": "USD 12.34" });
        let result = decoder(&val);
        match result {
            SkyResult::Ok((amount, code)) => {
                assert_eq!(code, "USD");
                assert_eq!(amount.0, RD::from_str("12.34").unwrap());
            }
            SkyResult::Err(e) => panic!("unexpected Err: {}", e),
        }

        // NULL → Err.
        let val_null = serde_json::json!({ "price": null });
        assert!(matches!(decoder(&val_null), SkyResult::Err(_)));

        // Bad format → Err.
        let val_bad = serde_json::json!({ "price": "NODECIMAL" });
        assert!(matches!(decoder(&val_bad), SkyResult::Err(_)));
    }

    #[tokio::test]
    async fn test_row_to_json_null_preservation() {
        // Verify that a SQL NULL cell becomes JsonVal::Null (not "").
        let pool = sqlx::sqlite::SqlitePoolOptions::new()
            .min_connections(1).max_connections(1)
            .connect("sqlite::memory:").await.expect("connect");
        sqlx::query("CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)")
            .execute(&pool).await.expect("create");
        sqlx::query("INSERT INTO t (id, v) VALUES (1, NULL)")
            .execute(&pool).await.expect("insert");
        let row = sqlx::query("SELECT v FROM t WHERE id = 1")
            .fetch_one(&pool).await.expect("fetch");
        let jv = row_to_json(&row);
        match jv.get("v") {
            Some(JsonVal::Null) => { /* correct */ },
            other => panic!("expected JsonVal::Null, got {:?}", other),
        }
    }

    #[tokio::test]
    async fn test_close() {
        let db = fresh_db().await;
        let r: SkyResult<String, ()> = db_close(db).await;
        assert!(matches!(r, SkyResult::Ok(())));
    }

    #[tokio::test]
    async fn test_unsafe_find_where() {
        let db = fresh_db().await;
        let mut r = HashMap::new();
        r.insert("title".to_string(), "alpha".to_string());
        let _: SkyResult<String, i64> = db_insert_row(db.clone(), "todos".into(), r).await;
        let found: SkyResult<String, Vec<HashMap<String, String>>> =
            db_unsafe_find_where(db, "todos".into(), "title = ?".into(), vec!["alpha".to_string()]).await;
        match found { SkyResult::Ok(v) => assert_eq!(v.len(), 1), _ => panic!("unsafe find") }
    }

    // ─── db_exec / db_query parameter-binding characterization (candidate B) ──────
    // These pin the param-carrying behavior of the raw exec/query kernels — the
    // two functions that route through the placeholder path. They lock the
    // contract across the build_sql → db_format_sql+bind deepening: same
    // round-trip values, same injection-safety, no behavior drift.

    /// A parameterised INSERT via db_exec then a parameterised SELECT via
    /// db_query round-trips the bound values.
    #[tokio::test]
    async fn test_exec_and_query_with_params() {
        let db = fresh_db().await;
        let ins: SkyResult<String, ()> = db_exec(
            db.clone(),
            "INSERT INTO todos (title, done) VALUES (?, ?)".into(),
            vec!["buy milk".to_string(), "0".to_string()],
        ).await;
        assert!(matches!(ins, SkyResult::Ok(())));

        let rows: SkyResult<String, Vec<HashMap<String, String>>> = db_query(
            db,
            "SELECT title, done FROM todos WHERE title = ?".into(),
            vec!["buy milk".to_string()],
        ).await;
        match rows {
            SkyResult::Ok(v) => {
                assert_eq!(v.len(), 1);
                assert_eq!(v[0].get("title").unwrap(), "buy milk");
                assert_eq!(v[0].get("done").unwrap(), "0");
            }
            other => panic!("unexpected: {:?}", other),
        }
    }

    /// The load-bearing safety property: a value carrying single quotes and SQL
    /// metacharacters is bound, not spliced — stored and returned VERBATIM, and
    /// the surrounding table is untouched (no injection executes).
    #[tokio::test]
    async fn test_query_param_with_quotes_and_metachars_roundtrips_safely() {
        let db = fresh_db().await;
        let nasty = "x'); DROP TABLE todos;-- O'Brien".to_string();
        let ins: SkyResult<String, ()> = db_exec(
            db.clone(),
            "INSERT INTO todos (title, done) VALUES (?, ?)".into(),
            vec![nasty.clone(), "0".to_string()],
        ).await;
        assert!(matches!(ins, SkyResult::Ok(())));

        // The value comes back byte-for-byte (proves it was bound, not splice-escaped-into-SQL).
        let rows: SkyResult<String, Vec<HashMap<String, String>>> = db_query(
            db.clone(),
            "SELECT title FROM todos WHERE title = ?".into(),
            vec![nasty.clone()],
        ).await;
        match rows {
            SkyResult::Ok(v) => {
                assert_eq!(v.len(), 1);
                assert_eq!(v[0].get("title").unwrap(), &nasty);
            }
            other => panic!("unexpected: {:?}", other),
        }

        // The table still exists with exactly the one row — the DROP never ran.
        let all: SkyResult<String, Vec<HashMap<String, String>>> =
            db_query(db, "SELECT title FROM todos".into(), vec![]).await;
        match all {
            SkyResult::Ok(v) => assert_eq!(v.len(), 1, "injection must not have dropped the table"),
            other => panic!("table gone or errored: {:?}", other),
        }
    }
}
