# Runtime panic-vector hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the `sky-runtime-rust` crate compliant with the no-runtime-errors rule for lock-family poison panics + adjacent panic vectors, and add a self-enforcing clippy gate.

**Architecture:** Sequence the swaps first (each commit stays green — no committed gate yet, so `cargo build`/`test`/`clippy` pass), then land the deny-gate config last once the crate is already clean. Lock-family swaps are a uniform mechanical replacement (`unwrap_or_else(|e| e.into_inner())`); the ~10 judgment cases are exact per-site edits; the gate is `clippy.toml` (test-exempt) + `Cargo.toml [lints.clippy]`.

**Tech Stack:** Rust (`std::sync::{Mutex,RwLock}` `PoisonError::into_inner`), clippy restriction lints, the existing CI gate `scripts/verify-rust-target.sh:20`.

---

## Build environment (every task)

```bash
export PATH="$HOME/.ghcup/bin:$PATH"
export CARGO_TARGET_DIR=$HOME/.cache/sky-rust-target
export RUSTC_WRAPPER=sccache
cd /home/arthur/Documentos/comp/sky/runtime-rust
```

- Runtime-only edits — **no cabal rebuild**. Verify with `cargo test`/`cargo clippy`.
- **Per-task verification** (the "test" for a behaviour-preserving refactor):
  1. `cargo test --features "live db redis_store" --lib 2>&1 | grep "test result"` → **164 passed** (unchanged).
  2. Targeted clippy on the flags this pass introduces (no committed gate yet):
     `cargo clippy --all-targets --all-features -- -D warnings -W clippy::unwrap_used -W clippy::expect_used 2>&1 | grep -E "unwrap_used|expect_used|warning:|error:" | grep "<file you touched>"` → **no hits for the file(s) you touched** (outside `#[cfg(test)]`).
- Fork-only: never touch `runtime-go/` or `src/Sky/Generate/Go/`. No co-author lines.
- **Safety net for the mechanical sed swaps:** if a `.read()/.write().unwrap()` were ever on a non-`RwLock` (an `io` result), `into_inner()` would not typecheck and `cargo build` fails — revert that one site. (Verified for this codebase: all `.read()/.write()` receivers are `RwLock`.)

---

### Task 1: Lock-family poison swaps in `live/`

**Files:**
- Modify: `runtime-rust/src/sky_runtime/live/store.rs` (14 sites: Mutex `.lock()` + RwLock `.read()`/`.write()`)
- Modify: `runtime-rust/src/sky_runtime/live/mod.rs` (6 Mutex `.lock().unwrap()` sites: 345,352,587,674,748,764)

Do NOT touch `live/pubsub.rs` (its `.lock().unwrap()` are all `#[cfg(test)]`).

- [ ] **Step 1: Apply the uniform swap to the two files**

```bash
cd /home/arthur/Documentos/comp/sky/runtime-rust/src/sky_runtime
for f in live/store.rs live/mod.rs; do
  sed -i \
    -e 's/\.lock()\.unwrap()/.lock().unwrap_or_else(|e| e.into_inner())/g' \
    -e 's/\.read()\.unwrap()/.read().unwrap_or_else(|e| e.into_inner())/g' \
    -e 's/\.write()\.unwrap()/.write().unwrap_or_else(|e| e.into_inner())/g' \
    "$f"
done
```

- [ ] **Step 2: Verify no bare lock-family unwrap remains in these files**

```bash
grep -nE "\.(lock|read|write)\(\)\.unwrap\(\)" live/store.rs live/mod.rs || echo "CLEAN"
```
Expected: `CLEAN`.

- [ ] **Step 3: Build + tests green (behaviour preserved)**

Run: `cd /home/arthur/Documentos/comp/sky/runtime-rust && cargo test --features "live db redis_store" --lib 2>&1 | grep "test result"`
Expected: `test result: ok. 164 passed`.

- [ ] **Step 4: Commit**

```bash
cd /home/arthur/Documentos/comp/sky
git add runtime-rust/src/sky_runtime/live/store.rs runtime-rust/src/sky_runtime/live/mod.rs
git commit -m "fix(rust): poison-tolerant lock recovery in live/store.rs + live/mod.rs"
```

---

### Task 2: Lock-family poison swaps in the top-level runtime files

**Files:**
- Modify: `runtime-rust/src/sky_runtime/server.rs` (6), `server_stream.rs` (6), `http_stream.rs` (8), `ws_client.rs` (7) — Mutex/RwLock `.unwrap()`
- Modify: `runtime-rust/src/sky_runtime/money.rs` (4 — `rates().lock().expect("money fx rates mutex")`)

- [ ] **Step 1: Apply the uniform swap (unwrap forms + money's expect form)**

```bash
cd /home/arthur/Documentos/comp/sky/runtime-rust/src/sky_runtime
for f in server.rs server_stream.rs http_stream.rs ws_client.rs money.rs; do
  sed -i \
    -e 's/\.lock()\.unwrap()/.lock().unwrap_or_else(|e| e.into_inner())/g' \
    -e 's/\.read()\.unwrap()/.read().unwrap_or_else(|e| e.into_inner())/g' \
    -e 's/\.write()\.unwrap()/.write().unwrap_or_else(|e| e.into_inner())/g' \
    -e 's/\.lock()\.expect("[^"]*")/.lock().unwrap_or_else(|e| e.into_inner())/g' \
    "$f"
done
```

(The `money.rs` test asserts at lines 333-337 use `RD::from_str(...).unwrap()` — NOT a lock form, so the sed leaves them untouched; they're test code anyway.)

- [ ] **Step 2: Verify no bare lock-family unwrap/expect remains**

```bash
grep -nE "\.(lock|read|write)\(\)\.(unwrap|expect)\(" server.rs server_stream.rs http_stream.rs ws_client.rs money.rs | grep -v unwrap_or || echo "CLEAN"
```
Expected: `CLEAN`.

- [ ] **Step 3: Build + tests green**

Run: `cd /home/arthur/Documentos/comp/sky/runtime-rust && cargo test --features "live db redis_store" --lib 2>&1 | grep "test result"`
Expected: `test result: ok. 164 passed`.

- [ ] **Step 4: Commit**

```bash
cd /home/arthur/Documentos/comp/sky
git add runtime-rust/src/sky_runtime/server.rs runtime-rust/src/sky_runtime/server_stream.rs runtime-rust/src/sky_runtime/http_stream.rs runtime-rust/src/sky_runtime/ws_client.rs runtime-rust/src/sky_runtime/money.rs
git commit -m "fix(rust): poison-tolerant lock recovery in server/stream/ws/money"
```

---

### Task 3: `live/mod.rs` judgment cases (cookie-sid + response builder)

**Files:**
- Modify: `runtime-rust/src/sky_runtime/live/mod.rs` (lines ~585, ~599, ~703 — note: line numbers shift after Task 1's swap; locate by content)

- [ ] **Step 1: Cookie-sid `expect` → fresh-sid fallthrough (2 sites)**

Find the two lines (grep `grep -n 'cookie_sid.expect' live/mod.rs`):
```rust
let s = cookie_sid.expect("live hit implies a cookie sid");
let s = cookie_sid.expect("cold hit implies a cookie sid");
```
Replace each with (the impossible `None` degrades to a fresh session — `new_sid` is defined in this file at ~line 390):
```rust
// cookie_sid is structurally Some on a store hit (the hit was looked up from it);
// the impossible None degrades to a fresh session rather than panicking.
let s = cookie_sid.unwrap_or_else(new_sid);
```
(Both sites get the identical replacement; the comment can be on the first only.)

- [ ] **Step 2: Response-builder `.unwrap()` → 500 fallback (1 site)**

Find the SSE `Response::builder()…body(body_stream).unwrap().into_response()` chain (grep `grep -n 'body(axum::body::Body::from_stream' live/mod.rs`). Replace the `.unwrap().into_response()` tail so the whole expression becomes a `match`:
```rust
match axum::response::Response::builder()
    .status(StatusCode::OK)
    .header(axum::http::header::CONTENT_TYPE, "text/event-stream")
    .header(axum::http::header::CACHE_CONTROL, "no-cache")
    .header("x-accel-buffering", "no")
    .body(axum::body::Body::from_stream(body_stream))
{
    Ok(r) => r.into_response(),
    // Headers/status are all literals, so this never fails; total fallback per
    // the no-runtime-errors rule.
    Err(_) => StatusCode::INTERNAL_SERVER_ERROR.into_response(),
}
```
(Match the exact builder chain already present — keep its existing headers verbatim; only convert the `.unwrap().into_response()` tail into the `match`.)

- [ ] **Step 3: Build + tests green**

Run: `cd /home/arthur/Documentos/comp/sky/runtime-rust && cargo test --features "live db redis_store" --lib 2>&1 | grep "test result"`
Expected: `test result: ok. 164 passed`. Also confirm no `expect(`/bare builder `unwrap` remains: `grep -nE "cookie_sid.expect|from_stream\(body_stream\)\)\s*\.unwrap" live/mod.rs || echo CLEAN` → `CLEAN`.

- [ ] **Step 4: Commit**

```bash
cd /home/arthur/Documentos/comp/sky
git add runtime-rust/src/sky_runtime/live/mod.rs
git commit -m "fix(rust): total cookie-sid fallthrough + SSE response 500 fallback (no panic)"
```

---

### Task 4: Crypto — AES/ChaCha `Result`-propagation + the 3 HMAC allows

**Files:**
- Modify: `runtime-rust/src/sky_runtime/crypto.rs` (4 AES/ChaCha at 162,184,196,218; 2 HMAC at 63,74)
- Modify: `runtime-rust/src/sky_runtime/email.rs` (1 HMAC at ~305)

- [ ] **Step 1: AES/ChaCha — match `new_from_slice` into the existing `SkyResult`**

There are 4 sites of the form `let cipher = <Cipher>::new_from_slice(&k).unwrap();`, each inside a `pub fn …(…) -> SkyResult<E, String>`. Replace each with a match that returns into the existing channel, using the function's own name in the message:

```rust
// crypto_aes_gcm_encrypt (line ~162):
let cipher = match Aes256Gcm::new_from_slice(&k) {
    Ok(c) => c,
    Err(e) => return SkyResult::Err(format!("Crypto.aesGcmEncrypt: {}", e).into()),
};
// crypto_aes_gcm_decrypt (~184):   message "Crypto.aesGcmDecrypt: {}"
// crypto_chacha20_encrypt (~196):  ChaCha20Poly1305::new_from_slice, message "Crypto.chacha20Encrypt: {}"
// crypto_chacha20_decrypt (~218):  ChaCha20Poly1305::new_from_slice, message "Crypto.chacha20Decrypt: {}"
```
Use the correct cipher type (`Aes256Gcm` vs `ChaCha20Poly1305`) and the enclosing function's name in each message. The `Err` branch is structurally never taken (`aead_read_key` validated `len == 32` just above) but is a real total fallback.

- [ ] **Step 2: HMAC — keep `.expect`, tag with `#[allow]` + `// INFALLIBLE:` (2 sites in crypto.rs)**

At `crypto_hmac_sha256` (line ~63) and `crypto_hmac_sha512` (~74), prefix the `let mut mac = …new_from_slice(...).expect(...)` statement with the allow + comment:
```rust
// INFALLIBLE: HMAC accepts any key length (new_from_slice never returns Err);
// the kernel is a pure `String -> String -> String` Sky surface with no Result
// channel, and a fallback MAC would be a silently-wrong hash (a security defect).
#[allow(clippy::expect_used)]
let mut mac = HmacSha256::new_from_slice(key.as_bytes())
    .expect("Hmac<Sha256> accepts any key length");
```
(Same for the Sha512 site with `HmacSha512` / its existing message.)

- [ ] **Step 3: HMAC — same allow on the email.rs site (1 site)**

At `email.rs` `hmac_bytes` (~line 305):
```rust
// INFALLIBLE: HMAC accepts any key length (never Err); internal helper with no
// Result channel — a fallback MAC would be a wrong SES signature.
#[allow(clippy::expect_used)]
let mut mac = HmacSha256::new_from_slice(key).expect("hmac key");
```

- [ ] **Step 4: Build + crypto tests green**

Run: `cd /home/arthur/Documentos/comp/sky/runtime-rust && cargo test --features "live db redis_store" --lib 2>&1 | grep "test result"`
Expected: `test result: ok. 164 passed` (the AES/ChaCha round-trip tests confirm the cipher change is happy-path-identical). Confirm only the 3 tagged HMAC sites keep an `expect`: `grep -rn "new_from_slice.*\.expect" crypto.rs email.rs | wc -l` → `3`.

- [ ] **Step 5: Commit**

```bash
cd /home/arthur/Documentos/comp/sky
git add runtime-rust/src/sky_runtime/crypto.rs runtime-rust/src/sky_runtime/email.rs
git commit -m "fix(rust): AES/ChaCha propagate into SkyResult; tag 3 irreducible HMAC expects #[allow]+INFALLIBLE"
```

---

### Task 5: The clippy gate + round-trip

**Files:**
- Create: `runtime-rust/clippy.toml`
- Modify: `runtime-rust/Cargo.toml` (add `[lints.clippy]`)

- [ ] **Step 1: Add the test-exemption config**

Create `runtime-rust/clippy.toml`:
```toml
# The no-runtime-errors rule (runtime-rust/CLAUDE.md) bans unwrap/expect in
# Sky-reachable library code. Tests legitimately use them; CI lints --all-targets,
# so exempt test code here.
allow-unwrap-in-tests = true
allow-expect-in-tests = true
```

- [ ] **Step 2: Deny the lints in Cargo.toml**

Append to `runtime-rust/Cargo.toml` (a new top-level table):
```toml
[lints.clippy]
# No-runtime-errors gate: a well-typed Sky program must not hit a panic vector.
# The only permitted exceptions are the 3 INFALLIBLE-tagged HMAC #[allow] sites
# (see "Soundness attention points" in README.md).
unwrap_used = "deny"
expect_used = "deny"
```

- [ ] **Step 3: Whole-crate clippy is green (mechanical proof of compliance)**

Run: `cd /home/arthur/Documentos/comp/sky/runtime-rust && cargo clippy --all-targets --all-features -- -D warnings 2>&1 | tail -5`
Expected: finishes with no `error:`/`warning:` (the crate is already clean from Tasks 1-4; the 3 HMAC allows are tagged; tests are exempt). If clippy flags a site you missed, fix it (swap or tag) and re-run.

- [ ] **Step 4: Gate round-trip — prove it BITES**

Temporarily add a bare unwrap to a NON-test function (e.g. top of `crypto.rs` `crypto_hmac_sha256`):
```bash
cd /home/arthur/Documentos/comp/sky/runtime-rust/src/sky_runtime
# inject
perl -0pi -e 's/(pub fn crypto_hmac_sha256\(key: String, msg: String\) -> String \{)/$1\n    let _gate: i64 = "x".parse().unwrap(); \/\/ TEMP gate probe/' crypto.rs
cd /home/arthur/Documentos/comp/sky/runtime-rust
cargo clippy --all-features -- -D warnings 2>&1 | grep -E "unwrap_used|used `unwrap`" | head
```
Expected: clippy FAILS citing `clippy::unwrap_used` on the injected line. Then revert:
```bash
cd /home/arthur/Documentos/comp/sky/runtime-rust/src/sky_runtime
perl -0pi -e 's/\n    let _gate: i64 = "x"\.parse\(\)\.unwrap\(\); \/\/ TEMP gate probe//' crypto.rs
cd /home/arthur/Documentos/comp/sky/runtime-rust
cargo clippy --all-features -- -D warnings 2>&1 | tail -2   # green again
git diff --stat src/sky_runtime/crypto.rs   # expect: no changes (clean revert)
```

- [ ] **Step 5: Commit**

```bash
cd /home/arthur/Documentos/comp/sky
git add runtime-rust/clippy.toml runtime-rust/Cargo.toml
git commit -m "feat(rust): clippy gate denies unwrap/expect in runtime lib (test-exempt)"
```

---

### Task 6: README "Soundness attention points" register

**Files:**
- Modify: `runtime-rust/README.md`

- [ ] **Step 1: Add the section** (place it after the "PubSub / Broker" section, before "Module structure" — locate with `grep -n "## Module structure\|### PubSub" runtime-rust/README.md`):

````markdown
## Soundness attention points

A living register of the runtime's deliberate, currently-live soundness
compromises — visible and revisitable rather than buried in code. Not a
changelog: when a compromise is eliminated, its entry is deleted.

### Irreducible `#[allow]` / panic vectors

The clippy gate (`Cargo.toml [lints.clippy]` + `clippy.toml`) denies
`unwrap`/`expect` in non-test library code. The **only** exceptions are 3
HMAC sites, each `#[allow(clippy::expect_used)]` with an `// INFALLIBLE:`
rationale:

| Site | Why unreachable | Why no total alternative |
|---|---|---|
| `crypto.rs` `crypto_hmac_sha256` | `Hmac::new_from_slice` never returns `Err` (HMAC accepts any key length) | pure Sky kernel `hmacSha256 : String -> String -> String` — no `Result` channel without breaking Go parity; no infallible HMAC constructor; a fallback MAC would be a silently-wrong hash (security defect) |
| `crypto.rs` `crypto_hmac_sha512` | same | same |
| `email.rs` `hmac_bytes` | same | internal SES-signing helper returning `Vec<u8>`; a fallback MAC would be a wrong signature |

Everything else in the crate is panic-vector-free: lock-family unwraps use
`unwrap_or_else(|e| e.into_inner())`; AES/ChaCha propagate `new_from_slice`
errors into their existing `SkyResult` channel.

### `dyn Any` register

| Site | Shape | Verdict |
|---|---|---|
| `live/pubsub.rs` broker registry | `Box<dyn Any>` → `Arc<Broker<T>>`, keyed by `TypeId` | **irreducible-by-design** — correct by construction (only an `Arc<Broker<T>>` is ever stored under `TypeId::of::<T>()`); never payload-dependent. The payload itself is never erased. |

*Reserved for the `dyn Any` audit (task #44):* when that audit runs, every
`dyn Any` in the runtime is catalogued here with a verdict — **reducible**
(monomorphisable away, with how) or **irreducible** (why) — so future work can
pick up the reducible ones.

### Out-of-scope panic vectors (future tightening)

~40 non-test `panic!`/`unreachable!` sites and `clippy::indexing_slicing` are
NOT yet gated (too large to bundle with the lock-family pass). Tracked as a
follow-up.
````

- [ ] **Step 2: Commit**

```bash
cd /home/arthur/Documentos/comp/sky
git add runtime-rust/README.md
git commit -m "docs(rust): README Soundness attention points register (HMAC allows + dyn Any)"
```

---

## Self-review notes

- **Spec coverage:** lock-family swap (Tasks 1-2), AES/ChaCha + HMAC (Task 4), cookie/builder (Task 3), clippy gate (Task 5), README register (Task 6). Out-of-scope panic/index recorded in the README register + (to be) filed.
- **Sequencing:** gate config lands in Task 5 AFTER Tasks 1-4 clean the crate, so every commit is green. The per-task verification uses ad-hoc `-W clippy::unwrap_used` flags before the gate exists.
- **Behaviour preservation:** every swap is happy-path-identical (poison recovery only changes the cascade-abort failure path; AES/ChaCha `Err` branch is never taken; cookie `None` is structurally impossible; builder never fails) — so the 164 runtime tests are the regression guard and must stay green at every task.
- **Type consistency:** `unwrap_or_else(|e| e.into_inner())` is uniform for Mutex/RwLock (PoisonError::into_inner returns the guard for all three). `new_sid` (mod.rs:390), `SkyResult::Err`, `StatusCode::INTERNAL_SERVER_ERROR` all confirmed in scope.
- **Line-number drift:** Tasks 3-4 locate sites by content (grep), not absolute line numbers, since Tasks 1-2's swaps shift them.
