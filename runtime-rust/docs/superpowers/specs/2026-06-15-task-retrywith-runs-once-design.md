# Task.retryWith runs once — design / disposition

**Divergence:** `Task.retryWith policy task` runs the task exactly once on
`--target rust` (Go re-runs it up to `policy.maxAttempts`).

**Disposition: DOCUMENT_INTENTIONAL.** Run-once is the principled floor: it is
observably correct for every verifiable case, and the only faithful fix needs a
FORBIDDEN shared-stdlib signature change. No `Any`/panic is introduced.

## Problem

| Backend | Task representation | retryWith loop |
|---|---|---|
| Go (`runtime-go/rt/task_retry.go`) | `SkyTask[any,any]` **IS** `func() any` — a re-runnable thunk | `Task_retryWith(policy, task)` loops `anyTaskInvoke(task)` up to `maxAttempts`, sleeping the policy backoff, consulting `shouldRetry` per Err |
| Rust (`runtime-rust/.../task.rs:136`) | `SkyTask<E,A> = Pin<Box<dyn Future + Send>>` — a **one-shot** value, consumed when awaited, not `Clone`, not re-runnable | `task_retry_with(task) -> task` — returns the future unchanged; awaited once |

Re-runnability in Go is a property of the **universal Task representation**
(every Sky Task lowers to a `func()any`), not of retry codegen. Rust's
`SkyTask` is a one-shot `Future`, so there is no thunk to re-invoke.

Codegen (`ExprEmitter.hs:1924`) drops the policy arg:
`emitDefaultCall ctx _fn "task_retry_with" [_policy, task]` → `task_retry_with(<task>)`.

## Answered questions

### Q1 — Can codegen re-emit the task as a `move ||` `Fn` thunk, soundly for all arg shapes?

**No.** The only shipped retry example is the canonical Sky shape:

```elm
let work = Task.succeed 42 in Task.retryWith policy work
```

At the call site, `exprToRustString ctx task` emits the **identifier `work`**
(a one-shot `SkyTask` value), not `task_succeed(42)`. `move || work` captures
the one-shot future by move → the closure is `FnOnce`, not the `Fn` a retry
loop needs. It either fails to compile as `Fn` or silently degrades to
**run-once under a different guise** — exactly the divergence. To make it
re-runnable, codegen would have to re-emit the *binding's RHS* across the
let boundary; the Rust emitter does not inline let-bound RHS, and doing so
breaks for any task built from effectful sub-expressions carrying their own
`let` scope. Literal-`Task.succeed` is the rare case that *would* survive;
variable-bound and composed tasks (the common shapes) do not. So re-emit is
not sound across the arg shapes Sky permits at that position.

### Q3 — Is a re-runnable task constructible given one-shot `SkyTask` + by-value (`FnOnce`) combinators?

A re-runnable thunk type **is** constructible — `core.rs:42`
(`disconnected_fn0 -> Arc<dyn Fn() -> SkyTask<E,T> + Send + Sync>`) already
proves the shape exists in this runtime. But threading it through requires a
`Fn() -> SkyTask<E,A>` thunk *at the retryWith arg position*. The only way to
get that thunk is for the **producer of the task** (the Sky source) to hand a
thunk — i.e. `retryWith : RetryPolicy e -> (() -> Task e a) -> Task e a`. That
is a shared-stdlib (`sky-stdlib/Sky/Core/Task.sky`) signature change →
FORBIDDEN. Forcing every combinator (`task_and_then` etc.) to become
re-runnable (`Clone`/`Fn` bounds) to synthesise the thunk would ripple
`Clone`/`Fn` across the whole one-shot-`Future` task runtime — not in scope and
not sound for futures that capture non-`Clone` resources.

### Q2 — How does the policy reach the runtime without the E0283 phantom-`e` blocker?

Moot for the disposition (we are not implementing), but for the record: option
(a) — reading the record's primitive fields (`maxAttempts`/`baseMs`/`kind`/
`jitter`) at the call site and passing a monomorphised `ShouldRetry<E>`
predicate — is the reflection-free path (the runtime crate never reflects;
Go's `readRetryPolicy`/`readShouldRetry` reflection is FORBIDDEN here). Option
(b) (generic over the project's `SkyCoreTaskRetryPolicy<E>`) keeps the opaque
struct but still needs a re-runnable task to *use* the policy — so it does not
unblock anything on its own. Neither matters while Q1/Q3 block re-running.

### Q4 — Does parity need re-running, or only the observable result?

Only the observable result. Re-running changes the outcome **only** when the
body is non-deterministic across calls — which, since Sky tasks are the only
effect carrier, requires reading mutable external state (time/network/file)
that differs between attempts. Run-once already yields the correct observable
result for every deterministic case:

| Case | Go (re-run) | Rust (run-once) | Same observable? |
|---|---|---|---|
| Always-Ok | Ok on attempt 1 | Ok on attempt 1 | ✅ |
| Always-Err | last Err after N | the same Err once | ✅ (identical Err value) |
| `RetryWhen` short-circuit on first Err | Err immediately | Err immediately | ✅ |
| Transient: fail then succeed | Ok after retry | Err (no retry) | ❌ — **only** divergent case |

The divergent case is **unreachable for shipped examples**: no well-typed
*pure* Sky program can build a fail-then-succeed task, and the Rust backend's
current effect surface exercises no transient external dependency in any
example. The divergence is real but, for everything we ship, **purely
theoretical**.

### Q5 — Soundness of re-awaiting (backoff/jitter/cap/executor)?

If a faithful loop were built, the panic-free Rust equivalents exist
(`tokio::time::sleep`, `fastrand`/non-crypto RNG for jitter, a saturating
30 s cap, all total — no `.unwrap()`). Sleeping inside `block_on`/`task_run`'s
executor is fine (`task.rs:5` already drives a tokio runtime on a spawned
thread). These are not the blocker — Q1/Q3 (no re-runnable arg without a
shared-stdlib shape change) are.

### Q6 — If a faithful loop can't be built/verified, what is the correct disposition + the proof test?

DOCUMENT_INTENTIONAL with a regression test pinning run-once's **correct
subset** (Ok-first-try, last-Err, predicate short-circuit) — these are at
parity with Go and must not regress. The in-Sky recursion workaround (recurse
on the `Result`) is already in `README.md`. The test that would *prove* a
future re-runnable implementation matches Go is a **fail-N-then-succeed counter
task** — which requires mutable state Sky cannot express purely, confirming the
divergence is unverifiable here and must not be "fixed" with something we can't
test (no-unverified-ship rule).

### Q7 — Does passing the policy through remove the E0283 turbofish hacks?

**No — independent.** The phantom-`e` turbofish pins
(`Types.hs:258` `linearBackoff`/`exponentialBackoff`/`defaultRetryPolicy`/
`retryAlways` → `::<SkyError>`) exist because a `RetryPolicy e` *built but never
tied to a concrete error* has an unconstrained `e` **at construction** — true
whether or not `task_retry_with` consumes the policy. Dropping the policy at the
call site avoids only one *additional* unconstrained site; it is not the root of
the turbofish scaffolding. So fixing the divergence would NOT simplify the
type-renderer, and the pins stay regardless.

## Disposition + rationale

**DOCUMENT_INTENTIONAL.** Priority-ordered:

1. **Correctness / soundness** — run-once is observably correct for every
   deterministic case (the only verifiable cases). The one divergent case
   (transient fail→succeed) is unreachable for shipped examples and
   unverifiable in pure Sky.
2. **No principle may be broken to fix it** — the faithful fix needs a
   thunk-shaped `retryWith` in the **shared stdlib** (FORBIDDEN), or a
   call-site re-emit that is unsound for the common let-bound / composed task
   shapes (Q1), or whole-runtime `Clone`/`Fn` ripple (Q3, out of scope + unsound
   for resource-capturing futures).
3. **No-unverified-ship** — we cannot prove a re-runnable loop matches Go
   without a fail-N-then-succeed task, which Sky can't express purely. Shipping
   an unverifiable re-run would violate the rule.
4. **Behavioral Go-parity is the *lowest* priority** and is the only thing
   run-once sacrifices — and only in the theoretical case.

This is a deliberate principled choice, not a blocked-on-infra gap and not a
non-Rust-specific divergence: the root is the one-shot `Future` Task
representation Rust uses *by design* (it is what makes "if it compiles, it
works" total — no re-runnable `dyn Any` thunk). Hence INTENTIONAL over BLOCKED.

## Principle check

- No shared-stdlib / Sky-source / Go / upstream-examples edit. (The faithful
  fix would need one — that is precisely why it is not implemented.)
- No `Box<dyn Any>`, no `.unwrap()`/`.expect()`/`panic!`/unchecked index/
  downcast added — `task_retry_with` is `task -> task`, total.
- Root-cause honest: the divergence is the one-shot-`Future` Task model, named
  as such; run-once is the correct, verifiable floor, not symptom-masking.
- Verifiable: the kept-parity subset (Ok-first / last-Err / predicate
  short-circuit) is regression-testable; the divergent case is not, and we do
  not ship an unverifiable "fix".

## Verification plan (for the DOCUMENT executors)

- `25-retry` already builds + runs on `--target rust` and asserts run-once
  yields `Ok 42` — keep it green (it pins the Ok-first-try parity case).
- Optionally add `runtime-rust/tests/` coverage asserting the last-Err and
  `RetryWhen` short-circuit subsets stay at parity (a task that always fails →
  the same Err; a `RetryWhen (\_ -> False)` → first Err, no extra attempts).
- README divergence row reworded from "design decision / [ ]" to clarified-
  intentional with the one-shot-`Future` root + the Q4 observable-parity table
  pointer.
