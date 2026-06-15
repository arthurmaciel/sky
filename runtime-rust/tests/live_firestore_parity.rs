//! Regression lock for the `live-firestore-store` divergence (DOCUMENT_AT_PARITY).
//!
//! Spec: `runtime-rust/docs/superpowers/specs/2026-06-15-live-firestore-store-design.md`.
//!
//! Ground truth (verified against the tree): NEITHER backend ships a firestore
//! session store. Go's `chooseStore` (runtime-go/rt/live_store.go) has no
//! firestore arm — `store="firestore"` hits `default` → `newMemoryStore`. The
//! Rust `choose_store` matches: it has no `firestore` arm, so an unknown kind
//! falls through to `MemoryStore::new(ttl)`. A *real* firestore store would
//! DIVERGE from Go AND is unverifiable in this environment (no GCP/emulator).
//! So behavioral Go-parity here MEANS firestore → in-memory fallback.
//!
//! This test locks that parity-by-absence so a FUTURE store backend (a real
//! firestore arm, a postgres-TLS / redis variant, …) cannot silently route
//! `"firestore"` away from memory without a red test.
//!
//! ## Feature-gating note (why this whole file is `#[cfg(feature = "live")]`)
//!
//! The `live` module — and therefore `choose_store` / `MemoryStore` /
//! `StoreHit` / `SessionStore` / `SessionEntry` — is compiled only under the
//! `live` cargo feature (`#[cfg(feature = "live")] pub mod live;`). A plain
//! `cargo test` (default features) does not compile those symbols, so the
//! whole module body is gated to keep the default test run green. Run the real
//! assertions with the feature on:
//!
//! ```text
//! cargo test --features live   --test live_firestore_parity
//! cargo test --features full   --test live_firestore_parity
//! ```
//!
//! ## Two locks, deliberately split
//!
//! 1. **Compile-time, parity-by-absence of a persistent backend.** This file
//!    builds and the assertions run with ONLY `live` enabled — NOT `db`,
//!    NOT `redis_store`. The persistent stores (`SqliteStore` /
//!    `PostgresStore` / `RedisStore`) are `#[cfg(feature = "db")]` /
//!    `#[cfg(feature = "redis_store")]`, so under `live`-only they don't even
//!    exist. The fact that `choose_store("firestore", …)` resolves to a usable
//!    store with neither feature present is the spec's point 4 ("`store=\"firestore\"`
//!    pulls no extra crate"), proven structurally by this test compiling at all.
//!
//! 2. **Run-time, observable memory-store behavior.** `choose_store("firestore", …)`
//!    must round-trip a session exactly like `MemoryStore` (memory always
//!    succeeds with no external service configured; a persistent backend over
//!    an unreachable/empty path would error or behave differently).

#![cfg(feature = "live")]

use std::sync::{Arc, Mutex};
use std::time::Duration;

use sky_runtime_rust::sky_runtime::live::store::{
    choose_store, MemoryStore, SessionHandle, SessionStore, StoreHit,
};
use sky_runtime_rust::sky_runtime::live::{build_index, SessionEntry};
use sky_runtime_rust::sky_runtime::html::Html;

/// Minimal `SessionHandle<(), ()>`, mirroring the `handle()` helper in
/// `store.rs`'s in-crate test module — the established construction pattern.
/// `()`/`()` keep the Model/Msg trivial (no serde needed for the memory path).
fn handle() -> SessionHandle<(), ()> {
    let (tx, _rx) = tokio::sync::mpsc::unbounded_channel::<()>();
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

/// Drive a `put → get → delete → get` round-trip against any store and return
/// `Ok(())` iff it behaves like the memory store: insert succeeds, a `get`
/// returns a `Live` handle (never `Cold` — there's no checkpoint backend), and
/// a `delete` makes the entry disappear. Total: no unwrap/expect/panic — every
/// failure is an explicit `Err(&'static str)` the caller turns into an
/// `assert!` message.
async fn exercise_like_memory(
    store: &dyn SessionStore<(), ()>,
) -> Result<(), &'static str> {
    if store.get("sid").await.is_some() {
        return Err("fresh store should not know an un-set sid");
    }
    store.set("sid", handle()).await;
    match store.get("sid").await {
        Some(StoreHit::Live(_)) => {}
        Some(StoreHit::Cold(_)) => {
            return Err("memory-parity store must return Live, never Cold (no checkpoint backend)")
        }
        None => return Err("store lost a session immediately after set"),
    }
    store.delete("sid").await;
    if store.get("sid").await.is_some() {
        return Err("delete did not remove the session");
    }
    Ok(())
}

/// `choose_store("firestore", …)` must round-trip exactly like the in-memory
/// store — the parity-by-absence behavioral lock.
#[tokio::test]
async fn firestore_kind_round_trips_like_memory() {
    let ttl = Duration::from_secs(60);

    // Reference behavior: a bare MemoryStore.
    let mem: MemoryStore<(), ()> = MemoryStore::new(ttl);
    if let Err(why) = exercise_like_memory(&mem).await {
        panic!("baseline MemoryStore misbehaved (test harness bug): {why}");
    }

    // The store actually selected for `store = "firestore"`. Empty path is what
    // a persistent backend would choke on; memory ignores it. No GCP/emulator
    // is configured, so a real firestore store could not round-trip here — the
    // success below is itself evidence the path is the memory fallback.
    let chosen: Arc<dyn SessionStore<(), ()>> = choose_store("firestore", "", ttl).await;
    if let Err(why) = exercise_like_memory(chosen.as_ref()).await {
        panic!(
            "choose_store(\"firestore\", …) did NOT behave like MemoryStore: {why}. \
             A store backend was added that routes \"firestore\" away from the \
             memory fallback — this DIVERGES from Go (whose chooseStore has no \
             firestore arm and falls to newMemoryStore). Re-read \
             docs/superpowers/specs/2026-06-15-live-firestore-store-design.md \
             before changing this."
        );
    }
}

/// `"firestore"` is just one unknown kind among many — it must hit the *same*
/// `default → memory` fallback as any other unrecognised store value and as the
/// empty string. Locks that no special firestore arm was inserted that treats
/// it differently from the generic unknown-kind path.
#[tokio::test]
async fn firestore_matches_generic_unknown_kind_fallback() {
    let ttl = Duration::from_secs(60);

    for kind in ["firestore", "not-a-real-store", "", "dynamodb"] {
        let store: Arc<dyn SessionStore<(), ()>> = choose_store(kind, "", ttl).await;
        if let Err(why) = exercise_like_memory(store.as_ref()).await {
            panic!(
                "choose_store({kind:?}, …) should fall back to memory like every \
                 other unknown kind, but it didn't: {why}"
            );
        }
    }
}
