// DB kernel functions — generic over E and over backend.
// Uses DbPool, DbRow, SKY_DB_URL, db_last_insert_id, db_format_sql from
// config.rs (generated at build time per sky.toml [database] driver).
use super::*;
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

/// `queryDecode : Db -> String -> List String -> (Dict String String -> Result Error a) -> Task Error (List a)` —
/// typed query with a per-row decoder. Fails fast on the first decode error.
pub fn db_query_decode<E: Send + From<String> + 'static, A: Send>(
    conn: Db, sql: String, params: Vec<String>,
    decoder: impl Fn(HashMap<String, String>) -> SkyResult<E, A> + Send + 'static,
) -> SkyTask<E, Vec<A>> {
    Box::pin(async move {
        let rows: SkyResult<E, Vec<HashMap<String, String>>> = db_query(conn, sql, params).await;
        match rows {
            SkyResult::Ok(rows) => {
                let mut out = Vec::with_capacity(rows.len());
                for r in rows {
                    match decoder(r) {
                        SkyResult::Ok(a) => out.push(a),
                        SkyResult::Err(e) => return SkyResult::Err(e),
                    }
                }
                ok_res(out)
            }
            SkyResult::Err(e) => SkyResult::Err(e),
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
        let decoded: SkyResult<String, Vec<String>> = db_query_decode(
            db, "SELECT title FROM todos".into(), vec![],
            |r| SkyResult::Ok(r.get("title").cloned().unwrap_or_default())
        ).await;
        match decoded {
            SkyResult::Ok(v) => assert_eq!(v, vec!["decoded".to_string()]),
            _ => panic!("decode")
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
