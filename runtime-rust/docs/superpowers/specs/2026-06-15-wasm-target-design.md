# WASM target (`wasm32-*`) — scope + blocking pieces

**Divergence id:** `wasm-target`
**Disposition:** `DOCUMENT_BLOCKED` (out-of-scope epic) — with a verifiable
*pure-kernel floor* identified as the first landable slice.

## Problem

The README lists `WASM target (wasm32-unknown-unknown)` as future work. The
Rust runtime today is built around a native, threaded, tokio reactor:

| Anchor | Reality |
|---|---|
| `core.rs:17` | `pub type SkyTask<E,A> = Pin<Box<dyn Future + Send + 'static>>` — unconditional `Send`. |
| `task.rs:5` | `block_on` builds a `tokio::runtime::Runtime` on a freshly `std::thread::spawn`ed OS thread. |
| `task.rs:99` | `task_parallel` = `tokio::spawn` per task (true parallelism). |
| `Emitter.hs:346` | entry is hardcoded `fn main() { block_on(sky_main()) … }`. |
| `Project.hs` | Cargo.toml is a native bin; feature-gating is `usesTokio`/`usesLive`-shaped, no wasm partition. |
| `random.rs`/`time.rs` | `SystemTime::now()` for entropy seed + clock (no syscall on `unknown-unknown`). |

There is **no `--target rust-wasm` surface** in `src/Sky/Build/Rust` and no
`crate-type = cdylib` / wasm-bindgen plumbing. Shipping wasm is a re-platforming
of every effectful kernel plus a runtime-type change — too large for one pass,
and the honest deliverable is this scope/blocker document.

## Answered questions (principled, no human input)

### 1. Which WASM flavour — does it change the disposition?

Pin the README target to **`wasm32-unknown-unknown` (browser, wasm-bindgen)**.
Rationale: the only reason to want Sky-on-wasm is browser delivery (the Sky.Live
view already renders to a VNode tree — a client-side wasm view is the payoff).
`wasm32-wasip1` is a server sandbox; it competes with the native binary we
already ship and buys nothing Sky users ask for.

This does **not** change the disposition (still BLOCKED epic), but it *raises*
the cost: WASI keeps `std::fs`/`SystemTime`/`getrandom`/`OsRng` working, so it
would shrink the epic to the tokio/`Send` rewrite. `unknown-unknown` requires
re-platforming every syscall kernel onto JS host APIs. We accept the larger cost
because the smaller target isn't the one users want. **Tiering** (document both):
a future WASI tier is a strictly easier subset of the `unknown-unknown` work and
need not be planned separately.

### 2. Can the `Send + 'static` bound be made target-conditional without forking the type?

Yes — and it **must** be `cfg`-gated, not forked. Browser wasm futures
(`wasm-bindgen-futures`, `spawn_local`) are `!Send`; native `tokio::spawn` /
thread-`block_on` require `Send`. A single alias can satisfy both only via a
`cfg`-selected bound:

```rust
// core.rs
#[cfg(not(target_arch = "wasm32"))]
pub type SkyTask<E,A> = Pin<Box<dyn Future<Output=SkyResult<E,A>> + Send + 'static>>;
#[cfg(target_arch = "wasm32")]
pub type SkyTask<E,A> = Pin<Box<dyn Future<Output=SkyResult<E,A>> + 'static>>;
```

The same `#[cfg]` split applies to every `Arc<dyn Fn(..) -> SkyTask + Send + Sync>`
in `core.rs` and the TEA Model (`tea.rs`/`live/`). **Codegen mirror (blocking):**
`Emitter.hs` emits `Send` bounds on generated closures (the form-target /
closure-Model paths); those literal `+ Send` tokens must become target-aware too,
or the emitted code won't compile on wasm. A sealed `MaybeSend` marker trait is
rejected — it leaks a bound into every generic signature in both runtime and
generated code, multiplying the codegen surface for no gain over `cfg`. Two
runtime crates is rejected — it duplicates ~40 kernel files and the README's
"single runtime crate" invariant. **Decision: `cfg`-gated alias + a matching
`cfg`-aware `Send`-token emission in Emitter.hs.**

### 3. WASM equivalent of `block_on` / `task_parallel` / `task_sequence`?

`block_on` has **no** browser-wasm equivalent — you cannot block the single JS
event-loop thread. The entry stops being `fn main(){ block_on(sky_main()) }` and
becomes a `#[wasm_bindgen(start)]` that `wasm_bindgen_futures::spawn_local`s the
`sky_main()` future, driven by the host event loop. `Emitter.hs`'s
`entryPointSection` gains a third arm (today: tokio-block / call-and-drop /
inline-`Task.run`) selected by target.

`task_parallel` degrades to **sequential `join`** (await each future in turn) on
wasm — there are no threads. This is an **observable divergence vs the Go
reference**: Go's `task_parallel` interleaves goroutines, wasm's does not.
Per the principle order (correctness > Go-parity), sequential-on-wasm is *sound*
(every task still runs, results in order, errors short-circuit identically) and
is the only correct option on a single thread — so it is a **documented
intentional parity gap**, not a defect. `task_sequence` is already sequential
(`task.rs:88`) and needs no change.

### 4. Which kernels are out-of-scope-by-construction, and is dropping them documented (not a silent break)?

The supported browser-wasm kernel subset is **pure + JSON + crypto-via-JS-entropy
+ a `fetch`-backed `Http.get`**. Everything that needs a socket, file, process,
or terminal is out by construction:

| Dropped on wasm | Kernel file | Why |
|---|---|---|
| `Sky.Http.Server`, `Sky.Live` server | `server.rs`, `live/` | axum/tower-http need a TCP listener. |
| `Std.Db`, redis | `db.rs` | sqlx/redis need a socket/file DB. |
| `Std.Email` | `email.rs` | lettre/reqwest SMTP. |
| `System.*` process | `system.rs` | `std::process::Command`. |
| `Sky.Tui`, `Sky.Webview` | `tui/`, `webview.rs` | crossterm/tao/wry are native. |
| `File.*` | `file.rs` | `std::fs` (no syscall on unknown-unknown). |
| `Sky.Core.WebSocket` (native) | `ws_client.rs` | tokio-tungstenite → must move to browser `WebSocket`. |

**Re-platformed (survive, different backend):**

| Kernel | Native | Browser-wasm |
|---|---|---|
| `Http.get/post` | reqwest | `web_sys::fetch` |
| `Crypto.randomBytes`, `Random.*` seed | `SystemTime` seed / OsRng | `crypto.getRandomValues` via `getrandom`'s `js` feature |
| `Time.now/unixMillis` | `SystemTime` | `js_sys::Date::now()` |

**No-panic principle is the hard gate here.** A Sky program that calls an
unsupported kernel on the wasm target MUST fail at **compile time** — codegen
refuses to emit the feature, exactly like the existing `usesDb`/`usesLive`
gating refuses to pull axum when unused. It must NEVER reach a wasm runtime
panic (`no_std`-style unreachable, an `unimplemented!()` stub, or a JS exception),
because the no-panic-from-well-typed-Sky rule forbids it. Concretely: the
`UsedKernels` analysis already exists; the wasm path reuses it to emit a
**build-time error** ("`Std.Db` is not available on the wasm target") rather than
a `cfg`-stubbed kernel that panics when called.

### 5. How does target selection flow `sky build` → codegen → Cargo, and what is the artifact?

- **Surface:** a new `--target rust-wasm` value (sibling of `TargetRust` in
  `app/Main.hs`), NOT a `[wasm]` sky.toml stanza — target is a build-time choice,
  not project config, matching the existing `--target` axis.
- **Artifact:** `crate-type = ["cdylib"]` + `.wasm` + wasm-bindgen JS glue.
  This adds **`wasm-bindgen-cli` / `wasm-pack` as a new toolchain dependency** —
  a real cost the epic must own (parallels the cgo-detect note for Sky.Webview).
- **Feature repartition:** the `usesTokio`-derived feature set splits. On wasm,
  `tokio`'s `full` feature is unavailable; the `async = ["tokio"]` /
  `server`/`db`/`http_client` features either drop (server/db) or swap their dep
  (`http_client` → `web-sys`/`gloo-net`). `Project.hs`'s Cargo.toml emitter gains
  a target branch; `Emitter.hs`'s entry + `Send`-token emission gain a target
  branch. This is the bulk of the `src/Sky/Generate/Rust` + `src/Sky/Build/Rust`
  work.

### 6. Is byte-for-byte Go parity achievable on browser wasm?

**No, and that is the honest disposition.** There is **no reference oracle**: the
equiv-sweep diffs native-Go vs native-Rust; Go has no `wasm32-unknown-unknown`
Sky backend to diff against. Entropy/clock come from JS host APIs, `task_parallel`
loses true parallelism, and the kernel set is a strict subset. The achievable
goal is **"a defined wasm subset that is internally sound and panic-free,"** not
full parity. This matches the triage verdict and is why this pass produces a
scope/blocker document, not an implementation.

### 7. Minimum verifiable proof-of-life — does it move the disposition?

**Yes, partially.** A pure-Sky program (`List`/`String`/`Dict`/`Maybe`/`Result`
+ JSON, no Task I/O) plausibly already cross-compiles to `wasm32-unknown-unknown`
**if** the `Send` bound and tokio-gated modules are `cfg`-excluded — every kernel
in the `baseUse` list of `Project.hs` is pure-`std`. The blocking pieces for the
*floor* are exactly two: (a) the `cfg`-gated `SkyTask` `Send` split (Q2), and (b)
a wasm-target Cargo/entry branch that excludes tokio modules (Q5). That floor is
verifiable **in-boundary** (a `runtime-rust/tests` build asserting the pure
kernels compile under `--target wasm32-unknown-unknown` with the tokio features
off) without touching `sky-stdlib/` or `examples/`.

So the disposition is **DOCUMENT_BLOCKED for the epic** (server/live/db/fetch/
entropy re-platforming + wasm-bindgen toolchain + codegen target axis) **plus a
named first slice**: land the pure-kernel wasm floor as an in-boundary,
verifiable proof-of-life. The floor does not ship a user-facing `--target
rust-wasm` (that needs the entry + Cargo work), so it stays a runtime-crate-level
compile assertion until the epic opens.

## Disposition + rationale

`DOCUMENT_BLOCKED`. The full target is an out-of-scope epic: it requires a
runtime-type change (`SkyTask` `Send`), a no-tokio async rewrite (entry +
parallel), a re-platform of every effectful kernel onto JS host APIs, a new
codegen target axis through `Project.hs`/`Emitter.hs`, and a new `wasm-bindgen`
toolchain dependency. None of it is a *defect* — the native backend is correct;
wasm is unbuilt. The one landable, in-boundary slice is the pure-kernel
`cfg`-gate floor, recorded here so the epic has a tracer-bullet starting point.

## Principle check

- **No shared-stdlib / Go edits.** Every change is in `runtime-rust/` (cfg gates),
  `src/Sky/Generate/Rust` + `src/Sky/Build/Rust` (target axis), and
  `runtime-rust/tests` (proof). No `sky-stdlib/`, no `runtime-go/`, no
  `src/Sky/Generate/Go/`, no `examples/` edits.
- **No `Any` / no panic.** The defining constraint of the wasm subset (Q4):
  unsupported kernels are a **compile-time** refusal, never a wasm runtime panic
  or stub. The `cfg`-gated `SkyTask` introduces no `Box<dyn Any>` — it only
  relaxes a `Send` bound on the existing `dyn Future`.
- **Verifiable.** The floor is asserted by an in-boundary `runtime-rust/tests`
  wasm-build check. The epic's full parity is explicitly declared
  *non*-verifiable (no Go wasm oracle) — which is itself the reason it is
  DOCUMENTED, not implemented.
- **Priority order honoured.** `task_parallel`→sequential on wasm trades
  Go-parity (lowest) for correctness/soundness on a single-threaded host —
  the correct call.

## Executor decomposition

1. **Spec author** — this file (done).
2. **README updater** — clarify the WASM divergence row with the pinned target,
   the BLOCKED-epic disposition, and the named pure-kernel floor slice.
3. **Proof test** — add an in-boundary `runtime-rust/tests` assertion / doc-test
   that pins the floor expectation (pure kernels are `cfg`-cleanable for wasm;
   `SkyTask` `Send` is the gate), without claiming the full target works.
