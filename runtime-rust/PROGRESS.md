# PROGRESS — Rust backend work log

This file is the **history / archaeology sink** for the `feat/runtime-rust` work.
It is the OPPOSITE of `README.md`:

- **`README.md`** = a *pristine current-state snapshot*. No history, dates, phases,
  tiers, SHAs, or changelog language. It is written ONLY by the
  `sky-rust-backend:update-docs` skill (which reads this file + `git log` + the
  actual source to mirror current status). Never edit `README.md` directly.
- **`PROGRESS.md`** (this file) = every step, with a timestamp, what was done, why,
  and the files touched. History lives here, not in `README.md`.
- **`CLAUDE.md`** = directives + *generalizable* learnings / pitfalls (also no
  history/dates).

**Convention:** newest entry at the TOP. Each entry: `## YYYY-MM-DD HH:MM — title`,
then a short what/why and an **Affected** list (files / commit).

---

## 2026-06-17 15:00 — Task.retryWith: real retry loop (was run-once)

**Bug.** `task_retry_with` (runtime) was the identity function (dropped the
policy, ran the task once) and the codegen peephole DROPPED the policy arg. A
transient task that fails-then-succeeds wrongly returned the first `Err` — the
headline flaky-upstream-API use case was broken.

**Fix (codegen reshape + runtime rewrite — the SqlField/Money "destructure a
generated ADT in codegen" pattern).**
- **Runtime** `task.rs`: `task_retry_with` is now a real loop, faithful to
  `runtime-go/rt/task_retry.go`. New signature takes PRIMITIVE policy fields
  (`max_attempts`/`base_ms`/`jitter`/`kind`) + a `should_retry: Fn(&E)->bool` +
  a re-runnable `make_task: Fn()->SkyTask`. Loop: 1..=max_attempts, Ok→return,
  Err→(last attempt OR !should_retry)→return Err, else sleep
  `retry_compute_delay` (ported Go's computeDelay: linear/exponential ×2,
  30 s cap, jitter ∈[0.5,1.5) via the runtime's total `lcg_next` LCG, all
  saturating/total) and loop. Bounds are `Send`-only (SkyTask is Send, not
  Sync). 11 `#[cfg(test)]` unit tests (delay math + loop semantics).
- **Codegen** `ExprEmitter.hs` retryWith peephole: bind the policy to a temp,
  read its struct fields directly, lower its `shouldRetry` enum into a boxed
  `Arc<dyn Fn(&SkyError)->bool>` predicate (`RetryAlways`→`|_|true`,
  `RetryWhen f`→`move|e|f(e.clone())`), and wrap the task EXPRESSION in
  `move || <expr>` so each attempt rebuilds the future. `Kernel.hs`: added
  `("Sky.Core.Task","retryWith")` mapping + refreshed the stale "run-once"
  comments.

**Residual (scoped, documented).** A task passed as a bare LOCAL VARIABLE bound
to a built `SkyTask` value (`let work = … in retryWith p work`) is a one-shot
`Pin<Box<dyn Future>>` — not Clone/reproducible (issue #8). That shape forces
`max_attempts=1` (run-once, returns the real Ok/Err verbatim — no sentinel
observed) via a single-shot `Mutex<Option<SkyTask>>` `Fn`+`Send` shim. The
retry-enabled path is the INLINE EXPRESSION form (the headline use case). So a
bound-value task ignores the policy's attempt count; an inline-expression task
genuinely retries.

**Evidence.** New fixture `runtime-rust/tests/sky/61-retry-transient/` (file-
backed cross-attempt counter): pre-fix it returned Err on attempt 1 / ran the
task once (counter=1); post-fix the transient task succeeds on attempt 3, the
always-fail case runs exactly maxAttempts(4), the RetryWhen-False case stops at
1. Existing `25-retry` (bound-value) still green; spot-checks `14-task-demo`
(run) + `07-todo-cli` (build) green. Pre-existing unrelated clippy error at
`string.rs:145` (slicing-may-panic) noted, NOT touched.

**Affected.** `runtime-rust/src/sky_runtime/task.rs`,
`src/Sky/Generate/Rust/Builder/ExprEmitter.hs`,
`src/Sky/Generate/Rust/Builder/Kernel.hs`,
`runtime-rust/tests/sky/61-retry-transient/{sky.toml,src/Main.sky}`.

## 2026-06-17 14:30 — CI: per-OS BUILD·RUN·EQUIV table in the job summary

Added a `Job summary (sweep table)` step (`if: always()`) to the examples-sweep
job: it finds the newest `~/.cache/sky/examples-sweep/sweep-*.table`, prepends the
OS name + the `VERDICT:` line parsed from `run-*.log`, and appends it — fenced to
preserve the fixed-width alignment — to `$GITHUB_STEP_SUMMARY`. Because each matrix
job writes its own summary, the run page shows ONE table per OS (ubuntu/macos/
windows). This is the no-write-perms README mirror the user chose (option 2): the
sweep results are visible inline on every run with no commit and no `contents:
write`. README stays single-writer via `update-docs`. Verified the shell logic
locally against a real `.table` (renders heading + verdict + fenced table).

- **Affected:** `.github/workflows/examples-sweep.yml`.

---

## 2026-06-17 14:00 — CI: drop sccache (retired GHA cache API kills every build)

Second cross-OS run (`27700228755`, all 3 OSes) failed at the new "Pre-warm Rust
deps" step — but the real cause is the sweep-wide sccache wrapper, not pre-warm:

```
sccache: error: Server startup failed: cache storage failed to read:
  Unexpected (permanent) at read => Our services aren't available right now
  uri: …artifactcache.actions.githubusercontent.com/…/_apis/artifactcache/cache?…&version=sccache-v0.15.0
  response: status: 400 … service: ghac
```

sccache's `SCCACHE_GHA_ENABLED` backend uses GitHub's **v1 Actions-Cache API**,
which GitHub retired; sccache 0.15.0 still talks v1, so no action bump fixes it.
Because sccache was `RUSTC_WRAPPER`, it failed on the first `rustc -vV` — i.e. it
would have killed EVERY cargo build on all three OSes, not just pre-warm.

Fix: turn sccache OFF on CI, keep it the LOCAL dev fast path. Cross-run warmth on
CI comes from `actions/cache@v4` (v2 cache service, already caching
`CARGO_TARGET_DIR` + `~/.cargo/registry`).

- `lib/env.sh`: couple `CARGO_INCREMENTAL=0` to the sccache branch (it exists ONLY
  because sccache needs it) and add a `SKY_NO_SCCACHE` opt-out. When sccache is off,
  `CARGO_INCREMENTAL` is left at cargo's default so a persisted target dir does
  incremental rebuilds. Verified: local → `sccache` + `CARGO_INCREMENTAL=0`
  (unchanged); `SKY_NO_SCCACHE=1` → both unset.
- `examples-sweep.yml` (both jobs): drop `RUSTC_WRAPPER`/`SCCACHE_GHA_ENABLED`/
  `CARGO_INCREMENTAL` job env + the `mozilla-actions/sccache-action` step; set
  `SKY_NO_SCCACHE: '1'`; drop the `sccache --show-stats` line from pre-warm.

- **Affected:** `.github/workflows/examples-sweep.yml`, `runtime-rust/scripts/lib/env.sh`.

---

## 2026-06-17 13:00 — CI: fix the three env failures from the first cross-OS run

First `examples-sweep.yml` run (all 3 OSes) failed on CI-environment issues, NOT
Rust bugs — diagnosed per OS and fixed at the right layer:

- **macOS + Windows aborted at the `command -v go` / `curl` preflight.** Root cause:
  `lib/env.sh` *clobbered* `PATH` (no trailing `$PATH`), dropping GitHub's
  `setup-go` / `setup-node` and Windows Git-Bash tool dirs. Fix: append `:$PATH` so
  the runner-provided `go`/`node`/`curl` stay reachable. The trailing `$PATH` is now
  documented as LOAD-BEARING on CI.
- **Ubuntu reported 0 green · 42 red.** Two compounding causes: (1) `rg` is not
  preinstalled, so `is_out_of_scope` silently returned "in scope" for all → Go-FFI
  examples (02/03/05/08/11/13…) leaked into `build_set` and each fails `--target
  rust`; (2) a cold sccache made the first example cold-compile the whole Rust dep
  tree and blow past the 180 s ceiling → every build sky-failed. Fixes: a loud `rg`
  preflight in `examples-sweep.sh` (exit 2 if missing) + an "Install ripgrep" step
  per-OS in the workflow; `SKY_SWEEP_BUILD_TIMEOUT` / `_FFI` made configurable
  (raised to 900 / 2400 on CI) plus a "Pre-warm Rust deps" workflow step
  (`cargo build --features full` under the same shared `CARGO_TARGET_DIR` + sccache)
  so each example hits the cache instead of cold-building.

Active goal: make CI work fully and precisely (it will be the guide for future
development). Expect 1–2 more push→run cycles to flush hidden per-OS issues
(BSD `script`, Windows no-pty/no-chromium, macOS Playwright).

- **Affected:** `.github/workflows/examples-sweep.yml`, `runtime-rust/scripts/examples-sweep.sh`, `runtime-rust/scripts/lib/env.sh`.

---

## 2026-06-17 12:00 — README examples table: per-row build/run + 4 perf columns; CLI usage after Goal

Made the examples table complete + self-describing under Project status: per-row
**Build**/**Run** ✅ columns (checked each of the 37 sweep rows — all green, replacing
the blanket "all ✅") and four Rust/Go perf-ratio columns — **Thru ↑** (throughput) ·
**RSS ↓** · **Cold ↓** (cold-start) · **Bin ↓** (binary size) — from the perf TSV.
Moved `## CLI usage` to immediately after `## Goal`. Encoded this canonical table
format + section order into the `update-docs` skill so regenerations preserve it.

- **Affected:** `README.md`, `update-docs/SKILL.md`.

## 2026-06-17 11:45 — Source-of-truth policy: README only via update-docs; add PROGRESS.md

Established the policy that fixes the multiple-sources-of-truth drift: `README.md`
is refreshed ONLY through `sky-rust-backend:update-docs` (it reads this file +
`git log` + current source); advancing work logs here instead of editing the
README inline. Generalizable learnings/pitfalls still go to `CLAUDE.md`.

- **Affected:** new `runtime-rust/PROGRESS.md`; `CLAUDE.md` Settled rules (the
  policy) + root-`.md` allowlist now includes `PROGRESS.md`; `update-docs` SKILL.md
  (inputs = PROGRESS.md + git + source; README-only-via-this-skill enforcement).

## 2026-06-17 11:39 — README rewritten pristine; learnings → CLAUDE

Rewrote `README.md` as a current-state-only snapshot: full examples table
(build·run·equiv·round-trip·notes) under Project status, glossary moved to the end,
all history/dates/phases/tiers removed. Moved disk-hygiene + multibackend-entry
pitfalls + "run the full sweep" learning into `CLAUDE.md`.

- **Affected:** `README.md`, `CLAUDE.md`. Commit `eadcede7`.

## 2026-06-17 11:26 — T1 Go-codegen guard (00 builds on --target go)

Gated the literal-lambda / call-arg emission on `all isEmittableGoType paramTys` /
`not (containsGenericTypeParam subbed)` so a callee-bound type var (`T1` from a
`func(T1) bool` retry predicate) is erased to `any` instead of leaking an undefined
identifier into emitted Go. Fork-local fix over the v0.16.29 regression; supersede
when upstream `feat/v0.17-fully-typed-codegen` tags.

- **Affected:** `src/Sky/Build/Compile.hs`. Commit `390909c7` (+ README/memory
  attribution correction `a2022d07`).

## 2026-06-17 11:10 — Deferred-effect model (#8): 00 + simple equiv-stdout, 37/37

Effect kernels (`log/io/file/crypto/random/system/time/trace/config_decode`) now
defer their I/O into the returned Task body (constructing a Task is pure). Codegen
runs a discarded Task-typed `let _ = <task>` via `task_run` across both
`exprToRustInner` and `substVar`'s `goDef` (the inlined-binding path `simple`
reaches), while a non-Task discard stays bind/drop (so `Sky/Test`'s discarded
List-of-Tasks stays silent, matching Go). Entry `block_on`s `sky_main` iff its body
tail is a Task. Regression fixture `54-discard-task-effect`. Full sweep 37 green.

- **Affected:** `runtime-rust/src/sky_runtime/{log,io,file,crypto,random,system,time,trace,config_decode}.rs`;
  `src/Sky/Generate/Rust/Builder/{ExprEmitter,Emitter,ModuleEmitter,Types}.hs`;
  `runtime-rust/tests/sky/54-discard-task-effect`. Commit `1ba0b764`.

## 2026-06-17 04:07 — fn-ptr-comparison lint on fn-variant enums

Enums with a fn-pointer variant (`ShouldRetry`'s `RetryWhen`, `SkyTestTest`'s
`Leaf`) keep `derive(PartialEq)` (holder structs need it) but `#[allow]` the
`unpredictable_function_pointer_comparisons` lint (the fn variant is matched, never
`==`-compared).

- **Affected:** `src/Sky/Generate/Rust/Builder/Emitter.hs`. Commit `fac670bd`.

## 2026-06-17 03:57 — Cross-platform CI + OS-aware checks.sh

New fork-local `.github/workflows/examples-sweep.yml` runs the sweep on
ubuntu/macos/windows (honest per-host scope; gates pushes on Go≡Rust parity).
`checks.sh` made OS-aware (`SKY_HOST_OS`, `EXERCISE_SKIP_RC`, guarded `reap`, BSD
`script`/xvfb branches). Existing `ci.yml` diagnosed not-broken (only a GHC version
staleness; fix proposed, not applied).

- **Affected:** `.github/workflows/examples-sweep.yml`,
  `runtime-rust/scripts/lib/checks.sh`, `runtime-rust/scripts/examples-sweep.sh`,
  skill docs. Commit `fbc19e83`.

## 2026-06-16 21:33 — Unified examples-sweep (build·run·equiv) + server body-equiv

Folded build-sweep + run-sweep + equiv-sweep into one `examples-sweep` (per-example
BUILD·RUN·EQUIV table, single SSOT `lib/checks.sh`). Server body-equiv byte-compares
each comparable GET route on both backends (sequential boot, port-sniff, dev-banner
off, skip Go-404, auth secret, ETXTBSY retry). Night gate + perf rename.

- **Affected:** `runtime-rust/scripts/{examples-sweep.sh,examples-perf-sweep.sh,lib/*,equiv-classification.tsv}`;
  Std.Log Go-format parity (`782397c2`) + E-pinning log wrappers (`3a9037ad`).
  Commits `22290857`, `6e8ef029`, `edd194dd`, `156bee99`, `57128081`, `100bae3a`.

## 2026-06-16 00:15 — Stdlib kernel parity: 44 kernels + Set + DbDec/Db

Implemented 44 Go-parity stdlib kernels (String/Path/Dict/File/Time/Random/Json),
the `Set` subsystem (BTreeSet-backed), and the `Std.Db.Decode` (DbDec) +
generated-ADT Db cluster (insertFields/updateFields/insertFieldsReturning,
DbDec.money via a shared `{run, fields}` Decoder). skydex parity tooling hardened.

- **Affected:** `runtime-rust/src/sky_runtime/*` (many), `src/Sky/Generate/Rust/Builder/*`,
  `tools/skydex/*`. Commits `083e0501`, `81f0166b`, `76989991`, `9e3c7dd9`,
  `b2fe42be`, `d669b11d` and siblings.

---

_Earlier history predating this log lives in `git log feat/runtime-rust`._
