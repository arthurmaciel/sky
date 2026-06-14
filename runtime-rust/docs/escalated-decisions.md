# Escalated decisions — detailed pros/cons

Two parity gaps whose correct fix is upstream or large. Each option below states
**what the change actually entails**, with pros/cons, so the trade-off is explicit.

---

## 1. `Bytes` byte-exactness for non-ASCII text

**The gap.** `Sky.Core.Bytes` is `type alias Bytes = String` (shared stdlib). A
Rust `String` is valid-UTF-8-only; a Go `string` holds arbitrary bytes. The Rust
runtime round-trips arbitrary bytes through `String` with a **Latin-1** convention
(byte 0xFF ↔ char U+00FF). Consequence: `Bytes.fromString "café" |> toBase64`
diverges between backends — Latin-1 encodes `é` as one byte 0xE9, Go's UTF-8 as
two bytes 0xC3 0xA9. **ASCII is byte-identical on both;** only non-ASCII *text* fed
through Bytes encoding diverges.

### Option A — make `Bytes` a distinct nominal type upstream (RECOMMENDED long-term)
**Entails:** change `sky-stdlib/Sky/Core/Bytes.sky` `type alias Bytes = String` →
an opaque `type Bytes`. Both backends then render it as their native byte
container (**Go `[]byte`, Rust `Vec<u8>`**). Re-type every Bytes kernel
(`fromString`/`toString`/`fromHex`/`toHex`/`fromBase64`/`toBase64`/`append`/
`slice`/`length`/`empty`/`isEmpty`) on both backends. Every place that relied on
`Bytes ≡ String` interchangeability (stdlib + examples + user code) must insert
explicit `Bytes.fromString` / `toString` conversions.
- **Pros:** byte-exact parity for *all* inputs incl. non-ASCII text; deletes the
  Latin-1 hack; principled `Bytes ≠ Text` separation; correctness > efficiency.
- **Cons:** breaking, cross-backend API change (touches the Go reference too →
  needs upstream buy-in); large blast radius; user-code migration; `String`-typed
  multiline-string / interpolation that currently flows into Bytes slots breaks.

### Option B — keep the `String` alias; document the divergence (RECOMMENDED now)
**Entails:** nothing (status quo) + the documented limitation already in README.
- **Pros:** zero churn; the real-world byte ops (hex/base64 of hashes, tokens,
  random bytes, binary blobs) are ASCII-domain and already byte-identical; the
  divergence is confined to non-ASCII *text* round-tripped through Bytes encoding,
  which is rare (you usually encode bytes, not human text).
- **Cons:** a genuine correctness gap for that narrow non-ASCII-text case; a
  silent backend divergence.

**Suggested call:** B now (narrow gap, ASCII-correct), keep A as the principled
upstream fix to schedule if/when non-ASCII-text-through-Bytes becomes load-bearing.

---

## 2. `Task.retryWith` actually retries (Rust)

**The gap.** `SkyTask<E,A> = Pin<Box<dyn Future>>` is consumed on first `.await`,
so the runtime can't re-run it; `task_retry_with` is currently a no-op (runs once).
Go's Task is a re-runnable `func() any`, so Go's retry just re-calls it.

### Option A — make `SkyTask` re-runnable (large Rust runtime change)
**Entails:** change the Task representation from a one-shot future to a re-runnable
thunk — `Arc<dyn Fn() -> Pin<Box<dyn Future>> + Send + Sync>` (or a two-type split:
a `Task` thunk that produces a fresh `Future` on each `run`). Every kernel that
produces or consumes a `SkyTask` (the entire effect surface — `Task.*`, `Http.*`,
`Db.*`, `File.*`, `System.*`, `Crypto` entropy, `Cmd.perform`, the Live/Server
dispatch) changes signature/wrapping; `task_run` calls the thunk.
- **Pros:** `retryWith` works, and unlocks future `retry`/`repeat`/`timeout`
  combinators; representation-level parity with Go's re-runnable Task.
- **Cons:** huge blast radius (every Task site, hundreds); a per-Task `Arc` +
  closure indirection (perf); high regression risk across the whole effect
  surface. Multi-session epic.

### Option B — codegen peephole: inline retry loop re-evaluating the task expr
**Entails:** a peephole for `retryWith policy taskExpr` emitting an async loop that
re-evaluates `taskExpr` each attempt, with the policy fields + `ShouldRetry` match
inlined.
- **Pros:** localized; no runtime-wide change.
- **Cons:** **fragile** — re-evaluating a Rust expression that move-captures its
  args (`http_get(url)`) is a use-of-moved-value compile error without per-case
  `.clone()` the peephole can't infer; works only for trivially re-evaluatable
  task exprs; also depends on the generated `RetryPolicy`/`ShouldRetry`
  struct/enum names. Likely to break on real task shapes — not shippable as-is.

### Option C — upstream API: `retryWith : RetryPolicy e -> (() -> Task e a) -> Task e a`
**Entails:** change the shared stdlib `retryWith` to take a **thunk**. Both
backends re-run the thunk per attempt cleanly (Rust calls the `Fn`, Go calls the
`func`). User code migrates `retryWith p task` → `retryWith p (\_ -> task)`.
- **Pros:** clean and correct on **both** backends with no fragile re-eval; the
  thunk is the natural "re-runnable task" shape; small, principled.
- **Cons:** breaking stdlib API change (affects the Go reference + all user
  `retryWith` call sites); needs upstream buy-in + migration.

**Suggested call:** C (thunk API) is the cleanest correct fix — pursue upstream;
A is the heavy Rust-only alternative if the API can't change. B is fragile, not
recommended. Meanwhile the documented workaround stands: recurse on the `Result`
in Sky.
