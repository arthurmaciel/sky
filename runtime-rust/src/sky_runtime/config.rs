// Config stub for standalone crate testing.
// In generated projects this file is OVERRIDDEN by the Sky compiler.
pub type SkyError = String;
pub fn str_err(s: &str) -> SkyError { s.to_string() }
pub type DbPool = ();
pub type DbRow = ();
pub const SKY_DB_URL: &str = "";
