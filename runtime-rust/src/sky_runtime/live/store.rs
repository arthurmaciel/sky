//! Session stores — the `SessionStore` abstraction + backends, mirroring Go's
//! `runtime-go/rt/live_store.go`.
//!
//! A session's LIVE state (the tokio driver, SSE channel, rebuilt `HandlerIndex`)
//! is always per-process. A persistent backend additionally keeps a serialized
//! **checkpoint** of the model (+ metadata) so a returning cookie / a restart can
//! reconstruct the session. `get` therefore returns either a `Live` handle (the
//! in-process session, owns its driver) or a `Cold` model (decoded from the
//! checkpoint; the caller spawns a fresh driver seeded with it).

use super::SessionEntry;
use std::collections::HashMap;
use std::sync::{Arc, Mutex, RwLock};
use std::time::{Duration, Instant};

/// The in-process live session (owns its driver goroutine + SSE channel).
pub type SessionHandle<Model, Msg> = Arc<Mutex<SessionEntry<Model, Msg>>>;

/// Result of a store lookup. `Live` = the in-process session (reuse it). `Cold`
/// = a model decoded from a persistent checkpoint (the caller hydrates: spawn a
/// fresh driver seeded with this model). Memory stores only ever return `Live`.
pub enum StoreHit<Model, Msg> {
    Live(SessionHandle<Model, Msg>),
    Cold(Model),
}

pub trait SessionStore<Model, Msg>: Send + Sync {
    /// Look up a session by sid. `None` = unknown (caller creates a new one).
    fn get(&self, sid: &str) -> Option<StoreHit<Model, Msg>>;
    /// Insert/refresh the live handle (and, for persistent backends, checkpoint
    /// the model). Called on session create and write-through on every commit.
    fn set(&self, sid: &str, handle: SessionHandle<Model, Msg>);
    /// Drop a session.
    fn delete(&self, sid: &str);
    /// Evict idle-expired sessions (called periodically by the eviction task).
    fn sweep(&self) {}
}

// ─── Memory store — default; in-process, lost on restart (Go memoryStore) ────

/// In-process store with idle-TTL eviction. `get` touches the entry's last-seen
/// so active sessions don't expire.
pub struct MemoryStore<Model, Msg> {
    sessions: RwLock<HashMap<String, (SessionHandle<Model, Msg>, Instant)>>,
    ttl: Duration,
}

impl<Model, Msg> MemoryStore<Model, Msg> {
    pub fn new(ttl: Duration) -> Self {
        MemoryStore { sessions: RwLock::new(HashMap::new()), ttl }
    }
}

impl<Model: Send + 'static, Msg: Send + 'static> SessionStore<Model, Msg> for MemoryStore<Model, Msg> {
    fn get(&self, sid: &str) -> Option<StoreHit<Model, Msg>> {
        let mut w = self.sessions.write().unwrap();
        w.get_mut(sid).map(|(h, seen)| {
            *seen = Instant::now(); // touch — keep active sessions alive
            StoreHit::Live(h.clone())
        })
    }
    fn set(&self, sid: &str, handle: SessionHandle<Model, Msg>) {
        self.sessions
            .write()
            .unwrap()
            .insert(sid.to_string(), (handle, Instant::now()));
    }
    fn delete(&self, sid: &str) {
        self.sessions.write().unwrap().remove(sid);
    }
    fn sweep(&self) {
        let now = Instant::now();
        let ttl = self.ttl;
        self.sessions
            .write()
            .unwrap()
            .retain(|_, (_, seen)| now.duration_since(*seen) <= ttl);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::sky_runtime::live::{build_index, Html};
    use tokio::sync::mpsc::unbounded_channel;

    // A minimal SessionEntry<(), ()> for exercising the store's TTL/touch logic.
    fn handle() -> SessionHandle<(), ()> {
        let (tx, _rx) = unbounded_channel::<()>();
        let tree: Html<()> = Html::HText(String::new());
        let index = build_index(&tree);
        Arc::new(Mutex::new(SessionEntry {
            model: (),
            last_view: tree,
            index,
            seq: 0,
            sse_tx: None,
            msg_tx: tx,
        }))
    }

    #[test]
    fn memory_store_get_set_delete() {
        let s: MemoryStore<(), ()> = MemoryStore::new(Duration::from_secs(60));
        assert!(s.get("a").is_none());
        s.set("a", handle());
        assert!(matches!(s.get("a"), Some(StoreHit::Live(_))));
        s.delete("a");
        assert!(s.get("a").is_none());
    }

    #[test]
    fn memory_store_ttl_eviction_and_touch() {
        let s: MemoryStore<(), ()> = MemoryStore::new(Duration::from_millis(40));
        s.set("idle", handle());
        s.set("active", handle());
        std::thread::sleep(Duration::from_millis(60));
        // touch "active" so it survives the sweep
        let _ = s.get("active");
        s.sweep();
        assert!(s.get("active").is_some(), "touched session should survive");
        assert!(s.get("idle").is_none(), "idle session should be evicted");
    }
}
