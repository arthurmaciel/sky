# SkyRust Project Context

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
| **Export the shared Rust target + sccache before any example build:** `export CARGO_TARGET_DIR="$HOME/.cache/sky-rust-target" RUSTC_WRAPPER=sccache` | every example is package `sky-app`; the shared target compiles axum/tokio/serde/sqlx once. It holds only the LAST-built binary — rebuild the specific example right before running it. Re-export every shell (state doesn't persist between tool calls) |
| **Don't wipe `dist-newstyle/`**; keep the gitignored `cabal.project.local` (`optimization: 0`, `profiling: False`). | incremental compile is the whole point — `-O0` cuts a full rebuild from minutes to ~180s, a one-module link to ~32s. Never commit the file (it would slow the shipped binary) |

Generated `Cargo.toml [profile.dev]` already drops debuginfo (`debug = 0`,
`incremental = true`), emitted by `emitCargoToml`. Sweep via
`SKY_BIN=$(cabal list-bin exe:sky) ./scripts/rust-sweep.sh` (~570s on warm sccache).

## Code navigation — use skydex, NOT Gortex

**Gortex OOMs this machine on this repo** (the global `~/.claude/CLAUDE.md`
mandates Gortex MCP tools — that mandate does NOT apply here; Gortex ballooned
past 15 GB and hung the box). Use **`skydex`**, the bounded Sky-tuned index
(`tools/skydex/`, ~64 MB peak; `tools/skydex/README.md`), or plain Read / `rg`.

**For free-text search use `rg` (ripgrep), NEVER `grep`/`Grep`.** skydex answers
SYMBOL/relationship queries (parity, deps, callers, `locate`); `rg` answers
free-text code-idiom searches inside file bodies that a symbol index can't
(`rg -F '-> SkyTask<()>'`, `rg 'pub mod'`). `rg` is installed and far faster than
grep — recursive by default and respects `.gitignore` (generated dirs skipped).
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

**Default reflex:** before a multi-file grep to answer "is the Rust backend
missing a kernel Go has?" / "what does this module depend on?" / "what tests
cover this?", run the matching `skydex` query — one focused answer instead of
pulling many files into context. `sync-with-upstream` Step 9 auto-refreshes it.

## Phase 1 Status: ✅ COMPLETE

- Runtime crate: `sky-runtime-rust` implemented with 54 tests passing
- Core types: SkyResult, SkyMaybe, SkyString, SkyList, SkyDict, SkyTask

## Phase 2: Codegen Implementation — ✅ DONE

**Rust codegen is implemented in the compiler** (`src/Sky/Generate/Rust/Builder.hs`):
- Full expression translation (functions, kernel calls, patterns, let bindings, binops, unions)
- Triggered via `--target rust` CLI flag

### Key Implementation Details

- **Entry point**: `generateRust` in `src/Sky/Build/Compile.hs` (line ~8400)
- **Output directory**: `sky-out/Rust/` (not `sky-out/rust/`)
- **Runtime**: Inlined with external deps (tokio, sqlx)
- **Default target**: Go (when no `--target` flag specified)


## Phase 3: Remaining Issues

### Known limitations
1. **Anonymous records lose type precision** — SkyValue/String fields only.
2. **JSON pipeline decoder (06-json)** — 11 remaining errors. `Box<dyn FnOnce>` chain from
   `json_dec_p_required`/`optional` + `json_dec_succeed` can't satisfy `Clone`/`Send`. Fundamental
   type-system mismatch: Sky's dynamically-typed pipeline pattern (`Decode.succeed f |= required "x" string`)
   creates deeply nested `FnOnce` types that Rust's static trait system can't express. Needs
   architecture-level restructuring (e.g. `Box<dyn Any>` or macros).
3. **Separate module files** — `mod` declarations instead of flat `main.rs`.

### Resolved
- **Def return type inference**: body-based fallback via `taskExprInnerType` — `main_expensive_task` now correctly returns `SkyTask<i64>`.
- **`System.setenv`/`System.unsetenv`**: stubs added via `std::env::set_var`/`remove_var`. Analyzer sets `usesTaskRun` for System.*.
- **`mainSig "formatTodo"` hack**: kept as last-resort (Db.getField polymorphic). solvedTypes takes priority for monomorphic functions.

### Working examples
- **01-hello-world**: 0 errors, 0 warnings, 0 external deps
- **04-local-pkg**: 0 errors, 0 warnings, 0 external deps (multi-module)
- **07-todo-cli**: 0 errors, 0 warnings, SQLite CRUD via sqlx-sqlite + tokio
- **14-task-demo**: 0 errors, 0 warnings, Task andThen/fail/run with error msgs
- **simple**: 0 errors, 0 warnings, task_sequence + task_parallel (tokio)
- **test_pkg**: 0 errors, 0 warnings, imports + Result/Maybe combinators

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
| `sky-rust-backend:build-sweep` | `build-sweep.sh` | `sky build --target rust` + `cargo build` over the largest example set |
| `sky-rust-backend:run-sweep` | `run-sweep.sh` | build + RUN each runnable example (cli no-panic; server/live boots + `curl GET / → 200`) |
| `sky-rust-backend:web-sweep` | `web-sweep.sh` + `web-verify.mjs` | drive live examples through headless chromium; hard-fail "click is a no-op" |
| `sky-rust-backend:equiv-sweep` | `equiv-sweep.sh` | build each comparable CLI example on BOTH backends, run both, diff stdout (Go≡Rust output parity) |
| `sky-rust-backend:perf-sweep` | `perf-sweep.sh` | Rust-vs-Go cold-start/RSS/binsize/throughput + regression report |
| `sky-rust-backend:keep-go-parity` | `keep-go-parity.sh` | orchestrate sync → warranted sweeps (planner: `snapshot`/`plan`) |
| `sky-rust-backend:sync-with-upstream` | — (agent-driven git runbook) | ingest `anzellai/sky` upstream into `feat/runtime-rust` |
| `sky-rust-backend:update-docs` | — (agent-driven) | commit pending work + refresh `runtime-rust/README.md` |
| `sky-rust-backend:ffi-audit` | `ffi_audit.py` | measure Sky→Rust auto-FFI coverage across a ~50-crate sample |
| `sky-rust-backend:quality-audit` | `quality-audit.sh` | deep soundness/security/efficiency audit — panic vectors, unsafe, dyn Any, footguns, undocumented `#[allow]`, beyond the clippy gate |
| `sky-rust-backend:autonomous-swarm` | — (agent-driven orchestration) | drive a large in-boundary task (port / migration / buildout) too big for one context with an autonomous sub-agent team: 1 asker + 3 reasoners that cross-critique → synthesis → de-risk spine → contracts skeleton → parallel executors under a data-race protocol → adversarial review |

The four sweeps are the verification phases (build → run → web → perf);
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

## Pre-final code gate (security · correctness · soundness — above all)

Any skill or agent that **writes code** runs this as its **pre-final stage,
BEFORE the commit / hand-off**. These three principles **outrank every other**
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

### Pitfalls
- **Parallel agents race on shared build state:** the one `CARGO_TARGET_DIR`
  (holds only the last build → clobber), the example's `sky-out`/`.skycache`
  (`resource busy`), and a shared wrapper git repo (commit race). Guardrail:
  parallel agents author **disjoint files only, never build, never touch the
  shared seam**; the orchestrator does the single integration build; stages
  mutating one shared resource run **sequentially**. (Codified in
  `sky-rust-backend:autonomous-swarm`.)
- **Wrapper shim string params must be `&str`** (the FFI generator passes `&arg`);
  a zero-arg fn binds `() -> Result` (call it `Mod.f ()`).
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
  over all of them. Pull a real app and `sky run` it on `--target rust`.
- Known unfixed codegen/runtime gaps:
  `2026-06-15-skyshop-rs-codegen-gaps.md` (unconstrained-`Result`→`i64`;
  `Dict.union`/`List.sortBy` absences).

### Optimization strategies (secure/correct/sound only)
- **De-risk the make-or-break spine with a minimal vertical slice BEFORE fanning
  out** — the single highest-value step; it surfaces the wrinkles every later
  agent needs.
- **Stub-first:** build the full app against stub wrappers (no heavy deps) to
  decouple the large Sky-side port from heavy/risky crate integration; swap in
  real crates one stage at a time, each ending GREEN.
- **Checkpoint-commit per stage** (general in-boundary fixes first, for
  bisectability) and carry a **wrinkles ledger** forward between agents.
- `go clean -cache` reclaims multi-GB fast; abort agent spawns under ~5 GB free.
