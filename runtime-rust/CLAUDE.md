# SkyRust Project Context

This file holds **directives for agents**, **learnt command optimizations**, and
**principles** working on the Sky Rust backend. It is NOT a status log — what
works / what's pending lives in git history + `skydex parity --gaps`, not here.

## Principles
The six principles and their strict priority order live at the top of
**`runtime-rust/README.md`** — that file is authoritative; this one defers to it.
In order: **security > correctness > soundness > efficiency > completeness >
readability** (a lower one never overrides a higher one). Everything below serves
them.

## Settled rules — said once, applied always

When the user settles a rule, it is recorded HERE and applied to all future work
without re-asking — it only changes when the user asks to change it. Adding the
rule here is mandatory, not optional. Current settled rules:

- **Boundary.** Edit only `runtime-rust/`, `src/Sky/Generate/Rust/`,
  `src/Sky/Build/Rust/`, `tools/`. NEVER the shared stdlib (`sky-stdlib/`), the Go
  backend (`runtime-go/`, `src/Sky/Generate/Go/`), or the author's `examples/`
  (except `examples/rust/`).
- **Rust tooling lives under `runtime-rust/scripts/`** — no Rust script at
  repo-root `scripts/`. Runners `source` the single-source `lib/env.sh`
  (command/env header — new speed opts go here) + `lib/examples.sh` (the build/
  run/web/perf example manifest — new test examples go here). Never duplicate
  either across runners.
- **Verify through the `sky-rust-backend:*` skills**, never the raw runner scripts.
- **`examples/rust/` holds only real, complete Sky projects** (currently just
  `skyshop-rs`). Sky projects that exist ONLY as Rust-backend tests/fixtures live
  under **`runtime-rust/tests/sky/`**, never in `examples/`.
- **`rg`, never `grep`** — even on piped stdin (`… | rg`).
- **`README.md` is written ONLY by `sky-rust-backend:update-docs`, and ONLY from
  the `## CLI usage` heading DOWNWARD.** Everything ABOVE `## CLI usage` (title,
  intro, `## Contract`, …) is the maintainer's hand-written content — NEVER touch
  it (no reword, reformat, or reflow of any line above `## CLI usage`), not via
  update-docs and not via any other edit. From `## CLI usage` to the end it is a
  *pristine current-state snapshot* with NO history, dates, phases, tiers, SHAs,
  or changelog language. This is the cure for multiple-sources-of-truth drift:
  progress is logged elsewhere, the regenerated region is *regenerated* from
  current truth.
  - **Log every step to `PROGRESS.md`** (the history / archaeology sink): an entry
    `## YYYY-MM-DD HH:MM — title` + what/why + the **Affected** files (newest at
    top). This is the ONLY place history/dates/SHAs belong.
  - **Generalizable learnings & pitfalls** → the `## Agent learnings` section of
    THIS file (also no history/dates).
  - `update-docs` mirrors current status into `README.md` from `PROGRESS.md` +
    `git log` + the actual source (typically a background session when called).
  - Allowed `runtime-rust/` root `.md` files: **`CLAUDE.md`, `README.md`,
    `PROGRESS.md`** — nothing else.

## Goal
Transpile Sky (Elm-compatible functional language) to Rust with native FFI to Rust libraries.

## Architecture: Hybrid

```
Sky Source → [Haskell] Parse + Type-Check → AST → [Rust] Codegen → Rust Code
                                                    (new)              ↓
                                                          Rust libs (direct calls)
```

- Reuse existing Haskell parser, canonicaliser, type checker (~13,000 lines)
- Add new Rust codegen module to Sky compiler
- Runtime crate (`sky-runtime-rust`) provides Sky primitives in Rust

## Build rules — read before any build

Non-negotiable for dev-loop work on `feat/runtime-rust` (release/CI use the
default `-O1` + a real `cabal install`). Violating these wastes minutes per
iteration and has burned past sessions.

| Rule | Why |
|---|---|
| **NEVER `cabal install --install-method=copy`.** `sky-out/sky` is a **symlink** to the dist-newstyle binary; `cabal build exe:sky` updates it in place. Set up once: `ln -sf "$(cabal list-bin exe:sky)" sky-out/sky`. | a copy-install pays a 39 MB write per rebuild for zero benefit |
| **Only codegen (`.hs`) edits need `cabal build`.** Edits under `runtime-rust/src/` are copied into the generated project at `sky build` time — rebuild only the example. | no compiler rebuild for runtime-only changes |
| **Self-contained PATH in every build shell:** `export PATH="$HOME/.cargo/bin:/usr/local/go/bin:/usr/local/bin:/usr/bin:/bin:$HOME/.ghcup/bin"` | the inherited `$PATH` is inconsistent across tool calls — `cargo`/`timeout` vanish, so `sky` fails to spawn `cargo` (looks like a build failure). Inline `for`-loops compound the drift — one example per command, or a committed script |
| **Export shared target + sccache + `CARGO_INCREMENTAL=0` before any example build:** `export CARGO_TARGET_DIR="$HOME/.cache/sky-rust-target" RUSTC_WRAPPER=sccache CARGO_INCREMENTAL=0` | `CARGO_INCREMENTAL=0` is mandatory — sccache silently skips ALL Rust compilation when incremental=true (all 90 requests landed in "non-cacheable: incremental"). With `CARGO_INCREMENTAL=0`: 178/226 cache hits, cold build drops from ~75 s to ~15 s. The shared target compiles axum/tokio/serde/sqlx once; holds only the LAST-built binary. Re-export every shell. |
| **Don't wipe `dist-newstyle/`**; keep the gitignored `cabal.project.local` (`optimization: 0`, `profiling: False`). | incremental compile is the whole point — `-O0` cuts a full rebuild from minutes to ~180s, a one-module link to ~32s. Never commit the file (it would slow the shipped binary) |
| **Don't wipe `sky-out .skycache .skydeps` for runtime-only changes.** `sky build` always copies `runtime-rust/src/sky_runtime/` before invoking cargo — incremental is handled automatically. A wipe is only needed when the Sky source changes in a way that confuses the cache (rare) or when debugging cache issues. | verified: touching or editing any `.rs` under `runtime-rust/src/` is picked up correctly by the next `sky build` without a wipe |

### Sweep tooling: single source of truth (no duplication, no drift)

Run verification through the **`sky-rust-backend:*` skills** (examples-sweep /
examples-perf-sweep / keep-go-parity), NEVER the raw runner scripts — the skills
are the agent-facing interface. The runners live ONLY under
`runtime-rust/scripts/` (no Rust script at repo-root `scripts/`).

**Sweep taxonomy (consolidated).** ONE sweep does build + run + equivalence:
- **examples-sweep** (`examples-sweep.sh`) — the cornerstone correctness gate.
  Per in-scope example it BUILDS (`--backend rust` + cargo), RUNS it headless per
  shape, AND asserts Go≡Rust EQUIVALENCE, emitting a per-example **BUILD·RUN·EQUIV**
  table. Folds the former build-sweep + run-sweep + equiv-sweep + web-sweep into
  one. GREEN row = BUILD ok AND RUN ok AND EQUIV ∈ {equiv-*, n/a, amber
  go-ref-broken}; RED = any *-fail / panic / hang / noserve / notty / DIFFER.
- **examples-perf-sweep** (`examples-perf-sweep.sh`, helper `rust-perf.sh`) —
  Rust-vs-Go cold-start / RSS / binsize / throughput + regression report.

**Night policy.** BOTH sweeps are gated to **22:00–08:00 America/Sao_Paulo** (slim
shared box) via `night_guard` in `lib/checks.sh`. Outside the window they print
`deferred: <sweep> runs 22:00–08:00 …` and exit 2; **`SKY_SWEEP_FORCE=1`**
overrides (and also downgrades the macOS-only mem-guard preflight to a WARN, for a
host where mem-guard can't run). `keep-go-parity.sh run` forces past the gate.

**Derived equiv mode.** The equiv mode is DERIVED from `example_shape` by
`equiv_mode` in `lib/examples.sh` (cli→stdout, server→body, live→scenario,
tui→pty, webview/fyne/Go-FFI→none), so an author-added example AUTO-CLASSIFIES
with no manual step. `equiv-classification.tsv` is **OVERRIDES-ONLY** (a small
file of exceptions + reasons), NOT a full classification — there is no
forced-coverage gate. A stdout-mode determinism auto-probe (run Go twice; unstable
stdout → `n/a`) and a per-route body-determinism probe stop false DIFFERs.

**Swarm-fix after sweep.** Any RED example (Rust-side build/run/equiv failure —
NOT amber `go-ref-broken`, which is an upstream Go bug) is root-caused + fixed
in-boundary via **sky-rust-backend:autonomous-swarm**, adhering to the README
principles, AFTER the full sweep (a complete RED list lets the swarm batch related
fixes). Each fix passes the pre-final code gate + adds a pre-fix-failing
regression fixture.

Three shared files under `runtime-rust/scripts/lib/` are the SINGLE SOURCE OF TRUTH
every runner sources — duplicating any across runners is forbidden:
- **`env.sh`** — the command env header: `PATH`, `CARGO_TARGET_DIR`, `RUSTC_WRAPPER=sccache`,
  `CARGO_INCREMENTAL=0` (mandatory — see above), `SKY_BIN`. **Any verified speed
  improvement is added HERE so every skill inherits it automatically.**
- **`examples.sh`** — the in-scope example manifest: `build_set`/`run_set`/
  `perf_set` (all DERIVED from disk), `is_web_example`, `example_shape`, and
  `equiv_mode` (DERIVED + tsv overrides). When sync-with-upstream lands new
  examples — or we add fixtures as Go-parity tests — update ONLY this file.
- **`checks.sh`** — the per-shape "exercise an already-built binary" functions
  (`exercise_cli` / `exercise_server` / `exercise_live` / `exercise_tui` /
  `exercise_webview` / `exercise_server_equiv`) + the shared helpers
  (`http_responds`, `free_port`, `scenario_for`, `reap`, `night_guard`,
  `$PANIC_RE`, the browser-stack probe). examples-sweep's RUN exercises the RUST
  binary; its EQUIV exercises BOTH backends' binaries to compare. "Did the binary
  work?" has ONE definition both consume.

Directive: a new speed optimization → `env.sh`; a new/changed test example →
`examples.sh`; a new/changed binary-exercise → `checks.sh`. Never edit a
per-runner copy.

### Fast inner loop (Sky source or runtime `.rs` changed, no `.hs` edit)

```bash
# One-time env (re-export every shell — state doesn't persist between tool calls)
export PATH="$HOME/.cargo/bin:/usr/local/go/bin:/usr/local/bin:/usr/bin:/bin:$HOME/.ghcup/bin"
export CARGO_TARGET_DIR="$HOME/.cache/sky-rust-target" RUSTC_WRAPPER=sccache CARGO_INCREMENTAL=0
SKY_BIN="$HOME/Documentos/comp/sky/sky-out/sky"

# Canonical inner loop — build + run in one step
cd examples/01-hello-world        # or whichever example
"$SKY_BIN" run --backend rust src/Main.sky
# Warm (source unchanged): ~0.3 s  |  First change: ~1-2 s (cargo incremental)
# sky run honours CARGO_TARGET_DIR for the binary path (commit 0bd3a84e)

# Runtime-only change (no Sky source touch needed, no wipe needed):
# 1. Edit runtime-rust/src/sky_runtime/foo.rs
# 2. "$SKY_BIN" run --backend rust src/Main.sky   ← re-copies runtime and runs cargo
```

### Standalone runtime compile-check (fastest correctness gate for `.rs` edits)

```bash
# Validate runtime-rust/src/ edits WITHOUT a full sky build.
# cargo check:  ~1.2 s warm  (no codegen, no link)
# cargo build:  ~2.4 s warm  (codegen + link, produces a usable .rlib)
cd /path/to/sky-repo
cargo check --manifest-path runtime-rust/Cargo.toml --features full   # fastest
cargo build --manifest-path runtime-rust/Cargo.toml --features full   # if you need link errors too
# Use `check` for "does this compile?" iterations; switch to `build` before sky-level testing.
```

Generated `Cargo.toml [profile.dev]` already drops debuginfo (`debug = 0`,
`incremental = true`), emitted by `emitCargoToml`. The `incremental = true` in
the generated project is fine for Cargo's own incremental tracker; the
`CARGO_INCREMENTAL=0` env var overrides it at the process level so sccache
can cache. Sweep via
`SKY_BIN=$(cabal list-bin exe:sky) ./runtime-rust/scripts/rust-sweep.sh` (~570s on warm sccache).

### `sky check` does NOT support `--backend rust`

`sky check` always runs the Go pipeline (`go build -o /dev/null`). It is
useful for HM type-check and Go codegen validation but it does NOT validate
the Rust codegen path. For Rust type-check validation, use `sky build --backend rust`
or the standalone `cargo check` above.

## Code navigation — use skydex

Use **`skydex`**, the bounded Sky-tuned code index (`tools/skydex/`, ~64 MB peak;
`tools/skydex/README.md`), or plain Read / `rg` for code navigation on this repo.
Any machine-wide MCP indexer mandated by the global `~/.claude/CLAUDE.md` does NOT
apply here — skydex is the indexer for this repo.

**For free-text search use `rg` (ripgrep), NEVER `grep`/`Grep` — even on piped stdin (`… | rg`).** skydex answers
SYMBOL/relationship queries (parity, deps, callers, `locate`); `rg` answers
free-text code-idiom searches inside file bodies that a symbol index can't
(`rg -F '-> SkyTask<()>'`, `rg 'pub mod'`). `rg` is installed, reads stdin,
and is 320× faster than `grep -r` on this repo: `grep -r` wades through 20+ GB
of `dist-newstyle/` (105 s); `rg` respects `.gitignore` and finishes in 0.33 s.
There is no workflow in this repo where `grep` wins.
Most useful flags:

| Flag | Use |
|---|---|
| `-n` | line numbers (clickable `file:line`) |
| `-F` | fixed/literal string — for idioms with regex metachars (`-> SkyTask<()>`, `::<_, ()>`) |
| `-w` | whole-word match (`rg -w set_empty`) |
| `-i` / `-S` | case-insensitive / smart-case |
| `-t hs` `-t rust` `-t go` | restrict to a language (`-t hs 'ecPipeInnerType'`) |
| `-g '<glob>'` | restrict by path glob (`-g 'src/Sky/Generate/Rust/**'`) |
| `-A N` `-B N` `-C N` | trailing / leading / surrounding context lines |
| `-l` / `-c` | files-with-matches only / count per file |
| `-o` | print only the matched text (extract names) |
| `--no-ignore` | include gitignored files (rarely needed; defeats the bounded default) |

Build once, then query (binary: `tools/skydex/target/release/skydex`; user alias
`sx`; run from the repo root):

```bash
( cd tools/skydex && cargo build --release )         # once
tools/skydex/target/release/skydex index --repo .    # build .skydex/index.db (~21s)
tools/skydex/target/release/skydex parity --gaps     # ← the keep-go-parity worklist (go-only = Rust missing it)
tools/skydex/target/release/skydex deps <module>     # module imports
tools/skydex/target/release/skydex covers <kernel>   # fixtures/examples exercising a kernel (find its tests)
tools/skydex/target/release/skydex roles | pipeline | wakeup
tools/skydex/target/release/skydex update --repo .   # incremental git-diff refresh (after commits / on sync)
```

**Default reflex:** before a multi-file `rg` to answer "is the Rust backend
missing a kernel Go has?" / "what does this module depend on?" / "what tests
cover this?", run the matching `skydex` query — one focused answer instead of
pulling many files into context.

**Keep skydex current — ALL written code refreshes the index.** Two layers:
- **Automatic (general):** a tracked `post-commit` hook (`.githooks/post-commit`)
  runs `skydex update` (incremental, backgrounded, defensive) after EVERY commit.
  Enable once per clone: `git config core.hooksPath .githooks`. No-ops cleanly if
  skydex isn't built / not yet indexed; never blocks a commit.
- **Explicit:** `sync-with-upstream` Step 9 + any skill that lands code should end
  with `skydex update --repo .`. After a large change or when in doubt, a full
  `skydex index --repo .` rebuilds from scratch (the walk includes
  untracked-non-ignored files, so it reflects the true working tree).
The index is the source of truth for parity/deps/coverage queries — a stale index
gives wrong answers, so refreshing after writing code is not optional.

## Codegen entry points (orientation)

- **Entry**: `generateRust` in `src/Sky/Build/Compile.hs`; the Rust codegen lives
  under `src/Sky/Generate/Rust/Builder/` (Kernel.hs routing, ExprEmitter, Types,
  TypeRenderer, Emitter, ModuleEmitter, Project).
- **Output**: `sky-out/Rust/`. **Default target** is Go; Rust via `--backend rust`.
- **Runtime**: `runtime-rust/src/sky_runtime/` is copied into the generated
  project at `sky build` time (external deps tokio/sqlx/axum/serde pulled per used
  feature). Current state of parity / what builds: ask `skydex parity --gaps` and
  run the `sky-rust-backend:build-sweep` skill — never tracked as a list here.

## Constraints

- **NO RUNTIME ERRORS — existential.** This is the reason the Rust backend
  exists. A well-typed Sky program MUST NOT be able to trigger a panic, an
  `unwrap`/`expect` failure, an unchecked downcast, an out-of-bounds index, or
  any other runtime abort in the generated Rust or the Rust runtime. "If it
  compiles, it works" is not aspirational here — it is the product. Where Go's
  backend leans on reflect + recover (a panic that gets caught and turned into
  a 500), the Rust backend MUST instead be **statically total**: errors that
  Sky's own type system models are `Result`/`Task` values; everything else is
  designed out, not caught.
  - **Mirroring Go's reflect/`any` risk surface is a defect, not parity.** When
    a Sky feature is dynamically typed at the *language* level (pub/sub
    payloads, FFI `any`, JSON `Value`), do not erase-and-downcast-and-hope. Use
    the concrete types the Sky type-checker already knows at each call site to
    **monomorphise the dynamism away** (e.g. per-type brokers keyed by
    `TypeId`, so the payload travels as its real type `T` and is never
    downcast). Any residual `dyn Any` must be provably-correct by construction
    (keyed so the one cast can never fail), never payload-dependent.
  - A genuine type mismatch that Sky's type system cannot catch (e.g. a
    publisher and subscriber that disagree on a topic's payload type) MUST
    degrade gracefully — drop + structured warn — NEVER panic.
  - `.unwrap()` / `.expect()` / `panic!` / `[i]` indexing / unchecked
    `downcast` in generated code or the runtime's Sky-reachable paths are
    treated as bugs to fix at the root, exactly like the main project's
    no-deferral rule. An internal invariant that "can't fail" still uses a
    total form (`if let` / `match` / `get`) with a structured-error fallback.
- Rust-native FFI (direct Rust lib calls) — mandatory from day 1 - MUST BE FULLY automatic, secure and sound
- All Rust targets: desktop, WASM, CLI, embedded

## Relevant Context from Sky Compiler

- Parser: `/home/arthur/Documentos/comp/sky/src/Sky/Parse/*.hs`
- Type Checker: `/home/arthur/Documentos/comp/sky/src/Sky/Type/**/*.hs`
- Canonicaliser: `/home/arthur/Documentos/comp/sky/src/Sky/Canonicalise/*.hs`
- Go Codegen: `/home/arthur/Documentos/comp/sky/src/Sky/Generate/Go/*.hs` — reference for Rust codegen structure

## Agent skills

### Rust-backend skill suite — the `sky-rust-backend` plugin

The Rust-backend verification + maintenance skills ship **in this repo** as a
plugin at `runtime-rust/plugins/sky-rust-backend/`, so they version with the
project and install on any agent that supports the plugin/skill format:

```bash
claude plugin marketplace add <sky-repo>/runtime-rust/plugins
claude plugin install sky-rust-backend@sky-rust-backend
# (local dev auto-loads it: ~/.claude/skills/sky-rust-backend symlinks here →
#  sky-rust-backend@skills-dir)
```

Skills are namespaced `sky-rust-backend:<name>`. Each wraps a **standalone
runner** under `runtime-rust/scripts/` — a user *without* an AI agent runs the
script directly; the skill is just the agent-facing wrapper + procedure.

| Skill | Runner (`runtime-rust/scripts/`) | Does |
|---|---|---|
| `sky-rust-backend:examples-sweep` | `examples-sweep.sh` + `lib/checks.sh` + `web-verify.mjs` | The cornerstone gate. ONE sweep: per in-scope example BUILD (`--backend rust` + cargo) · RUN headless per shape (cli no-panic / server+live boot+serve / live browser ROUND-TRIP / tui pty / webview xvfb) · EQUIV Go≡Rust per DERIVED mode (stdout-diff cli / body-diff server / both-pass-scenario live / both-no-crash tui). Emits a BUILD·RUN·EQUIV table. Folds the old build/run/equiv/web sweeps. Night-gated. |
| `sky-rust-backend:examples-perf-sweep` | `examples-perf-sweep.sh` (helper `rust-perf.sh`) | Rust-vs-Go cold-start/RSS/binsize/throughput + regression report. Night-gated. |
| `sky-rust-backend:keep-go-parity` | `keep-go-parity.sh` | orchestrate sync → examples-sweep (always) → examples-perf-sweep (warranted) → swarm-fix RED examples (planner: `snapshot`/`plan`/`run`) |
| `sky-rust-backend:sync-with-upstream` | — (agent-driven git runbook) | ingest `anzellai/sky` upstream into `feat/runtime-rust` |
| `sky-rust-backend:update-docs` | — (agent-driven) | commit pending work + refresh `runtime-rust/README.md` |
| `sky-rust-backend:ffi-audit` | `ffi_audit.py` | measure Sky→Rust auto-FFI coverage across a ~50-crate sample |
| `sky-rust-backend:quality-audit` | `quality-audit.sh` | deep soundness/security/efficiency audit — panic vectors, unsafe, dyn Any, footguns, undocumented `#[allow]`, beyond the clippy gate |
| `sky-rust-backend:autonomous-swarm` | — (agent-driven orchestration) | drive a large in-boundary task (port / migration / buildout) too big for one context with an autonomous sub-agent team: 1 asker + 3 reasoners that cross-critique → synthesis → de-risk spine → contracts skeleton → parallel executors under a data-race protocol → adversarial review |

The three sweeps are the verification phases (build+equiv → run+web → perf);
`keep-go-parity` chains them after an upstream sync. The runner scripts are the
canonical procedure — improve the **script** after a run, never improvise the
steps.

### Domain docs

**Of the `.md` files at `runtime-rust/` root, only `CLAUDE.md` and `README.md`
exist.** Everything that matters for the future — new design decisions, progress
conclusions that inform later decisions (not archaeology), TODO/checklist items,
the roadmap and future plan, the soundness/decision ledger, the glossary —
lives in **`README.md`** (structured per the `prune-archaeology` house style:
tables / bullets / `[ ]`-todo-lists / schemas over prose). Do NOT create new
standalone root `.md` files; fold the content into `README.md`. (`docs/` subdir
files — `docs/adr/`, escalated-decisions, etc. — are exempt; this rule is the
root only.) The `update-docs` skill enforces this.

General skills enabled:
- `/grill-me` — stress-test plans and designs
- `/grill-with-docs` — challenge plans against domain glossary + ADRs
- `/improve-codebase-architecture` — find deepening opportunities

## Pre-final code gate (security · correctness · soundness · Efficiency · Completeness · Readability — above all)

> **Principles — applied to every change, in this strict priority order:**
> **1. Security · 2. Correctness · 3. Soundness · 4. Efficiency · 5. Completeness · 6. Readability.**
> A lower principle never justifies compromising a higher one (a readable name
> that breaks correctness is rejected; an efficient path that opens a soundness
> hole is rejected). Names are self-contained and uncontracted — richer-but-
> longer beats terse-but-cryptic, because a non-informative name is pure loss to
> anyone who doesn't already know the code.

Any skill or agent that **writes code** runs this as its **pre-final stage,
BEFORE the commit / hand-off**. These six principles **outrank every other**
(efficiency, Go-parity, brevity, even "it builds") — a change that hurts any of
them is unacceptable, no matter what it buys.

| Principle | What it forbids |
|---|---|
| **Security** | auth / secret / payment bypass; injection; a verification-skipping path reachable in production; a secret in a log/error string |
| **Correctness** | a wrong result from valid input; a broken contract (wire / serde / DB-column / Go-shared name); any shape where `sky` type-checks but `cargo build` fails or the program misbehaves — the "type-checks ⇒ builds ⇒ works" floor MUST hold |
| **Soundness** | a panic / `unwrap` / `expect` / `Box<dyn Any>` / unchecked downcast / OOB / UB / data race reachable from well-typed Sky; any non-total-by-construction path |

**How.** Run it **adversarially** — assume a flaw exists and hunt for it — with
**independent** reviewer agent(s) (`superpowers:requesting-code-review`,
`/security-review`, `sky-rust-backend:quality-audit`), never a self-pat.
Reviewers are read-only, so they fan out safely over parallel-authored work.

**Outcome.**
- **Clean** → proceed to commit / hand-off.
- **A principle is hurt** → RETHINK and REIMPLEMENT it adequately in-boundary; re-review until clean.
- **No adequate in-boundary implementation exists** → **REVERT** the change,
  **LOG** it in `runtime-rust/README.md` (what was attempted, which principle it
  violated, what a correct fix would need), and **SIGNAL the user** explicitly.
  NEVER ship a security / correctness / soundness violation; NEVER bury it as a
  silent workaround.

Not optional, not negotiable — it is the reason the Rust backend exists (a
well-typed Sky program must never fault). The skyshop-rs Phase-6 review — a
CRITICAL emulator auth-bypass plus two "type-checks but `cargo`-fails" codegen
holes that a green build hid — is why this gate is mandatory, not advisory.

## Agent learnings (self-improving loop)

Durable, **verified**, generalizable knowledge future agents should inherit.
Every `sky-rust-backend:*` skill, at the END of its run, records significant
conclusions here so behaviour compounds. This is **curated knowledge, not a
log** — hold it to the same bar as a code review:

| Rule | |
|---|---|
| **Only if secure, correct, and sound** | Never record an insecure shortcut, an unverified optimization, or anything that trades away safety. If you can't verify it, don't write it. |
| **Only if significant + generalizable** | A non-obvious pitfall, a deeper foundational insight, or a real optimization strategy — NOT session play-by-play, one-off facts, or anything the code/specs already state. Most runs add nothing; that is correct. |
| **Reconcile, don't append** | Update/dedupe/prune existing entries before adding; structure over prose (tables/bullets). A wrong or stale entry teaches the wrong thing — delete it. |
| **Link, don't duplicate** | Point to the spec/skill/memory holding the detail; keep entries to the distilled, transferable insight. |

### Foundational understanding
- **A wrapper `fn(..) -> Result<T, String>` binds as a SYNC Sky `Result`, not a
  `Task`.** So a thin wrapper hiding an async runtime lets Sky call sites stay
  synchronous (no `Cmd.perform` re-threading). This is what makes async/framework
  crates reachable.
- **Wrapper-crate pattern (the way to reach crates auto-FFI can't bind):** a thin
  fork-local crate over the framework crate, plain `&str`→`Result`/`Dict String
  String` surface, a **dedicated-thread current-thread tokio runtime** async→sync
  bridge (NEVER `block_on` an ambient runtime; `.join()` maps panic→`Err`),
  delivered via a local `file://` **git** dep in `["rust.dependencies]`. Needs NO
  compiler change (`RustGitDep` + the inspector's `--git` already support it).
  Proven by `examples/rust/skyshop-rs` (see [[skyshop-rs-port]]).
- **An FFI `Result<_, String>` error slot is UNUSABLE on the Sky side** — the
  `.skyi` advertises `String` but codegen emits `SkyError`, so `Err e` can't be
  read. Encode any status the Sky side inspects in the **Ok** payload
  (`_status=...`), never in the `Err` slot.
- **Sky's ONE global `Decoder a` forces a SHARED Rust decoder, not per-source
  specialization.** JsonDec/DbDec/Config all use the same `Decoder a` (no source
  type param), so codegen renders every `Decoder a` identically and can't pick
  `Decoder<JsonVal,…>` vs `Decoder<Row,…>`. The correct in-boundary design:
  ONE `Decoder<E,T> = Box<dyn Fn(&JsonVal) -> SkyResult<E,T>>`, COMBINATORS shared
  (DbDec.map → decode_map — they're source-agnostic), SOURCE unified on JsonVal
  (a DB row is a `JsonVal::Object` of string/Null fields via a NULL-preserving
  `row_to_json`), PRIMITIVES source-specific + total (db_decode_int parses a string
  field). Correct-by-construction: runner fns fix the source. See
  [[../docs/superpowers/specs/2026-06-16-dbdec-subsystem]].
- **Generated Sky ADTs can't cross the runtime FFI boundary — the runtime can't
  name or destructure them.** `Money`, `SqlValue`, `SqlField` are per-project
  GENERATED enums; a kernel taking `List (String, SqlField)` receives an opaque
  type the runtime can't match. Either the runtime returns a non-ADT shape and
  CODEGEN wraps it into the ADT at the call site (e.g. `db_decode_money` returns
  `(Decimal,String)`; codegen emits a `decode_map` building the Money ctor), or
  codegen destructures the ADT into a runtime-friendly form BEFORE the kernel
  call. This is a recurring class (money / Db.insertFields / SqlValue params).

### Pitfalls
- **A codegen-emitted trait impl that recurses into ALL fields needs EVERY field
  type to impl the trait — including runtime opaque types.** The `SkyStringify`
  derive (errorToString fix) emits `impl SkyStringify for <GeneratedType>` whose
  body calls `.sky_show()` on every field; a field of a RUNTIME type (`element::
  Color`, `Element<M>`, `Html<M>`, …) that doesn't impl the trait is an E0599 that
  type-checks-but-cargo-fails — and it hit EVERY Std.Ui project, not just the one
  example tested. Two rules: (1) when adding such a recursing trait, impl it for
  ALL runtime types that can be a generated-struct field (the Std.Ui/Html element
  types are the common ones); (2) **co-locate the impl with the type's module**
  (`ui/element.rs`, `html.rs`), NOT in an always-compiled module like
  `stringify.rs` — those modules are only included in a generated project when
  used (`Project.hs` gates `ui`/`html` on usesHtml/Live/Tui), so an always-present
  module referencing them is E0433 on a non-UI build. Validate against a Std.Ui
  example (`26-ui-showcase`/`19-skyforum`), not just a CLI one.
- **Feature-gated crate types need `#[cfg(feature=…)]` on their trait impls too.**
  An `impl SkyStringify for serde_json::Value` in an always-compiled module fails
  E0433 when the `json` feature is off (generated projects DO enable `json` by
  default, but the standalone runtime crate and any non-json feature subset don't).
  Gate the impl to match the type's feature.
- **sccache's GitHub-Actions cache backend is dead — never use it on CI.**
  `SCCACHE_GHA_ENABLED` drives sccache against GitHub's *v1* Actions-Cache API
  (`artifactcache.actions.githubusercontent.com`), which GitHub retired; sccache
  (≤0.15) still talks v1, so it fails at the first `rustc -vV` with `ghac …
  services aren't available` (HTTP 400). Since sccache is `RUSTC_WRAPPER`, that
  kills EVERY cargo build, not just the step it surfaces in. On CI persist
  `CARGO_TARGET_DIR` + `~/.cargo/registry` via `actions/cache@v4` (v2 service)
  instead, and disable sccache with `SKY_NO_SCCACHE=1` (lib/env.sh honours it).
  sccache stays the LOCAL dev fast path (disk backend, unaffected). The
  `CARGO_INCREMENTAL=0` mandate is coupled to sccache — drop it when sccache is
  off so the cached target dir does incremental rebuilds.
- **A NEW runtime `*.rs` file needs THREE wirings, none auto-discovered:** the
  source `runtime-rust/src/sky_runtime/mod.rs` (`pub mod x; pub use x::*;` — for
  the standalone `cargo build --features full`), AND `Project.hs`'s `baseMods`
  (`"pub mod x;"`) AND `baseUse` (`"pub use x::*;"`) — the GENERATED project's
  `mod.rs` is a hardcoded codegen list, NOT a directory scan. Miss the Project.hs
  re-export and the file is copied but its fns are unreachable (`E0425 cannot
  find function`). Cost a debugging loop on `path.rs`/`set.rs` — verify with
  `rg 'pub (mod|use) x' <generated>/sky_runtime/mod.rs`.
- **skydex `parity` is a PRESENCE index, not a type checker — it OVER-credits.**
  A kernel reads "ok" if a conventionally-named Rust fn exists, even when it's
  unrouted in Kernel.hs or arity/type-wrong (e.g. `db_decode_nullable` exists but
  takes 2 args vs Sky's 1 → latent cargo-fail if used). The behavioral PROBE is
  the truth; don't trust a `parity` drop without a build+run probe of the kernel.
- **Parallel agents race on shared build state:** the one `CARGO_TARGET_DIR`
  (holds only the last build → clobber), the example's `sky-out`/`.skycache`
  (`resource busy`), and a shared wrapper git repo (commit race). Guardrail:
  parallel agents author **disjoint files only, never build, never touch the
  shared seam**; the orchestrator does the single integration build; stages
  mutating one shared resource run **sequentially**. (Codified in
  `sky-rust-backend:autonomous-swarm`.)
- **Wrapper shim string params must be `&str`** (the FFI generator passes `&arg`);
  a zero-arg fn binds `() -> Result` (call it `Mod.f ()`).
- **Multibackend entry — force a non-req Live `init`'s param 0 to `()`, do NOT
  trust the natural render.** A `Live.app` init's param 0 is the request slot; an
  ignored slot (`init _` annotated `()` / `{}` / a free `a`) renders inconsistently
  and sometimes WRONG (a `{}` annotation can resolve to the model struct via the
  open-record-param quirk; a free `a` renders generic). The `Live.app` wrapper
  `move |_r| init(())` then mismatches (E0308). Force param 0 uniformly: `LiveReq`
  for a req-reader (detected by `collectLiveReqInitFns`), else `()` — the wrapper's
  `init(())` always type-checks and Tui passes the `Fn(())` init directly. A
  req-reader is "param 0 binds a var used in the body", not "init has an arg".
- **`Task.run`/`Webview.app` are `Ffi.kernel` aliases → `VarTopLevel`, not
  `VarKernel`.** Any backend-entry peephole that only matches `VarKernel` silently
  misses the alias (the *pure* kernels `Live.app`/`Tui.app`/`Cli.program` DO arrive
  as `VarKernel`). Match both. (Generalises the `VarTopLevel`-vs-`VarKernel`
  ExprEmitter rule above to the multibackend-entry path.)
- **Run the FULL sweep, not a hand-picked subset.** The non-req-init pin surfaced
  ONLY in the complete sweep — a targeted regression subset missed `26-ui-showcase`.
  A new codegen-shape fix needs its own pre-fix-failing fixture AND a full-sweep pass.
- **Verification-skipping emulator/test paths MUST be dev-gated** (`ENV` then
  `SKY_ENV`; unset/dev/development/local ⇒ dev, else refuse). A leaked
  `*_EMULATOR_HOST` in production is an auth/data bypass — gate it.
- **"Green build" ≠ correct, and the fixture sweep ≠ enough.** The example sweep
  misses code shapes no example exercises. For every codegen-shape fix, add a
  regression fixture that fails pre-fix. The strongest check is **running a real
  third-party project** as a proof-test: `sky-playground` surfaced 4 missing
  stdlib kernels (`list_head`/`list_drop`/`file_mkdir_all`/`process_run`), 2
  closure-codegen gaps (E0282 param-infer, E0599 non-`Clone` capture), and a
  `sky run` `CARGO_TARGET_DIR` binary-path bug — the entire fixture sweep passed
  over all of them. Pull a real app and `sky run` it on `--backend rust`.
- **ExprEmitter special-case patterns for Ffi.kernel stdlib functions MUST match
  `VarTopLevel`, not `VarKernel`.** When a Sky source imports `import Std.Db as Db`
  and calls `Db.insertFields`, the canonicaliser produces
  `Can.Call (Ann.At _ (Can.VarTopLevel mod "insertFields")) args` — NOT `VarKernel`.
  `VarKernel` only fires for kernels written as raw `Ffi.kernel "Name"` at the
  call site. The generic `VarTopLevel` handler routes through `kernelToRust` (giving
  the right function name via Kernel.hs) but skips any special-case inline-conversion
  logic. Pattern: add parallel `Can.VarTopLevel mdl "fnName"` arms WITH
  `ModuleName._name mdl == "Std.Db"` guards alongside every `VarKernel` arm.
  Symptom when missing: cargo errors like `expected Vec<(String, SqlParam)>, found
  Vec<(String, StdDbSqlField)>` — the function name is right but the type conversion
  wrapper was skipped.
- **Rust `Decimal` (our newtype) does NOT implement `Display`/`ToString`.**
  Inline match-arm code that calls `.to_string()` on a `Decimal` field fails with
  E0599. Use the runtime helper `decimal_to_string(d)` everywhere a `Decimal` must
  become a `String` (SqlDecimal / SqlMoney arms in `sqlValueMatchArms`).
- Known unfixed codegen/runtime gaps:
  `2026-06-15-skyshop-rs-codegen-gaps.md` (unconstrained-`Result`→`i64`;
  `Dict.union`/`List.sortBy` absences).

### Optimization strategies (secure/correct/sound only)
- **musl static builds MUST ship a fast global allocator (mimalloc), not musl's
  default malloc.** Measured (alloc-stress 2×2): musl's own malloc is ~7× slower
  than glibc (~11× slower than mimalloc) on high-volume small allocations, and
  it is NOT contention-driven (≈same at `-c4` and `-c50`). mimalloc also beats
  glibc 1.72× on dynamic. So `--static` keeps `static_alloc` (mimalloc)
  default-on; a musl+system-malloc build is a ~11× throughput cliff (allowed only
  RSS-constrained, behind a loud warning). The allocator is a `#[cfg(feature=
  "static_alloc")]` toggle DECOUPLED from linking, so it composes on dynamic too.
  NEVER a bump/arena allocator globally (can't free per-object → unbounded RSS →
  OOM). Bench it with the alloc-stress fixture on a CLEAN CPU — concurrent build
  load skews ab throughput.
- **De-risk the make-or-break spine with a minimal vertical slice BEFORE fanning
  out** — the single highest-value step; it surfaces the wrinkles every later
  agent needs.
- **Stub-first:** build the full app against stub wrappers (no heavy deps) to
  decouple the large Sky-side port from heavy/risky crate integration; swap in
  real crates one stage at a time, each ending GREEN.
- **Checkpoint-commit per stage** (general in-boundary fixes first, for
  bisectability) and carry a **wrinkles ledger** forward between agents.
- `go clean -cache` reclaims multi-GB fast; abort agent spawns under ~5 GB free.
- **Disk hygiene — cargo `target/` dirs accumulate fast** (a full example sweep can
  exceed 20 GB). The sweep idiom deletes each example's target right after building
  (`rm -rf sky-out/Rust/target` post-build). The shared `CARGO_TARGET_DIR` is
  package `sky-app` for every example, so it holds only the LAST-built binary —
  rebuild the specific example immediately before running it. Manual reclaim:
  `rm -rf runtime-rust/target tools/sky-ffi-inspect-rs/target ~/.cache/sky` +
  `find runtime-rust/tests/sky -type d -name target -exec rm -rf {} +`. Leave
  `~/.cargo/registry` and `~/.cargo/git` alone (global, slow to rebuild). A stale
  `sky-out/sky` from an unfinished background `cabal install` is the usual cause of
  a "fix didn't take effect" symptom — confirm the binary mtime before building.
