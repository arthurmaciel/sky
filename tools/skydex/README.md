# skydex

A small, bounded-memory Rust CLI that indexes the Sky repo into one SQLite graph
capturing cross-language kernel parity, module/import dependencies, file roles,
compiler-pipeline membership, and test/example coverage. Refreshed incrementally
on `sync-with-upstream`.

> **Do NOT run Gortex on this repo.**
> Gortex OOM'd a 15 GB machine indexing this codebase. `skydex` is the bounded
> replacement — measured peak RSS **~64 MB** on the full 1861-file repo under a
> strict `ulimit -v 400000` (400 MB) gate. The memory contract is enforced by a
> `ulimit -v` shell test in `tests/memory_bound.rs` and `scripts/mem-test.sh`.

---

## Anti-OOM contract

Three streaming stages — no file is held in memory once its row is written:

1. **Walk** — `git ls-files` → role-classified paths. Never touches generated
   dirs (`.skycache/`, `sky-out/`, `dist-newstyle/`, `node_modules/`, etc. are
   gitignored). Files above 2 MB are skipped with a warning.
2. **Extract** — one file at a time: tree-sitter for Go/Rust/TS (tree created
   and **dropped** before the next file); line-scan for Haskell, Bash, `.sky`.
3. **Store** — rows streamed into `.skydex/index.db` (SQLite WAL). No in-memory
   accumulation between files.

---

## Commands

```
skydex index   [--repo .] [--db .skydex/index.db]    # full re-index
skydex update  [--repo .] [--db .skydex/index.db]    # incremental git-diff re-scan
skydex parity  [--db ...] [--gaps]                    # kernel parity table (--gaps = mismatches only)
skydex deps    <module>  [--db ...]                   # import deps of a module
skydex roles   [--db ...]                             # file counts by role
skydex pipeline [--db ...]                            # Haskell module counts by compiler stage
skydex covers  <kernel> [--db ...]                    # fixture/example files that cover a kernel
skydex wakeup  [--db ...]                             # digest summary (files/symbols/edges/gaps)
```

### Typical workflow

```bash
# First time (or after `git clean`):
cd tools/skydex && cargo build --release
./target/release/skydex index --repo ../..

# After a sync-with-upstream merge:
./target/release/skydex update --repo ../..

# Surface new parity gaps:
./target/release/skydex parity --gaps
```

---

## SQLite schema

```sql
-- Every git-tracked file (gitignore-excluded generated dirs never appear)
CREATE TABLE files (
    path TEXT PRIMARY KEY,   -- repo-relative path
    lang TEXT,               -- hs | go | rs | sh | ts | sky | other
    role TEXT,               -- compiler-hs | runtime-go | runtime-rust | stdlib-sky |
                             -- script-sh | console-ts | example | fixture | other
    size INTEGER,            -- bytes
    sha  TEXT                -- reserved; empty in v0.1
);

-- Top-level symbols (functions, structs, constants, Sky bindings)
CREATE TABLE symbols (
    file TEXT,               -- → files.path
    name TEXT,               -- symbol name
    kind TEXT,               -- def | binding | …
    line INTEGER             -- 1-based line number (0 when unavailable)
);
CREATE INDEX i_sym_name ON symbols(name);

-- Directed graph edges
CREATE TABLE edges (
    src  TEXT,               -- → files.path (or module name for import edges)
    dst  TEXT,               -- target path or module name or stage name
    kind TEXT                -- import | in-stage | covers
);
CREATE INDEX i_edge_src ON edges(src);
CREATE INDEX i_edge_dst ON edges(dst);

-- Cross-language kernel parity
CREATE TABLE kernels (
    name      TEXT PRIMARY KEY,  -- Sky kernel name e.g. "List.head"
    sky_decl  INTEGER,           -- 1 if a Ffi.kernel declaration was found
    hs_route  TEXT,              -- Kernel.hs routing function name
    go_impl   INTEGER,           -- 1 if a Go impl was found (e.g. List_head)
    rust_impl INTEGER,           -- 1 if a Rust impl was found (e.g. list_head)
    parity    TEXT               -- ok | go-only | rust-only | orphan-route
);

-- Index metadata
CREATE TABLE meta (
    k TEXT PRIMARY KEY,      -- e.g. "last_sha"
    v TEXT
);
```

**Edge `kind` values:**
- `import` — a file/module imports another (`import Sky.Core.List`, Go `import`, Rust `use`)
- `in-stage` — a Haskell source file belongs to a compiler stage (`parse`, `canonicalise`, `type`, `build`, `generate`)
- `covers` — a fixture or example `.sky` file imports (and therefore exercises) a stdlib module

---

## Build

```bash
cd tools/skydex
cargo build --release     # release binary: target/release/skydex
cargo test                # 16 unit + integration tests
```

No external system deps. SQLite is bundled via `rusqlite`'s `bundled` feature.
tree-sitter grammars for Go, Rust, TypeScript are linked statically. Haskell
and Bash fall back to line-scan (no grammar dep needed).

---

## Running the memory-bound test explicitly

```bash
cd tools/skydex
cargo build --release
bash scripts/mem-test.sh        # exits 0 if the full repo indexes under 400 MB
cargo test -- --ignored         # runs the #[ignore] memory_bound integration test
```

`scripts/mem-test.sh` also prints a `skydex wakeup` digest so you can see
what was indexed.
