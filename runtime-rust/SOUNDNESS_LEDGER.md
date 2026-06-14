# Soundness Ledger

The Rust backend's reason to exist is **no runtime errors from well-typed Sky**
(`runtime-rust/CLAUDE.md`). That means: no `panic!`/`unwrap`/`expect`/unchecked
`downcast`/`[i]` indexing in Sky-reachable code, and no `dyn Any` payload erasure.
A `clippy` deny gate (`lib.rs` + `Cargo.toml [lints.clippy]`) enforces this; the
**only** exceptions are the entries below, each tagged in-code with
`// SKY-RUST-AUDIT:ACCEPTED (… ) [ledger #N]`. Every entry is *sound by
construction* — it cannot fail for any well-typed Sky program — not "unlikely".

> **⏳ FUTURE REVIEW POINT (after the Rust backend stabilises).** Re-examine every
> entry: has it become reducible? In particular `#4` (`dyn Any`) — if the compiler
> ever monomorphises the pub/sub payload type or the cache K/V into the generated
> code, the registries could drop `Any` entirely. None of these are in generated
> code; the "no-`Any`" rule targets generated code, which has **zero** `Any`.

## #1 — `crypto.rs` HMAC constructor (`expect`) · 2 sites

`crypto.rs:66`, `crypto.rs:82` — `Hmac::<Sha256/512>::new_from_slice(key).expect(…)`.
HMAC (RFC 2104) accepts a key of **any** length (it hash-pads/truncates), so
`new_from_slice` is total — it returns `Err` only for the `InvalidLength` variant
that this construction cannot produce. The kernel signature is a pure
`hmacSha256 : String -> String -> String` with **no `Result` channel**, and a
fallback/zero MAC would be a *security* defect (silent wrong authentication), so
degrading is worse than the impossible panic. **Sound:** the error variant is
unconstructible for HMAC.

## #2 — `email.rs` SES request signing (`expect`) · 1 site

`email.rs:321` — same HMAC-`expect` shape inside the internal AWS SES SigV4
signing helper. No `Result` channel on the helper; a fallback MAC is a *wrong
signature* (request rejected or, worse, misattributed). **Sound:** same HMAC
any-length invariant as #1.

## #3 — `ffi_polyfills.rs` dynamic-dispatch fallback (`panic!`) · 2 sites

`ffi_polyfills.rs:29` (`ffi_call_pure_polyfill`), `:45` (`ffi_call_task_polyfill`)
— both return an **unconstrained generic `T`**, so no total value can be
synthesised. `Ffi.callPure` is **statically dead for valid Sky**: the compiler's
peephole resolves the string-literal-kernel + list-literal call shape at compile
time, so this dynamic path is unreachable from well-typed code; it panics with a
"refactor to a string-literal kernel" message only if someone hand-writes the
unsupported dynamic shape. `Ffi.callTask` on `--target rust` is a **deferred
feature** (sub-project D) that fails loudly rather than miscompiling. **Sound for
valid Sky:** unreachable (callPure) / not-yet-a-feature (callTask). *Closing #3
fully = implement `Ffi.callTask` (roadmap T1) so the second site disappears.*

## #4 — `dyn Any` registries (TypeId-/handle-keyed) · 2 subsystems

The only `dyn Any` in the crate. Both are **container-level** erasure keyed so the
one cast can never fail — the *payload* always travels as its real Rust type.

- **Pub/sub broker** — `live/pubsub.rs:86` `HashMap<TypeId, Box<dyn Any + Send +
  Sync>>`. Exactly one `Arc<Broker<T>>` is stored under `TypeId::of::<T>()`; the
  single `downcast_ref::<Arc<Broker<T>>>()` (`:97`) is keyed by that same
  `TypeId`, so it is *provably* `Some`. The impossible `None` arm logs a
  "please report" BUG line and rebuilds — it never panics. The broadcast payload
  `T` is never erased (this is the monomorphise-the-dynamism design from
  `CLAUDE.md`, the opposite of Go's reflect-and-downcast broker).
- **`Std.Cache`** — `cache.rs:58` per-entry `Box<dyn Any + Send>` (value `V`) and
  `:71` per-handle `Box<dyn Any + Send>` (the `Vec<CacheEntry<K>>`). Every op on a
  given `Cache k v` handle uses the *same* `K`/`V` (enforced by Sky's opaque
  `Cache k v` type), so the downcasts (`:130/:185/:199/:241/:243`) are
  K/V-consistent by construction. A mismatch can only arise from a
  type-system-violating call that cannot be written in Sky; it degrades to a
  cache **miss / no-op** (`get` → `Nothing`), never a panic.

`Cache_remove`/`size`/`clear` carry no `V`/`K` witness, which is why the store is
`Any`-erased rather than generic — the witness only exists on the K/V-bearing ops.

## #5 — single `unsafe` block (`pre_exec` / `prctl`) · 1 site

`live/console_proxy.rs:156` — `unsafe { cmd.pre_exec(|| libc::prctl(PR_SET_PDEATHSIG…)) }`
to make the spawned console child die with its parent. The closure runs in the
forked child between `fork` and `exec`, calls only the **async-signal-safe**
`libc::prctl`, allocates nothing, takes no locks, and re-enters no Rust runtime —
the documented-safe `pre_exec` usage pattern. Failure is non-fatal (best-effort
hardening). This is the crate's **only** `unsafe`; there is no `transmute`,
`from_raw`/`into_raw`, `static mut`, or raw-pointer arithmetic anywhere.

## Not in this ledger but worth noting

- `html.rs:42` `OnRaw(String, Arc<dyn Any + Send + Sync>)` — an opaque event
  payload that is **only ever passed through**, never `downcast` in Rust (it
  exists to carry a host-supplied value across the boundary). No cast → no
  failure mode. (P1 limitation: heterogeneous raw-event payloads.)

## Audit command

```bash
grep -rn "SKY-RUST-AUDIT" runtime-rust/src/
grep -rEn "dyn Any|std::any|downcast|transmute|\bunsafe\b|from_raw|into_raw|static mut" \
  runtime-rust/src/ src/Sky/Generate/Rust/ src/Sky/Build/Rust/   # generated/codegen must stay empty
```
