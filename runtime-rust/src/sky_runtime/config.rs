// Config stub for standalone crate testing.
// In generated projects this file is OVERRIDDEN by the Sky compiler.
pub type SkyError = String;

#[cfg(feature = "db")]
pub type DbPool = sqlx::sqlite::SqlitePool;
#[cfg(feature = "db")]
pub type DbRow = sqlx::sqlite::SqliteRow;
#[cfg(feature = "db")]
pub const SKY_DB_URL: &str = "sqlite::memory:";

#[cfg(not(feature = "db"))]
pub type DbPool = ();
#[cfg(not(feature = "db"))]
pub type DbRow = ();
#[cfg(not(feature = "db"))]
pub const SKY_DB_URL: &str = "";

// sub-B.1 backend-portability helpers. In generated projects these are
// REPLACED by Project.hs's per-driver impls (sqlite/mysql/postgres). The
// standalone runtime crate (used by `cargo test`) defaults to sqlite shapes.
#[cfg(feature = "db")]
pub fn db_last_insert_id(res: &sqlx::sqlite::SqliteQueryResult) -> i64 {
    res.last_insert_rowid()
}
#[cfg(feature = "db")]
pub fn db_format_sql(sql: String) -> String { sql }  // sqlite uses `?` placeholders
