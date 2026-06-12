# S6 PubSub / Broker (Rust backend) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Emit and run Sky's pub/sub surface (`Cmd.publish` / `Cmd.publishNoEcho`, `Sub.subscribeTopic`, `PubSub.publish` / `PubSub.publishNoEcho`) on the Rust backend with **zero payload-type erasure** — per-type monomorphic brokers — so independent Sky.Live sessions can broadcast to one another.

**Architecture:** One `Broker<T>` per concrete payload type `T`, held in a global registry keyed by `TypeId` (the only `dyn Any`, correct-by-construction). Each topic is a single `tokio::sync::broadcast` channel; `SkipOrigin` echo-suppression is filtered receiver-side by comparing the event's `origin` to the subscriber's session sid (threaded via a task-local). `Cmd.publish` lowers to a new `SkyCmd::Publish` variant carrying a typed thunk that the Live dispatch loop runs with the session sid injected as origin. `PubSub.publish` is a Task-shaped form callable from any context.

**Tech Stack:** Rust (`tokio::sync::broadcast`, `std::any::TypeId`), the Sky→Rust codegen (Haskell: `Kernel.hs` kernel mapping, `Walker.hs` usage analyzer), `cargo test` under the `live` feature.

---

## Build environment (every task)

```bash
export PATH="$HOME/.ghcup/bin:$PATH"
export CARGO_TARGET_DIR=$HOME/.cache/sky-rust-target
export RUSTC_WRAPPER=sccache
export SKY=$(cd /home/arthur/Documentos/comp/sky && pwd)/sky-out/sky
```

- **Runtime-only edits** (`runtime-rust/src/sky_runtime/**`) are copied into a generated project at `sky build` — NO cabal rebuild needed; test them with `cd runtime-rust && cargo test --features live`.
- **Codegen edits** (`src/Sky/Generate/Rust/Builder/**`) require a cabal rebuild + install before they take effect:
  `cabal build exe:sky && cabal install --overwrite-policy=always --installdir=./sky-out --install-method=copy exe:sky`.
- **Never** run `cabal build` while a rust-sweep using the same `sky` binary is running.
- Fork-only: never touch `runtime-go/`, `src/Sky/Generate/Go/`, or any shared (non-`TargetRust`) seam.

## No-runtime-errors rule (applies to every Rust line below)

Per `runtime-rust/CLAUDE.md`: no `unwrap()` / `expect()` / `panic!` / unchecked `[i]` indexing / unchecked `downcast` in any Sky-reachable path. Mutex locks use `lock().unwrap_or_else(|e| e.into_inner())`. The one `downcast_ref` is `TypeId`-keyed and has a total `match` with a rebuild arm. Task 6 includes a grep audit that must come back empty.

## File structure

| File | Responsibility | Change |
|---|---|---|
| `runtime-rust/src/sky_runtime/live/pubsub.rs` | The broker: `Broker<T>`, `broker::<T>()` registry, `cmd_publish*`, `sub_subscribe_topic`, `pubsub_publish*`, the `SESSION_SID` task-local, the `LIVE_RUNNING` flag. | **Create** |
| `runtime-rust/src/sky_runtime/live/mod.rs` | Live session driver. | **Modify** — declare `mod pubsub`; thread sid into `run_cmd` + `SkyCmd::Publish` arm; wrap `spawn_subs` in the sid scope; set `LIVE_RUNNING` in `serve_live`. |
| `runtime-rust/src/sky_runtime/tea.rs` | `SkyCmd` / `SkySub` enums + the CLI loop. | **Modify** — add `SkyCmd::Publish` variant + its `cli_run_cmd` arm. |
| `src/Sky/Generate/Rust/Builder/Kernel.hs` | Sky kernel → Rust fn-name map. | **Modify** — 10 new `(mod,name)` cases. |
| `src/Sky/Generate/Rust/Builder/Walker.hs` | Per-module kernel-usage analyzer. | **Modify** — flag the pub/sub kernels `usesTea = True, usesLive = True`. |

---

### Task 1: Broker core — `live/pubsub.rs` with per-type `Broker<T>`

**Files:**
- Create: `runtime-rust/src/sky_runtime/live/pubsub.rs`
- Modify: `runtime-rust/src/sky_runtime/live/mod.rs` (add `mod pubsub;` declaration)

- [ ] **Step 1: Declare the module.** In `runtime-rust/src/sky_runtime/live/mod.rs`, find the existing submodule declarations (near the top, e.g. `mod dispatch;` / `mod sse;`) and add:

```rust
mod pubsub;
pub use pubsub::*;
```

- [ ] **Step 2: Write the broker + registry with failing tests.** Create `runtime-rust/src/sky_runtime/live/pubsub.rs`:

```rust
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

    /// Broadcast `payload` to every subscriber on `topic`. Returns the live
    /// subscriber count. A topic whose subscribers have all dropped is lazily
    /// pruned and returns 0. Fire-and-forget — `send` failing (no receivers) is
    /// not an error.
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
            // Structurally impossible (TypeId-keyed); rebuild, never panic.
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
    LIVE_RUNNING.store(true, Ordering::SeqCst);
}

fn live_running() -> bool {
    LIVE_RUNNING.load(Ordering::SeqCst)
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
```

(The `tests` use `.unwrap()` — that is allowed in `#[cfg(test)]`, which is not a Sky-reachable path.)

- [ ] **Step 3: Run the tests to verify they pass.**

Run: `cd runtime-rust && cargo test --features live pubsub:: 2>&1 | tail -20`
Expected: `test result: ok. 4 passed` for the `pubsub::tests` module. (If `tokio::test` is unavailable, add nothing — the crate already depends on tokio with the `macros`/`rt` features for the existing `live` tests.)

- [ ] **Step 4: No-panic check on the new file.**

Run: `grep -nE "unwrap\(\)|expect\(|panic!|unreachable!" runtime-rust/src/sky_runtime/live/pubsub.rs | grep -v "unwrap_or_else\|cfg(test)\|mod tests" || echo CLEAN`
Expected: `CLEAN` (the only `unwrap`s are inside `#[cfg(test)]`).

- [ ] **Step 5: Commit.**

```bash
git add runtime-rust/src/sky_runtime/live/pubsub.rs runtime-rust/src/sky_runtime/live/mod.rs
git commit -m "feat(rust): S6 per-type pub/sub Broker<T> core (zero payload erasure)"
```

---

### Task 2: `SkyCmd::Publish` variant + `cmd_publish` / `cmd_publish_no_echo`

**Files:**
- Modify: `runtime-rust/src/sky_runtime/tea.rs` (add the enum variant + the `cli_run_cmd` arm)
- Modify: `runtime-rust/src/sky_runtime/live/pubsub.rs` (add `cmd_publish*`)
- Modify: `runtime-rust/src/sky_runtime/live/mod.rs` (thread sid into `run_cmd` + its `SkyCmd::Publish` arm)

- [ ] **Step 1: Add the `SkyCmd::Publish` variant.** In `runtime-rust/src/sky_runtime/tea.rs`, change the `SkyCmd` enum:

```rust
pub enum SkyCmd<M> {
    None,
    Batch(Vec<SkyCmd<M>>),
    Perform(Box<dyn FnOnce() -> Pin<Box<dyn Future<Output = M> + Send>> + Send>),
    /// pub/sub broadcast. The thunk receives the publishing session's sid (the
    /// origin), injected by the Live dispatch loop, and returns the subscriber
    /// count. Not generic over the payload type T — T is captured inside the
    /// thunk (the same erasure-free pattern as `Perform`'s boxed future).
    Publish(Box<dyn FnOnce(&str) -> i64 + Send>),
}
```

- [ ] **Step 2: Run the build to see the exhaustiveness failures.**

Run: `cd runtime-rust && cargo build --features live 2>&1 | grep -E "non-exhaustive|pattern .SkyCmd::Publish. not covered" | head`
Expected: errors at each `match cmd` over `SkyCmd` that lacks a `Publish` arm — at minimum `tea.rs` `cli_run_cmd` and `live/mod.rs` `run_cmd`. Use this list to be sure you cover every site.

- [ ] **Step 3: Add the `cli_run_cmd` arm (CLI has no session → empty origin).** In `runtime-rust/src/sky_runtime/tea.rs`, inside `cli_run_cmd`'s `match cmd`, add:

```rust
        SkyCmd::Publish(thunk) => {
            // No Live session in a Cli program; publish with an empty origin
            // (no subscriber's owner_sid matches "" → echo-default no-op).
            let _ = thunk("");
        }
```

- [ ] **Step 4: Add `cmd_publish` / `cmd_publish_no_echo`.** In `runtime-rust/src/sky_runtime/live/pubsub.rs`, add (above the `#[cfg(test)]` module):

```rust
use crate::sky_runtime::SkyCmd;

/// `Cmd.publish topic payload` — echo-by-default broadcast. The payload `T` is
/// captured in the thunk; the dispatch loop supplies the origin sid.
pub fn cmd_publish<T, M>(topic: String, payload: T) -> SkyCmd<M>
where
    T: Clone + Send + 'static,
{
    SkyCmd::Publish(Box::new(move |origin| broker::<T>().publish(&topic, payload, origin, false)))
}

/// `Cmd.publishNoEcho topic payload` — sets the SkipOrigin bit; the publisher's
/// own subscription is suppressed receiver-side.
pub fn cmd_publish_no_echo<T, M>(topic: String, payload: T) -> SkyCmd<M>
where
    T: Clone + Send + 'static,
{
    SkyCmd::Publish(Box::new(move |origin| broker::<T>().publish(&topic, payload, origin, true)))
}
```

- [ ] **Step 5: Thread the sid into `run_cmd` + add its arm.** In `runtime-rust/src/sky_runtime/live/mod.rs`, change the `run_cmd` signature and recursion to carry the session sid, and add the `Publish` arm:

```rust
fn run_cmd<Msg: Send + 'static>(cmd: SkyCmd<Msg>, tx: &UnboundedSender<Msg>, sid: &str) {
    match cmd {
        SkyCmd::None => {}
        SkyCmd::Batch(items) => {
            for c in items {
                run_cmd(c, tx, sid);
            }
        }
        SkyCmd::Perform(thunk) => {
            let tx = tx.clone();
            tokio::spawn(async move {
                let m = thunk().await;
                let _ = tx.send(m);
            });
        }
        SkyCmd::Publish(thunk) => {
            // Inject this session's sid as the broadcast origin (Go parity:
            // liveApp.Publish sets Origin = session.sid). Fire-and-forget.
            let _ = thunk(sid);
        }
    }
}
```

Then update the two `run_cmd(...)` call sites in this file (the build error list from Step 2 gives the exact lines — the per-session driver and the init path) to pass the sid:

```rust
        run_cmd(cmd, &msg_tx, &sid);
```

For the init call site (in the GET handler, before `drive_session` is spawned) the session sid is the freshly-created/looked-up sid in scope at that point — pass it the same way. If that scope binds the sid under a different name, use that binding.

- [ ] **Step 6: Build to green.**

Run: `cd runtime-rust && cargo build --features live 2>&1 | grep -E "^error" | head ; echo done`
Expected: `done` with no `error` lines.

- [ ] **Step 7: Commit.**

```bash
git add runtime-rust/src/sky_runtime/tea.rs runtime-rust/src/sky_runtime/live/pubsub.rs runtime-rust/src/sky_runtime/live/mod.rs
git commit -m "feat(rust): SkyCmd::Publish + cmd_publish/cmd_publish_no_echo with dispatch-time origin"
```

---

### Task 3: `sub_subscribe_topic` + session-sid task-local

**Files:**
- Modify: `runtime-rust/src/sky_runtime/live/pubsub.rs` (add `sub_subscribe_topic`, the `SESSION_SID` task-local + `with_session_sid` + `current_session_sid`)
- Modify: `runtime-rust/src/sky_runtime/live/mod.rs` (wrap `spawn_subs` in the sid scope)

- [ ] **Step 1: Add the task-local + `sub_subscribe_topic`.** In `runtime-rust/src/sky_runtime/live/pubsub.rs`, add:

```rust
use crate::sky_runtime::SkySub;

tokio::task_local! {
    /// The session sid in scope while a session's subscriptions are being
    /// (re)materialised. Read synchronously inside the SkySub::Source closure
    /// so the spawned recv loop captures the owning session's sid for
    /// SkipOrigin filtering. Unset (→ "") outside a session.
    static SESSION_SID: String;
}

/// Run `f` with `sid` available to `current_session_sid()`. The Live dispatch
/// loop wraps subscription (re)materialisation in this scope.
pub fn with_session_sid<R>(sid: String, f: impl FnOnce() -> R) -> R {
    SESSION_SID.sync_scope(sid, f)
}

fn current_session_sid() -> String {
    SESSION_SID.try_with(|s| s.clone()).unwrap_or_default()
}

/// `Sub.subscribeTopic topic toMsg` — receive `topic` broadcasts as `Msg`s.
/// The codegen-facing form carries no sid; the owning session's sid is read
/// from the materialisation scope. SkipOrigin is filtered here, receiver-side.
pub fn sub_subscribe_topic<T, M, F>(topic: String, to_msg: F) -> SkySub<M>
where
    T: Clone + Send + 'static,
    M: Send + 'static,
    F: Fn(T) -> M + Send + Sync + 'static,
{
    SkySub::Source(Box::new(move |emit| {
        let owner_sid = current_session_sid();
        let mut rx = broker::<T>().subscribe(&topic);
        tokio::spawn(async move {
            loop {
                match rx.recv().await {
                    Ok(ev) => {
                        // Receiver-side echo-suppression: skip exactly the
                        // origin's own subscription when the publish asked for it.
                        if ev.skip_origin && ev.origin == owner_sid {
                            continue;
                        }
                        emit(to_msg(ev.payload));
                    }
                    // A slow session dropped `n` messages: warn-equivalent (drop)
                    // and keep going. Never panic.
                    Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
                    // All senders gone (broker pruned the topic): end the task.
                    Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
                }
            }
        })
    }))
}
```

- [ ] **Step 2: Add a failing integration-style test** for end-to-end deliver + echo + SkipOrigin, in `pubsub.rs`'s `#[cfg(test)]` module:

```rust
    use std::sync::{Arc, Mutex};

    // Drive a subscriber the way the Live loop does: inside with_session_sid,
    // materialise the Source, then collect emitted Msgs.
    async fn collect_one(owner_sid: &str, topic: &str) -> (tokio::task::JoinHandle<()>, Arc<Mutex<Vec<String>>>) {
        let got = Arc::new(Mutex::new(Vec::<String>::new()));
        let got2 = got.clone();
        let emit: Arc<dyn Fn(String) + Send + Sync> = Arc::new(move |m| got2.lock().unwrap().push(m));
        let sub = with_session_sid(owner_sid.to_string(), || {
            sub_subscribe_topic::<String, String, _>(topic.to_string(), |p| p)
        });
        let handle = match sub {
            SkySub::Source(spawn) => spawn(emit),
            _ => unreachable!("subscribeTopic builds a Source"),
        };
        tokio::time::sleep(std::time::Duration::from_millis(20)).await; // let it subscribe
        (handle, got)
    }

    #[tokio::test]
    async fn echo_default_delivers_to_origin() {
        let (h, got) = collect_one("sid-A", "echo-topic").await;
        broker::<String>().publish("echo-topic", "m".to_string(), "sid-A", false);
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        assert_eq!(*got.lock().unwrap(), vec!["m".to_string()]); // origin RECEIVES (echo)
        h.abort();
    }

    #[tokio::test]
    async fn skip_origin_suppresses_only_origin() {
        let (ha, got_a) = collect_one("sid-A", "ne-topic").await; // the publisher's own sub
        let (hb, got_b) = collect_one("sid-B", "ne-topic").await; // a different session
        broker::<String>().publish("ne-topic", "m".to_string(), "sid-A", true); // publishNoEcho from A
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        assert!(got_a.lock().unwrap().is_empty());                 // A suppressed
        assert_eq!(*got_b.lock().unwrap(), vec!["m".to_string()]); // B receives
        ha.abort();
        hb.abort();
    }
```

- [ ] **Step 3: Run to verify pass.**

Run: `cd runtime-rust && cargo test --features live pubsub:: 2>&1 | tail -8`
Expected: all `pubsub::tests` pass (now 6 tests).

- [ ] **Step 4: Wrap `spawn_subs` in the sid scope.** In `runtime-rust/src/sky_runtime/live/mod.rs`, find every `spawn_subs(subs(...), &msg_tx, &mut sub_handles)` call (the per-session driver and the init path) and wrap it:

```rust
        pubsub::with_session_sid(sid.clone(), || {
            spawn_subs(subs(next.clone()), &msg_tx, &mut sub_handles)
        });
```

(For the init path, use whatever local holds the freshly-resolved session sid; clone it.)

- [ ] **Step 5: Build to green.**

Run: `cd runtime-rust && cargo build --features live 2>&1 | grep -E "^error" | head ; echo done`
Expected: `done`.

- [ ] **Step 6: Commit.**

```bash
git add runtime-rust/src/sky_runtime/live/pubsub.rs runtime-rust/src/sky_runtime/live/mod.rs
git commit -m "feat(rust): sub_subscribe_topic + session-sid task-local (receiver-side SkipOrigin)"
```

---

### Task 4: Task-shaped `pubsub_publish` / `pubsub_publish_no_echo`

**Files:**
- Modify: `runtime-rust/src/sky_runtime/live/pubsub.rs` (add the two Task-shaped fns)
- Modify: `runtime-rust/src/sky_runtime/live/mod.rs` (call `pubsub::mark_live_running()` in `serve_live`)

- [ ] **Step 1: Add the Task-shaped publishers.** In `runtime-rust/src/sky_runtime/live/pubsub.rs`, add:

```rust
use crate::sky_runtime::{ok_res, SkyResult, SkyTask};

/// `PubSub.publish topic payload : Task Error Int` — callable from any context
/// (raw handlers, post-init, scheduled jobs). Resolves to the subscriber count,
/// or an error when no Live app is running in this process (Go's `Unavailable`).
/// Server-side publishes carry an empty origin, so echo-default is a no-op.
pub fn pubsub_publish<T, E>(topic: String, payload: T) -> SkyTask<E, i64>
where
    T: Clone + Send + 'static,
    E: From<String> + Send + 'static,
{
    Box::pin(async move {
        if !live_running() {
            return SkyResult::Err(E::from(
                "PubSub.publish: no Live.app running in this process".to_string(),
            ));
        }
        ok_res(broker::<T>().publish(&topic, payload, "", false))
    })
}

/// `PubSub.publishNoEcho` — same, with the SkipOrigin bit set.
pub fn pubsub_publish_no_echo<T, E>(topic: String, payload: T) -> SkyTask<E, i64>
where
    T: Clone + Send + 'static,
    E: From<String> + Send + 'static,
{
    Box::pin(async move {
        if !live_running() {
            return SkyResult::Err(E::from(
                "PubSub.publishNoEcho: no Live.app running in this process".to_string(),
            ));
        }
        ok_res(broker::<T>().publish(&topic, payload, "", true))
    })
}
```

- [ ] **Step 2: Add a failing test** for the no-Live `Err` path, in `pubsub.rs` tests:

```rust
    #[tokio::test]
    async fn pubsub_publish_errs_without_live_app() {
        // LIVE_RUNNING starts false; in a unit test no serve_live ran.
        let t: SkyTask<String, i64> = pubsub_publish::<u8, String>("t".to_string(), 1);
        match t.await {
            SkyResult::Err(e) => assert!(e.contains("no Live.app")),
            SkyResult::Ok(_) => panic!("expected Err Unavailable"),
        }
    }
```

(Run this test in isolation so a prior test in the same binary hasn't set `LIVE_RUNNING`: `cargo test --features live pubsub::tests::pubsub_publish_errs_without_live_app`. The flag is process-global; `mark_live_running` is only called by `serve_live`, which no unit test invokes — but keep this test name unique and run it on its own to be safe.)

- [ ] **Step 3: Run the test.**

Run: `cd runtime-rust && cargo test --features live pubsub::tests::pubsub_publish_errs_without_live_app 2>&1 | tail -5`
Expected: `test result: ok. 1 passed`.

- [ ] **Step 4: Mark live-running in `serve_live`.** In `runtime-rust/src/sky_runtime/live/mod.rs`, inside `serve_live` (the shared bind/serve setup), before the axum server starts accepting, add:

```rust
    pubsub::mark_live_running();
```

- [ ] **Step 5: Build to green.**

Run: `cd runtime-rust && cargo build --features live 2>&1 | grep -E "^error" | head ; echo done`
Expected: `done`.

- [ ] **Step 6: Commit.**

```bash
git add runtime-rust/src/sky_runtime/live/pubsub.rs runtime-rust/src/sky_runtime/live/mod.rs
git commit -m "feat(rust): Task-shaped pubsub_publish/_no_echo + LIVE_RUNNING flag"
```

---

### Task 5: Codegen — kernel mappings + analyzer flags

**Files:**
- Modify: `src/Sky/Generate/Rust/Builder/Kernel.hs` (10 new cases in `kernelToRust`)
- Modify: `src/Sky/Generate/Rust/Builder/Walker.hs` (flag pub/sub kernels `usesTea = True, usesLive = True`)

- [ ] **Step 1: Add the kernel-name mappings.** In `src/Sky/Generate/Rust/Builder/Kernel.hs`, in the `kernelToRust` case expression (next to the existing `("Cmd", "perform") -> "cmd_perform"` and `("Sub", "every") -> "sub_every"` lines), add:

```haskell
    ("Cmd", "publish")            -> "cmd_publish"
    ("Std.Cmd", "publish")        -> "cmd_publish"
    ("Cmd", "publishNoEcho")      -> "cmd_publish_no_echo"
    ("Std.Cmd", "publishNoEcho")  -> "cmd_publish_no_echo"
    ("Sub", "subscribeTopic")     -> "sub_subscribe_topic"
    ("Std.Sub", "subscribeTopic") -> "sub_subscribe_topic"
    ("PubSub", "publish")            -> "pubsub_publish"
    ("Std.PubSub", "publish")        -> "pubsub_publish"
    ("PubSub", "publishNoEcho")      -> "pubsub_publish_no_echo"
    ("Std.PubSub", "publishNoEcho")  -> "pubsub_publish_no_echo"
```

- [ ] **Step 2: Flag the analyzer to pull the live module.** In `src/Sky/Generate/Rust/Builder/Walker.hs`, in `analyzeMod` (where `modName`/`fnName` are in scope, next to the existing `["Cmd", "Sub", "Cli"]` → `usesTea` clause), add a clause. The pub/sub broker lives under `live/`, so these specific functions need `usesLive` too:

```haskell
            -- S6: pub/sub kernels live in the broker (live/pubsub.rs), so they
            -- need the live module pulled (usesLive) in addition to the TEA loop
            -- (usesTea). Gated on the FUNCTION name so Cmd.none/batch/perform +
            -- Sub.none/batch/every are unaffected.
            , if (modName `elem` ["Cmd", "Std.Cmd"] && fnName `elem` ["publish", "publishNoEcho"])
                 || (modName `elem` ["Sub", "Std.Sub"] && fnName == "subscribeTopic")
                 || modName `elem` ["PubSub", "Std.PubSub"]
              then mempty { usesTea = True, usesLive = True } else mempty
```

(If `analyzeMod` matches on a per-reference basis where `fnName` is bound, this slots in alongside the sibling clauses. If `Std.Cmd`/`Std.Sub` are matched via `isSuffixOf` elsewhere, mirror that style — the key is: these five functions set both flags.)

- [ ] **Step 3: Rebuild + install the compiler.**

Run:
```bash
cd /home/arthur/Documentos/comp/sky && export PATH="$HOME/.ghcup/bin:$PATH"
cabal build exe:sky 2>&1 | grep -iE "error:|Linking" | head
cabal install --overwrite-policy=always --installdir=./sky-out --install-method=copy exe:sky 2>&1 | tail -1
```
Expected: a `Linking …/sky` line, no `error:`.

- [ ] **Step 4: Verify the mappings emit.** Build the canonical pub/sub example to Rust and grep the generated code:

```bash
cd /home/arthur/Documentos/comp/sky/examples/27-multi-session-chat
export CARGO_TARGET_DIR=$HOME/.cache/sky-rust-target RUSTC_WRAPPER=sccache
rm -rf sky-out/Rust .skycache .skydeps
$SKY build src/Main.sky --target rust 2>&1 | tail -8
grep -nE "cmd_publish|sub_subscribe_topic|pubsub_publish" sky-out/Rust/src/*.rs | head
```
Expected: a `Build complete` line, and grep hits showing `cmd_publish(...)` / `sub_subscribe_topic(...)` in the emitted Rust. (If the emit fails for an unrelated codegen reason, capture it as a separate bug — the mapping itself is verified by the grep hits.)

- [ ] **Step 5: Commit.**

```bash
cd /home/arthur/Documentos/comp/sky
git add src/Sky/Generate/Rust/Builder/Kernel.hs src/Sky/Generate/Rust/Builder/Walker.hs
git commit -m "feat(rust): map pub/sub kernels (Cmd.publish/Sub.subscribeTopic/PubSub.*) + pull live module"
```

---

### Task 6: Acceptance — `27-multi-session-chat` through the triple

**Files:**
- Test: `examples/27-multi-session-chat` (build + run)
- Reference: `scripts/rust-sweep.sh`, `scripts/rust-equiv.sh`, `scripts/rust-perf.sh`

- [ ] **Step 1: No-panic audit of all new runtime code.**

Run:
```bash
cd /home/arthur/Documentos/comp/sky
grep -nE "\.unwrap\(\)|\.expect\(|panic!|unreachable!" runtime-rust/src/sky_runtime/live/pubsub.rs \
  | grep -vE "unwrap_or_else|unwrap_or_default|#\[cfg\(test\)\]" \
  | grep -vnE "mod tests" || echo CLEAN
```
Expected: `CLEAN`. (Any hit outside `#[cfg(test)]` is a no-runtime-errors violation — fix at the root before continuing.)

- [ ] **Step 2: Full runtime test sweep stays green.**

Run: `cd runtime-rust && cargo test --features "live db redis_store" 2>&1 | grep -E "test result|error\[" | tail`
Expected: all suites `ok` (the prior 154 live tests + the new `pubsub::tests`), no `error[`.

- [ ] **Step 3: Example builds on the sweep.**

Run:
```bash
cd /home/arthur/Documentos/comp/sky
export SKY_BIN=$PWD/sky-out/sky CARGO_TARGET_DIR=$HOME/.cache/sky-rust-target RUSTC_WRAPPER=sccache
bash scripts/rust-sweep.sh 2>&1 | grep -E "^27-multi-session-chat"
```
Expected: `27-multi-session-chat            builds` (was `sky-build-fails`).

- [ ] **Step 4: Go-backend equivalence.** Run the equivalence harness with the reference set to the Go backend:

```bash
cd /home/arthur/Documentos/comp/sky
SKY_REF_TARGET=go bash scripts/rust-equiv.sh 27-multi-session-chat 2>&1 | tail -5
```
Expected: `OK[27-multi-session-chat]` — a message published in one session reaches the other session's subscriber, and echo-by-default reaches the publisher, identically to Go. (If `rust-equiv.sh` has no scenario for 27 yet, add a two-session scenario that opens two SSE sessions, posts a chat message in session A, and asserts both A and B receive the broadcast patch. Keep the scenario file under the harness's existing scenario directory; mirror an existing multi-session scenario's shape.)

- [ ] **Step 5: Perf gate.**

Run:
```bash
cd /home/arthur/Documentos/comp/sky
export SKY_BIN=$PWD/sky-out/sky CARGO_TARGET_DIR=$HOME/.cache/sky-rust-target RUSTC_WRAPPER=sccache AB_TIMEOUT_S=60
timeout 700 bash scripts/rust-perf.sh 27-multi-session-chat 2>&1 | tail -8
```
Expected: the `live`-shape table; binsize/coldstart PASS (the live `rss` envelope carries the S1 quiet-host re-baseline caveat — a `rss`-only over-threshold is the known calibration issue, not a regression).

- [ ] **Step 6: Flip S6 DONE + README note.** In `runtime-rust/docs/superpowers/plans/2026-06-09-rust-go-parity-roadmap-tracking.md`, set the S6 task **Status: DONE (2026-06-11)**, check its steps, and record the triple result for `27-multi-session-chat`. In `runtime-rust/README.md`, add a one-line pub/sub-parity note next to the Sky.Live verification entries (per-type broker, zero payload erasure, `27` green; `37`'s pub/sub leg builds — full `37` still blocked on its anon-struct gap).

- [ ] **Step 7: Commit.**

```bash
cd /home/arthur/Documentos/comp/sky
git add runtime-rust/docs/superpowers/plans/2026-06-09-rust-go-parity-roadmap-tracking.md runtime-rust/README.md
git commit -m "docs(rust): S6 PubSub DONE — 27-multi-session-chat through the triple"
```

---

## Self-review notes

- **Spec coverage:** broker (T1), `Cmd.publish*` + variant + origin injection (T2), `Sub.subscribeTopic` + sid task-local + receiver-side SkipOrigin (T3), Task-shaped `PubSub.*` + Unavailable (T4), codegen mappings + analyzer (T5), acceptance triple + no-panic audit + S6 DONE (T6). Echo/SkipOrigin, lazy prune, and per-type isolation all have explicit tests.
- **Count-under-SkipOrigin nuance:** `publish` returns `receiver_count()`, which under `publishNoEcho` includes the suppressed origin subscriber (Go subtracts it). Accepted minor divergence — the count is rarely consumed and pub/sub is fire-and-forget (spec §"no delivery guarantee"). Echo-default counts are exact, so `27` (which uses `Cmd.publish`) matches Go.
- **Error-kind nuance:** the runtime is generic over `E: From<String>`, so `Unavailable` is surfaced as a `From<String>` error with a clear message, not a typed `ErrorKind::Unavailable` (the runtime has no typed error kinds anywhere — consistent with `task_fail`/`str_err`).
- **Type consistency:** `broker::<T>()`, `Broker<T>`, `Event<T>`, `cmd_publish`, `cmd_publish_no_echo`, `sub_subscribe_topic`, `pubsub_publish`, `pubsub_publish_no_echo`, `with_session_sid`, `mark_live_running`, `SkyCmd::Publish` — names match across all tasks and the codegen map.
- **Re-subscription / replay gap:** subscriptions re-materialise each commit (abort + re-subscribe), matching Go's per-commit model; a message published in the microsecond gap of one session's re-subscribe is missed — identical to Go and acceptable for fire-and-forget. Documented in T3.
