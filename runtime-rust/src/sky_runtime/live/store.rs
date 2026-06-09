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
use async_trait::async_trait;
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

/// Async so persistent backends (sqlite/postgres via sqlx, redis) can do I/O;
/// memory impls have sync bodies. The driver + axum handlers are already async,
/// so call sites just `.await`.
#[async_trait]
pub trait SessionStore<Model, Msg>: Send + Sync {
    /// Look up a session by sid. `None` = unknown (caller creates a new one).
    async fn get(&self, sid: &str) -> Option<StoreHit<Model, Msg>>;
    /// Insert/refresh the live handle (and, for persistent backends, checkpoint
    /// the model). Called on session create and write-through on every commit.
    async fn set(&self, sid: &str, handle: SessionHandle<Model, Msg>);
    /// Drop a session.
    async fn delete(&self, sid: &str);
    /// Evict idle-expired sessions (called periodically by the eviction task).
    async fn sweep(&self) {}
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

#[async_trait]
impl<Model: Send + 'static, Msg: Send + 'static> SessionStore<Model, Msg> for MemoryStore<Model, Msg> {
    async fn get(&self, sid: &str) -> Option<StoreHit<Model, Msg>> {
        let mut w = self.sessions.write().unwrap();
        w.get_mut(sid).map(|(h, seen)| {
            *seen = Instant::now(); // touch — keep active sessions alive
            StoreHit::Live(h.clone())
        })
    }
    async fn set(&self, sid: &str, handle: SessionHandle<Model, Msg>) {
        self.sessions
            .write()
            .unwrap()
            .insert(sid.to_string(), (handle, Instant::now()));
    }
    async fn delete(&self, sid: &str) {
        self.sessions.write().unwrap().remove(sid);
    }
    async fn sweep(&self) {
        let now = Instant::now();
        let ttl = self.ttl;
        self.sessions
            .write()
            .unwrap()
            .retain(|_, (_, seen)| now.duration_since(*seen) <= ttl);
    }
}

fn now_secs() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

// ─── SQLite store — persistent model checkpoint + live mem-cache (Go sqliteStore)

/// Persistent store: keeps a `mem_cache` of live handles (same-process, owns the
/// driver) AND a `sky_sessions(sid, blob, last_seen)` table holding the
/// serde-JSON model checkpoint. `get` returns the live handle on a cache hit,
/// else a `Cold` model decoded from the blob (the caller hydrates a fresh
/// driver). Requires `Model: Serialize + DeserializeOwned` (the codegen derives
/// it). Mirrors Go's `sqliteStore`.
#[cfg(feature = "db")]
pub struct SqliteStore<Model, Msg> {
    pool: sqlx::SqlitePool,
    mem_cache: RwLock<HashMap<String, SessionHandle<Model, Msg>>>,
    ttl: Duration,
}

#[cfg(feature = "db")]
impl<Model, Msg> SqliteStore<Model, Msg> {
    pub async fn new(path: &str, ttl: Duration) -> Result<Self, sqlx::Error> {
        let url = format!("sqlite:{path}?mode=rwc");
        let pool = sqlx::SqlitePool::connect(&url).await?;
        sqlx::query(
            "CREATE TABLE IF NOT EXISTS sky_sessions (\
             sid TEXT PRIMARY KEY, blob TEXT NOT NULL, last_seen INTEGER NOT NULL)",
        )
        .execute(&pool)
        .await?;
        Ok(SqliteStore { pool, mem_cache: RwLock::new(HashMap::new()), ttl })
    }
}

#[cfg(feature = "db")]
#[async_trait]
impl<Model, Msg> SessionStore<Model, Msg> for SqliteStore<Model, Msg>
where
    Model: serde::Serialize + serde::de::DeserializeOwned + Clone + Send + Sync + 'static,
    Msg: Send + Sync + 'static,
{
    async fn get(&self, sid: &str) -> Option<StoreHit<Model, Msg>> {
        // Same-process live handle wins (owns the running driver).
        let cached = self.mem_cache.read().unwrap().get(sid).cloned();
        if let Some(h) = cached {
            let _ = sqlx::query("UPDATE sky_sessions SET last_seen = ? WHERE sid = ?")
                .bind(now_secs()).bind(sid).execute(&self.pool).await;
            return Some(StoreHit::Live(h));
        }
        // Cold: decode the persisted model checkpoint (post-restart / other replica).
        let row: Option<(String,)> = sqlx::query_as("SELECT blob FROM sky_sessions WHERE sid = ?")
            .bind(sid).fetch_optional(&self.pool).await.ok().flatten();
        let blob = row?.0;
        let model: Model = serde_json::from_str(&blob).ok()?;
        let _ = sqlx::query("UPDATE sky_sessions SET last_seen = ? WHERE sid = ?")
            .bind(now_secs()).bind(sid).execute(&self.pool).await;
        Some(StoreHit::Cold(model))
    }
    async fn set(&self, sid: &str, handle: SessionHandle<Model, Msg>) {
        let model = handle.lock().unwrap().model.clone();
        self.mem_cache.write().unwrap().insert(sid.to_string(), handle);
        if let Ok(blob) = serde_json::to_string(&model) {
            let _ = sqlx::query(
                "INSERT INTO sky_sessions (sid, blob, last_seen) VALUES (?, ?, ?) \
                 ON CONFLICT(sid) DO UPDATE SET blob=excluded.blob, last_seen=excluded.last_seen",
            )
            .bind(sid).bind(blob).bind(now_secs()).execute(&self.pool).await;
        }
    }
    async fn delete(&self, sid: &str) {
        self.mem_cache.write().unwrap().remove(sid);
        let _ = sqlx::query("DELETE FROM sky_sessions WHERE sid = ?")
            .bind(sid).execute(&self.pool).await;
    }
    async fn sweep(&self) {
        let cutoff = now_secs() - self.ttl.as_secs() as i64;
        let _ = sqlx::query("DELETE FROM sky_sessions WHERE last_seen < ?")
            .bind(cutoff).execute(&self.pool).await;
        // mem_cache entries are live (driver running); the DB is the TTL
        // authority for the persisted checkpoint. Go keeps the live pointers too.
    }
}

/// Select a backend from `[live] store` (Go `chooseStore`), falling back to
/// memory on any error — never crash. The `Model: Serialize` bound is for the
/// persistent backends; memory needs none, but a single signature keeps the
/// codegen call uniform (it derives serde on the model when emitting this).
pub async fn choose_store<Model, Msg>(kind: &str, path: &str, ttl: Duration) -> Arc<dyn SessionStore<Model, Msg>>
where
    Model: serde::Serialize + serde::de::DeserializeOwned + Clone + Send + Sync + 'static,
    Msg: Send + Sync + 'static,
{
    #[cfg(feature = "db")]
    if kind == "sqlite" {
        match SqliteStore::new(path, ttl).await {
            Ok(s) => {
                eprintln!("[sky.live] session store: sqlite @ {path}");
                return Arc::new(s);
            }
            Err(e) => eprintln!("[sky.live] sqlite store unavailable ({e}); falling back to memory"),
        }
    }
    let _ = (kind, path);
    Arc::new(MemoryStore::new(ttl))
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

    #[tokio::test]
    async fn memory_store_get_set_delete() {
        let s: MemoryStore<(), ()> = MemoryStore::new(Duration::from_secs(60));
        assert!(s.get("a").await.is_none());
        s.set("a", handle()).await;
        assert!(matches!(s.get("a").await, Some(StoreHit::Live(_))));
        s.delete("a").await;
        assert!(s.get("a").await.is_none());
    }

    // A SessionEntry<i32, ()> with a given model, for the sqlite checkpoint test.
    #[cfg(feature = "db")]
    fn handle_i32(model: i32) -> SessionHandle<i32, ()> {
        let (tx, _rx) = unbounded_channel::<()>();
        let tree: Html<()> = Html::HText(String::new());
        let index = build_index(&tree);
        Arc::new(Mutex::new(SessionEntry { model, last_view: tree, index, seq: 0, sse_tx: None, msg_tx: tx }))
    }

    /// Restart survival: a store writes a checkpoint, a FRESH store over the same
    /// file (no mem-cache) decodes it as a `Cold` model.
    #[cfg(feature = "db")]
    #[tokio::test]
    async fn sqlite_store_checkpoint_survives_restart() {
        let path = std::env::temp_dir().join(format!("skytest_p5_{}.db", std::process::id()));
        let p = path.to_str().unwrap();
        let _ = std::fs::remove_file(p);
        {
            let s: SqliteStore<i32, ()> = SqliteStore::new(p, Duration::from_secs(60)).await.unwrap();
            s.set("s1", handle_i32(42)).await;
            // same-process get is a Live cache hit
            assert!(matches!(s.get("s1").await, Some(StoreHit::Live(_))));
        }
        {
            // "restart": new store, empty mem-cache → decodes the checkpoint
            let s: SqliteStore<i32, ()> = SqliteStore::new(p, Duration::from_secs(60)).await.unwrap();
            match s.get("s1").await {
                Some(StoreHit::Cold(m)) => assert_eq!(m, 42),
                _ => panic!("expected Cold(42) after restart"),
            }
        }
        let _ = std::fs::remove_file(p);
    }

    #[tokio::test]
    async fn memory_store_ttl_eviction_and_touch() {
        let s: MemoryStore<(), ()> = MemoryStore::new(Duration::from_millis(40));
        s.set("idle", handle()).await;
        s.set("active", handle()).await;
        std::thread::sleep(Duration::from_millis(60));
        // touch "active" so it survives the sweep
        let _ = s.get("active").await;
        s.sweep().await;
        assert!(s.get("active").await.is_some(), "touched session should survive");
        assert!(s.get("idle").await.is_none(), "idle session should be evicted");
    }
}
