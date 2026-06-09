# Rust Sky.Live P5 — Session Stores Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Match the Go backend's session-store design (`runtime-go/rt/live_store.go`):
a `SessionStore` abstraction with cookie-based session reuse, TTL eviction, and
persistent backends, so Sky.Live apps preserve state across refreshes/navigation
and survive a server restart. Ships the memory + sqlite backends (covering both
in-memory-TTL and persistent restart-survival) behind a trait that redis/postgres/
firestore slot into as follow-ons.

**Architecture (mirrors Go exactly):**
- `SessionStore` trait — `get(sid) -> Option<SessionHandle>`, `set(sid, handle)`,
  `delete(sid)`, `new_id()`. `choose_store(kind, path, ttl)` dispatches on
  `[live] store` and **falls back to memory on any error** (Go parity — never crash).
- The persisted form is a **checkpoint** of the model + metadata (`seq`, `last_seen`),
  NOT the live goroutine state. Persistent stores keep a `mem_cache` of live
  session handles (same-process, owns the tokio driver) PLUS the serialized blob
  (cross-process / post-restart). `get` returns the live handle if cached, else
  decodes the blob into a fresh session.
- **Cookie reuse**: GET looks up `sky_sid` in the store; a hit re-renders the
  existing session's current model (no new session); a miss creates + stores one.
- **Write-through**: `set` after init and after every commit (in the driver).
- Go's runtime `validateSessionValue` becomes a **compile-time** serde derive: the
  codegen derives `Serialize + Deserialize` on the model's transitive type closure
  when the store is persistent; a non-serde-able model is a clean compile error.

**Tech stack:** Rust runtime (`runtime-rust/src/sky_runtime/live/*`), Haskell codegen
(`src/Sky/Generate/Rust/Builder.hs` + `Project.hs`). `SkyConfig` already exposes
`_liveStore` / `_liveStorePath` / `_liveTtl`. sqlite via `sqlx` (already a dep when
`usesDb`; add for persistent Live). serde + serde_json (already deps when usesLive).

**Scope (P5):** the `SessionStore` trait + memory (TTL) + sqlite (persistent) +
cookie reuse + write-through + transitive-serde codegen + sky.toml wiring + remove
the dead `MemStore`/`LiveSession` (P1-T8). OUT (same-trait follow-ons): redis,
postgres, firestore backends (external-service I/O); the pub/sub `Broker` on the
store; cross-replica SSE affinity.

---

## Task 1: `SessionStore` trait + memory backend (with TTL)

**Files:**
- Create: `runtime-rust/src/sky_runtime/live/store.rs`
- Modify: `runtime-rust/src/sky_runtime/live/mod.rs` (wire module; replace the raw `SessionMap`)
- Delete/repurpose: the dead `MemStore`/`LiveSession` in `live/session.rs`

The current `LiveState.sessions: Arc<Mutex<HashMap<String, Arc<Mutex<SessionEntry>>>>>`
becomes a `SessionStore` behind a trait. `SessionEntry` already holds the live
state (model, last_view, index, msg_tx, sse_tx); add `seq`/`last_seen` if missing
(seq exists). The store value is `Arc<Mutex<SessionEntry<Model, Msg>>>` (the live
handle).

- [ ] **Step 1: Trait + memory impl + TTL test**

```rust
use std::collections::HashMap;
use std::sync::{Arc, Mutex, RwLock};
use std::time::{Duration, Instant};

pub type SessionHandle<Model, Msg> = Arc<Mutex<super::SessionEntry<Model, Msg>>>;

pub trait SessionStore<Model, Msg>: Send + Sync {
    fn get(&self, sid: &str) -> Option<SessionHandle<Model, Msg>>;
    fn set(&self, sid: &str, handle: SessionHandle<Model, Msg>);
    fn delete(&self, sid: &str);
}

/// In-process store with idle-TTL eviction (Go memoryStore parity).
pub struct MemoryStore<Model, Msg> {
    sessions: RwLock<HashMap<String, (SessionHandle<Model, Msg>, Instant)>>,
    ttl: Duration,
}

impl<Model, Msg> MemoryStore<Model, Msg> {
    pub fn new(ttl: Duration) -> Self {
        MemoryStore { sessions: RwLock::new(HashMap::new()), ttl }
    }
    /// Evict sessions idle longer than ttl. Call from a periodic sweep.
    pub fn evict_expired(&self) {
        let now = Instant::now();
        let mut w = self.sessions.write().unwrap();
        w.retain(|_, (_, seen)| now.duration_since(*seen) <= self.ttl);
    }
}

impl<Model: Send + 'static, Msg: Send + 'static> SessionStore<Model, Msg> for MemoryStore<Model, Msg> {
    fn get(&self, sid: &str) -> Option<SessionHandle<Model, Msg>> {
        let mut w = self.sessions.write().unwrap();
        if let Some((h, seen)) = w.get_mut(sid) {
            *seen = Instant::now(); // touch
            Some(h.clone())
        } else {
            None
        }
    }
    fn set(&self, sid: &str, handle: SessionHandle<Model, Msg>) {
        self.sessions.write().unwrap().insert(sid.to_string(), (handle, Instant::now()));
    }
    fn delete(&self, sid: &str) {
        self.sessions.write().unwrap().remove(sid);
    }
}
```
Test: insert two handles, `evict_expired` with a tiny ttl after a sleep removes
the idle one; `get` touches (so a recently-got handle survives a later evict).
Use a `MemoryStore<i32, i32>` with a dummy `SessionEntry`-free handle? — `SessionHandle`
wraps `SessionEntry`; for the unit test, construct a minimal `SessionEntry` or test
`evict_expired` via a store of `Arc<Mutex<i32>>` by making the test generic helper.
Simplest: test the TTL retain logic on a `MemoryStore<(), ()>` with hand-built
`SessionEntry<(),()>` values (fill the fields with empties + a dummy channel).

- [ ] **Step 2: Wire into `LiveState`**

Replace `sessions: SessionMap<Model, Msg>` with `store: Arc<dyn SessionStore<Model, Msg>>`.
Update `LiveState` + its `Clone`. `live_app`/`live_app_routed` build a
`MemoryStore` (or the chosen store — Task 4) and store it as `Arc<dyn …>`. Spawn a
background eviction task (tokio interval 60 s → `store.evict_expired()` — add
`evict_expired` to the trait, or downcast; simplest: add `fn sweep(&self)` to the
trait, no-op for stores that self-manage). Update the page/sse/event handlers to
use `store.get(sid)` / `store.set(sid, handle)` instead of the raw map.

- [ ] **Step 3: Delete dead `MemStore`/`LiveSession`** from `session.rs` (P1-T8,
unused — confirm `grep -rn "MemStore\|LiveSession" src/sky_runtime/` shows only
session.rs + its tests, then remove them + their tests, OR repurpose `LiveSession`
as the canonical `SessionEntry` if cleaner). Keep `session.rs` compiling.

- [ ] **Step 4: build + test** — `cargo test --features live store_` + `cargo build --features live`.

- [ ] **Step 5: Commit** (NO co-author trailer)
```bash
git add runtime-rust/src/sky_runtime/live/
git commit -m "feat(rust): Sky.Live SessionStore trait + MemoryStore (TTL eviction)"
```

---

## Task 2: cookie-based session reuse + write-through

**Files:**
- Modify: `runtime-rust/src/sky_runtime/live/mod.rs`

- [ ] **Step 1: GET reuses by cookie**

In the `page` handler, before `new_sid()`: read `sky_sid` from the request cookie
(`sid_from_cookie`). If `store.get(sid)` returns a handle, REUSE it: lock it, take
its current model, re-render (`view` → assign_sky_ids → render_html), refresh its
`last_view`/`index`, and return the page with the SAME sid cookie (no new driver).
Only on a miss: `new_sid()`, init(req), create the SessionEntry + driver, `store.set`.
(For a routed app, re-apply `route_resolver` to the reused model so navigation to a
new path updates `model.page` — match Go, which calls applyRoute on every GET.)

- [ ] **Step 2: write-through in the driver**

After each commit in `drive_session` (model updated), call `store.set(sid, handle)`
so the persistent backend checkpoints the new model. Pass the `store` + `sid` into
`drive_session` (Arc clone). For the memory store this is a touch; for sqlite it
re-encodes the blob (Task 3).

- [ ] **Step 3: gate the reuse — counter survives refresh**

Verified at Task 5's gate; here just `cargo build --features live` clean and a
manual smoke (counter: GET, click +, GET again with the cookie → count preserved).

- [ ] **Step 4: Commit** (NO co-author trailer)
```bash
git add runtime-rust/src/sky_runtime/live/mod.rs
git commit -m "feat(rust): Sky.Live cookie-based session reuse + write-through to store"
```

---

## Task 3: sqlite persistent backend

**Files:**
- Modify: `runtime-rust/src/sky_runtime/live/store.rs`

Mirrors Go's `sqliteStore`: a `mem_cache` of live handles (same-process) + a
`sky_sessions(sid TEXT PRIMARY KEY, blob BLOB, last_seen INTEGER)` table holding
the serialized model checkpoint. Requires `Model: serde::Serialize +
DeserializeOwned` (the codegen guarantees it — Task 4). The store is generic over
`Model: Serialize + DeserializeOwned + Clone + Send + 'static`.

- [ ] **Step 1: SqliteStore**

```rust
pub struct SqliteStore<Model, Msg> {
    pool: sqlx::SqlitePool,
    mem_cache: RwLock<HashMap<String, SessionHandle<Model, Msg>>>,
    ttl: Duration,
    // reconstruct a fresh live handle from a decoded model (driver re-spawned by
    // the caller on a cold hit — see note).
}
```
`set`: cache the live handle; serialize `handle.lock().model` (+ seq) to JSON/bincode;
`INSERT … ON CONFLICT(sid) DO UPDATE`. `get`: mem_cache hit → live handle; else
`SELECT blob` → decode model → the caller must re-spawn a driver for it (return a
"cold" handle the page handler hydrates). `delete`: remove from cache + table.
`sweep`: `DELETE FROM sky_sessions WHERE last_seen < now-ttl` + evict mem_cache.

> Cold-hit reconstruction: decoding gives a model with NO driver/sse/index. The
> page handler, on a cold `get`, must build a fresh `SessionEntry` + spawn a driver
> seeded with the decoded model (same as the miss path but seeded). Structure
> `get` to return an enum `Hit::Live(handle)` / `Hit::Cold(Model)` so the page
> handler knows whether to hydrate. (Adjust the trait accordingly — a
> `get_or_cold` returning `Option<Either<handle, Model>>`.)

- [ ] **Step 2: choose_store + fallback**

```rust
pub fn choose_store<Model, Msg>(kind: &str, path: &str, ttl: Duration)
    -> Arc<dyn SessionStore<Model, Msg>>
where Model: serde::Serialize + serde::de::DeserializeOwned + Clone + Send + Sync + 'static, Msg: Send + Sync + 'static
{
    match kind {
        "sqlite" => match SqliteStore::new(path, ttl) {
            Ok(s) => { eprintln!("[sky.live] session store: sqlite @ {path}"); Arc::new(s) }
            Err(e) => { eprintln!("[sky.live] sqlite store unavailable ({e}); falling back to memory"); Arc::new(MemoryStore::new(ttl)) }
        },
        _ => Arc::new(MemoryStore::new(ttl)),
    }
}
```
> The `Model: Serialize+Deserialize` bound on `choose_store` means `live_app` can
> only call it when the codegen derived serde on the model. For memory-only apps
> (no serde derive), `live_app` builds `MemoryStore` directly (no bound). So emit
> TWO entry shapes (Task 4): persistent-store path (bounded, calls choose_store) vs
> memory path (unbounded). OR always require serde — simpler but forces serde on
> every Live model. Decide in Task 4; prefer: codegen derives serde only when the
> store is persistent, and emits the choose_store call then.

- [ ] **Step 3: test** — round-trip a model through `SqliteStore` set→(drop cache)→get
decodes the same model; restart survival (new store over the same file path sees
the row). Use `sqlite::memory:`-shared or a tempfile.

- [ ] **Step 4: Commit** (NO co-author trailer)
```bash
git add runtime-rust/src/sky_runtime/live/store.rs
git commit -m "feat(rust): Sky.Live SqliteStore — model-checkpoint persistence + mem-cache + TTL"
```

---

## Task 4: codegen — serde on the model closure + store wiring

**Files:**
- Modify: `src/Sky/Generate/Rust/Builder.hs`, `src/Sky/Generate/Rust/Project.hs`

- [ ] **Step 1: derive serde on the model's transitive type closure**

When `Toml._liveStore config` is persistent (`"sqlite"`/`"postgres"`/`"redis"`),
the Live app's `Model` type AND every type reachable from it (Page, nested records,
ADTs + their field types) must derive `serde::Serialize + Deserialize`. Reuse the
form-target stamping machinery (P2): a pre-pass computes the model's transitive
type-name closure (from the Live.app `view`/`init` solved type → Model → walk its
fields/ctors), and the struct/enum emitters add `Serialize, Deserialize` to those
types' derive lists. (Enums need it too — extend the enum `typeDefToString`.) A
reachable non-serde type (function field) → clean Rust compile error (the
`validateSessionValue` equivalent).

- [ ] **Step 2: emit the store choice**

Thread `Toml._liveStore` / `_liveStorePath` / `_liveTtl` into the `live_app` /
`live_app_routed` emission: when persistent, emit
`live_app_with_store(…, choose_store::<Model,Msg>("sqlite", "<path>", <ttl>))` (or
pass the store into `live_app`); when memory, the current `live_app(…)` (memory
default). Add the runtime `live_app*` store parameter (Task 1/2 already moved
`LiveState` to `store`; the entry takes an `Arc<dyn SessionStore>`).

- [ ] **Step 3: generated Cargo deps**

`Project.hs`/`emitCargoToml`: when `usesLive` AND `_liveStore == "sqlite"`, add the
sqlx sqlite dep (mirror the usesDb sqlx wiring) to the generated project. serde is
already added for usesLive (P2). Add `bincode`/`serde_json` if used for the blob
(serde_json already present).

- [ ] **Step 4: build the compiler** (`timeout 1800 cabal install …`).

- [ ] **Step 5: Commit** (NO co-author trailer)
```bash
git add src/Sky/Generate/Rust/Builder.hs src/Sky/Generate/Rust/Project.hs
git commit -m "feat(rust): codegen — serde-derive model closure + sqlite session store wiring"
```

---

## Task 5: P5 gate — `examples/rust/32-live-sessions`

**Files:**
- Create: `examples/rust/32-live-sessions/{sky.toml,src/Main.sky}`

A counter with `[live] store = "sqlite"` + `storePath`. Gate proves (a) cookie
reuse (refresh preserves count) and (b) restart survival (kill + restart with the
same sqlite file + cookie → count preserved).

- [ ] **Step 1: example** — counter (Model `{count:Int}`, onClick Increment),
`sky.toml` with `[live] store = "sqlite"`, `storePath = "sessions.db"`.

- [ ] **Step 2: build + codegen check** — `MainModel` derives `serde::Serialize, Deserialize`;
`choose_store::<…>("sqlite", "sessions.db", …)` emitted; generated Cargo has sqlx-sqlite.

- [ ] **Step 3: gate**
```bash
cd examples/rust/32-live-sessions && rm -rf sky-out .skycache sessions.db
sky build src/Main.sky
./sky-out/Rust/target/debug/sky-app &   # run 1
# GET / (capture sky_sid cookie); POST /_sky/event click x3; GET / with cookie → count 3
# kill run 1; restart; GET / with the SAME cookie → count STILL 3 (restored from sqlite)
```
Expected: refresh shows the incremented count (cookie reuse); after restart the
same cookie restores the persisted count (sqlite survival).

- [ ] **Step 4: Commit** (NO co-author trailer)
```bash
git add examples/rust/32-live-sessions
git commit -m "feat(rust): P5 gate — 32-live-sessions: cookie reuse + sqlite restart survival"
```

---

## Task 6: Regression + README

- [ ] **Step 1: Regression** — `cargo test --features live` all pass; rebuild
27–31 (memory-store apps still emit the memory path + behave identically — confirm
28 click, 30 routing, 31 req); Go hello-world; FFI byte-identity 0 failures.
- [ ] **Step 2: README** — bump to 32 examples; add 32-live-sessions row; update the
Sky.Live section: P5 (session stores — SessionStore trait + memory/TTL + sqlite
persistence + cookie reuse + write-through, Go `live_store.go` parity); note
redis/postgres/firestore as same-trait follow-ons; move stores out of Ahead.
- [ ] **Step 3: Commit** (NO co-author trailer)
```bash
git add runtime-rust/README.md
git commit -m "docs(rust): sync README — Sky.Live P5 (session stores: trait + memory + sqlite)"
```

---

## Self-review notes

- **Matches Go's `live_store.go`**: the trait + choose_store(+memory fallback) +
  memory(TTL) + sqlite(checkpoint blob + mem_cache live pointer) + cookie reuse +
  write-through. The live driver stays per-process; the blob is a checkpoint — no
  stateless-driver refactor (Go doesn't do one either).
- **Go's runtime `validateSessionValue` → Rust compile-time serde derive** on the
  model's transitive closure (Task 4). Non-serde model = clean compile error.
- **Cold-hit hydration**: a sqlite get that misses the mem_cache decodes a model;
  the page handler spawns a fresh driver seeded with it (the live goroutines are
  per-process; the blob never owns them — Go parity).
- **Backward-compatible**: memory-store apps (no `[live] store` or `= "memory"`)
  keep the current behavior — but now WITH cookie reuse + TTL (fixes the per-GET
  leak). No serde derived for them.
- **Follow-ons (same trait):** redis, postgres, firestore backends; the store's
  pub/sub `Broker`; cross-replica SSE affinity. Each is an additive `SessionStore`
  impl, not an architecture change.
