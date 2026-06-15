# skydex — a bounded-memory, Sky-tuned code index (design)

**Date:** 2026-06-15 · **Status:** design (brainstorming output)

## Why
The Sky project spans 5 languages (~241 hs · 332 go · 90 rs · 69 sh · 71 ts +
541 `.sky`, ~260k LOC). The relations that matter for *this* project are
cross-language and Sky-specific — a kernel routes through `Kernel.hs` to a Go
impl AND a Rust impl AND the shared `.sky` stdlib — exactly the class of gap
that bit us repeatedly (missing kernels, Go≡Rust parity). A general engine
(Gortex) can't see those, and **Gortex OOM'd a 15 GB machine indexing this
repo** (unbounded: full ASTs + symbols + call graph + vector embeddings held in
RAM). So: a small Rust tool that captures the Sky-relevant relations under a
**hard memory bound**.

## Goal
A small Rust CLI (`skydex`) that indexes the repo into a single on-disk SQLite
graph, refreshed incrementally on `sync-with-upstream`, capturing four relation
families: (1) Sky cross-language **parity**, (2) module/import **dependency
graph**, (3) **file roles + compiler-pipeline** map, (4) **test/example
coverage** links.

## Non-goals (the unbounded things that crashed Gortex — explicitly out)
- No vector/semantic embeddings, no full call graph, no LSP/rust-analyzer.
- Not a general code-intelligence engine. Sky-tuned, narrow, bounded.

## Hard constraints
- **Bounded + small peak RAM** (target < ~200 MB) regardless of repo size — never
  hold the whole graph or more than one AST. Enforced by a `ulimit -v` test.
- Fast cold index (seconds–low-minutes); sub-second incremental update.
- Single-file artifact (`.skydex/index.db`), gitignored.

## Architecture — 3 streaming stages

### 1. Walk
`git ls-files` (respects `.gitignore` → `dist-newstyle`/`target`/`sky-out`/
`.skycache`/`node_modules` never enter — the walk Gortex failed to bound).
Stream paths. Classify each by **role** from its path: `compiler-hs` /
`runtime-go` / `runtime-rust` / `stdlib-sky` / `script-sh` / `console-ts` /
`example` / `fixture`. Hard per-file size cap (skip + log > ~2 MB).

### 2. Extract — one file at a time; parse → emit rows → DROP tree
- **Mainstream (hs/go/rs/sh/ts/tsx): tree-sitter.** Parse → query the AST for
  top-level symbol defs (fn/type/module) + imports (`import`/`use`/`mod`/
  `source`). Emit `symbols` + import `edges`. **Drop the tree (RAII) before the
  next file** — the tree is the only large alloc; freed immediately → bounded.
- **Sky (`.sky`): line-scan** (no public grammar): `import` lines, `Ffi.kernel
  "Name"` decls, top-level binding names.
- **Sky parity layer (targeted):** scan `Kernel.hs` routing rows
  `("Mod","fn") -> "mod_fn"` → routing edges; match against the tree-sitter Go
  (`func Mod_fn`) + Rust (`pub fn mod_fn`) symbols → **parity triples**
  (Sky ↔ Go ↔ Rust). **Mismatch detection** is the headline: routed-with-Go-but-
  no-Rust-impl (the gap class we hit), stdlib decl with no routing, orphaned
  impl → a `parity` status per kernel.
- **Pipeline map:** classify each Haskell module under a stage
  (`src/Sky/Parse/*`→Parse, `Canonicalise`→Canonicalise, `Type`→Type,
  `Build`→Build, `Generate`→Generate).
- **Test/example coverage:** for each `runtime-rust/tests/sky/*` + `examples/*`,
  line-scan its `.sky` for imported kernels/modules → `covers` edges
  (kernel ← exercised-by → fixture).

### 3. Store — SQLite (`.skydex/index.db`)
`files(path, lang, role, size, sha)` · `symbols(file, name, kind, line)` ·
`edges(src, dst, kind)` (kind ∈ import/routes-go/routes-rust/impl-go/impl-rust/
sky-decl/covers/in-stage) · `kernels(name, sky_decl, hs_route, go_impl,
rust_impl, parity)` · `meta(last_sha, indexed_at)`. Streamed inserts, one
transaction.

## Query CLI
`skydex index` · `skydex update` · `skydex parity [--gaps]` (kernels missing a
Rust/Go impl, routing mismatches, orphans) · `skydex deps/rdeps <module>` ·
`skydex roles` · `skydex pipeline` · `skydex covers <kernel>` ·
`skydex wakeup` (≈500-token digest) · `skydex export --graphml|--dot`.

## Incremental update (the sync hook)
`skydex update`: read `meta.last_sha` → `git diff --name-only <last_sha>..HEAD`
→ re-extract + upsert changed/added files, drop deleted files' rows, recompute
parity for touched kernels, update `meta`. `sync-with-upstream`'s final step
calls `skydex update`. Bounded by the diff, not the repo.

## Anti-OOM contract (the point of the whole thing)
1. `git ls-files` — no walk into generated/vendored trees.
2. One file at a time; tree dropped before the next (RAII).
3. Rows streamed to SQLite (on-disk); only a small cross-link index in RAM
   (kernel + module names, a few thousand entries).
4. Per-file size cap.
5. No embeddings/vector/call-graph.
6. Optional self-RSS soft ceiling → abort with a clear error rather than OOM.

## Crate layout
`tools/skydex/` (repo-root `tools/`, alongside `sky-ffi-inspect-rs` — it indexes
the whole project, not just the Rust backend): `walk.rs` · `extract/{hs,go,
rust,bash,ts,sky}.rs` · `parity.rs` · `store.rs` (rusqlite, bundled) ·
`query.rs` · `main.rs` (clap). Deps: `tree-sitter` + 5 grammars, `rusqlite`,
`clap`, `regex`, `gix`/shell-out for `git ls-files`.

## Testing
- Per-extractor unit tests: a fixture file per language → expected symbols/imports.
- **Parity golden test:** index the live repo, assert known triples link
  (e.g. `List.head` Sky↔Go↔Rust) and known gaps flag (e.g. `Dict.union` missing
  on Rust).
- **Memory test (the load-bearing one):** index the full repo under
  `ulimit -v 300000` (≈300 MB) — MUST complete. Proves the bound + prevents
  regression.

## Open questions for review
- SQLite vs a flat append-only file: SQLite chosen (queryable SQL, incremental
  upsert, single file). Reconsider only if a dep-free build is required.
- `.skydex/index.db` gitignored (default) vs committed (so agents read it
  without re-indexing). Lean gitignored + `skydex update` is cheap.
