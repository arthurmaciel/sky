# Auto async→Task FFI for foreign `async fn` / `-> impl Future` (#44) — design

**Goal.** Bind a foreign `async fn` (or a fn returning `impl Future<Output=T>`) automatically,
so a Sky program can call it without a hand-written wrapper shim. This is the keystone FFI
unlock: the empirical `skyshop-rs`-no-shim test (2026-06-23) showed EVERY real operation of
firestore / async-stripe / firebase is `async fn` and auto-FFI drops them — the shim crates
exist ONLY to paper over this.

**Status:** GUARDIAN-CLEARED — APPROVE-FOR-IMPLEMENTATION (design only; no implementation this pass,
per user). The make-or-break was verified in source: Sky's `block_on` (`task.rs:5`) is a real
multi-thread `tokio::runtime::Runtime::new()` + `enable_all()` (reactor+timer present) on EVERY entry
shape (cli/server/live/tui; webview = current-thread tokio, still `enable_all`). So native `.await` of
a foreign tokio future works — NO "no reactor running" panic. The native-await-as-`Task` design ships
as written; the shim's block_on-on-a-dedicated-thread is NOT needed (and would itself panic inside an
already-running worker). See the constraint checklist + phased plan below.

### Guardian constraint checklist (blocking — the plan MUST honor)
1. **[C5 — MANDATORY, highest priority] `catch_unwind` around every foreign await.** The synchronous
   panic gate is NOT installed on server/live (`Emitter.hs:408`), and a foreign `async fn` can panic
   mid-poll (a deep `.unwrap()` on a malformed server reply, reachable from well-typed Sky). Emit
   `match std::panic::AssertUnwindSafe(::crate::foo(args)).catch_unwind().await { Ok(v)=>…, Err(_)=>err_res(SkyError::from("foreign async call panicked")) }`
   (`FutureExt::catch_unwind` from `futures`). `AssertUnwindSafe` justified by C3 by-value args (no
   shared mutable state straddles the catch). Without this the no-runtime-panic existential is violated.
2. **[C1 — strict Send gate]** the multi-thread runtime + `task_parallel`'s `tokio::spawn` require a
   `Send` future. rustdoc does NOT state auto-trait `Send`, so gate CONSERVATIVE-CONJUNCTIVE: admit only
   when every ARG type AND the Output type are provably `Send` (the closed Sky-coercible set is all
   Send); else DROP `async-future-not-send`. Sound over-approximation — never admits a non-Send future.
   Do NOT fork to `spawn_local`/current-thread (a non-Send future could still reach `task_parallel`).
3. **[C2/C3 — by-value args]** no borrowed arg may straddle the await; `&self`/`&T` that must outlive
   the await → DROP or owned-clone bridge (compose with #45 generic-Self + the #28 by-ref pattern).
   #44 targets async FREE fns + (post-#45) by-value-receiver methods.
4. **[Recognition — TWO-PRONGED]** `is_async==true` ⇒ rustdoc `output` is ALREADY the desugared `T`
   (no `Future` to unwrap); `-> impl Future<Output=T>` / `Pin<Box<dyn Future<Output=T>>>` ⇒ unwrap the
   `Output=` binding first. Unit-test all three extract the SAME `T`. (The inspector already maps the
   Pin/Future arm → Task and `classify_effect` tags `is_async→effectful`; extend to the bare-`is_async`
   case + the `impl Future` arm.)
5. **[C4 — crate/feature gating]** an async-FFI binding must pull the foreign crate (+ its tokio
   features) into the generated Cargo.toml via the `usesTokio`/crate-gating path. The Sky entry is
   already tokio (verified) — no entry change — but DISCHARGE the no-reactor worry with a green
   **pure-Sky.Cli** async fixture, not just the assertion.
6. **[Result-flatten totality]** `async fn -> Result<X,E>` → `Task Error X'` flattening `E → SkyError`
   must be TOTAL for any concrete foreign `E` (Debug-based `SkyError::from_foreign`, NEVER a blind
   `.to_string()` that assumes `E: Display` — the `Decimal`/Display pitfall). Route through the same
   normalization as #32; Sky reads status from the Ok payload, never the Err slot. Sequence/​co-land
   **#34** (the #32 `String→SkyError` constructor-keyed hardening) — the flatten exercises that path.
7. **[Go-byte-identity]** gated entirely on an async signature the Go inspector never emits; non-async
   fns byte-identical.
8. **[Proof bar]** fixtures discharging each risk: negative-row (non-Send / non-bindable-Output → DROP);
   a **pure-Cli** async fixture (no-reactor discharge); a **server `Cmd.perform`** async fixture; and a
   **foreign-future-panics-mid-poll** fixture asserting it becomes `Err` (proves C5).

### Phased plan (TDD; each phase guardian-final on the diff at impl time)
- **P0 — fixture** `NN-ffi-async` (hand-stub): `async fn ping()->String`, `async fn add(i64,i64)->i64`,
  `async fn try_div(i64,i64)->Result<i64,String>` (flatten), `async fn boom()->i64` (panics → must Err),
  + a non-Send/non-bindable-Output NEGATIVE row (must DROP). kernel.json + Main.sky `Task.run`-ing each.
- **P1 — inspector recognition** (`tools/sky-ffi-inspect-rs`): the two-pronged Output extraction
  (is_async vs Future/Pin) + the strict Send gate + `async-future-not-send`/non-bindable drops + emit the
  `Task`-shaped binding metadata. Unit tests per shape (same `T`), per drop.
- **P2 — codegen wrapper** (`src/Sky/Build/Rust` + `Builder`): emit `Box::pin(async move { catch_unwind(await) → coerce/flatten })`; the C5 boundary; the Result-flatten via the #32 path; crate/tokio gating (C4).
- **P3 — integration**: build P0 end-to-end on rust (`Task.run` each → asserts); the Cli + server +
  panic fixtures; guardian-final on the whole diff; real-crate confirmation (CI): re-run the
  `skyshop-rs`-no-shim firestore add, confirm a SIMPLE async op now binds (typed ops still need #45/#47).
- Sequencing: **#34 → #44** (shared error-normalization). #44 is the GATE; #45 (generic-Self) + #47
  (serde-bound) layer on top to reach the full firestore/stripe typed surface.

## The architectural decision — bind as a Sky `Task`, await natively (NOT block_on)

The shim pattern (`examples/rust/skyshop-rs/wrappers/*`) ran each async op to completion on a
**dedicated-thread current-thread tokio runtime** via `block_on`, presenting a SYNC `&str→Result`
surface. It did that because it had to hand auto-FFI a *synchronous* fn (auto-FFI couldn't model
async at all). **Auto-binding removes that constraint**, and two existing facts make a far cleaner
design available:

1. Sky's Rust `Task` IS an async future: a `SkyTask<E,T> = Box::pin(async move { … })` driven by
   tokio (the generated entry does `block_on(sky_main())`; Sky.Live/server run on tokio; the Task
   executor is the ambient tokio runtime).
2. The inspector ALREADY maps `Pin<Box<dyn Future<Output=T>>> → Task Error T` (`main.rs:~3468`).

So a foreign `async fn foo(a) -> T` binds as a Sky **`Task Error T'`**, and codegen emits:
```rust
pub fn rust_<crate>_foo(arg0: A) -> SkyTask<SkyError, T'> {
    Box::pin(async move {
        // await the foreign future on Sky's OWN tokio executor — no block_on, no extra thread
        let v = ::crate::foo(arg0).await;
        // coerce/flatten T into the Sky shape (see Result-flatten below)
        ok_coerce(v)
    })
}
```

**Why this beats the shim's block_on:**
- **No ambient-runtime panic.** `tokio block_on` *inside* an already-running runtime (every Sky.Live
  handler is on a tokio worker) PANICS ("cannot start a runtime from within a runtime"). The shim
  dodged this with a dedicated OS thread + `.join()`. Native `.await` inside a `Task` has NO such
  hazard — it runs on the executor that's already driving the Task.
- **No extra thread / runtime per call** (the shim spun a thread + a current-thread runtime per op).
- **Sound by construction** — an effect is modelled as the effect type (`Task`), matching Sky's
  effect boundary, and the future is polled by the one executor.

## Recognition (inspector, `tools/sky-ffi-inspect-rs`)

A fn is async-binding-eligible when its rustdoc signature is one of:
- `header.is_async == true` (the `async fn` sugar — rustdoc sets this flag; the desugared return is
  the `Output` type),
- return type is `impl Future<Output = T>` (an `impl_trait` whose bound is `Future` with an `Output=`
  assoc binding),
- return type is `Pin<Box<dyn Future<Output=T>>>` (already partially handled — unify the paths).

In all three, extract the **Output type `T`** and route it through the SAME return-type resolver
auto-FFI already uses. The async-ness is ORTHOGONAL to `T`'s bindability:
- `T` resolvable to a closed/Sky type → bind as `Task Error T'`.
- `T` non-bindable (generic, complex struct, serde-bound) → DROP with the existing reason (this is
  why #44 alone does NOT bind firestore's typed-doc ops — they also need #45 generic-Self / #47
  serde-bound; #44 is the GATE, not the whole story).

## Output-type shaping (the `T` cases)

| Foreign `Output = T` | Sky binding | Wrapper body tail |
|---|---|---|
| a Sky-coercible value `X` (String/i64/struct/…) | `Task Error X'` | `ok_res(coerce(v))` |
| `Result<X, E>` (firestore/stripe return these) | `Task Error X'` (FLATTEN) | `match v { Ok(x)=>ok_res(coerce(x)), Err(e)=>err_res(SkyError::from_foreign(e)) }` — reuse the #32 Result-error normalization (`E → SkyError`) |
| `()` | `Task Error ()` | `ok_res(())` |
| non-bindable `X` | DROP (existing reason) | — |

The `Result`-flatten is the common firestore/stripe shape and reuses the existing Result-return +
#32 error-slot machinery.

## Constraints / soundness gates (for the guardian)

- **C1 — `Send` future.** Sky's Task executor is (for server/Live) a multi-thread tokio runtime, which
  requires the awaited future be `Send`. A foreign `async fn` returning a non-`Send` future would be a
  cargo-fail (E0277 `… cannot be sent between threads`). GATE: bind only when the future is provably
  `Send` (the common case — most crate async fns are `Send`). A non-`Send` future → DROP
  `async-future-not-send`. (Rustdoc doesn't always state `Send`; conservative approach: assume `Send`
  for an ordinary `async fn` whose arg/output are `Send`, and let a rare non-Send case surface as the
  drop OR a contained cargo-fail — the guardian must rule on whether to gate strictly or admit-and-risk.
  Strict gate = sound over-drop; preferred.)
- **C2 — args by value, no borrowed `&self` escaping the await.** An async METHOD (`async fn(&self)`)
  borrows the receiver across the await — the wrapper owns the receiver for the call (compose with
  #45 method binding: take the receiver by value/clone, await, return). #44 alone targets async FREE
  fns + async methods once #45 lands. A borrowed arg that must outlive the await → DROP (or owned-clone
  bridge, like the closures #28 by-ref case).
- **C3 — entry must have a tokio runtime.** A pure Sky.Cli program's entry `block_on(sky_main())`
  establishes one; confirm the generated entry always provides a tokio runtime when ANY async-FFI Task
  is reachable (gate the runtime/`tokio` feature on async-FFI usage, like `usesTokio`). A `Task`-typed
  binding reachable ⇒ the entry already drives Tasks ⇒ runtime present. Confirm no non-tokio entry
  shape can reach an async-FFI Task.
- **C4 — feature gating.** The generated Cargo.toml must enable `tokio` (+ the crate) whenever an
  async-FFI binding is reached. Reuse the `usesTokio`/`usesBackendApp` gating; an async-FFI binding
  sets the tokio requirement.
- **C5 — no panic / total.** No `.unwrap()`/`block_on`/index in the wrapper; a foreign future that
  panics is caught at the Task boundary (Sky's `Cmd.perform`/Task runner already wraps in
  `SafeGo`/recover — confirm an FFI-await panic is caught and becomes `Err`, OR add a `catch_unwind`
  around the await via `FutureExt::catch_unwind` from `futures` — guardian to rule).
- **C6 — Go-byte-identity.** The whole path gates on an async signature the Go inspector never emits;
  a non-async fn is byte-identical.

## What #44 unblocks (and what it does NOT)

- **Unblocks:** any foreign `async fn` whose args + Output are otherwise Sky-bindable — e.g. a simple
  `async fn ping() -> String`, `async fn count() -> Result<i64, E>`. This is the GATE that makes async
  crates reachable at all.
- **Does NOT alone bind:** firestore/stripe ops whose Output is a generic/serde-bound/complex struct
  or whose receiver is a generic-Self builder — those ALSO need #45 (generic-Self) + #47 (serde-bound).
  #44 is necessary-not-sufficient for the full firestore/stripe surface; it is the keystone the other
  two build on.

## Proof bar (when implemented — not this pass)

1. Hand-stub fixture `NN-ffi-async`: a dep-free crate with `async fn ping() -> String`,
   `async fn add(a:i64,b:i64) -> i64`, `async fn try_div(a:i64,b:i64) -> Result<i64,String>` (Result
   flatten), and a NEGATIVE row (a non-`Send`/non-bindable-Output async fn that must DROP). kernel.json
   + Main.sky `Task.run`-ing each, asserting the results.
2. Inspector unit tests: `is_async` / `impl Future` / `Pin<Box<dyn Future>>` all recognized + Output
   extracted; non-Send → drop; non-bindable Output → drop.
3. Real-crate confirmation (CI): re-run the `skyshop-rs`-no-shim firestore add and confirm a simple
   async op now binds (the typed ones still need #45/#47).

## Non-goals (this epic)
Generic-Self async methods (#45 first), serde-bound async (#47), streaming/`Stream` returns, async
closures, cancellation. #44 is the synchronous-await-as-Task gate only.
