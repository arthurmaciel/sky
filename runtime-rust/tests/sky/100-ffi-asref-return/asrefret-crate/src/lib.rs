#![allow(dead_code)]
//! #73 probe — RETURN-position AsRef<str> / &str. WALL-2 (#58) handled AsRef<str>
//! in PARAM position; the RETURN side is the firestore SKY_DCE=0 residual.
#[derive(Clone)]
pub struct Doc {
    name: String,
}
impl Doc {
    pub fn new(name: String) -> Doc {
        Doc { name }
    }
    /// borrowed &str return — translateRustRet already maps &str -> String.
    pub fn borrowed_name(&self) -> &str {
        &self.name
    }
    /// impl AsRef<str> return — the residual: an opaque impl-trait return that
    /// should bind as Sky String via `.as_ref().to_string()`.
    pub fn tag(&self) -> impl AsRef<str> {
        self.name.clone()
    }
}
