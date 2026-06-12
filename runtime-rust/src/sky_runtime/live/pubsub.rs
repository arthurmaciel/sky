//! S6 — in-process pub/sub broker for the Rust backend.
//!
//! One `Broker<T>` per concrete payload type `T`, held in a global registry
//! keyed by `TypeId`. The payload travels as its real Rust type `T` end-to-end
//! and is NEVER erased or downcast — the only `dyn Any` is the broker-container
//! indirection, which is correct by construction (a `Broker<T>` is only ever
//! stored under `TypeId::of::<T>()`). This is the no-runtime-errors design from
//! runtime-rust/CLAUDE.md: a statically-typed broker, not Go's reflect registry.

use std::any::{Any, TypeId};
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use tokio::sync::broadcast;

/// Per-topic broadcast buffer. A subscriber that lags more than this many
/// messages gets `RecvError::Lagged` (handled by skipping, never panicking).
const TOPIC_CAP: usize = 256;

/// One broadcast envelope. `origin` is the publishing session's sid;
/// `skip_origin` requests receiver-side echo-suppression (publishNoEcho).
#[derive(Clone)]
pub struct Event<T> {
    pub payload: T,
    pub origin: String,
    pub skip_origin: bool,
}

/// One broker per concrete payload type `T`. A topic is a single broadcast
/// channel shared by all of that topic's subscribers; SkipOrigin is filtered
/// receiver-side (see `sub_subscribe_topic`), so the broker stays a plain
/// `topic -> Sender` map.
pub struct Broker<T> {
    topics: Mutex<HashMap<String, broadcast::Sender<Event<T>>>>,
}

impl<T: Clone + Send + 'static> Broker<T> {
    fn new() -> Self {
        Broker { topics: Mutex::new(HashMap::new()) }
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, HashMap<String, broadcast::Sender<Event<T>>>> {
        // Poison-tolerant: a panic elsewhere must not abort the whole app; the
        // map is still valid data.
        self.topics.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Register a subscriber on `topic`, creating the channel if needed.
    pub fn subscribe(&self, topic: &str) -> broadcast::Receiver<Event<T>> {
        let mut g = self.lock();
        let tx = g
            .entry(topic.to_string())
            .or_insert_with(|| broadcast::channel(TOPIC_CAP).0);
        tx.subscribe()
    }

    /// Broadcast `payload` to every subscriber on `topic`. Returns the subscriber
    /// count **at the time of send** — not a delivery guarantee (subscribers may
    /// drop concurrently; pub/sub is fire-and-forget). A topic whose subscribers
    /// have all dropped is lazily pruned and returns 0. Fire-and-forget — `send`
    /// failing (no receivers) is not an error.
    pub fn publish(&self, topic: &str, payload: T, origin: &str, skip_origin: bool) -> i64 {
        let mut g = self.lock();
        match g.get(topic) {
            Some(tx) => {
                let n = tx.receiver_count() as i64;
                if n == 0 {
                    g.remove(topic); // lazy prune
                    return 0;
                }
                let _ = tx.send(Event { payload, origin: origin.to_string(), skip_origin });
                n
            }
            None => 0,
        }
    }
}

/// Global per-type registry. The ONE `downcast_ref` is keyed by `TypeId`, so it
/// is correct by construction; the impossible `None` arm rebuilds rather than
/// `unwrap` (no panic). The payload type is never involved in this cast.
fn registry() -> &'static Mutex<HashMap<TypeId, Box<dyn Any + Send + Sync>>> {
    static R: OnceLock<Mutex<HashMap<TypeId, Box<dyn Any + Send + Sync>>>> = OnceLock::new();
    R.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Get (or lazily create) the broker for payload type `T`.
pub fn broker<T: Clone + Send + 'static>() -> Arc<Broker<T>> {
    let mut g = registry().lock().unwrap_or_else(|e| e.into_inner());
    let entry = g
        .entry(TypeId::of::<T>())
        .or_insert_with(|| Box::new(Arc::new(Broker::<T>::new())));
    match entry.downcast_ref::<Arc<Broker<T>>>() {
        Some(b) => b.clone(),
        None => {
            // Unreachable by construction (the registry only ever stores an
            // Arc<Broker<T>> under TypeId::of::<T>()). If it somehow fired it
            // would discard live subscribers, so log a bug report rather than
            // fail silently, then return a fresh broker (never panic).
            eprintln!(
                "[sky-runtime BUG] pubsub broker downcast mismatch for {:?} — please report",
                TypeId::of::<T>()
            );
            let b = Arc::new(Broker::<T>::new());
            *entry = Box::new(b.clone());
            b
        }
    }
}

// ─── Live-running flag (for PubSub.publish's Unavailable) ───────────────────

static LIVE_RUNNING: AtomicBool = AtomicBool::new(false);

/// Called by `serve_live` once the Live app is bound + serving.
pub fn mark_live_running() {
    LIVE_RUNNING.store(true, Ordering::Release);
}

#[allow(dead_code)]
fn live_running() -> bool {
    LIVE_RUNNING.load(Ordering::Acquire)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn fan_out_to_two_subscribers() {
        let b = broker::<String>();
        let mut a = b.subscribe("room1");
        let mut c = b.subscribe("room1");
        let n = b.publish("room1", "hi".to_string(), "pub", false);
        assert_eq!(n, 2);
        assert_eq!(a.recv().await.unwrap().payload, "hi");
        assert_eq!(c.recv().await.unwrap().payload, "hi");
    }

    #[tokio::test]
    async fn zero_subscribers_returns_zero() {
        let b = broker::<i64>();
        assert_eq!(b.publish("empty-topic-xyz", 7, "", false), 0);
    }

    #[tokio::test]
    async fn per_type_isolation_same_topic_string() {
        // Same topic string "shared", two different payload types -> different
        // brokers -> no cross-talk. This is the zero-erasure safety property.
        let bs = broker::<String>();
        let bi = broker::<i64>();
        let mut s_rx = bs.subscribe("shared");
        let _i_rx = bi.subscribe("shared");
        assert_eq!(bi.publish("shared", 42, "", false), 1); // only the i64 sub
        assert_eq!(bs.publish("shared", "x".to_string(), "", false), 1); // only the String sub
        assert_eq!(s_rx.recv().await.unwrap().payload, "x");
    }

    #[tokio::test]
    async fn event_carries_origin_and_skip_flag() {
        let b = broker::<u8>();
        let mut rx = b.subscribe("t");
        b.publish("t", 1, "sid-A", true);
        let ev = rx.recv().await.unwrap();
        assert_eq!(ev.origin, "sid-A");
        assert!(ev.skip_origin);
    }
}
