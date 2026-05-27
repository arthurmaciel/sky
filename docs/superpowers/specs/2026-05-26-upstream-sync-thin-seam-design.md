# Tracking upstream Sky with a thin-seam Rust backend

**Date:** 2026-05-26
**Branch:** `feat/runtime-rust`
**Status:** design approved, pending spec review

## Problem

The Sky compiler is developed upstream at `github.com/anzellai/sky` and moves
fast. Our Sky→Rust backend lives on the long-lived `feat/runtime-rust` branch of
a fork (`origin = arthurmaciel/sky`), and we ingest upstream by merging it into
that branch. The pain is **merge conflicts in shared compiler files** every time
upstream advances.

Investigation shows why: upstream's FFI/codegen functions are **Go-only with no
`CompileTarget` awareness** — e.g. `generateBindings :: PkgInfo -> IO [String]`,
`emitSkyi :: PkgInfo -> String`, `pkgToModuleName :: String -> String`,
`runInspector :: String -> IO …`. Our Rust work changed those **signatures**
(added a `CompileTarget` parameter and `TargetRust` equations) and interleaved
~143 lines of Rust logic into `FfiGen.hs` alone (plus `Compile.hs` ~47,
`app/Main.hs` ~74, `Toml.hs` ~25). Editing an upstream function's signature and
body is the single biggest conflict generator.

Meanwhile the genuinely-isolated Rust code (`runtime-rust/`,
`tools/sky-ffi-inspect-rs/`, `src/Sky/Generate/Rust/Builder.hs`,
`EmbeddedInspectorRust.hs`, `examples/rust/`) **never conflicts** — upstream
doesn't have those paths.

## Goal

Shrink the shared-file conflict surface to near-zero so `git merge upstream/main`
into `feat/runtime-rust` lands cleanly almost every time, **without** changing
the merge-based topology and **without** any behavior change to either backend.

## Guiding principle

**Restore every upstream-owned function to its exact upstream shape; relocate
all Rust behavior — logic AND dispatch — into new Rust-only modules and minimal
call-site branches.**

A function whose signature/body matches upstream byte-for-byte cannot conflict.
A new module upstream doesn't have cannot conflict. What remains is a handful of
small, well-understood seams: the `CompileTarget` type, three `SkyConfig` fields,
a few `case target of` dispatch arms, export-list names, and cabal entries.

## Key decisions

| Decision | Choice | Rationale |
|---|---|---|
| Topology | Keep merge-upstream-into-branch | User-chosen "clean merge"; least machinery |
| Where Rust logic lives | New `Sky.Build.Rust.*` / `Sky.Cli.RustDeps` / `Sky.Sky.Toml.Rust` modules | Zero conflicts in files upstream lacks |
| Upstream functions | Reverted to upstream Go-only signatures | Signature drift is the top conflict source |
| Dispatch (Go vs Rust) | At call sites in `Compile.hs` / `Main.hs` | Avoids FfiGen→Rust import cycle; arms are tiny |
| Shared FFI types | Stay in `FfiGen.hs`, imported by `Rust.Ffi` | One-way dep (Rust→upstream); no `.hs-boot` |
| Upstream remote | `https://github.com/anzellai/sky.git`, fetch-only | No SSH setup needed for read-only ingest |
| `main` | Pristine `--ff-only` mirror of `upstream/main` | Never accumulates local drift |

### Out of scope (YAGNI)

- Rebase/overlay/submodule topologies (clean-merge chosen).
- Upstreaming the backend to anzellai.
- Touching `Generate/Rust/Builder.hs` or `EmbeddedInspectorRust.hs` internals
  (already isolated).

## Design

### New module tree (all Rust-only; never conflicts)

```
src/Sky/Build/Rust/
  Ffi.hs        -- generateRustBindings, emitRustFile, emitRustSkyi,
                --   rustKernelName, rustModuleName, runRustInspector(+Multi),
                --   translateRustRet, byteSeqKind, dedupByRustName,
                --   resolveRustType, skyTypeToRust, rustSnakeCase, isKnownSky,
                --   the to_u8_* codegen  (moved out of FfiGen.hs)
  Project.hs    -- generateRustProject: the Compile.hs `TargetRust` body
src/Sky/Cli/RustDeps.hs       -- rust add / install / git-dep handler bodies
src/Sky/Sky/Toml/Rust.hs      -- RustDepSpec + parseRustDepSpec + parseInlineTable
src/Sky/Generate/Rust/Builder.hs        -- unchanged (already separate)
src/Sky/Build/EmbeddedInspectorRust.hs  -- unchanged (already separate)
```

`Rust.Ffi` imports `FfiGen` for Go-neutral helpers (`PkgInfo`, `FnInfo`,
`slugify`, `lowerFirst`, `emitKernelJson`, `wrapperSkyType`, inspector subprocess
primitives). Dependency flows one way (Rust → upstream): **no import cycle**.

### Per-file seam

**`src/Sky/Build/FfiGen.hs`** (biggest win)
- Restore to upstream signatures/bodies: `generateBindings :: PkgInfo -> IO [String]`,
  `emitSkyi :: PkgInfo -> String`, `pkgToModuleName :: String -> String`,
  `kernelNameFromPkg :: PkgInfo -> String`, `runInspector`, `runInspectorMulti`
  (drop the `CompileTarget` param and `TargetRust` equations).
- Delete all Rust bodies → move to `Rust.Ffi`.
- Add to the export list the Go-neutral helpers `Rust.Ffi` needs.
- Residual Rust footprint: **0** beyond export-list names.

**`src/Sky/Build/Compile.hs`**
- The `Toml.TargetRust ->` branch body moves to `RustProject.generateRustProject`.
  The arm becomes a one-line delegation. The `case target` already exists.

**`app/Main.hs`**
- `add` / `install`: Go path calls upstream `runInspector` / `generateBindings`.
  One dispatch near the top of each handler: `TargetRust -> RustDeps.addRust …`
  / `RustDeps.installRust …`. The rust git-dep branch + rust add/install bodies
  move into `Sky.Cli.RustDeps`.

**`src/Sky/Sky/Toml.hs`**
- Keep `CompileTarget(..)` and the `_target` / `_rustDeps` / `_sqlxTls`
  `SkyConfig` fields (additive dispatch keys). Move `RustDepSpec`,
  `parseRustDepSpec`, `parseInlineTable` to `Sky.Sky.Toml.Rust`; the
  `["rust.dependencies"]` / `[rust]` parse arms delegate.

**`sky-compiler.cabal`** — register the 4 new modules under `other-modules`
(additive; trivial-conflict).

### Fork hygiene + sync runbook

One-time:
```bash
git remote add upstream https://github.com/anzellai/sky.git
```
`main` is a pristine mirror of `upstream/main` (never receives Rust commits);
`feat/runtime-rust` carries our work on top.

Per-release runbook (`docs/runtime-rust/syncing-upstream.md`, ~10 lines):
```bash
git fetch upstream --tags
git checkout main && git merge --ff-only upstream/main
git checkout feat/runtime-rust && git merge main
# rebuild + verify (below)
```
`origin` (`arthurmaciel/sky`) stays the publish/backup remote for the branch;
`upstream` is fetch-only. We do not rely on GitHub fork-sync — explicit
`git fetch upstream` is scriptable and clear.

## Verification

This is a **pure refactor** — no behavior change. Prove that, and prove the
surface shrank.

**Behavior-preservation:**
- Go path byte-identical: `cabal test` green, same pending count; Go FFI specs
  (`FfiGenGoKernelJsonSpec`, `FfiGenMultiSpec`) unchanged. Build
  `examples/01-hello-world` + one FFI-using Go example — clean.
- Rust path unchanged: all 15 `examples/rust/*` build + run from a clean slate
  with today's output (existing regression sweep).
- Compiler builds; `sky-out/sky --version` prints `sky dev`.

**Conflict-surface metric** (Rust-related lines in the four shared files):
- Before ≈ 289 (`FfiGen` 143 + `Compile` 47 + `Main` 74 + `Toml` 25).
- Target after **< ~40 total**, `FfiGen.hs` Rust footprint **= 0** beyond
  export-list names. `git diff main -- src/Sky/Build/FfiGen.hs` should show the
  Rust logic removed (FfiGen reconverged to upstream).

**Merge dry-run:** with `upstream` added, throwaway
`git merge --no-commit --no-ff upstream/<tag newer than our base>` on a scratch
branch; confirm conflicts (if any) are confined to the `CompileTarget` /
config / dispatch seams, never the Rust logic. Abort the scratch merge.
Best-effort (local `main` is far behind).

**Sequencing safety:** extract one file at a time; `cabal build` + Rust
regression sweep after each; commit per file. Any perturbation to Go or Rust
output stops the line until fixed. Reversible at each commit.
