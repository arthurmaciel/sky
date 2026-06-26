// 76-ffi-borrowed-ref: Wall-3b proof fixture.
//
// These methods have generic params bounded by &str / &Path / &OsStr —
// the exact shape that caused 169 "not-bindable borrowed_ref" drops for
// Firestore's get_doc / delete_by_id family.
//
// Wall-3b fix: type_to_typeref now accepts non-mut borrowed_ref whose inner
// type is str / String / Path / OsStr / OsString / PathBuf, lowers it to Sky
// `String`, and records the arg index in `borrowAsRefArgs` so the call site
// emits `argJ.as_ref()`.

use std::path::Path;

pub struct Store {
    label: String,
}

impl Store {
    pub fn new(label: &str) -> Self {
        Self { label: label.to_string() }
    }

    /// Generic &str param — the primary Wall-3b target.
    /// Analogous to Firestore's `get_doc<S: AsRef<str>>(col: S, id: S)`.
    pub fn get<S: AsRef<str>>(&self, key: S) -> String {
        format!("{}:{}", self.label, key.as_ref())
    }

    /// Generic &str param with ownership pattern (two &str args).
    pub fn put<S: AsRef<str>>(&self, key: S, value: S) -> String {
        format!("{}:{}={}", self.label, key.as_ref(), value.as_ref())
    }

    /// Generic &Path param — covers the Path variant of the Wall-3b set.
    pub fn resolve<P: AsRef<Path>>(&self, path: P) -> String {
        format!("{}/{}", self.label, path.as_ref().display())
    }

    /// Static constructor taking &str — no receiver (free function shape).
    pub fn from_key<S: AsRef<str>>(key: S) -> Self {
        Self { label: key.as_ref().to_string() }
    }
}
