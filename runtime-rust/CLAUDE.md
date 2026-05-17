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

### Dead files deleted (Session 17)

93. **`Sky/Generate/Rust/{Decl,Expr,Kernel,Module,Pattern,Test,Types}.hs`** — 7 files (1192 lines), never compiled (only `Builder.hs` in cabal:131). Several had syntax errors, broken patterns, and stale `Result` type orders. Wiped from repo.

### Session 17 — Batch bugfix from BUGFIX-PLAN.md audit

94. **LCG persistence** — `static AtomicU64` seeded once, not per-call wall clock. Eliminates duplicate "random" values from rapid calls.
95. **Real SHA-256** — `sha2` crate (Cargo feature gated on `usesCrypto`). Previously used `DefaultHasher` (SipHash, 64-bit).
96. **`task_run` error honoured** — entry point matches `block_on()` result: `eprintln!("{:?}", e)` + `exit(1)` on error.
97. **`collectVarLocals(Multi)` binds pattern vars** — Case/LetDestruct/LetRec branches register pattern-bound variables, eliminating spurious `.clone()` injections.
98. **`Can.Update` wrapped in `{ … }`** — record update expressions now valid in argument position.
99. **`Can.VarKernel` dot→underscore** — `Sky.Core.Foo` kernel names become `sky_core_foo` (valid Rust identifier).
100. **`Can.PRecord` struct-name prefix** — `{ field }` patterns become `StructName { field }` via `ecRecordMap` lookup.
101. **`extraKernelSection` gated** — Time/Random/File/Crypto stubs only emitted when user touches the module.
102. **`Task.sequence`/`Task.perform` set `usesTaskRun`** — `hasTokio` correctly True when only sequence/perform used.
103. **`sha2` dep added** — only when `Crypto.*` imported (pattern: same as `sqlx` for `Db.*`).
104. **New `UsedKernels` flags** — `usesTime`, `usesRandom`, `usesFile`, `usesCrypto`.
105. **Dead `argToRust` removed** — diverged duplicate of inline closure logic.

### Session 18 — Def return type inference + System.setenv/unsetenv

106. **Def return type via body inference** — when `hasTypeVars ret` is True (polymorphic), fall back to `taskExprInnerType(ecSolvedTypes, body)`. Fixes `main_expensive_task` having `-> SkyTask<i64>` (was `SkyTask<()>`).
107. **`System.setenv`/`System.unsetenv`** — `std::env::set_var`/`remove_var` with `SkyTask<()>` wrappers. Analyzer sets `usesTaskRun` for System.*.
108. **`taskExprInnerType` System entries** — `setenv`/`unsetenv` return `"()"`.

### Session 19 — Inline-let optimization (Vec<SkyTask>.clone() fix)

109. **`substVar` walker** — Substitutes `VarLocal name` with inline `vec![...]` throughout expression tree. Handles Call, Let, Lambda, Case, If, Binop with full recursion. Mirrors `println→log_info` routing.
110. **Inline-let in `Can.Let`** — When a let-bound variable is a `List` used ≥ 2 times, inline `vec![]` at each use site. Avoids `Vec::clone()` on non-Clone elements.
111. **`simple` example 0 errors** — Was blocked by `Vec<SkyTask>.clone()` (`Pin<Box<dyn Future>>` not Clone).

### Session 21 — Root-cause fixes: 43→11 errors, ecCloneVars systematic rewrite, 06 examples at 0

112. **Zero-arg function references (Root Cause A)** — `ecZeroArgDefs` set tracks zero-arg definitions;
     `()` appended at every `VarTopLevel`/`VarKernel` reference (was bare fn name = fn pointer mismatch).
113. **`val.clone()` in `json_dec_p_optional` (Root Cause B)** — `d(val.clone())` passes `Value` instead of
     `&Value`; changed to `d(val)` (already `&Value` from `v.get(&n)`).
114. **`TRecord→()` in `typeToRustString` (Root Cause C)** — threaded `ecRecordMap` through all call sites;
     `TRecord` now looks up anonymous struct name instead of always returning `"()"`.
115. **`result_traverse` undefined (Root Cause D)** — added Rust runtime function.
116. **`string_to_int` return type (Root Cause E)** — changed from `SkyResult<String, i64>` to `SkyMaybe<i64>`
     (matches Sky's `String.toInt : String -> Maybe Int`).
117. **Unconditional clone of all VarLocal args (Root Cause F)** — replaced with `ecCloneVars`-based cloning:
     only clone when variable appears ≥ 2 times in body. Was cloning every arg, breaking `Box<dyn Fn>`.
118. **`collectVarLocalsMulti` didn't count let/case/pattern-bound vars (Root Cause G)** — removed overly-
     aggressive bound-set tracking; all variables now counted for multi-use, enabling correct clone insertion.
119. **Lambda parameter multi-use tracking** — removed `v \`notElem\` paramNames` filter so lambda params
     used ≥ 2 times get cloned correctly.
120. **`argToRustString` extracted from nested lambda-case** — avoided GHC 9.6 view-pattern issue; the
     function-call arg rendering is now a standalone helper.
121. **`ecNoCloneVars` field in `EmitCtx`** — reserve for future non-Clone type variables (e.g. decoder vars).
122. **All 6 examples at 0 errors** — `01-hello-world`, `04-local-pkg`, `07-todo-cli`, `14-task-demo`,
     `simple`, `test_pkg`. All verified clean build from scratch.

112. **Result kernel sigs** — `resultSig` for map, andThen, mapError, withDefault, map2-5, andMap, combine, traverse for `Sky.Core.Result` and bare `Result` module.
113. **Decoder lifetime bounds** — `T: 'static` on `json_dec_field`, `json_dec_at`, `json_dec_list`. `Send+Sync` bounds removed (over-constrains FnOnce capture).
114. **Synthetic record constructors** — `buildModule` scans `Can._aliases` for record type aliases missing matching `Def` declarations and emits constructor functions (fixes `main_user_profile` missing).
115. **Zero-arg VarTopLevel in println args** — `fnName | "println"`  matches, VarTopLevel args get `()` appended to call the function.
116. **`test_pkg` now 0 errors** — Resolved by earlier fixes.

## Phase 3: Remaining Issues

### Known limitations
1. **Anonymous records lose type precision** — SkyValue/String fields only.
2. **JSON pipeline decoder (06-json)** — 11 remaining errors. `Box<dyn FnOnce>` chain from
   `json_dec_p_required`/`optional` + `json_dec_succeed` can't satisfy `Clone`/`Send`. Fundamental
   type-system mismatch: Sky's dynamically-typed pipeline pattern (`Decode.succeed f |= required "x" string`)
   creates deeply nested `FnOnce` types that Rust's static trait system can't express. Needs
   architecture-level restructuring (e.g. `Box<dyn Any>` or macros).
3. **Separate module files** — `mod` declarations instead of flat `main.rs`.

### Resolved
- **Def return type inference**: body-based fallback via `taskExprInnerType` — `main_expensive_task` now correctly returns `SkyTask<i64>`.
- **`System.setenv`/`System.unsetenv`**: stubs added via `std::env::set_var`/`remove_var`. Analyzer sets `usesTaskRun` for System.*.
- **`mainSig "formatTodo"` hack**: kept as last-resort (Db.getField polymorphic). solvedTypes takes priority for monomorphic functions.

### Working examples
- **01-hello-world**: 0 errors, 0 warnings, 0 external deps
- **04-local-pkg**: 0 errors, 0 warnings, 0 external deps (multi-module)
- **07-todo-cli**: 0 errors, 0 warnings, SQLite CRUD via sqlx-sqlite + tokio
- **14-task-demo**: 0 errors, 0 warnings, Task andThen/fail/run with error msgs
- **simple**: 0 errors, 0 warnings, task_sequence + task_parallel (tokio)
- **test_pkg**: 0 errors, 0 warnings, imports + Result/Maybe combinators

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