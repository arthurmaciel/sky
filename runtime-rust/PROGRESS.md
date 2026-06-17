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
