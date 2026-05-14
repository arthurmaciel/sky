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

## Phase 2: Codegen Module (Next)

**Add Rust codegen to Sky compiler** (`src/Sky/Generate/Rust/`):
- Convert Sky AST to Rust source code
- Type mapping (Sky → Rust)
- Pattern matching translation (`case` → `match`)
- Lambda/closure handling
- Module organization

## Phase 3: FFI System (Priority Crates)

Test crates for FFI integration:
- tokio, serde, uuid, axum, clap, rayon, reqwest, sqlx, tokio-postgres

## Key Files

| File | Purpose |
|------|---------|
| `SKYRUST-PLAN.md` | Detailed project plan |
| `README.md` | Project overview |
| `sky-runtime-rust/src/lib.rs` | Runtime primitives (54 tests) |
| `sky-compiler/src/Sky/Generate/Rust/` | Rust codegen module (7 files) |

## Rust Codegen Module (`sky-compiler/src/Sky/Generate/Rust/`)

| File | Lines | Purpose |
|------|-------|---------|
| `Types.hs` | ~100 | Type mapping from Sky to Rust |
| `Expr.hs` | ~200 | Expression transpilation |
| `Pattern.hs` | ~150 | Pattern matching → match expressions |
| `Decl.hs` | ~250 | Declaration transpilation |
| `Kernel.hs` | ~350 | Runtime function calls mapping |
| `Module.hs` | ~150 | Module emit and organization |
| `Builder.hs` | ~150 | Orchestration, validation |
| **Total** | ~1,350 | |

## Constraints

- 1-year timeline to production
- Rust-native FFI (direct Rust lib calls) — mandatory from day 1
- WASM target priority over embedded
- All Rust targets: desktop, WASM, CLI, embedded

## Relevant Context from Sky Compiler

- Parser: `/home/arthur/Documentos/comp/sky-anzel/src/Sky/Parse/*.hs` (2,685 lines)
- Type Checker: `/home/arthur/Documentos/comp/sky-anzel/src/Sky/Type/**/*.hs` (5,503 lines)
- Canonicaliser: `/home/arthur/Documentos/comp/sky-anzel/src/Sky/Canonicalise/*.hs` (2,758 lines)
- Go Codegen: `/home/arthur/Documentos/comp/sky-anzel/src/Sky/Generate/Go/*.hs` (1,624 lines) — reference for Rust codegen structure