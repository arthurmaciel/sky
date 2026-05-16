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

## Phase 1 Status: ✅ COMPLETE

- Runtime crate: `sky-runtime-rust` implemented with 54 tests passing
- Core types: SkyResult, SkyMaybe, SkyString, SkyList, SkyDict, SkyTask

## Phase 2: Codegen Implementation — ✅ DONE

**Rust codegen is implemented in the compiler** (`src/Sky/Generate/Rust/Builder.hs`):
- Full expression translation (functions, kernel calls, patterns, let bindings, binops, unions)
- Works for simple examples (hello-world compiles and runs)
- Triggered via `--target rust` CLI flag

### Key Implementation Details

- **Entry point**: `generateRust` in `src/Sky/Build/Compile.hs` (line ~8400)
- **Output directory**: `sky-out/Rust/` (not `sky-out/rust/`)
- **Runtime**: Inlined with external deps (tokio, sqlx)
- **Default target**: Go (when no `--target` flag specified)

### Working Features

| Feature | Status |
|---------|--------|
| Hello world | ✅ Compiles and runs ("Hello from Sky!") |
| Todo-cli (real SQLite) | ✅ All 7 operations work: add, list, done, undone, remove, clear, help |
| --target rust flag | ✅ Wired into CLI |
| Expression translation | ✅ Functions, calls, patterns, let, binops |
| Kernel calls | ✅ Special handling (Log.println → println! macro) |
| Type mapping | ✅ Basic types, ADTs, records, Tasks |
| Union/ADT handling | ✅ Pattern matching → match expressions |
| Db backend (sqlx AnyPool) | ✅ SQLite, PostgreSQL, MySQL via URL scheme |
| Rust API naming convention | ✅ Types CamelCase, functions snake_case |

### Fixes Applied During Implementation

1. `Can.TAlias` field access - uses pairs, not ty field
2. Removed `Can.Forall` pattern - not in Type, in Annotation
3. Renamed main → sky_main to avoid duplicate
4. Removed `#[derive(Debug)]` causing conflict with manual impl
5. Fixed list functions with Clone bounds (sky_list_head, map, filter, fold, drop)
6. Fixed println! macro generation (kernelToRust + Call handler)
7. Cleaned up unused std imports (Future, Pin, Context, Poll)
8. Fixed build syntax error (comma before "use std::fmt")

### Session 11 — sqlx AnyPool DB Integration

9. **sqlx AnyPool** — Real DB backend replacing HashMap stubs. Supports SQLite/PostgreSQL/MySQL via URL scheme auto-detection. `AnyPool::connect("sqlite:path?mode=rwc")` creates files on demand. `install_default_drivers()` registers backends at runtime.
10. **URL construction from sky.toml** — `[database] driver = "sqlite", path = "todos.db"` compiles to const `SKY_DB_URL`. `?mode=rwc` auto-creates SQLite files. Non-sqlite drivers pass the path as-is.
11. **`build_sql` helper** — Replaces `?` placeholders with escaped `'values'` (single-quote doubling). DB-agnostic: works for SQLite, PostgreSQL, MySQL.
12. **`row_to_map` helper** — Converts `AnyRow` → `HashMap<String,String>` with multi-type fallback (`&str` → `i64` → `f64` → empty).
13. **`sky_err` helper** — Maps `sqlx::Error` to the correct `SkyError` variant: Error ADT (`SkyCoreErrorError::Error(kind, info)`) when the Error module is imported, bare `String` otherwise.
14. **0 Rust compiler errors and warnings** — todo-cli emits clean output end-to-end.

## Non-Negotiable Rule: Rust API Naming Conventions

All generated Rust code MUST follow the [Rust API naming conventions](https://rust-lang.github.io/api-guidelines/naming.html):

- **Types** (structs, enums, type aliases): `CamelCase` — `SkyCoreErrorError`, `SkyCoreErrorErrorKind`
- **Functions** (including kernel stubs): `snake_case` — `task_map`, `task_and_then`, `db_query`
- **Module-prefixed names**: Converted via `toCamelCase` for types and `toSnakeCase` for functions

The naming helpers `toCamelCase` and `toSnakeCase` in `Builder.hs` handle the conversion:
- `Sky_Core_List_map` → type: `SkyCoreListMap`, function: `sky_core_list_map`
- `Sky_Core_Error_ErrorKind` → type: `SkyCoreErrorErrorKind`, function: `sky_core_error_error_kind`

**Exception**: Variable names from Sky source code retain their Sky naming (CamelCase like `todoTitle`). The `#![allow(non_snake_case)]` attribute is added to suppress these. This is accepted because Sky's variable naming conventions differ from Rust's.

### Code Locations

| File | Purpose |
|------|---------|
| `src/Sky/Generate/Rust/Builder.hs` | Core codegen (~1200 lines) - the actual working implementation |
| `src/Sky/Build/Compile.hs` | generateRust function (line ~8400) |
| `app/Main.hs` | --target CLI flag handling |
| `src/Sky/Sky/Toml.hs` | CompileTarget type (TargetGo/TargetRust) |

### Technical Decisions Made

- Used `Ann.At` instead of `A.Located` (data constructor is `At`, not `Located`)
- `ModuleName.Canonical` wraps a single `String` field, not a list
- Simplified Union/Alias field access to avoid record pattern issues
- Removed explicit `-> ()` return type from generated functions
- Kernel calls use special handling: Log.println → println! macro

## Phase 3: Multi-module + Full Stdlib Coverage

### Immediate (todo-cli needs)
1. **`Log.info` / `Log.errorWith` with attrs** — currently stubbed to `println!`. Need proper structured logging.
2. **`Db.open` alias** — Currently only `Db.connect` is mapped. `Db.open` (the Go API) also needs a kernel route.
3. **Error type for `sky_err`** — Currently uses `Unexpected` variant for all DB errors. Map specific sqlx errors (connection refused → `Network`, constraint violation → `Conflict`, etc.).

### Medium term
4. **Separate module files** — `mod` declarations instead of flat `main.rs`.
5. **`Random.*`, `Time.*`, `File.*`, `Crypto.*` kernels** — Currently stubbed or missing.
6. **`System.setenv` / `System.unsetenv`** — Go target has these in v0.11.5+.

### Longer term
- Sky.Http.Server (axum backend)
- Sky.Live (server-driven UI)
- Benchmark `task_parallel` vs Go goroutines

## Constraints

- 1-year timeline to production
- Rust-native FFI (direct Rust lib calls) — mandatory from day 1
- WASM target priority over embedded
- All Rust targets: desktop, WASM, CLI, embedded

## Relevant Context from Sky Compiler

- Parser: `/home/arthur/Documentos/comp/sky/src/Sky/Parse/*.hs`
- Type Checker: `/home/arthur/Documentos/comp/sky/src/Sky/Type/**/*.hs`
- Canonicaliser: `/home/arthur/Documentos/comp/sky/src/Sky/Canonicalise/*.hs`
- Go Codegen: `/home/arthur/Documentos/comp/sky/src/Sky/Generate/Go/*.hs` — reference for Rust codegen structure