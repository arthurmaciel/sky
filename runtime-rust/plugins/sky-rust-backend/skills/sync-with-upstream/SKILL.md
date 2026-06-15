---
name: sync-with-upstream
description: "Ingest the latest anzellai/sky upstream release into the feat/runtime-rust branch: fast-forward main, merge, resolve the two expected thin-seam conflicts, adapt the Rust backend to any upstream shared-type changes, verify, commit the merge. Use when the user asks to sync with upstream / pull the latest upstream into the Rust branch. Trigger: /sky-rust-backend:sync-with-upstream."
---

# sync-with-upstream

Pull the latest upstream `anzellai/sky` into the long-lived `feat/runtime-rust`
branch with the thin-seam workflow. The thin-seam refactor
(`docs/superpowers/specs/2026-05-26-upstream-sync-thin-seam-design.md`) keeps the
conflict surface tiny: expect **exactly two conflicts** (`sky-compiler.cabal`
trivial + `src/Sky/Build/Compile.hs` dispatch hunk), plus occasional small
Rust-side adaptations when upstream changes a *shared* type the Rust codegen
consumes.

Reference runbook in-repo: `docs/runtime-rust/syncing-upstream.md`.

## Constraints (read before doing anything)

- `origin` = `arthurmaciel/sky` (our fork). `upstream` = `anzellai/sky`
  (fetch-only). `main` is a **pristine mirror** of `upstream/main` — never
  commit our work to it.
- **Never break the Go backend.** All our changes are Rust-target-gated. If a
  resolution would alter Go behaviour, it's wrong.
- **Never push** unless the user explicitly asks.
- Append the `Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>` trailer to
  any new commit (the merge commit).

## Steps (execute in order)

### Step 1 — Preconditions

```bash
git status --short          # working tree must be clean (commit/stash first)
git branch --show-current   # must be feat/runtime-rust
git remote -v | grep upstream || git remote add upstream https://github.com/anzellai/sky.git
```

### Step 2 — Fetch + fast-forward main

```bash
git fetch upstream --tags
git checkout main && git merge --ff-only upstream/main
git checkout feat/runtime-rust
```
If `--ff-only` fails, `main` has drifted (it shouldn't) — stop and tell the user.

### Step 3 — Merge main into the branch

```bash
git merge --no-edit main
git diff --name-only --diff-filter=U     # the conflicted files
```
Expected conflicts: `sky-compiler.cabal` and `src/Sky/Build/Compile.hs`. If
`FfiGen.hs` / `app/Main.hs` / `Toml.hs` show up, the thin-seam has regressed —
investigate before resolving (don't just paper over it).

### Step 4 — Resolve `sky-compiler.cabal`

Always the test-stanza `build-depends`. Take the **union** of both sides
(upstream's list is usually a superset that already includes our
`cryptohash-sha256`). Delete the `<<<<<<<`/`=======`/`>>>>>>>` markers, keep all
distinct deps.

### Step 5 — Resolve `src/Sky/Build/Compile.hs`

This is the one inherent conflict: our `case Toml._target of {...}` dispatch
wraps upstream's Go-codegen block, which upstream churns every release. Resolve
by keeping **upstream's** version of the codegen and re-wrapping our dispatch:

1. Take upstream's (`=======`..`>>>>>>>`) **pure `let` bindings** verbatim —
   these include `typesWithDeps` and any new bindings (e.g. the Auth gate,
   region types). They're pure, so they can sit before the dispatch.
2. Then our dispatch:
   ```haskell
                   case Toml._target config of
                       Toml.TargetRust -> do
                           rawAliases <- readIORef globalKernelAlias
                           RustProject.generateRustProject config (canMod : map snd validDeps)
                               entrySrcMod typesWithDeps rawAliases outDir srcHash
                       Toml.TargetGo ->
                           <upstream's IO block — the `if not (null …) then … else …`>
   ```
3. The `TargetGo ->` arm is upstream's IO block (everything after the pure
   bindings), **re-indented** to nest under the arm. For a large block, do this
   with a script rather than by hand (read the conflict line ranges, reindent
   the IO half by +N spaces, splice). Confirm `grep -nE '^(<<<<<<<|=======|>>>>>>>)'`
   reports nothing.

The HEAD-side `TargetGo` body is our *older* copy of the Go codegen — discard it;
upstream's is newer.

### Step 6 — Adapt the Rust backend to shared-type changes

Upstream sometimes reshapes a type the Rust codegen consumes. The build will
pinpoint these (errors in `Sky/Generate/Rust/*` or `Sky/Build/Rust/*`). Known
class: `Solve.SolvedTypes` became a record (v0.15) — `generateRust` must project
`_stEnv` before passing the env map to `RustBuilder.buildProgram`. Fix by
extracting the field the Rust code actually needs; never change the Go path.

```bash
cabal build exe:sky 2>&1 | grep -iE "error:" -A4 | head
```
Iterate until it compiles, then install:
```bash
cabal install --overwrite-policy=always --installdir=./sky-out --install-method=copy exe:sky
./sky-out/sky --version    # prints: sky dev
```

### Step 6b — Mirror the Sky version into the Rust runtime crate

The Rust runtime crate records the Sky version it targets in
`runtime-rust/Cargo.toml` under `[package.metadata.sky] runtime_version`. It
MUST mirror the Sky version this sync ingests, so a Rust crate built from this
branch advertises the same version as the compiler that emits its code.

The authoritative version is the latest upstream tag, now reachable from `main`
after Step 2's `--tags` fast-forward (the cabal `version:` field is a `0.0.0`
placeholder — CI injects the real number — so do NOT read it from there):

```bash
SKY_VER=$(git describe --tags --abbrev=0 main | sed 's/^v//')   # e.g. 0.16.24
sed -i -E "s/^(runtime_version = )\"[^\"]*\"/\1\"$SKY_VER\"/" runtime-rust/Cargo.toml
grep -A1 'package.metadata.sky' runtime-rust/Cargo.toml          # confirm new value
```

This is a metadata-only field (`[package.metadata.*]` is ignored by Cargo's
build), so it never affects the Rust build or the Go backend — it's purely the
crate's self-reported provenance. If the value already matches (re-running a
sync), the `sed` is a no-op. Stage `runtime-rust/Cargo.toml` with the merge
commit in Step 8.

### Step 7 — Verify (do NOT skip; do NOT commit a broken merge)

- **Rust sweep** — all 15 `runtime-rust/tests/sky/*` build + run from a clean slate
  (clear `~/.cache/sky/tools/sky-ffi-inspect-rs` first; `sky add … --target rust`
  then `sky run`; `04-uuid` needs `--features v4`). Each must print `OK -> …`.
- **Go regression** — `examples/01-hello-world` builds clean
  (`Build complete: sky-out/app`).
- **Go FFI byte-identity** — targeted, because the full suite hangs (see note):
  ```bash
  cabal test --test-options='--match "FfiGen" --match "Toml" --match "Kernel"'
  ```
  Expect `0 failures`, incl. `FfiGen Go kernel.json byte-identity (Cross-backend
  rule 5)`. If the golden fixture legitimately changed upstream, reconcile it.

> **Full `cabal test` caveat:** the suite hangs in runtime server-spawning specs
> (`Sky.Cli.Watch`, `Console`, `Sky.Build.ExampleSweep`) which start `sky`
> servers that don't self-exit in this environment. Use `--match` (above) or
> `--skip "ExampleSweep" --skip "watch" --skip "console"` with a `timeout`. If a
> run hangs, kill the orphan `cabal test` / `sky-tests` / `app-live` / `sky console`
> processes (`pkill -9 -f …`) before retrying.

### Step 7b — Pre-final code gate (security · correctness · soundness)

Before committing the merge, put the conflict resolutions + any Rust-backend
adaptation (Steps 4–6) through the **`## Pre-final code gate`** in
`runtime-rust/CLAUDE.md`: an independent, adversarial security/correctness/
soundness inspection that **outranks every other principle**. A merge that
silently changes a shared-type contract, reintroduces a panic vector, or papers
over an upstream behaviour change is exactly what this catches. Clean → Step 8.
A principle hurt → rethink + reimplement the resolution and re-review. No
adequate in-boundary resolution → REVERT, LOG it in `runtime-rust/README.md`,
and SIGNAL the user. Never commit a merge that violates one of the three.

### Step 8 — Complete the merge commit

Only after Step 7 is green AND Step 7b's gate passes:
```bash
git add sky-compiler.cabal src/Sky/Build/Compile.hs runtime-rust/Cargo.toml <any Rust files touched in Step 6>
git commit --no-edit   # or supply a message describing the version + resolutions
```
Merge-commit message should name the upstream version, the two resolutions, the
`runtime_version` bump (Step 6b), and any Rust-side adaptation — then the
`Co-Authored-By` trailer.

### Step 9 — Report

```
sync-with-upstream complete
  upstream: anzellai/sky @ <vX.Y.Z>
  merge commit: <sha>
  runtime_version: <X.Y.Z> (mirrored into runtime-rust/Cargo.toml)
  conflicts: cabal (union) + Compile.hs (dispatch wrap)[ + Rust adaptation: <what>]
  verify: 15/15 Rust examples · Go hello-world · FFI byte-identity (N examples, 0 failures)
  branch: feat/runtime-rust (not pushed)
```

## Background-task hygiene

Building 15 examples + a partial test run spawns subprocesses. Before declaring
done, sweep orphans (per the project CLAUDE.md): kill stray
`sky-out/app` / `app-live` / `sky console` / `example-sweep` / `sky-tests`
processes and any leftover poll loops.

## Part of a parity pass?

When the goal is "ingest upstream **and** re-verify Rust parity", this skill is
step 2 of **sky-rust-backend:keep-go-parity**, which snapshots before the sync
and runs the warranted sweeps after.

## Capture learnings (self-improving loop)

After this skill's work completes, record any **significant, verified,
generalizable** learning — a non-obvious pitfall, a deeper foundational insight,
or a secure/correct/sound optimization — to the **`## Agent learnings`** section
of `runtime-rust/CLAUDE.md`, so future agents improve. Obey that section's rules:
**only if secure, correct, and sound + verified**; **reconcile (update / dedupe /
prune), never blind-append**; **skip when nothing significant** — most runs add
nothing, and manufacturing an entry is worse than none.
