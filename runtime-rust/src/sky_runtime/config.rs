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
