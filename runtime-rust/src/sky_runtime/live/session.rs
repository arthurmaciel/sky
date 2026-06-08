use super::sse::SseTx;
use crate::sky_runtime::live::dispatch::HandlerIndex;
use crate::sky_runtime::live::html::Html;
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use tokio::sync::mpsc::UnboundedSender;

/// Per-session live state. `last_view` + `index` are re-derived each commit.
///
/// Fields are not yet read until `live_app` is wired in Task 10.
// fields consumed by live_app in Task 10
#[allow(dead_code)]
pub struct LiveSession<Model, Msg> {
    pub model: Model,
    pub last_view: Html<Msg>,
    pub index: HandlerIndex<Msg>,
    pub seq: u64,
    pub sse_tx: Option<SseTx>,
    /// Cmd/Sub results re-enter the update loop here.
    pub msg_tx: UnboundedSender<Msg>,
}

/// In-memory session store (P1). TTL gc + persisted backends land in P5.
/// The whole server is monomorphic over (Model, Msg), so one concrete store
/// type suffices.
pub struct MemStore<T> {
    inner: Arc<Mutex<HashMap<String, T>>>,
}

impl<T> Clone for MemStore<T> {
    fn clone(&self) -> Self {
        MemStore {
            inner: self.inner.clone(),
        }
    }
}

impl<T> MemStore<T> {
    pub fn new() -> Self {
        MemStore {
            inner: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    pub fn put(&self, id: String, v: T) {
        self.inner.lock().unwrap().insert(id, v);
    }

    pub fn delete(&self, id: &str) {
        self.inner.lock().unwrap().remove(id);
    }

    pub fn with<R>(&self, id: &str, f: impl FnOnce(&T) -> R) -> Option<R> {
        self.inner.lock().unwrap().get(id).map(f)
    }

    pub fn update<R>(&self, id: &str, f: impl FnOnce(&mut T) -> R) -> Option<R> {
        self.inner.lock().unwrap().get_mut(id).map(f)
    }
}

impl<T> Default for MemStore<T> {
    fn default() -> Self {
        Self::new()
    }
}

// ─── tests ────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn store_put_get_delete() {
        let store: MemStore<i32> = MemStore::new();
        store.put("s1".into(), 41);
        assert_eq!(store.with("s1", |v| *v), Some(41));
        store.update("s1", |v| *v += 1);
        assert_eq!(store.with("s1", |v| *v), Some(42));
        store.delete("s1");
        assert_eq!(store.with("s1", |v| *v), None);
    }

    #[test]
    fn store_clone_shares_state() {
        let a: MemStore<String> = MemStore::new();
        let b = a.clone();
        a.put("k".into(), "v".into());
        assert_eq!(b.with("k", |s| s.clone()), Some("v".into()));
    }

    #[test]
    fn store_default_is_empty() {
        let s: MemStore<u8> = MemStore::default();
        assert_eq!(s.with("x", |v| *v), None);
    }
}
