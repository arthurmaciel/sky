# skydex v2 — locations + trustworthy reverse-deps (enhancement spec)

**Date:** 2026-06-15 · **Status:** design · **Builds on:** `2026-06-15-skydex-design.md` (v1, shipped)

## Why
v1 tells you *what* (missing kernels, deps, roles) but often not *where* precisely,
and its import edges are **file-level with unresolved, language-specific targets** —
so "how many files import module X" isn't trustworthy across languages. Two
additive enhancements close that, both preserving the bounded-memory invariant.

## Scope (v2)

**A. Locations** — make the high-value outputs jump-to-edit:
- **A1** add `col` to `symbols` (free: tree-sitter `start_position().column`; regex `match.start()`).
- **A2** add route/impl **locations** to `kernels` so `parity` rows point at the edit sites.
- **A3** new `locate <name>` query → `file:line:col kind` for any symbol/kernel.

**B. Trustworthy reverse-deps** — make import counts complete + cross-language:
- **B1** dedup edges → unambiguous counting (one edge per `file → target`).
- **B2** resolve import targets to canonical nodes (`edges.resolved` = the defining file path when local).
- **B3** import-form coverage: Rust grouped `use a::{b,c}`, TS `export … from` re-exports.
- **B4** new `rdeps <module|path>` / `importers` query → distinct importing files + count.

## Non-goals (explicit — these were considered and dropped)
- **Edge line/column / per-import-site rows** — intra-file precision a *count* doesn't use; you don't navigate to an import line.
- "Column on every term" framing — column is the marginal coordinate; the win is route/impl sites + target resolution.
- Full LSP-grade resolution — Rust crate-internal item resolution is best-effort; external Go/npm packages stay unresolved **by design** (NULL).

## Design

### A1 — symbol column
`symbols(file, name, kind, line, col)`. tree-sitter: `cap.node.start_position().column as i64`. line-scan: the regex capture-group start within the line. Additive column (default 0 where a line-scan doesn't track it).

### A2 — kernel locations
`kernels(name, …, hs_route_loc, go_impl_loc, rust_impl_loc, parity)`, each `*_loc` = `"path:line"` TEXT (NULL if absent). Sources:
- Go/Rust impl loc — the impl is already a `symbols` row (file+line); JOIN `symbols` on the impl name during reconcile.
- `hs_route_loc` — capture the line of the routing row during the `Kernel.hs` scan (currently discarded).

`parity --gaps` then prints e.g.
`go-only  Dict.union  route=Kernel.hs:312  go=dict_kernel.go:88  rust=<missing → dict.rs>`
— a diagnosis *and* the jump targets, collapsing a multi-file grep per gap.

### A3 — `locate <name>`
`SELECT file, line, col, kind FROM symbols WHERE name=? ORDER BY file` → `file:line:col  kind`; also surfaces a kernel's route/impl locs.

### B1 — edge dedup + counting semantics
`CREATE UNIQUE INDEX u_edge ON edges(src,dst,kind)`; `put_edge` → `INSERT OR IGNORE`. One row per `(file, target, kind)`, so `COUNT(*) WHERE dst=X AND kind='import'` **equals** the distinct importing-file count (no double-counting when a file imports X twice). (Per-site rows are the dropped non-goal.)

### B2 — target resolution (the meat)
Add `edges.resolved TEXT` (the defining file path, NULL if external/unresolvable). After the full index (so the `files` table is complete), run a **resolution pass**: hold the set of all tracked paths in a `HashSet<String>` (bounded ~file count, ~1865 short strings), stream over the import edges, and per language compute a candidate path + test membership:
- **Haskell / Sky** — module `A.B.C` → a file ending `A/B/C.hs` (Haskell) / `A/B/C.sky` (Sky); `.`→`/`.
- **TS/JS** — `./rel` / `../rel` normalized against `dirname(src)`, trying `.ts/.tsx/.js/.mjs/.jsx` and `/index.*`.
- **Go** — local package path → its repo dir; external (`github.com/…` not in this repo) → NULL by design.
- **Rust** — best-effort: `crate::a::b` → `<crate-src>/a/b.rs` or `a/b/mod.rs` within the same crate root; ambiguous → NULL (don't over-invest in Rust item resolution).

Bounded: one streamed pass over `edges` (on disk) + the path set (bounded); `UPDATE edges SET resolved=?` in a transaction. No whole-graph-in-RAM.

### B3 — import-form coverage
- **Rust** — capture grouped `use a::{b, c}` (emit the crate-path target; the leaf names matter less than the module). Adjust the `use_declaration` query to handle `scoped_use_list`.
- **TS** — add `(export_statement source:(string)@imp)` for re-exports.
- **Haskell / Go / Sky** — already capture the module name (the exposing list is not needed). No change.

### B4 — `rdeps <module|path>` / `importers`
`SELECT DISTINCT src FROM edges WHERE kind='import' AND (resolved=?1 OR dst LIKE ?2) ORDER BY src`, plus a `--count` form. Accepts a module name (matches `dst`) OR a file path (matches `resolved`) — so "who imports the file at P" works uniformly across languages once B2 lands.

## Bounded-memory
Invariant unchanged: extraction stays one-file-at-a-time, trees dropped per file. The new resolution pass holds only the path `HashSet` (bounded) + streams edges. The `ulimit -v` full-repo test continues to gate the whole thing.

## Testing
- A1 — symbol `col` captured (tree-sitter + line-scan unit tests).
- A2 — golden on the real repo: `Dict.union` carries a non-null `hs_route_loc` + `go_impl_loc`; `rust_impl_loc` NULL.
- B1 — a file importing the same module twice → exactly one edge row.
- B2 — resolution golden: Sky `import Sky.Core.List` → `sky-stdlib/Sky/Core/List.sky`; a TS `./x` → the real file; an external Go import → NULL.
- B3 — Rust `use a::{b,c}` → ≥1 edge; TS `export … from` → an edge.
- B4 — `rdeps Sky.Core.List` returns the importing files; `--count` matches `COUNT(DISTINCT src)`.
- The full-repo `ulimit -v` memory test still passes.

## Rollout
Schema-additive (new columns + a unique index) → `skydex index` rebuilds from scratch; all v1 queries unchanged. ~4 TDD tasks: (1) locations (symbol col + kernel locs + `locate`); (2) edge dedup + the resolution pass + `edges.resolved`; (3) import-form coverage (Rust grouped-use, TS re-export); (4) `rdeps`/`importers`. Each ends green + the memory test holds.
