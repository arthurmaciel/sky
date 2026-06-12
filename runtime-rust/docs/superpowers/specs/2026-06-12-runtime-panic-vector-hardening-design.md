# Runtime panic-vector hardening (lock-family + clippy gate) — design

**Date:** 2026-06-12
**Branch:** `feat/runtime-rust` (fork `arthurmaciel/sky` only)
**Task:** #53 (widened from "bare `.lock().unwrap()` in `live/mod.rs`" to a
whole-runtime panic-vector pass, per the `runtime-rust/CLAUDE.md`
no-runtime-errors rule whose reach is the entire runtime's Sky-reachable paths).

## Purpose

Bring the `sky-runtime-rust` crate into compliance with the existential
no-runtime-errors rule for the lock-family poison-panic class and the adjacent
panic vectors, and add a **clippy gate** so the codebase stays compliant — the
absence of which is exactly how these crept in (S6 review surfaced the first
ones). The result: a well-typed Sky program cannot trigger a `Mutex`/`RwLock`
poison panic, an infallible-cipher panic, a cookie-sid `expect`, or a
response-builder `unwrap` from the runtime, and `cargo clippy` mechanically
proves no new `unwrap`/`expect` enters non-test library code.

## Governing rule

`runtime-rust/CLAUDE.md` — **NO RUNTIME ERRORS (existential).** No
`unwrap`/`expect`/`panic!`/unchecked-index/unchecked-downcast in the runtime's
Sky-reachable paths. Mutex poisoning is recovered via `into_inner()`. Panics are
**designed out, not caught**. This pass applies that rule to the lock-family +
the adjacent vectors and makes it self-enforcing.

## Current state

Counted across `runtime-rust/src/sky_runtime/**` (non-test):

- **Lock-family poison unwraps (~50):** `Mutex.lock().unwrap()/.expect()`,
  `RwLock.read().unwrap()`, `RwLock.write().unwrap()` — `live/store.rs` (14),
  `http_stream.rs` (8), `ws_client.rs` (7), `server_stream.rs` (6), `server.rs`
  (6), `live/mod.rs` (6), `money.rs` (4 lock `.expect`s).
- **AES/ChaCha cipher-from-fixed-key `.unwrap()` (4):** `crypto.rs:162,184,196,218`.
- **HMAC `.expect()` (3):** `crypto.rs:63,74`, `email.rs:305`.
- **Cookie-sid `.expect()` (2):** `live/mod.rs:585,599`.
- **Response-builder `.unwrap()` (1):** `live/mod.rs:703`.
- **No clippy gate:** CI runs `cargo clippy --all-targets --all-features -- -D
  warnings` (`scripts/verify-rust-target.sh:20`), but `clippy::unwrap_used` /
  `expect_used` are restriction lints (off by default), so nothing flags these.
- **Out of scope (filed follow-up):** ~40 non-test `panic!`/`unreachable!` and
  `clippy::indexing_slicing` — too large to bundle; a deliberate future tightening.

## Design

### Part A — lock-family poison swap (~50 sites, behaviour-preserving)

Uniform mechanical replacement; `PoisonError::into_inner()` returns the guard for
all three lock types:

```rust
x.lock().unwrap()        →  x.lock().unwrap_or_else(|e| e.into_inner())
x.lock().expect("…")     →  x.lock().unwrap_or_else(|e| e.into_inner())   // money.rs
x.read().unwrap()        →  x.read().unwrap_or_else(|e| e.into_inner())
x.write().unwrap()       →  x.write().unwrap_or_else(|e| e.into_inner())
```

Rationale (CLAUDE.md "defence in depth is the floor"): a panic in one session
must not poison a shared lock and cascade-abort every other session. Recovering
the guard is the correct floor even in a no-panic design. On the happy path
(unpoisoned lock) the behaviour is identical — so the 164 runtime tests stay
green unchanged.

### Part B — the judgment cases (10 sites)

**AES/ChaCha (4) — propagate into the existing `Result` channel (zero allow).**
The key is a runtime-length `Vec<u8>` returned by `aead_read_key` (which
validates `k.len() == 32` immediately above each site), so there is no
type-level length proof and no infallible constructor. But these functions
**already return `SkyResult<E, String>`** and `aead_read_key` already feeds that
channel — so match the `new_from_slice` error into it rather than `unwrap`:

```rust
let cipher = Aes256Gcm::new_from_slice(&k).unwrap();                    // before — panic vector
let cipher = match Aes256Gcm::new_from_slice(&k) {                      // after — total, no allow
    Ok(c) => c,
    Err(e) => return SkyResult::Err(format!("Crypto.aesGcmEncrypt: {}", e).into()),
};
```

Same shape for `aesGcmDecrypt` / `chacha20Encrypt` / `chacha20Decrypt` (each
with its own message). The `Err` branch is structurally never taken (the length
was just validated) but is a genuine total fallback using the existing error
path — exactly the CLAUDE.md form ("an internal invariant that can't fail still
uses a total form with a structured-error fallback"). No `#[allow]`, no panic
vector; the only cost is an unreachable cold branch (~free).

**HMAC (3) — the irreducible exception (`#[allow]`, audited).** HMAC keys are
variable-length, so `new_from_slice` is the only constructor and returns
`Result` for API consistency while never returning `Err`. There is **no**
infallible constructor; the enclosing kernels are **pure** Sky surfaces
(`hmacSha256 : String -> String -> String`, identical on the Go backend) so they
**cannot** gain a `Result` channel without breaking the Sky API + Go parity; and
a fallback hash on the impossible `Err` would be a **silently wrong MAC — a
security defect strictly worse than the unreachable panic**. So these 3 keep
`.expect(...)` under a tagged allow:

```rust
#[allow(clippy::expect_used)] // INFALLIBLE: HMAC accepts any key length (never Err);
// pure-String Sky kernel has no Result channel and a fallback hash would be a wrong MAC.
let mut mac = HmacSha256::new_from_slice(key.as_bytes())
    .expect("Hmac<Sha256> accepts any key length");
```

These are the **only** `#[allow]`s in the crate after this pass, and each is
recorded in the README soundness register (Part D).

**Cookie-sid `expect` (2) — graceful fallthrough.** `cookie_sid` is
structurally `Some` whenever the store returned a hit (the hit was looked up
*from* `cookie_sid`), so the `expect` never fires — but it is a panic vector.
Replace with a total form that mints a fresh sid on the impossible `None`:

```rust
let s = cookie_sid.expect("live hit implies a cookie sid");   // before
let s = cookie_sid.unwrap_or_else(new_sid);                   // after — impossible None → fresh session
```

**Response-builder `.unwrap()` (1) — total fallback.** `Response::builder()…
.body(stream)` returns `Result` (only fails on invalid header/status, all
literals here). Replace the `.unwrap().into_response()` with a match that falls
back to a 500:

```rust
match Response::builder()
    .status(StatusCode::OK)
    .header(/* … literal headers … */)
    .body(axum::body::Body::from_stream(body_stream))
{
    Ok(r) => r.into_response(),
    Err(_) => StatusCode::INTERNAL_SERVER_ERROR.into_response(),
}
```

### Part C — the clippy gate (self-enforcement)

- **`runtime-rust/clippy.toml`** (new):
  ```toml
  allow-unwrap-in-tests = true
  allow-expect-in-tests = true
  ```
  Required because CI lints `--all-targets` (test code legitimately uses
  `unwrap`/`expect`). These keys exempt `#[cfg(test)]` modules + test harnesses.

- **`runtime-rust/Cargo.toml`** `[lints.clippy]` (new — declarative, visible):
  ```toml
  [lints.clippy]
  unwrap_used = "deny"
  expect_used = "deny"
  ```

- **Enforcement is automatic** via the existing CI step
  (`scripts/verify-rust-target.sh:20`, `cargo clippy --all-targets
  --all-features -- -D warnings`). No new CI wiring. After the pass that command
  is green, which mechanically proves zero `unwrap`/`expect` in non-test library
  code except the 3 tagged HMAC allows.

The `[lints]`/`clippy.toml` apply when the runtime crate is linted directly; the
TH-embedded copy in generated projects is compiled with `cargo build` (never
clippy), so the gate protects the source-of-truth crate, which is the right
place to maintain it.

### Part D — README soundness register (new section)

Add a **"Soundness attention points"** section to `runtime-rust/README.md`: a
living register of the runtime's known, deliberate soundness compromises, so
they are visible and revisitable rather than buried in code. Structure:

1. **Irreducible `unwrap`/`expect`/`#[allow]`** — the 3 HMAC sites
   (`crypto.rs:63,74`, `email.rs:305`), each with: location, why the `Err` is
   unreachable, why no total alternative exists (pure Sky API can't return
   `Result`; no infallible HMAC constructor; a fallback MAC would be a security
   defect). This is the audit trail for the only allows in the crate.

2. **`dyn Any` usages** — seeded with the one known case (the S6 pub/sub broker
   registry: `Box<dyn Any>` → `Arc<Broker<T>>`, `TypeId`-keyed, correct by
   construction, never payload-dependent). **Reserved to receive the conclusions
   of the `dyn Any` audit (task #44):** when #44 runs, each `dyn Any` in the
   runtime is catalogued here with a verdict — *reducible* (monomorphisable away,
   with a how) or *irreducible* (why), so future work can pick up the reducible
   ones. The section is the durable home for #44's findings.

This section is **not** a changelog — it records only currently-live compromises;
when one is eliminated, its entry is deleted.

## Out of scope

- The ~40 non-test `panic!`/`unreachable!` and `clippy::indexing_slicing` — a
  separate, larger tightening (filed as a follow-up task).
- Any change to the Go backend or shared codegen.
- Changing the behaviour of any happy path (every swap is behaviour-preserving;
  poison recovery only changes the cascade-abort failure path).

## Testing

- **Mechanical proof:** `cd runtime-rust && cargo clippy --all-targets
  --all-features -- -D warnings` passes with the new deny lints — i.e. zero
  `unwrap`/`expect` in non-test library code outside the 3 tagged HMAC allows.
- **Behaviour preserved:** `cargo test --features "live db redis_store"` — the
  164 runtime tests stay green (lock swaps + cipher-ctor change + cookie
  fallthrough + builder fallback are all happy-path-identical).
- **Gate round-trip:** adding a fresh bare `.unwrap()` to a non-test function
  makes `cargo clippy …` FAIL (proves the gate bites); reverting restores green.
- **AES/ChaCha equivalence:** the existing crypto round-trip tests
  (`aesGcmEncrypt`→`aesGcmDecrypt`, `chacha20Encrypt`→`chacha20Decrypt`) stay
  green after the `unwrap` → match-into-`Result` change (happy path identical).

## Done-criteria

- Every non-test lock-family `unwrap`/`expect` in the runtime uses
  `unwrap_or_else(|e| e.into_inner())`.
- AES/ChaCha propagate `new_from_slice`'s error into their existing
  `SkyResult` channel (no `unwrap`, no allow).
- The only `#[allow(clippy::expect_used)]` in the crate are the 3 HMAC sites,
  each tagged with an `// INFALLIBLE:` rationale.
- `clippy.toml` + `Cargo.toml [lints.clippy]` deny `unwrap_used`/`expect_used`
  (test-exempt); the existing CI clippy step passes green and now enforces it.
- `runtime-rust/README.md` has a "Soundness attention points" section recording
  the 3 HMAC allows + the `dyn Any` register seeded with the broker case and
  reserved for the #44 audit conclusions.
- 164 runtime tests green; gate round-trip verified.
