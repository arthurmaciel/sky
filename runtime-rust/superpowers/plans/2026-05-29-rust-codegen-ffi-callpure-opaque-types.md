# Rust codegen — `Ffi.callPure` peephole + opaque-type registry — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close sub-project A's headline gate (`examples/00-standard-libs` on `target=rust`) by fixing the two remaining Rust-codegen integration gaps documented in `docs/runtime-rust/sub-A-stdlib-parity-result.md`.

**Architecture:** Two paired changes inside `src/Sky/Generate/Rust/Builder.hs`. (1) A peephole arm in the Rust call-emission path that recognises `Ffi.callPure "<KernelName>" [args]` with literal-string name + literal-list args, parses the name as `(Module, Fn)`, looks up `kernelToRust`, and emits a direct kernel call (eliminating the indirection through a nonexistent `ffi_call_pure` symbol). `Ffi.toAny` becomes compile-time identity inside matched contexts. (2) A `runtimeOpaqueTypes` registry that swaps the placeholder enum stub for `pub use sky_runtime::<RustType> as <CodegenName>;` when an opaque Sky type is backed by a runtime newtype. Both are Rust-target-gated; Go path byte-identical.

**Tech Stack:** Haskell (GHC 9.4.8) compiler code; Rust 1.x runtime; `cabal test` for codegen tests; `examples/00-standard-libs` + `examples/rust/*` as integration tests.

**Source spec:** `docs/superpowers/specs/2026-05-29-rust-codegen-ffi-callpure-opaque-types-design.md`

---

## Preconditions

- Branch: `feat/runtime-rust` (HEAD `7e1302e5` after the spec commit).
- `mem-guard.sh` running.
- Clean working tree.
- `cabal build exe:sky` currently green.
- `sky-out/sky --version` prints `sky dev`.

## File Structure

This work touches four files. No new files are created.

| File | Responsibility | Edits |
|---|---|---|
| `src/Sky/Generate/Rust/Builder.hs` | All compile-time Rust codegen | Tasks 1, 3, 5, 6 — add `runtimeOpaqueTypes`, peephole arms in call emission, opaque-type emission swap |
| `runtime-rust/src/sky_runtime/mod.rs` (source) | Runtime module index | Task 2 — declare new `ffi_polyfills` module |
| `runtime-rust/src/sky_runtime/ffi_polyfills.rs` | Runtime panic stubs for non-peephole-matched `Ffi.callPure` calls + identity `ffi_to_any_polyfill` | Task 2 (new file) |
| `src/Sky/Generate/Rust/Project.hs` | Generated-`mod.rs` declarations | Task 2 — add `pub mod ffi_polyfills;` + `pub use` to the hardcoded baseMods/baseUse |
| `docs/runtime-rust/sub-A-stdlib-parity-result.md` | Status doc | Task 9 — record what shipped + headline-gate outcome |

---

## Task 0: Investigation — pin the two unknown insert sites

**Files:**
- Read: `src/Sky/Generate/Rust/Builder.hs` (large; targeted searches)

**Outputs:**
- Exact `file:line` for where `Can.Call` (or equivalent app node) is dispatched in the Rust call-emission path — the peephole inserts here (used by Tasks 3 + 4).
- Exact `file:line` for the opaque-type placeholder emission (`pub enum … { __Internal(f64) }`) — registry swap inserts here (used by Task 6).
- One Sky-test fixture to confirm the AST shape `Ffi.callPure` lands in after canonicalisation (important for Task 3's pattern match).

- [ ] **Step 1: Locate the call-emission entry point**

Run from repo root:
```bash
grep -n "Can.Call" src/Sky/Generate/Rust/Builder.hs | head -40
grep -n "Can\.VarTopLevel" src/Sky/Generate/Rust/Builder.hs | head -20
grep -n "emitExpr\|emitCall\|exprToRust" src/Sky/Generate/Rust/Builder.hs | head -20
```
Expected: a few hits centred on one function (likely named `emitExpr`, `exprToRust`, or `exprToRustExpr`). That function's `Can.Call` arm is where the peephole goes — record its line number.

- [ ] **Step 2: Locate the opaque-type placeholder emission**

```bash
grep -n "__Internal" src/Sky/Generate/Rust/Builder.hs
grep -n "Decimal__Internal\|f64.*placeholder\|userType\|opaqueType" src/Sky/Generate/Rust/Builder.hs | head -20
grep -n "pub enum " src/Sky/Generate/Rust/Builder.hs | head -20
```
Expected: one location emits the `pub enum <Name> { <Tag>__Internal(f64) }` template. Record its line number and the surrounding function name (likely `userTypeSection`, `emitTypeDecl`, or similar).

- [ ] **Step 3: Confirm the canonicalised AST shape of `Ffi.callPure`**

```bash
grep -n "callPure\|callTask\|toAny" src/Sky/Type/Constrain/Expression.hs
grep -n "Can.VarTopLevel\|Can.VarKernel\|Can.VarForeign" src/Sky/AST/Canonical.hs | head -20
```
Look for how `Ffi.callPure` is constructed in the Can AST. Most likely it lands as a `Can.Call` with the callee being a `Can.VarTopLevel "Ffi" "callPure"` or `Can.VarKernel`. Record the exact constructor name and shape — Task 3's pattern match keys on this.

- [ ] **Step 4: Verify the string-literal AST constructor**

```bash
grep -n "CString\|StringLit\|Can.Str " src/Sky/AST/Canonical.hs | head -20
grep -n "Can.List \|ListLit\|CList " src/Sky/AST/Canonical.hs | head -20
```
Record the exact constructor names for `String` literals and `List` literals in `Can` — Task 3 pattern-matches against these.

- [ ] **Step 5: Write a one-page investigation note**

Create `docs/runtime-rust/task-0-investigation-notes.md` with:
- `Builder.hs:NNN` — call-emission entry function name and the `Can.Call` line (peephole inserts here)
- `Builder.hs:MMM` — opaque-type emission function name and the `pub enum` line (registry swap inserts here)
- The exact `Can.Call` AST shape for `Ffi.callPure "X" [args]` (callee constructor + args list)
- The exact `Can.Str` / `Can.List` constructor names

- [ ] **Step 6: Commit**

```bash
git add docs/runtime-rust/task-0-investigation-notes.md
git commit -m "docs(rust): Task 0 — investigation notes for codegen-completion plan

Pins the Builder.hs insertion points for the Ffi.callPure peephole and
the runtimeOpaqueTypes registry swap, plus the Can.Call AST shape for
Ffi.callPure post-canonicalisation."
```

---

## Task 1: Add `kernelToRust` polyfill arms for the three Ffi entries

**Files:**
- Modify: `src/Sky/Generate/Rust/Builder.hs` — `kernelToRust` table (around line 1842, near the existing `("Ffi", "kernel") -> "ffi_kernel_polyfill"` arm)

**Purpose:** Ensure that any non-peephole-matched `Ffi.callPure` / `Ffi.callTask` / `Ffi.toAny` call falls through to the runtime polyfill symbols (added in Task 2) instead of the broken snake-case default `ffi_call_pure` / `ffi_call_task` / `ffi_to_any`.

- [ ] **Step 1: Add the three arms**

In `Builder.hs`, at the existing `("Ffi", "kernel") -> "ffi_kernel_polyfill"` arm, add directly below:

```haskell
        ("Ffi", "callPure") -> "ffi_call_pure_polyfill"
        ("Ffi", "callTask") -> "ffi_call_task_polyfill"
        ("Ffi", "toAny")    -> "ffi_to_any_polyfill"
```

- [ ] **Step 2: Verify the compiler still builds**

```bash
cabal build exe:sky 2>&1 | tail -5
```
Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add src/Sky/Generate/Rust/Builder.hs
git commit -m "feat(rust): kernelToRust arms for Ffi.callPure/callTask/toAny → polyfills

Routes the three Ffi entries that previously fell through the snake-case
default to named polyfill symbols (implemented in the next commit). The
peephole rewriter (subsequent commit) handles the common case of
literal-string kernel name + literal-list args directly; the polyfills
are only reached for dynamic-dispatch shapes that aren't statically
resolvable."
```

---

## Task 2: Add runtime polyfill stubs

**Files:**
- Create: `runtime-rust/src/sky_runtime/ffi_polyfills.rs`
- Modify: `runtime-rust/src/sky_runtime/mod.rs` — declare the new module
- Modify: `src/Sky/Generate/Rust/Project.hs` — `baseMods` / `baseUse` lists (lines 78-93)

**Purpose:** Provide the three runtime symbols `ffi_call_pure_polyfill`, `ffi_call_task_polyfill`, `ffi_to_any_polyfill` so any code path reaching them (only non-peephole-matched cases) gets an actionable panic instead of a link error.

- [ ] **Step 1: Write the polyfill file**

Create `runtime-rust/src/sky_runtime/ffi_polyfills.rs` with:

```rust
// Ffi.* polyfill stubs.
//
// The Rust codegen's peephole rewriter handles the static-dispatch shape of
// `Ffi.callPure "<Kernel>" [args]` (kernel name + args list both literal) by
// emitting a direct kernel call. These polyfills only get linked when a
// non-static-dispatch shape appears in user code — they fail loud with an
// actionable message so the user can refactor to the static shape (or use
// `Ffi.kernel` for value-level kernel selection).

/// Identity wrapper. Matches `Ffi.toAny`'s static signature `a -> any` but
/// performs no type erasure at runtime — the codegen retains concrete types.
/// Only reached when `Ffi.toAny` appears outside a peephole-matched
/// `Ffi.callPure` argument list.
pub fn ffi_to_any_polyfill<T>(x: T) -> T {
    x
}

/// Reached only when `Ffi.callPure` is invoked with a non-literal kernel
/// name or non-literal args list (i.e. dynamic dispatch). Sky's static
/// dispatch path is the peephole — refactor the call site to use a string
/// literal + list literal, or use `Ffi.kernel "<Name>"` for value-level
/// kernel selection.
pub fn ffi_call_pure_polyfill<T, A>(name: String, _args: Vec<A>) -> T {
    panic!(
        "Ffi.callPure {:?}: dynamic dispatch is not supported on target=rust. \
         Use a string-literal kernel name + list-literal args (peephole-resolved \
         at compile time), or `Ffi.kernel \"{}\"` for value-level kernel selection.",
        name, name
    );
}

/// Same shape as ffi_call_pure_polyfill but for the Task-returning variant.
/// `Ffi.callTask` Rust-target support is deferred to sub-project D
/// (Sky.Http.Server, which needs Task-emitting kernels).
pub fn ffi_call_task_polyfill<T, A>(name: String, _args: Vec<A>) -> T {
    panic!(
        "Ffi.callTask {:?}: not yet supported on target=rust (sub-project D). \
         Use target=go for now, or move the Task-returning kernel into a \
         non-Task Ffi.callPure call.",
        name
    );
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn to_any_is_identity_i64() {
        assert_eq!(ffi_to_any_polyfill::<i64>(42), 42);
    }

    #[test]
    fn to_any_is_identity_string() {
        assert_eq!(ffi_to_any_polyfill::<String>("hi".to_string()), "hi".to_string());
    }

    #[test]
    #[should_panic(expected = "Ffi.callPure")]
    fn call_pure_panics_with_kernel_name() {
        let _: i64 = ffi_call_pure_polyfill::<i64, i64>("Decimal_fromInt".to_string(), vec![1]);
    }

    #[test]
    #[should_panic(expected = "sub-project D")]
    fn call_task_panics_with_sub_d_hint() {
        let _: i64 = ffi_call_task_polyfill::<i64, i64>("Http_get".to_string(), vec![1]);
    }
}
```

- [ ] **Step 2: Declare the module in the source `mod.rs`**

Edit `runtime-rust/src/sky_runtime/mod.rs`. After the existing `pub mod decimal;` line, add:

```rust
pub mod ffi_polyfills;
```

And under the corresponding `pub use ...::*;` block, add:

```rust
pub use ffi_polyfills::*;
```

(If the source `mod.rs` doesn't have explicit `pub use` lines because it's only the source-of-record for the runtime's own tests, just `pub mod` is enough — the compiler-generated `mod.rs` is what user builds consume.)

- [ ] **Step 3: Update the compiler-generated `mod.rs` builder**

Edit `src/Sky/Generate/Rust/Project.hs`, lines 78-93. The `baseMods` list currently ends with `,"pub mod decimal;"]`. Add `ffi_polyfills`:

```haskell
        baseMods = ["// GENERATED by Sky compiler — do not edit"
                   ,"pub mod config;","pub mod core;","pub mod task;"
                   ,"pub mod log;","pub mod system;","pub mod time;"
                   ,"pub mod random;","pub mod file;","pub mod crypto;"
                   ,"pub mod json;"
                   ,"pub mod encoding;","pub mod regex_kernel;","pub mod jwt;"
                   ,"pub mod decimal;"
                   ,"pub mod ffi_polyfills;"]
```

And to `baseUse`, after `"pub use decimal::*;"`:

```haskell
        baseUse = [..., "pub use decimal::*;"
                       ,"pub use ffi_polyfills::*;"]
```

- [ ] **Step 4: Verify Rust runtime tests pass**

```bash
cd runtime-rust && cargo test --lib ffi_polyfills 2>&1 | tail -20
```
Expected: 4 tests pass (`to_any_is_identity_i64`, `to_any_is_identity_string`, `call_pure_panics_with_kernel_name`, `call_task_panics_with_sub_d_hint`).

- [ ] **Step 5: Verify the compiler still builds**

```bash
cd /home/arthur/Documentos/comp/sky && cabal build exe:sky 2>&1 | tail -5
```
Expected: build succeeds.

- [ ] **Step 6: Commit**

```bash
git add runtime-rust/src/sky_runtime/ffi_polyfills.rs \
        runtime-rust/src/sky_runtime/mod.rs \
        src/Sky/Generate/Rust/Project.hs
git commit -m "feat(rust): Ffi.callPure/callTask/toAny runtime polyfill stubs

ffi_to_any_polyfill: compile-time identity (a -> a). Matches Ffi.toAny's
static signature; only reached when toAny is used outside a peephole-
matched callPure context.

ffi_call_pure_polyfill: actionable panic naming the kernel and pointing
the user at the peephole-eligible form or Ffi.kernel.

ffi_call_task_polyfill: actionable panic naming sub-project D as the
ETA for Task-returning kernels on target=rust.

Declared in source mod.rs and added to the compiler-generated mod.rs
builder in Project.hs (baseMods + baseUse). 4 runtime tests pass."
```

---

## Task 3: Peephole rewriter for `Ffi.callPure "<KernelName>" [args]`

**Files:**
- Modify: `src/Sky/Generate/Rust/Builder.hs` at the `Can.Call` arm identified in Task 0 (call this `Builder.hs:NNN`)

**Purpose:** When the codegen encounters the AST shape `Ffi.callPure` applied to a literal string + literal list, parse the kernel name as `(Module, Fn)`, look up `kernelToRust`, and emit a direct call. Otherwise fall through to the existing path (which routes through the polyfill via Task 1's arm).

- [ ] **Step 1: Write a fixture test FIRST**

Add a test to `test/Sky/Build/RustCodegenSpec.hs` (or create it if absent — check `test/Sky/Build/` for the existing pattern, mirror an existing codegen spec like `FfiGenSpec.hs`). The test compiles a tiny Sky program that exercises `Ffi.callPure` with a literal kernel name and asserts the generated Rust contains the direct kernel call.

```haskell
-- test/Sky/Build/RustCodegenSpec.hs additions (or new file)
describe "Ffi.callPure peephole" $ do
    it "rewrites Ffi.callPure \"Decimal_fromInt\" [n] to decimal_from_int(n)" $ do
        let sky = unlines
                [ "module M exposing (..)"
                , "import Sky.Core.Prelude exposing (..)"
                , ""
                , "f : Int -> StdDecimalDecimal"   -- opaque-type token (Task 5/6 makes it work)
                , "f n = Ffi.callPure \"Decimal_fromInt\" [ n ]"
                ]
        rust <- compileSkyToRust sky
        rust `shouldContain` "decimal_from_int(n)"
        rust `shouldNotContain` "ffi_call_pure"

    it "rewrites Ffi.callPure with multiple literal args" $ do
        let sky = unlines
                [ "module M exposing (..)"
                , "import Sky.Core.Prelude exposing (..)"
                , ""
                , "g : Int -> StdDecimalDecimal -> String"
                , "g places d = Ffi.callPure \"Decimal_toStringFixed\""
                , "                  [ Ffi.toAny places, Ffi.toAny d ]"
                ]
        rust <- compileSkyToRust sky
        rust `shouldContain` "decimal_to_string_fixed(places, d)"
        rust `shouldNotContain` "ffi_to_any"
        rust `shouldNotContain` "ffi_call_pure"

    it "falls through to polyfill for non-literal kernel name" $ do
        let sky = unlines
                [ "module M exposing (..)"
                , "import Sky.Core.Prelude exposing (..)"
                , ""
                , "h : String -> Int"
                , "h k = Ffi.callPure k []"        -- k is a variable, not a literal
                ]
        rust <- compileSkyToRust sky
        rust `shouldContain` "ffi_call_pure_polyfill"
```

If `compileSkyToRust` doesn't already exist as a test helper, add one mirroring whatever the Go side uses (probably a wrapper around the same `RustBuilder.buildProgram` + `emitRust` pipeline Project.hs calls).

- [ ] **Step 2: Run the test to verify it fails**

```bash
cabal test --test-options='--match "Ffi.callPure peephole"' 2>&1 | tail -20
```
Expected: 3 failures (the rewriter doesn't exist yet — generated Rust still has `ffi_call_pure(...)`).

- [ ] **Step 3: Implement the peephole**

In `Builder.hs` at the `Can.Call` arm (line from Task 0 — call it `NNN`), wrap the existing dispatch:

```haskell
-- TEMPLATE — the exact Can constructors come from Task 0's investigation notes.
-- Below uses the most likely shape; adapt to actual constructor names.

emitExpr ctx (Can.Call (Can.VarTopLevel modName "callPure")
                       [Can.Str kernelName, Can.List argExprs])
    | modName == ffiModule =                         -- ffiModule = the canonical "Ffi" module identity
        let (skyMod, skyFn) = parseKernelName kernelName  -- "Decimal_fromInt" -> ("Decimal", "fromInt")
            rustFn = kernelToRust skyMod skyFn
            args   = map (peepholeToAny ctx) argExprs
        in rustFn ++ "(" ++ List.intercalate ", " args ++ ")"

-- Existing Can.Call arm continues unchanged below this new arm:
emitExpr ctx (Can.Call …) = …
```

Plus the helpers:

```haskell
-- | Split a kernel name "Decimal_fromInt" into ("Decimal", "fromInt").
-- The first underscore is the module/fn boundary; subsequent underscores
-- stay in the function name. Decimal_toStringFixed → ("Decimal", "toStringFixed").
parseKernelName :: String -> (String, String)
parseKernelName s = case break (== '_') s of
    (m, '_' : f) -> (m, f)
    (m, "")      -> (m, "")   -- malformed; kernelToRust returns the snake-cased default

-- | When emitting an arg inside a matched peephole, Ffi.toAny x collapses to
-- just x (the value retains its concrete type). All other shapes route to the
-- standard expression emit.
peepholeToAny :: CodegenCtx -> Can.Expr -> String
peepholeToAny ctx (Can.Call (Can.VarTopLevel m "toAny") [inner])
    | m == ffiModule = emitExpr ctx inner
peepholeToAny ctx e  = emitExpr ctx e
```

The exact constructor names (`Can.Call`, `Can.VarTopLevel`, `Can.Str`, `Can.List`) come from Task 0's investigation. Adapt as needed — the shape is unchanged: pattern-match on the literal AST, parse, emit, fall through to the existing arm for everything else.

- [ ] **Step 4: Run the test to verify it passes**

```bash
cabal test --test-options='--match "Ffi.callPure peephole"' 2>&1 | tail -20
```
Expected: 3 passes.

- [ ] **Step 5: Verify nothing else broke**

```bash
cabal test --test-options='--match "FfiGen" --match "Toml" --match "Kernel"' 2>&1 | tail -10
```
Expected: prior pass count, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add src/Sky/Generate/Rust/Builder.hs test/Sky/Build/RustCodegenSpec.hs
git commit -m "feat(rust): Ffi.callPure peephole — direct kernel call from literal name+args

Recognises Ffi.callPure (StringLit \"<KernelName>\") (ListLit args) at the
call-emission site in Builder.hs. Parses <KernelName> as (Module, Fn) on
the first '_', looks up kernelToRust, emits the resolved kernel name with
the args spliced inline. Ffi.toAny inside a matched args list collapses to
identity (the value retains its concrete Rust type).

Non-matched shapes (variable kernel name, non-literal args list) fall
through to the existing call path, which now routes to the panicking
polyfill via the kernelToRust arm added in the prior commit.

3 new codegen tests cover: single-arg literal, multi-arg with toAny,
fall-through to polyfill for variable name."
```

---

## Task 4: Free-standing `Ffi.toAny` peephole

**Files:**
- Modify: `src/Sky/Generate/Rust/Builder.hs` — extend the call-emission `Can.Call` arms

**Purpose:** `Ffi.toAny` already collapses to identity inside a matched `Ffi.callPure` (via `peepholeToAny` from Task 3). But user code can also call `Ffi.toAny x` outside that context — `let erased = Ffi.toAny 42 in ...`. In that case the kernel routes to `ffi_to_any_polyfill` (Task 1's arm + Task 2's runtime stub), which IS compile-time identity. That's correct — but we can save a function call by also peephole-collapsing free-standing `Ffi.toAny` calls to bare emission.

- [ ] **Step 1: Write the fixture test**

Add to `test/Sky/Build/RustCodegenSpec.hs`:

```haskell
    it "collapses standalone Ffi.toAny x to bare x" $ do
        let sky = unlines
                [ "module M exposing (..)"
                , "import Sky.Core.Prelude exposing (..)"
                , ""
                , "wrap : Int -> Int"
                , "wrap n = Ffi.toAny n"
                ]
        rust <- compileSkyToRust sky
        rust `shouldNotContain` "ffi_to_any"
        rust `shouldContain` "wrap"
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cabal test --test-options='--match "collapses standalone Ffi.toAny"' 2>&1 | tail -10
```
Expected: 1 failure (output still contains `ffi_to_any_polyfill(n)`).

- [ ] **Step 3: Add a top-level peephole arm before the polyfill fallthrough**

In `Builder.hs`, at the `Can.Call` arm (same area as Task 3), add ABOVE the existing dispatch but BELOW the callPure peephole:

```haskell
emitExpr ctx (Can.Call (Can.VarTopLevel m "toAny") [inner])
    | m == ffiModule = emitExpr ctx inner
```

This sits between Task 3's callPure peephole and the existing fall-through.

- [ ] **Step 4: Run the test to verify it passes**

```bash
cabal test --test-options='--match "collapses standalone Ffi.toAny"' 2>&1 | tail -10
```
Expected: pass.

- [ ] **Step 5: Re-run the prior codegen tests**

```bash
cabal test --test-options='--match "Ffi.callPure peephole" --match "Ffi.toAny"' 2>&1 | tail -15
```
Expected: 4 passes, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add src/Sky/Generate/Rust/Builder.hs test/Sky/Build/RustCodegenSpec.hs
git commit -m "feat(rust): collapse standalone Ffi.toAny x to bare x in Rust codegen

Outside a peephole-matched Ffi.callPure args list, Ffi.toAny used to route
to ffi_to_any_polyfill which is compile-time identity. The function call
is correct but pointless — the value retains its concrete type either way.
This adds a top-level Can.Call arm that pattern-matches Ffi.toAny and
emits the inner expression directly, avoiding the polyfill hop entirely.

The polyfill remains in place as a safety net for any indirect reference
(value-level partial application of Ffi.toAny, etc.)."
```

---

## Task 5: `runtimeOpaqueTypes` registry

**Files:**
- Modify: `src/Sky/Generate/Rust/Builder.hs` — add the registry near the top of the module, alongside `kernelToRust`

**Purpose:** Hold the mapping `(SkyModule, SkyType) → "sky_runtime::<RustType>"` so Task 6 can look up whether to emit the placeholder enum or the `pub use` alias. Single entry for sub-A; sub-projects B-F extend.

- [ ] **Step 1: Add the registry definition**

Near `kernelToRust` in `Builder.hs`, add:

```haskell
-- | Sky opaque types whose Rust representation lives in `sky_runtime`.
-- When the codegen would otherwise emit a placeholder enum
-- `pub enum <CodegenName>Stub { __Internal(f64) }`, look up
-- `(skyModule, skyType)` here. A `Just rustPath` directs the emission
-- to `pub use <rustPath> as <codegenName>;` instead — the runtime's
-- type IS the canonical representation.
--
-- Sub-projects B-F add entries here as their runtime types land.
runtimeOpaqueTypes :: Map.Map (String, String) String
runtimeOpaqueTypes = Map.fromList
    [ (("Std.Decimal", "Decimal"), "sky_runtime::Decimal")
    ]
```

Make sure `Data.Map.Strict as Map` is imported — if it isn't, add it. (Check the existing imports first; if `Map` is unused in this module, add `import qualified Data.Map.Strict as Map` at the top alongside the other qualified imports.)

- [ ] **Step 2: Verify the compiler still builds**

```bash
cabal build exe:sky 2>&1 | tail -5
```
Expected: build succeeds (the registry is unused until Task 6 wires it up — Haskell allows unused top-level bindings).

- [ ] **Step 3: Commit**

```bash
git add src/Sky/Generate/Rust/Builder.hs
git commit -m "feat(rust): runtimeOpaqueTypes registry — single entry for Std.Decimal

Adds the compile-time map (SkyModule, SkyType) -> 'sky_runtime::<Rust>' that
the opaque-type emission path (next commit) consults. One entry to start:
(Std.Decimal, Decimal) -> sky_runtime::Decimal. Sub-projects B-F extend as
their runtime newtypes land."
```

---

## Task 6: Hook the registry into the opaque-type emission path

**Files:**
- Modify: `src/Sky/Generate/Rust/Builder.hs` at the placeholder-emission location identified in Task 0 (call this `Builder.hs:MMM`)

**Purpose:** When emitting an opaque type, look up `(skyModule, skyType)` in `runtimeOpaqueTypes`. If present, emit `pub use <rustPath> as <codegenName>;` instead of the placeholder enum.

- [ ] **Step 1: Write the fixture test**

Add to `test/Sky/Build/RustCodegenSpec.hs`:

```haskell
describe "runtimeOpaqueTypes" $ do
    it "emits pub use sky_runtime::Decimal as StdDecimalDecimal for Std.Decimal.Decimal" $ do
        let sky = unlines
                [ "module Std.Decimal exposing (..)"
                , ""
                , "type Decimal"             -- opaque (no constructors)
                ]
        rust <- compileSkyToRust sky
        rust `shouldContain` "pub use sky_runtime::Decimal as StdDecimalDecimal;"
        rust `shouldNotContain` "pub enum StdDecimalDecimal"
        rust `shouldNotContain` "__Internal(f64)"

    it "still emits placeholder enum for unregistered opaque types" $ do
        let sky = unlines
                [ "module MyApp.Token exposing (..)"
                , ""
                , "type Token"
                ]
        rust <- compileSkyToRust sky
        rust `shouldContain` "pub enum MyAppTokenToken"
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cabal test --test-options='--match "runtimeOpaqueTypes"' 2>&1 | tail -15
```
Expected: first test fails (output still has `pub enum StdDecimalDecimal { __Internal(f64) }`).

- [ ] **Step 3: Branch the emission**

At `Builder.hs:MMM` (the function that emits the placeholder), find the branch that produces the `pub enum <Name> { ... }` template. Add the registry lookup:

```haskell
-- TEMPLATE — the function signature and exact names come from Task 0.
-- Below shows the structural change.

emitOpaqueTypeDecl :: (String, String) -> String -> String
emitOpaqueTypeDecl (skyMod, skyTy) codegenName =
    case Map.lookup (skyMod, skyTy) runtimeOpaqueTypes of
        Just rustPath ->
            "pub use " ++ rustPath ++ " as " ++ codegenName ++ ";"
        Nothing ->
            -- Existing placeholder template, unchanged:
            "pub enum " ++ codegenName ++ " {\n" ++
            "    " ++ skyTy ++ "__Internal(f64)\n" ++
            "}"
```

If the emission isn't structured as a single function returning a single string, adapt — the registry check is one `Map.lookup` and a branch; the placeholder path is whatever was there before.

- [ ] **Step 4: Run the tests to verify both pass**

```bash
cabal test --test-options='--match "runtimeOpaqueTypes"' 2>&1 | tail -15
```
Expected: 2 passes.

- [ ] **Step 5: Run the full codegen-spec suite**

```bash
cabal test --test-options='--match "FfiGen" --match "Toml" --match "Kernel" --match "RustCodegen"' 2>&1 | tail -15
```
Expected: prior count + new tests, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add src/Sky/Generate/Rust/Builder.hs test/Sky/Build/RustCodegenSpec.hs
git commit -m "feat(rust): bridge runtime-provided opaque types via registry lookup

When emitting an opaque Sky type, Builder.hs now looks up (skyModule,
skyType) in runtimeOpaqueTypes. Hit -> 'pub use sky_runtime::<Rust> as
<CodegenName>;' alias. Miss -> placeholder 'pub enum <Name> { __Internal(f64) }'
exactly as before.

Std.Decimal.Decimal now becomes a true type alias to sky_runtime::Decimal
(the rust_decimal newtype), so kernel return types and codegen-emitted
signatures match and arbitrary-precision arithmetic actually works end-to-end."
```

---

## Task 7: Rebuild the compiler binary + Rust-example regression sweep

**Files:** None modified — verification only.

**Purpose:** Confirm the changes don't break any of the 16 working Rust examples.

- [ ] **Step 1: Rebuild the compiler**

```bash
cabal install --overwrite-policy=always --installdir=./sky-out --install-method=copy exe:sky 2>&1 | tail -5
./sky-out/sky --version
```
Expected: `sky dev`.

- [ ] **Step 2: Clean-build every Rust example**

```bash
set -e
for d in examples/rust/*/; do
    echo "=== $d ==="
    (cd "$d" && rm -rf sky-out .skycache .skydeps && ../../../sky-out/sky build src/Main.sky) || { echo "FAIL: $d"; exit 1; }
done
echo "All 16 Rust examples built clean."
```
Expected: every example builds, final line printed.

- [ ] **Step 3: Run each Rust example and capture output**

```bash
set -e
for d in examples/rust/*/; do
    bin="$d/sky-out/Rust/target/debug/sky-app"
    if [ -x "$bin" ]; then
        echo "=== $d ==="
        timeout 10s "$bin" 2>&1 | head -5 || echo "(timeout or non-zero exit)"
    fi
done
```
Expected: each prints its expected `OK -> …` (or equivalent — match what was in the prior status doc).

- [ ] **Step 4: Verify Go regression**

```bash
cd examples/01-hello-world && rm -rf sky-out .skycache && ../../sky-out/sky build src/Main.sky 2>&1 | tail -3
cd ../..
```
Expected: `Build complete: sky-out/app`.

- [ ] **Step 5: Run the targeted cabal-test sweep**

```bash
cabal test --test-options='--match "FfiGen" --match "Toml" --match "Kernel" --match "RustCodegen"' 2>&1 | tail -10
```
Expected: 0 failures.

No commit (pure verification).

---

## Task 8: Headline gate — `examples/00-standard-libs` on `target=rust`

**Files:**
- Modify (temporarily): `examples/00-standard-libs/sky.toml` — set `target = "rust"` for the test run
- Modify: `docs/runtime-rust/sub-A-stdlib-parity-result.md` — record the outcome

**Purpose:** The contractual sub-A acceptance criterion. The Crypto/Jwt/Encoding/Std.Decimal/Std.Time/Std.Money suites must produce the same per-test outcomes as `target=go`.

- [ ] **Step 1: Capture target=go baseline**

```bash
cd examples/00-standard-libs && rm -rf sky-out .skycache
../../sky-out/sky run src/Main.sky 2>&1 | tee /tmp/sub-A-go-baseline.txt | tail -40
cd ../..
```
Save the per-suite pass/fail lines from `/tmp/sub-A-go-baseline.txt` — these are the targets for target=rust.

- [ ] **Step 2: Switch the example to target=rust**

Edit `examples/00-standard-libs/sky.toml` and add `target = "rust"` under `[project]` (or whichever section is the live one — check the file first). Save.

- [ ] **Step 3: Clean and run on target=rust**

```bash
cd examples/00-standard-libs && rm -rf sky-out .skycache
../../sky-out/sky run src/Main.sky 2>&1 | tee /tmp/sub-A-rust-result.txt | tail -60
cd ../..
```

- [ ] **Step 4: Diff the suites we promised parity on**

Compare `/tmp/sub-A-go-baseline.txt` and `/tmp/sub-A-rust-result.txt`. For each of the in-scope suites (String, List, Dict, Maybe, Result, Math, Crypto, Jwt, Encoding, Json, Std.Decimal, Std.Money, Std.Time), the pass/fail outcome must match.

Out-of-scope suites are EXPECTED to fail (Std.Auth → sub-C; Std.Db → sub-B; Live → sub-E; etc.). Those are documented exceptions, not regressions.

- [ ] **Step 5: Restore the example**

Revert the `sky.toml` edit so the example sweep and CI default behaviour is preserved:

```bash
cd examples/00-standard-libs && git checkout sky.toml && cd ../..
```

Verify with `git diff` that only `sky.toml` (now unmodified) is touched.

- [ ] **Step 6: Update the status doc with the result**

Edit `docs/runtime-rust/sub-A-stdlib-parity-result.md`. Replace the "Integration gap discovered at the headline gate (Task 17)" + "Investigation results" sections with a "Headline gate result" section listing:
- Suites at parity (with pass counts)
- Suites with expected sub-B/C/D/E/F failures (each listing the sub-project that covers them)
- Compiler binary version + commit SHA
- Date

- [ ] **Step 7: Commit**

```bash
git add docs/runtime-rust/sub-A-stdlib-parity-result.md
git commit -m "docs(rust): sub-A headline gate result — codegen completion landed

The codegen-completion plan (Tasks 0-9, peephole + opaque-type registry)
closed the two integration gaps. examples/00-standard-libs on target=rust
now matches target=go on the in-scope suites: <list>. Suites covered by
later sub-projects (Std.Auth -> C, Std.Db -> B, etc.) still fail with the
expected 'not yet implemented' errors — that's the boundary, not a
regression.

Sub-project A is complete."
```

---

## Task 9: Final cleanup + push

**Files:** None.

**Purpose:** Background-task hygiene + push the branch.

- [ ] **Step 1: Background-task hygiene**

```bash
# Orphan polling loops
ps -u $USER -o pid,command | awk '/while pgrep|until ! pgrep/ && /\/bin\/zsh -c/ {print $1}' | xargs -n1 kill -9 2>/dev/null
# Stray sleeps + verification leftovers
ps -u $USER -o pid,ppid,command | awk '$3 == "sleep" && $2 != 1 {print $1}' | xargs -n1 kill -9 2>/dev/null
pkill -f "examples/.*/sky-out/app" 2>/dev/null
# mem-guard alive?
pgrep -f mem-guard.sh >/dev/null || (nohup ./scripts/mem-guard.sh > /tmp/mem-guard.out 2>&1 & disown)
```

- [ ] **Step 2: Verify clean state**

```bash
git status --short
git log --oneline feat/runtime-rust ^origin/feat/runtime-rust
```
Expected: clean tree, the Task 0-9 commits listed.

- [ ] **Step 3: Push**

**Per project CLAUDE.md: never push unless the user explicitly asks.** Surface the unpushed commit list to the user with a one-line summary and wait for an explicit "push" before running `git push`.

---

## Self-review (per the writing-plans skill)

**Spec coverage:**
- Spec §5.1 (Issue 2 peephole) → Tasks 1, 2, 3, 4 ✅
- Spec §5.2 (Issue 3 registry) → Tasks 5, 6 ✅
- Spec §6 (soundness gate — additive arms) → enforced by Tasks 3, 4, 6 leaving existing arms untouched ✅
- Spec §7 (Task 0 investigation precondition) → Task 0 ✅
- Spec §8 (verification: codegen tests, regression sweep, headline gate, status doc) → Tasks 3/4/6 (tests), 7 (regression), 8 (gate + doc) ✅
- Spec §10 (cross-backend safety — only Rust files) → enforced by the file list at the top of this plan ✅

**Placeholder scan:**
- Task 0 produces concrete file:line outputs used by Tasks 3 + 6 — not a placeholder, an explicit dependency
- Tasks 3 and 6 contain code TEMPLATES with the constructor names parametric on Task 0's findings — this is necessary because the AST constructors aren't pinned in the spec; the alternative would be to read Builder.hs in full before writing the plan, which Task 0 does exactly. ✅

**Type consistency:**
- `kernelToRust` arms in Task 1 (`ffi_call_pure_polyfill` etc.) match the function names defined in Task 2's polyfill file ✅
- `runtimeOpaqueTypes` keyed on `(String, String)` in Task 5 matches the lookup in Task 6 ✅
- `compileSkyToRust` test helper used in Tasks 3, 4, 6 — flagged as needing creation if not present (Task 3, Step 1)

No gaps found.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-05-29-rust-codegen-ffi-callpure-opaque-types.md`. Two execution options:

**1. Subagent-Driven (recommended)** — dispatch a fresh subagent per task, controller-side review between tasks. Tasks 0, 7, 8, 9 stay controller-side (investigation + verification + push); Tasks 1-6 are subagent-dispatched with sonnet.

**2. Inline Execution** — execute all tasks in this session using executing-plans.

Which approach?
