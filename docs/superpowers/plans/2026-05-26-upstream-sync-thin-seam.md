# Thin-Seam Upstream Tracking — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Shrink the shared-compiler-file conflict surface against upstream `anzellai/sky` by restoring upstream-owned functions to their Go-only signatures and relocating all Rust logic + dispatch into new Rust-only modules, plus add fork hygiene (upstream remote + sync runbook).

**Architecture:** A behavior-preserving refactor. Move Rust-specific code out of `FfiGen.hs`, `Compile.hs`, `app/Main.hs`, `Toml.hs` into new `Sky.Build.Rust.Ffi`, `Sky.Generate.Rust.Project`, `Sky.Cli.RustDeps`, `Sky.Sky.Toml.Rust` modules. Dependency flows one way (Rust modules → upstream FfiGen helpers) so there is no import cycle. Go-vs-Rust dispatch moves to the call sites. The Go and Rust backends emit byte-identical output afterward.

**Tech Stack:** Haskell/GHC (`cabal`), Sky compiler internals, git (merge-based upstream tracking).

**Spec:** `docs/superpowers/specs/2026-05-26-upstream-sync-thin-seam-design.md`

> **Nature of this work:** This is a *refactor with no behavior change*, not a feature. There is no new failing unit test to write. The "test" for every task is **the existing regression suite staying green** plus, at the end, the **conflict-surface re-measurement** dropping as predicted. Each task is verified, then committed. Extract one concern at a time; if any verification regresses, stop and fix before the next task (each commit is a safe rollback point).

---

## Verification protocol (referenced by every task as "run the SWEEP")

These commands are the green-bar check. Run the subset noted in each task.

```bash
# (a) compiler builds + installs
cd /home/arthur/Documentos/comp/sky
cabal build exe:sky 2>&1 | grep -iE "error:" | grep -v '"error"\|-> "String"\|unreachable: filtered' && echo "BUILD ERRORS" || echo "build ok"
cabal install --overwrite-policy=always --installdir=./sky-out --install-method=copy exe:sky 2>&1 | tail -1
./sky-out/sky --version    # must print: sky dev

# (b) Rust example regression sweep (all 15 must print "OK -> ...")
rm -rf ~/.cache/sky/tools/sky-ffi-inspect-rs
cd /home/arthur/Documentos/comp/sky/examples/rust
SKY_BIN=$(pwd)/../../sky-out/sky
run_ex() { d=$1; crate=$2; feat=$3
  cd /home/arthur/Documentos/comp/sky/examples/rust/$d
  rm -rf sky-out .skycache .skydeps
  if [ -n "$feat" ]; then $SKY_BIN add "$crate" --target rust --features "$feat" >/dev/null 2>&1; else $SKY_BIN add "$crate" --target rust >/dev/null 2>&1; fi
  out=$(timeout 250 $SKY_BIN run src/Main.sky 2>&1)
  if echo "$out" | grep -q "Build complete, running"; then echo "[$d] OK -> $(echo "$out" | tail -1)"
  else echo "[$d] FAIL: $(echo "$out" | grep -E 'error\[E[0-9]+\]|could not compile|Undefined' | head -1)"; fi
}
run_ex 01-rand rand;          run_ex 02-num-cpus num_cpus;  run_ex 03-chrono chrono
run_ex 04-uuid uuid v4;       run_ex 05-roman roman;        run_ex 06-lipsum lipsum
run_ex 07-deunicode deunicode;run_ex 08-semver semver;      run_ex 09-bytesize bytesize
run_ex 10-titlecase titlecase;run_ex 11-fastrand fastrand;  run_ex 12-ulid ulid
run_ex 13-petname petname;    run_ex 14-crc32fast crc32fast;run_ex 15-uuid-bytes uuid

# (c) Go backend unaffected
cd /home/arthur/Documentos/comp/sky/examples/01-hello-world && rm -rf sky-out .skycache .skydeps && ../../sky-out/sky build src/Main.sky 2>&1 | tail -1   # "Build complete: sky-out/app"

# (d) Go compile-time specs (Task 3 + Task 4 only — slower)
cd /home/arthur/Documentos/comp/sky && cabal test 2>&1 | tail -5   # zero failures
```

`SWEEP(a,b,c)` means run blocks a, b, c. The inspector binary is embedded via Template Haskell, so any change to `tools/sky-ffi-inspect-rs/` (none in this plan) would need a `touch` + rebuild — not applicable here since this plan touches only Haskell.

---

## Task 0: Fork hygiene — upstream remote + sync runbook

**Files:**
- Create: `docs/runtime-rust/syncing-upstream.md`

- [ ] **Step 1: Confirm the upstream remote exists (added during brainstorming)**

Run: `git remote -v | grep upstream`
Expected: `upstream  https://github.com/anzellai/sky.git (fetch)`. If absent:
`git remote add upstream https://github.com/anzellai/sky.git`

- [ ] **Step 2: Make upstream fetch-only (block accidental pushes)**

```bash
git remote set-url --push upstream DISABLED
git remote -v | grep upstream    # push URL now "DISABLED"
```

- [ ] **Step 3: Write the sync runbook**

Create `docs/runtime-rust/syncing-upstream.md`:

````markdown
# Syncing with upstream anzellai/sky

`origin` = `arthurmaciel/sky` (our fork; publish/backup for `feat/runtime-rust`).
`upstream` = `anzellai/sky` (fetch-only). `main` is a **pristine mirror** of
`upstream/main` — never commit Rust work to it.

## Per-release sync

```bash
git fetch upstream --tags
git checkout main && git merge --ff-only upstream/main   # pristine fast-forward
git checkout feat/runtime-rust && git merge main
```

After the thin-seam refactor, expect at most these trivial conflicts:

- `sky-compiler.cabal` — both sides add `build-depends`. Resolve by **keeping
  both** dependency lists (union).
- `src/Sky/Build/Compile.hs` — a small target-dispatch hunk where our
  `case Toml._target of { TargetRust -> Rust.Project.generateRustProject … }`
  meets upstream's edits to the Go-codegen block. Re-apply our dispatch arm
  around upstream's updated Go block. (This one cannot be fully eliminated;
  it is shrunk to the dispatch wrapper, not the full body.)

Then rebuild + verify: `cabal install … exe:sky` and run the Rust example sweep
(`docs/superpowers/plans/2026-05-26-upstream-sync-thin-seam.md` Verification
protocol block b).
````

- [ ] **Step 4: Commit**

```bash
git add docs/runtime-rust/syncing-upstream.md
git commit -m "docs(rust): upstream sync runbook + fetch-only upstream remote

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 1: Extract Toml rust-dep parsing → `Sky.Sky.Toml.Rust`

**Files:**
- Create: `src/Sky/Sky/Toml/Rust.hs`
- Modify: `src/Sky/Sky/Toml.hs` (move `RustDepSpec`, `parseRustDepSpec`, `parseInlineTable`; delegate)
- Modify: `sky-compiler.cabal` (register new module)

- [ ] **Step 1: Create the new module**

`src/Sky/Sky/Toml/Rust.hs`:

```haskell
-- | Rust-target dependency parsing for sky.toml's ["rust.dependencies"] and
-- [rust] sections. Split out of Sky.Sky.Toml so the Go-relevant Toml code
-- stays byte-identical to upstream and merges cleanly.
module Sky.Sky.Toml.Rust
    ( RustDepSpec(..)
    , parseRustDepSpec
    ) where

-- (imports as needed by the moved code, e.g. Data.List for isPrefixOf)
```

- [ ] **Step 2: Move the parsing code verbatim**

From `src/Sky/Sky/Toml.hs`, cut `data RustDepSpec = …` (line ~23), `parseRustDepSpec` (line ~211), and `parseInlineTable` (line ~218) **verbatim** into `Sky.Sky.Toml.Rust`. Add to that module's export list `RustDepSpec(..)` and `parseRustDepSpec` (keep `parseInlineTable` unexported — it's an internal helper).

**Cycle-avoidance (important):** `Toml.hs` will import `RustDepSpec` *from*
`Toml.Rust` (its `SkyConfig._rustDeps` field needs it), so `Toml.Rust` must NOT
import anything from `Toml.hs` — that would be a mutual import cycle. If the
moved parsers call tiny helpers like `trim` / `stripQuotes` that also live in
`Toml.hs`, **duplicate those small helpers into `Toml.Rust`** (define them
locally) so the dependency stays strictly one-way (`Toml → Toml.Rust`).

- [ ] **Step 3: Re-export from Toml.hs and delegate**

In `src/Sky/Sky/Toml.hs`:
- Keep `data SkyConfig` with `_target`, `_rustDeps`, `_sqlxTls` fields and `CompileTarget(..)`/`parseCompileTarget` (these are the dispatch keys — unchanged).
- Add `import Sky.Sky.Toml.Rust (RustDepSpec(..), parseRustDepSpec)`.
- Keep re-exporting `RustDepSpec(..)` from `Sky.Sky.Toml`'s export list (so existing importers of `Sky.Sky.Toml (RustDepSpec(..))` are unaffected).
- The parse arm at line ~126 (`let spec = parseRustDepSpec value`) now resolves to the imported function — no code change needed there.

- [ ] **Step 4: Register the module in cabal**

In `sky-compiler.cabal`, add `Sky.Sky.Toml.Rust` to the library `other-modules` list (alphabetically near `Sky.Sky.Toml`).

- [ ] **Step 5: Build + verify**

Run `SWEEP(a, b)`. (a) builds; (b) all 15 Rust examples still resolve deps and run — this exercises `["rust.dependencies"]` parsing for `uuid = { version, features }` (04-uuid) and bare versions.
Expected: build ok; 15× `OK -> …`.

- [ ] **Step 6: Commit**

```bash
git add src/Sky/Sky/Toml.hs src/Sky/Sky/Toml/Rust.hs sky-compiler.cabal
git commit -m "refactor(rust): extract rust-dep parsing to Sky.Sky.Toml.Rust

Toml.hs keeps CompileTarget + SkyConfig fields (dispatch keys); RustDepSpec +
parsers move out. No behavior change.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 2: Extract Compile.hs Rust codegen branch → `Sky.Generate.Rust.Project`

**Files:**
- Create: `src/Sky/Generate/Rust/Project.hs`
- Modify: `src/Sky/Build/Compile.hs:1449-1529` (the `Toml.TargetRust -> do` branch body)
- Modify: `sky-compiler.cabal`

- [ ] **Step 1: Read the exact branch**

Read `src/Sky/Build/Compile.hs` lines `1448-1530`. The `case Toml._target config of` at 1448 has `Toml.TargetRust -> do` (1449) through 1529, then `Toml.TargetGo -> do` (1530). Identify every free variable the `TargetRust` body uses (e.g. `canMod`, `validDeps`, `entrySrcMod`, `typesWithDeps`, `config`, `outDir`, `globalKernelAlias`, `srcHash`) — these become the parameters of the extracted function.

- [ ] **Step 2: Create the new module with the moved body**

`src/Sky/Generate/Rust/Project.hs`:

```haskell
-- | Rust-target project codegen orchestration: emit main.rs + module files,
-- copy the runtime, write Cargo.toml, copy FFI bindings. Extracted verbatim
-- from the Compile.hs `TargetRust` branch so upstream's Go-codegen block in
-- Compile.hs stays minimally wrapped.
module Sky.Generate.Rust.Project
    ( generateRustProject
    ) where

-- imports: whatever the moved body referenced — e.g.
--   import Sky.Generate.Rust.Builder (generateRust) and qualified RustBuilder
--   import qualified Sky.Sky.Toml as Toml
--   System.Directory / FilePath / Data.IORef / qualified Data.Map / Data.Char
--   import qualified Sky.Build.Rust.Ffi as RustFfi   -- ONLY if the branch
--     calls Rust FFI binding generation; otherwise omit (added in Task 3)

generateRustProject :: <param types matching the free vars from Step 1>
                    -> IO (Either String FilePath)
generateRustProject <params> = do
    <the body of the TargetRust branch, lines 1450-1529, verbatim>
```

Move lines `1450-1529` **verbatim** as the function body, replacing the captured free variables with the named parameters. The branch already `return (Right mainRustPath)` at its end, matching `IO (Either String FilePath)`.

- [ ] **Step 3: Replace the branch with a one-line delegation**

In `Compile.hs`, the `Toml.TargetRust -> do … (80 lines)` arm becomes:

```haskell
                    Toml.TargetRust ->
                        RustProject.generateRustProject <args in the same order as the params>
```

Add `import qualified Sky.Generate.Rust.Project as RustProject` to Compile.hs. Leave the `Toml.TargetGo -> do` arm **completely untouched** (this is what keeps upstream's Go block mergeable).

- [ ] **Step 4: Register the module in cabal**

Add `Sky.Generate.Rust.Project` to `sky-compiler.cabal` `other-modules` (near `Sky.Generate.Rust.Builder`).

- [ ] **Step 5: Build + verify**

Run `SWEEP(a, b, c)`. (b) all 15 Rust examples build+run (exercises the extracted codegen end-to-end). (c) Go hello-world builds (proves the `TargetGo` arm is intact).
Expected: build ok; 15× `OK -> …`; `Build complete: sky-out/app`.

- [ ] **Step 6: Commit**

```bash
git add src/Sky/Build/Compile.hs src/Sky/Generate/Rust/Project.hs sky-compiler.cabal
git commit -m "refactor(rust): extract Compile.hs Rust codegen branch to Sky.Generate.Rust.Project

The TargetRust orchestration body moves out; Compile.hs keeps a one-line
delegation. The TargetGo branch is byte-identical, shrinking the recurring
upstream merge conflict to the dispatch wrapper. No behavior change.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 3: Extract Rust FFI logic → `Sky.Build.Rust.Ffi`, restore FfiGen Go-only signatures, rewire callers

This is the largest task and is **atomic**: restoring FfiGen's signatures breaks its callers, so the new module, the signature restoration, and the caller rewiring must land in one compiling commit.

**Files:**
- Create: `src/Sky/Build/Rust/Ffi.hs`
- Create: `src/Sky/Cli/RustDeps.hs`
- Modify: `src/Sky/Build/FfiGen.hs` (restore Go-only signatures; export shared helpers)
- Modify: `app/Main.hs` (dispatch add/install; move Rust handler bodies to RustDeps)
- Modify: `src/Sky/Build/Compile.hs` (if it calls `generateBindings`/`runInspector*` for Rust)
- Modify: `sky-compiler.cabal`

- [ ] **Step 1: Widen FfiGen's export list with the Go-neutral shared helpers**

In `src/Sky/Build/FfiGen.hs`'s `module … ( … ) where`, add the names `Sky.Build.Rust.Ffi` will import: `slugify`, `lowerFirst`, `emitKernelJson`, `wrapperSkyType`, `_pkgPath`, `_pkgFns`, and the JSON-decode entry the inspector uses for `PkgInfo` (the `FromJSON PkgInfo` instance is exported automatically with `PkgInfo(..)`). Keep the existing exports. (Additive — this is the only residual conflict point on FfiGen, and it is trivial.)

- [ ] **Step 2: Create `Sky.Build.Rust.Ffi` and move the Rust FFI functions into it**

`src/Sky/Build/Rust/Ffi.hs`:

```haskell
-- | All Rust-target FFI binding generation. Owns everything the Go FFI
-- generator (Sky.Build.FfiGen) does NOT need to know about. Imports the
-- Go-neutral shared helpers from FfiGen; FfiGen never imports this module
-- (one-way dependency, no cycle).
module Sky.Build.Rust.Ffi
    ( generateRustBindings   -- :: PkgInfo -> IO [String]   (was generateBindings TargetRust)
    , runRustInspector       -- :: String -> [String] -> IO (Either String PkgInfo)
    , runRustInspectorMulti  -- :: [String] -> [String] -> IO [Either String PkgInfo]
    , emitRustSkyi           -- :: PkgInfo -> String
    , rustModuleName         -- :: String -> String   (was pkgToModuleName TargetRust)
    , rustKernelName         -- :: PkgInfo -> String   (was kernelNameFromPkg TargetRust part)
    ) where

import Sky.Build.FfiGen
    ( PkgInfo(..), FnInfo(..), slugify, lowerFirst, emitKernelJson, wrapperSkyType )
-- + EmbeddedInspectorRust, aeson, System.Process, System.Directory, Data.Char,
--   Data.List, qualified Data.Set — as the moved bodies require.
```

Move these **verbatim** from `FfiGen.hs` into this module (cut, then delete from FfiGen):
`skyTypeToRust`, `rustSnakeCase`, `isNumericRust`, `trimStr`, `stripGeneric1`,
`okTypeOfResult`, `ByteKind`(+`byteSeqKind`), `translateRustRet`, `emitRustFile`
(and its `where`-local `emitRustFnSimple`), `pkgToCrateImport`, `dedupByRustName`,
`resolveRustInspector`.

Then add the small wrappers that were previously the `TargetRust` equations:
- `generateRustBindings pkg0` = the body of the old `generateBindings TargetRust pkg0` (the dedup + write `.rs`/`.skyi`/`.kernel.json` to `.skycache/ffi/rust/`).
- `emitRustSkyi pkg` = the body of the old `emitSkyi TargetRust pkg`.
- `rustModuleName path` = the body of the old `pkgToModuleName TargetRust path`.
- `rustKernelName pkg` = the Rust branch of `kernelNameFromPkg` (the `"Rust_"` prefix path).
- `runRustInspector` / `runRustInspectorMulti` = self-contained: `resolveRustInspector >>= \bin -> <run binary, decode JSON to PkgInfo>`. Copy the run-and-decode body from the old `runInspectorForTarget` TargetRust path (a little duplication is intentional — it keeps FfiGen's `runInspector` byte-identical to upstream).

- [ ] **Step 3: Restore FfiGen's functions to upstream Go-only signatures**

In `src/Sky/Build/FfiGen.hs`, restore these to their upstream shape (drop the `CompileTarget` param and the `TargetRust` equations; keep only the Go body):

```haskell
generateBindings :: PkgInfo -> IO [String]          -- was: CompileTarget -> PkgInfo -> IO [String]
emitSkyi :: PkgInfo -> String                       -- was: CompileTarget -> PkgInfo -> String
pkgToModuleName :: String -> String                 -- was: CompileTarget -> String -> String
kernelNameFromPkg :: PkgInfo -> String              -- was: CompileTarget -> PkgInfo -> String
runInspector :: String -> IO (Either String PkgInfo)        -- was: runInspectorForTarget
runInspectorMulti :: [String] -> IO [Either String PkgInfo] -- was: runInspectorMultiForTarget
resolveInspector :: IO (Either String FilePath)             -- Go-only (was: CompileTarget -> …)
```

Delete `inspectorName`, `inspectorCallPrefix` if upstream did not have them (verify with `git show main:src/Sky/Build/FfiGen.hs | grep -nE "^inspectorName|^inspectorCallPrefix"` — they are ours; fold the Go value back inline into `runInspector`/`resolveInspector` exactly as upstream has it). Update FfiGen's export list: `generateBindings`, `runInspector`, `runInspectorMulti` (rename from the `*ForTarget` exports), `pkgToModuleName`, `emitSkyi`, `kernelNameFromPkg` keep their names but new arities.

The cleanest way to get the exact upstream bodies: `git show main:src/Sky/Build/FfiGen.hs` and copy the upstream definitions of these functions verbatim.

- [ ] **Step 4: Create `Sky.Cli.RustDeps` for the Main.hs Rust handler bodies**

Read `app/Main.hs` `addHandler` (757-893), `regenMissingRustBindings` (962-), and the install handler. Move the **Rust-specific** bodies — the `(TargetRust, GitDep …)` branch (~792), the `TargetRust ->` arms that call the inspector/`generateBindings`, and `regenMissingRustBindings` — into:

```haskell
-- | Rust-target `sky add` / `sky install` dependency handling, split out of
-- app/Main.hs so the Go add/install path stays upstream-shaped.
module Sky.Cli.RustDeps
    ( addRustDep        -- mirror the signature addHandler needs for the Rust path
    , installRustDeps
    , regenMissingRustBindings
    ) where

import qualified Sky.Build.Rust.Ffi as RustFfi
import Sky.Sky.Toml (RustDepSpec(..))
-- + whatever the moved bodies used (System.Directory, appendRustDependency, …)
```

These call `RustFfi.runRustInspector` / `RustFfi.generateRustBindings` instead of the old `*ForTarget`.

- [ ] **Step 5: Rewire the Main.hs / Compile.hs call sites to dispatch**

In `app/Main.hs` `addHandler` and the install handler, replace the `*ForTarget` calls with an explicit dispatch near the top:

```haskell
case target of
    TargetGo   -> do  -- upstream-shaped Go path
        r <- FfiGen.runInspector pkg            -- (was runInspectorForTarget target pkg features)
        ... names <- FfiGen.generateBindings info ...
    TargetRust -> RustDeps.addRustDep <args>    -- whole Rust flow lives in RustDeps
```

Apply the analogous dispatch in the install handler and any `Compile.hs` site that called `FfiGen.generateBindings target …` / `runInspectorForTarget` for the Rust path. Add imports: `import qualified Sky.Cli.RustDeps as RustDeps` (Main.hs), `import qualified Sky.Build.Rust.Ffi as RustFfi` where a site calls Rust binding generation directly. Register `Sky.Build.Rust.Ffi` and `Sky.Cli.RustDeps` in `sky-compiler.cabal`.

- [ ] **Step 6: Build + verify (full)**

Run `SWEEP(a, b, c, d)`.
- (a) builds + installs.
- (b) all 15 Rust examples `OK -> …` (proves the Rust FFI path is intact through the new modules: `sky add` → `runRustInspector` → `generateRustBindings`, and codegen).
- (c) Go hello-world builds.
- (d) `cabal test` — zero failures, same pending count as before this plan (proves FfiGen's restored Go signatures didn't change Go FFI behavior; the `FfiGenGoKernelJsonSpec` / `FfiGenMultiSpec` specs pass).
Expected: all green.

- [ ] **Step 7: Confirm FfiGen reconverged toward upstream**

```bash
git diff main -- src/Sky/Build/FfiGen.hs | grep -cE "^\+.*(TargetRust|emitRust|byteSeq|translateRust|to_u8_|skyTypeToRust)"
```
Expected: `0` (the Rust logic is gone from FfiGen). Spot-check the function signatures match `git show main:src/Sky/Build/FfiGen.hs` for `generateBindings`, `emitSkyi`, `runInspector`.

- [ ] **Step 8: Commit**

```bash
git add src/Sky/Build/FfiGen.hs src/Sky/Build/Rust/Ffi.hs src/Sky/Cli/RustDeps.hs app/Main.hs src/Sky/Build/Compile.hs sky-compiler.cabal
git commit -m "refactor(rust): relocate Rust FFI to Sky.Build.Rust.Ffi; restore FfiGen Go-only signatures

FfiGen's generateBindings/emitSkyi/pkgToModuleName/kernelNameFromPkg/runInspector
revert to their upstream Go-only signatures; all Rust FFI logic + the Go-vs-Rust
dispatch move to Sky.Build.Rust.Ffi + Sky.Cli.RustDeps, with dispatch at the
Main.hs/Compile.hs call sites. One-way import (Rust -> FfiGen), no cycle. Go and
Rust output byte-identical. Removes the signature-drift conflict fault line.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 4: Re-measure the conflict surface + final verification

**Files:** none (measurement only; may amend the runbook).

- [ ] **Step 1: Full green-bar**

Run `SWEEP(a, b, c, d)` once more from a clean state. All 15 Rust examples `OK`, Go hello-world builds, `cabal test` zero failures.

- [ ] **Step 2: Conflict-surface metric**

```bash
cd /home/arthur/Documentos/comp/sky
for f in src/Sky/Build/FfiGen.hs src/Sky/Build/Compile.hs app/Main.hs src/Sky/Sky/Toml.hs; do
  echo "$f: $(grep -icE 'rust|TargetRust|sky_runtime|cargo|emitRust|to_u8_|byteSeq' "$f") Rust-related lines"
done
```
Expected: `FfiGen.hs` ≈ 0 (only export names); total across the four files **< ~40** (down from ~289).

- [ ] **Step 3: Dry-run merge re-measure (the acceptance proof)**

```bash
git fetch upstream
git checkout -b scratch/merge-probe2
git merge --no-commit --no-ff upstream/main > /tmp/m2.txt 2>&1
git diff --name-only --diff-filter=U          # conflicted files
for f in $(git diff --name-only --diff-filter=U); do echo "$f: $(grep -c '^<<<<<<<' "$f") hunk(s)"; done
git merge --abort
git checkout feat/runtime-rust
git branch -D scratch/merge-probe2
```
Expected vs the pre-refactor baseline (Compile.hs ~228-line hunk + cabal):
- `FfiGen.hs`, `Main.hs`, `Toml.hs`: **no conflict** (signature-clean now).
- `Compile.hs`: conflict shrunk to the small dispatch wrapper (not the 228-line body).
- `sky-compiler.cabal`: unchanged trivial hunk.

- [ ] **Step 4: No code commit** (verification only). If the metric or dry-run did not improve as predicted, investigate before declaring done — but do not force changes that perturb the regression suite.

---

## Done criteria

- `Sky.Sky.Toml.Rust`, `Sky.Generate.Rust.Project`, `Sky.Build.Rust.Ffi`,
  `Sky.Cli.RustDeps` exist; FfiGen reconverged to upstream Go-only signatures.
- All 15 Rust examples build + run; Go hello-world builds; `cabal test` green.
- Conflict-surface metric < ~40 lines across the four shared files, `FfiGen.hs` ≈ 0.
- Dry-run merge of `upstream/main` conflicts only in `Compile.hs` (shrunk) + cabal.
- `upstream` remote is fetch-only; `docs/runtime-rust/syncing-upstream.md` exists.
