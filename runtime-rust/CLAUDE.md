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
- **Runtime**: Inlined (no external crate dependency)
- **Default target**: Go (when no `--target` flag specified)

### Working Features

| Feature | Status |
|---------|--------|
| Hello world | ✅ Compiles and runs ("Hello from Sky!") |
| --target rust flag | ✅ Wired into CLI |
| Expression translation | ✅ Functions, calls, patterns, let, binops |
| Kernel calls | ✅ Special handling (Log.println → println! macro) |
| Type mapping | ✅ Basic types (String, Int, Float, Bool) |
| Union/ADT handling | ✅ Pattern matching → match expressions |

### Fixes Applied During Implementation

1. `Can.TAlias` field access - uses pairs, not ty field
2. Removed `Can.Forall` pattern - not in Type, in Annotation
3. Renamed main → sky_main to avoid duplicate
4. Removed `#[derive(Debug)]` causing conflict with manual impl
5. Fixed list functions with Clone bounds (sky_list_head, map, filter, fold, drop)
6. Fixed println! macro generation (kernelToRust + Call handler)
7. Cleaned up unused std imports (Future, Pin, Context, Poll)
8. Fixed build syntax error (comma before "use std::fmt")

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
| `src/Sky/Generate/Rust/Builder.hs` | Core codegen (366 lines) - the actual working implementation |
| `src/Sky/Build/Compile.hs` | generateRust function (line ~8400) |
| `app/Main.hs` | --target CLI flag handling |
| `src/Sky/Sky/Toml.hs` | CompileTarget type (TargetGo/TargetRust) |

### Technical Decisions Made

- Used `Ann.At` instead of `A.Located` (data constructor is `At`, not `Located`)
- `ModuleName.Canonical` wraps a single `String` field, not a list
- Simplified Union/Alias field access to avoid record pattern issues
- Removed explicit `-> ()` return type from generated functions
- Kernel calls use special handling: Log.println → println! macro

## Phase 3: FFI System (Future)

Test crates for FFI integration:
- tokio, serde, uuid, axum, clap, rayon, reqwest, sqlx, tokio-postgres

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