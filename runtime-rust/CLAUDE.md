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
| Kernel calls | ✅ Log.println → log_info(), Db→sqlx, Time/Random/File/Crypto stubs |
| Type mapping | ✅ Basic types, ADTs, records, Tasks |
| Union/ADT handling | ✅ Pattern matching → match expressions |
| Db backend (sqlx, backend-specific) | ✅ SqlitePool/PgPool/MySqlPool via sky.toml driver |
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

### Session 11 — sqlx Backend Integration

9. **sqlx** — Real DB backend replacing HashMap stubs. Backend-specific pool types (SqlitePool/PgPool/MySqlPool as `DbPool`) via sky.toml `[database] driver`. No `AnyPool`, only the needed backend compiled.
10. **URL construction from sky.toml** — `[database] driver = "sqlite", path = "todos.db"` compiles to const `SKY_DB_URL`. `?mode=rwc` auto-creates SQLite files. Non-sqlite drivers pass the path as-is.
11. **`build_sql` helper** — Replaces `?` placeholders with escaped `'values'` (single-quote doubling). DB-agnostic.
12. **`row_to_map` helper** — Converts `DbRow` (backend-specific) → `HashMap<String,String>`.
13. **`sky_err` helper** — Maps `sqlx::Error` to correct `SkyError` variant (Network/Io/Conflict/Timeout/Unavailable/Unexpected).

### Session 12 — Conditional compilation (UsedKernels analyzer)

14. **`UsedKernels`** — `analyzeKernelUsage` walks all expressions collecting which kernels are used (Db, Task.run, Task.parallel, Json).
15. **Conditional Cargo.toml** — tokio dep only when Task/Db is used; sqlx dep only when Db is used; serde_json dep only when Json.* is used.
16. **Conditional runtime stubs** — Db section, JSON section, task_parallel only emitted when the user's code actually uses them.
17. **Hello-world: 0 external deps** — 0.33s build time, no tokio/sqlx/serde_json.

### Session 13 — Structured log attrs + extra kernel stubs

18. **`fmt_attrs`** — Formats `[k,v,k,v,…]` pairs as ` key=value` for `log_info_with`/`log_error_with`.
19. **`taskExprInnerType`** — Added Task, Log, Time, Random, File, Crypto kernel return types for pipe type inference.
20. **Extra kernel stubs** — Time.now/sleep, Random.int/float/choice (LCG, std seed), File.read/write/exists/delete, Crypto.sha256/randomBytes/randomToken, Http.get (returns error, needs reqwest).
21. **`Db.open` alias** — `db_open`/`db_open_with_path` aliases for `db_connect`.
22. **String kernel aliases** — `string_from_int/join/append/length/is_empty/reverse/to_upper/to_lower/trim/contains/to_int`.
23. **`else if` syntax fix** — `Can.If` branches now emit `else if cond { }` instead of `else cond { }`.
24. **Result type ordering fix** — `SkyResult<E, A>` matches Can.TType `[e, a]` order (error-first).

### Session 14 — Println → log_info, main return type, ok_res class fix

25. **Println routes through log_info** — No longer emits `println!` macro + ad-hoc Task wrapper. Goes through `log_info()` which returns `SkyTask<()>` correctly. Eliminates `()` vs `SkyTask<()>` type mismatch.
26. **main return type conditional** — `SkyTask<()>` when user writes `main = println "..."` (no Task.run), `()` when Task.run is used explicitly (todo-cli pattern).
27. **`ok_res` helper** — `fn ok_res<A>(a: A) -> SkyResult<SkyError, A>`. ALL runtime stubs that construct `SkyResult::Ok(x)` with E=SkyError now use `ok_res(x)`. Closes the E0282 class permanently — no turbofish required at any call site.
28. **`#[derive(Clone, Debug)]`** — All generated enums and structs now derive Debug alongside Clone. Fixes `Error.toString` / `format!("{:?}", e)` in all examples.

### Session 15 — Anonymous record struct generation

29. **`collectAnonRecordTypes`** — Walks all expressions for `Can.Record` nodes not matched by a type alias. Generates `RStructDef` entries with SkyValue-typed fields.
30. **Anonymous record literals** — Previously emitted bare `{ field: value }` (invalid Rust). Now emits `AnonR_field1_field2 { field: value.to_string() }` for inline records without matching type alias.

### Session 16 — Backend-specific sqlx (AnyPool → SqlitePool/PgPool/MySqlPool)

31. **`dbPoolType`/`dbRowType`** — Maps sky.toml driver to concrete sqlx types: `sqlite→SqlitePool,SqliteRow`, `postgres→PgPool,PgRow`, `mysql→MySqlPool,MySqlRow`.
32. **No AnyPool** — Avoids `install_default_drivers()` and all backend feature flags. Only the selected backend is compiled.

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
| `src/Sky/Generate/Rust/Builder.hs` | Core codegen (~1830 lines) - the actual working implementation |
| `src/Sky/Build/Compile.hs` | generateRust function (line ~8400) |
| `app/Main.hs` | --target CLI flag handling |
| `src/Sky/Sky/Toml.hs` | CompileTarget type (TargetGo/TargetRust) |

### Technical Decisions Made

- Used `Ann.At` instead of `A.Located` (data constructor is `At`, not `Located`)
- `ModuleName.Canonical` wraps a single `String` field, not a list
- Simplified Union/Alias field access to avoid record pattern issues
- `ok_res` helper for all `SkyResult::Ok` construction (closes E0282 class)
- `Log.println` routes through `log_info` (not `println!` macro)
- `sky_main` return type is conditional on `Task.run` usage
- Anonymous records get synthetic `__anon__` structs (SkyValue fields)
- Backend-specific sqlx types, not AnyPool (no AnyDriver registration)

## Phase 3: Remaining Issues

### Known limitations (no fix planned short-term)
1. **Anonymous records lose type precision** — SkyValue/String fields only.
2. **JSON decoder lifetimes (06-json)** — 139 errors from `Fn`/`FnOnce`/lifetime mismatches in `Decoder<T>` closure types.
3. **Def return type inference** — simple/test_pkg examples have Task-returning Def functions with wrong return type.
4. **Separate module files** — `mod` declarations instead of flat `main.rs`.
5. **`System.setenv` / `System.unsetenv`** — Go target has these in v0.11.5+.

### Working examples
- **01-hello-world**: 0 errors, 0 warnings, 0 external deps
- **04-local-pkg**: 0 errors, 0 warnings, 0 external deps (multi-module)
- **07-todo-cli**: 0 errors, 0 warnings, SQLite CRUD via sqlx-sqlite + tokio
- **14-task-demo**: 0 errors, 0 warnings, Task andThen/fail/run with error msgs

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