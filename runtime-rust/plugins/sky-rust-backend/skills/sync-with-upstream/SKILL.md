---
name: sync-with-upstream
description: "Ingest the latest anzellai/sky upstream RELEASE TAG (not main — finished code only) into the feat/runtime-rust branch: fetch tags, merge the highest vX.Y.Z tag, resolve the two expected thin-seam conflicts, adapt the Rust backend to any upstream shared-type changes, verify, commit the merge, refresh skydex. Use when the user asks to sync with upstream / pull the latest upstream into the Rust branch. Trigger: /sky-rust-backend:sync-with-upstream."
---

# sync-with-upstream

Pull the latest upstream `anzellai/sky` into the long-lived `feat/runtime-rust`
branch with the thin-seam workflow. The thin-seam refactor
(`runtime-rust/superpowers/specs/2026-05-26-upstream-sync-thin-seam-design.md`) keeps the
conflict surface tiny: expect **exactly two conflicts** (`sky-compiler.cabal`
trivial + `src/Sky/Build/Compile.hs` dispatch hunk), plus occasional small
Rust-side adaptations when upstream changes a *shared* type the Rust codegen
consumes.

Reference runbook in-repo: `runtime-rust/docs/syncing-upstream.md`.

## Constraints (read before doing anything)

- `origin` = `arthurmaciel/sky` (our fork). `upstream` = `anzellai/sky`
  (fetch-only). We sync to the **latest upstream release TAG** (`vX.Y.Z` —
  finished, coherent code), NEVER to `upstream/main` (ongoing dev that can be
  parked mid-feature). `main` is at most a convenience mirror of that tag — never
  commit our work to it.
- **Never break the Go backend.** All our changes are Rust-target-gated. If a
  resolution would alter Go behaviour, it's wrong.
- **Never push** unless the user explicitly asks.
- Do NOT add a `Co-Authored-By` trailer to the merge commit — the repo convention
  forbids the trailer (see `git log`: no recent commit carries one).

## Steps (execute in order)

### Step 1 — Preconditions

```bash
git status --short          # working tree must be clean (commit/stash first)
git branch --show-current   # must be feat/runtime-rust
git remote -v | grep upstream || git remote add upstream https://github.com/anzellai/sky.git
```

### Step 2 — Fetch + identify the latest upstream RELEASE TAG

**Sync to the latest upstream release TAG, NOT `upstream/main`.** A tag (`vX.Y.Z`)
is finished, shipped code; `upstream/main` is ongoing development that may be
parked mid-feature (a half-landed change that doesn't build/behave coherently).
We only ever ingest a coherent release.

```bash
git fetch upstream --tags --force
# Highest semver release tag (e.g. v0.16.31). `--sort=-v:refname` orders by
# version, not commit date, so a back-ported patch tag can't masquerade as latest.
UPSTREAM_TAG=$(git tag -l 'v*' --sort=-v:refname | head -1)
echo "latest upstream release tag: $UPSTREAM_TAG"
```
Hold `$UPSTREAM_TAG` for the rest of the run (re-derive it in any new shell).
Keep `main` as a convenience mirror of that tag (optional — the branch merges the
tag directly, not `main`): `git branch -f main "$UPSTREAM_TAG"`.

### Step 3 — Merge the release TAG into the branch

```bash
git checkout feat/runtime-rust
git merge --no-edit "$UPSTREAM_TAG"
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

The authoritative version is `$UPSTREAM_TAG` from Step 2 — the release tag this
sync merged (the cabal `version:` field is a `0.0.0` placeholder — CI injects the
real number — so do NOT read it from there):

```bash
SKY_VER="${UPSTREAM_TAG#v}"   # e.g. 0.16.31  (re-derive UPSTREAM_TAG if a new shell)
[ -n "$SKY_VER" ] || { echo "ERROR: UPSTREAM_TAG empty — re-derive it (Step 2) before bumping." >&2; exit 1; }
sed -i -E "s/^(runtime_version = )\"[^\"]*\"/\1\"$SKY_VER\"/" runtime-rust/Cargo.toml
# VERIFY the bump LANDED — this is the load-bearing line. A silent sed no-op (the
# key got indented/renamed under [package.metadata.sky], or SKY_VER was empty)
# would otherwise leave runtime_version STALE through the entire sync with no
# visible error — exactly the "Rust version stuck at an old release" bug. Assert
# the file now holds the expected value; fail LOUD if not.
got="$(awk -F'"' '/^runtime_version = /{print $2}' runtime-rust/Cargo.toml)"   # portable (rg -oP needs PCRE2, not always built)
[ "$got" = "$SKY_VER" ] || { echo "ERROR: runtime_version bump FAILED — got '${got:-<none>}', want '$SKY_VER'. The sed did not match: confirm the [package.metadata.sky] block has 'runtime_version' at column 0. Fix before committing." >&2; exit 1; }
echo "runtime_version bumped → $SKY_VER ✓"
```

This is a metadata-only field (`[package.metadata.*]` is ignored by Cargo's
build), so it never affects the Rust build or the Go backend — it's purely the
crate's self-reported provenance. Re-running a sync at the same version is a
clean no-op: the `sed` rewrites the line to the identical value and the VERIFY
passes. The VERIFY is mandatory precisely so a *failed* bump (sed matched
nothing) can never masquerade as a successful no-op. Stage
`runtime-rust/Cargo.toml` with the merge commit in Step 8.

### Step 7 — Verify (do NOT skip; do NOT commit a broken merge)

- **Rust sweep** — every `runtime-rust/tests/sky/*` fixture builds + runs from a clean slate
  (clear `~/.cache/sky/tools/sky-ffi-inspect-rs` first; `sky add … --backend rust`
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
`runtime_version` bump (Step 6b), and any Rust-side adaptation (no
`Co-Authored-By` trailer — see Constraints).

### Step 9 — Refresh the code index (skydex)

After the merge commits, refresh the bounded Sky index so the cross-language
parity map reflects the new upstream:
```bash
( cd tools/skydex && cargo build --release ) && \
  tools/skydex/target/release/skydex update --repo .
```
`skydex update` only re-scans the merge's diff (git-diff incremental) — fast.
Then `skydex parity --gaps` surfaces any kernel the upstream added on the Go
side that the Rust backend hasn't implemented yet (the exact follow-up the sync
should produce).

### Step 10 — Report

```
sync-with-upstream complete
  upstream: anzellai/sky @ <vX.Y.Z>
  merge commit: <sha>
  runtime_version: <X.Y.Z> (mirrored into runtime-rust/Cargo.toml)
  conflicts: cabal (union) + Compile.hs (dispatch wrap)[ + Rust adaptation: <what>]
  verify: all Rust fixtures · Go hello-world · FFI byte-identity (N examples, 0 failures)
  branch: feat/runtime-rust (not pushed)
```

## Background-task hygiene

Building the Rust fixtures + a partial test run spawns subprocesses. Before declaring
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
