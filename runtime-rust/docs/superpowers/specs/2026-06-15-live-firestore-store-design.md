# Sky.Live firestore session store — design / disposition

**divergenceId:** `live-firestore-store`
**Disposition:** `DOCUMENT_AT_PARITY`
**Date:** 2026-06-15

## Problem

The Rust backend has no `firestore` arm in `choose_store`. The triage filed this
as a DOCUMENT-blocked item ("same SessionStore trait, but no gcloud/emulator to
verify → unverifiable persistent store"). Before writing any skeleton, the
ground truth had to be checked against the Go reference: **does Go itself ship a
firestore store?**

## Ground truth (verified against the tree, 2026-06-15)

| Claim | Verified at | Reality |
|---|---|---|
| Go has a firestore session store | `runtime-go/rt/live_store.go:980-1035` `chooseStore` | **NO.** Arms exist only for `sqlite` / `postgres` / `redis`. `default` → `newMemoryStore(ttl)`. No `newFirestoreStore` / `firestoreSessionStore` symbol anywhere in `runtime-go/rt/*.go`. |
| Go maps `store="firestore"` → memory | same `default` branch | **YES**, silently, with a `session store: memory` log line. |
| Docs already concede this | `docs/skylive/pubsub-design.md:282` | "NOT IN RUNTIME — `firestoreSessionStore` is mentioned in docs but no Go code exists today." |
| Docs overpromise firestore as a store value | `docs/skylive/overview.md:127`, `docs/sky-toml.md:123,133` | List `firestore` as valid. This is a **Go/docs-owned gap**, present in the reference backend, not introduced by Rust. |
| Rust `choose_store` falls to memory for unknown kinds | `runtime-rust/src/sky_runtime/live/store.rs:332-369` | **YES.** No `firestore` arm; `let _ = (kind, path); Arc::new(MemoryStore::new(ttl))`. |
| `liveStore="firestore"` pulls no extra crate | `src/Sky/Generate/Rust/Builder/Emitter.hs:784-786` | **YES.** `needsDb` gates on `["sqlite","postgres"]`, `needsRedis` on `"redis"`; `"firestore"` matches neither → no `db`/`redis_store` feature, no `sqlx`/`redis` dep. Cargo.toml is byte-identical to a `store="memory"` live app. |
| Any firestore code in the Rust boundary | grep `firestore` over `runtime-rust/src/`, `Cargo.toml`, `src/Sky/Generate/Rust/` | **NONE.** Zero hits. |

## Asker's questions — answered from ground truth

1. **Does Go actually implement a firestore store?** No. `store="firestore"`
   silently maps to memory. Therefore behavioral Go-parity *means*
   firestore→memory-fallback. An actual Rust firestore impl would be a
   **divergence FROM Go**, not parity. This reframes the disposition from
   "infra-blocked skeleton" to **already at parity — document only**.

2. **Does `store="firestore"` already produce a clean Rust build that boots on
   memory?** Yes. `choose_store` has no firestore arm → memory; `emitCargoToml`
   pulls no crate for `"firestore"`. The build compiles, boots, and serves on an
   in-memory store, matching Go at the behavioral level. The "unverified
   skeleton that cannot be reached without explicit config" criterion is
   satisfied trivially — **there is no firestore code path to reach.**

3. **Is the docs overpromise out-of-boundary for Rust to correct?** Yes. `docs/`
   and `runtime-go/` are NEVER-EDIT. The docs overpromise relative to Go's own
   runtime. Rust inherits the same documentation/runtime gap. The correct Rust
   action is to **match Go's gap, not close it.**

4. **Is there an acceptable middle ground (feature-gated skeleton)?** No. Even a
   default-OFF `firestore_store` feature would ship persistent-store code that
   cannot be verified here (no GCP/emulator round-trip) AND that, if it worked,
   would diverge from Go (which has no firestore store). It buys nothing toward
   parity and risks the no-runtime-error guarantee. "NEVER ship something you
   cannot verify" forces the pure DOCUMENT disposition.

5. **Should the README divergence row be reclassified?** Yes — from "future /
   SessionStore-trait-parity" to **parity-by-absence**. Wording below.

6. **Regression-test risk from future store backends?** A future store arm
   (e.g. a real firestore arm, or a postgres-TLS / redis variant) could
   accidentally route `"firestore"` away from memory, or `emitCargoToml` could
   start pulling a crate for it. Lock the current behavioral-parity state with a
   regression test (executor task 3).

## Disposition + rationale

**DOCUMENT_AT_PARITY.** This is not a Rust-specific divergence: both backends
have no firestore store and both fall to an in-memory store for
`store="firestore"`. The Rust behavior is byte-for-byte the Go behavior. The
only way to "implement firestore" would (a) diverge from the Go reference and
(b) be unverifiable in this environment — both forbidden. The README's prior
"future" classification was based on the *docs'* promise, not Go's *runtime*;
the verified runtime is at parity.

## Principle check

- **No shared-stdlib / Go / docs / examples edits.** Confirmed — only
  `runtime-rust/` README + `runtime-rust/tests/` + this spec are touched.
- **No `Any` / panic / unwrap.** No code added; the existing memory fallback is
  total (`Arc::new(MemoryStore::new(ttl))`).
- **Verifiable here.** The regression test asserts the *absence* of a firestore
  path (memory fallback + no crate) — verifiable with `cargo test`, no GCP
  needed.
- **Security > correctness > soundness > efficiency > Go-parity.** All upheld:
  matching Go's behavior IS parity; shipping unverified firestore code would
  trade away the no-runtime-error guarantee for nothing.

## Executor decomposition (DOCUMENT — disjoint files)

1. **Spec** (this file) — done.
2. **README divergence row** — reclassify line 33 to parity-by-absence
   (`runtime-rust/README.md` only).
3. **Regression test** — assert `choose_store("firestore", …)` returns a memory
   store and `emitCargoToml` with `liveStore="firestore"` pulls no extra crate
   (`runtime-rust/tests/` only).

### Proposed README row wording

```
| [=] | Sky.Live: firestore session store | at parity (Go has none either) | Go's `chooseStore` (live_store.go) has NO firestore arm — `store="firestore"` hits `default` → `newMemoryStore`. Rust's `choose_store` matches: unknown kind → `MemoryStore`, and `emitCargoToml` pulls no crate for `"firestore"`. The docs (`docs/skylive/overview.md`, `docs/sky-toml.md`) overpromise relative to Go's own runtime — a shared docs/Go gap, not a Rust divergence. A real firestore store would DIVERGE from Go AND is unverifiable here (no GCP/emulator). Parity-by-absence, locked by a regression test. |
```
