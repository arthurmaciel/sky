# Closures/HOFs auto-FFI — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bind a Rust FFI fn/method that takes a closure argument so a Sky lambda passes across the boundary — zero hand stubs, sound by construction, misuse → first-class Sky `E4400`.

**Architecture:** Reuses the Wall #2 (A)-model: one rustc-monomorphised generic wrapper per fn. New work — represent a closure arg in the typed `Call` AST (`TRClosure`); render the wrapper param as `<Fj: Fn(..)->R + Clone>`; gate the call-site Sky lambda on a **positive `Clone`-allowlist** over each capture's monomorphised type (NOT the `ecNoCloneVars` denylist — guardian REJECT); wrap the adaptor call in `catch_unwind`; owned-clone bridge for `Fn(&A)` params; inspector emits closure metadata.

**Tech Stack:** Haskell (GHC 9.4, the Sky compiler), Rust (the runtime + `sky-ffi-inspect-rs`), Aeson (kernel.json), Hspec (`--match` targeted), the fixture runner `runtime-rust/scripts/ffi-fixtures-test.sh`.

**Source of truth:** `runtime-rust/docs/superpowers/specs/2026-06-22-rust-ffi-closures-design.md` (guardian-cleared APPROVE-WITH-CONSTRAINTS; constraints B1–B5).

**Sequencing:** Land AFTER #22 (borrowed-ref owned-copy, in flight). **Disk-constrained box:** light local verify only — `cabal build exe:sky` (symlink `sky-out/sky` to the dist-newstyle binary, NEVER `--install-method=copy`), targeted `--match` specs, ONE fixture build. Full suite + real-crate proof on CI. `export PATH="$HOME/.ghcup/bin:$HOME/.cargo/bin:$PATH"` + `CARGO_TARGET_DIR` + `sccache` before any Rust build. Guardian-final on the diff before commit (settled rule).

**Boundary:** Shared/epic-authorized: `FfiCall.hs`, `FfiInstance.hs`, `Ffi.hs`, `Compile.hs`, `Project.hs`, `Sky.Reporting`. Rust: `tools/sky-ffi-inspect-rs/src/main.rs`, the fixture. NEVER: the Go inspector, `src/Sky/Generate/Go/`, `runtime-go/`, `sky-stdlib/`, author `examples/`.

---

## File structure

| File | Responsibility | Action |
|---|---|---|
| `runtime-rust/tests/sky/49-ffi-closures/` | Executable spec: hand-stub crate + kernel.json + Main.sky + setup.sh | Create |
| `src/Sky/Build/Rust/FfiCall.hs` | `TRClosure` TypeRef variant; parse + render a closure arg as `<Fj: …>` | Modify |
| `src/Sky/Build/Rust/FfiInstance.hs` | Positive `Clone`-allowlist (`rustTypeIsClone`); closure bindability + capture-gate `E4400`; wrapper synthesis of closure params + `catch_unwind` + owned-clone bridge | Modify |
| `src/Sky/Build/Rust/Ffi.hs` / `src/Sky/Generate/Rust/Project.hs` | Emit the closure wrapper into `<crate>_generics.rs`; S4 tree-shake unchanged | Modify |
| `src/Sky/Build/Compile.hs` | Thread the closure-arg slot trait-kind from the FFI signature to the call-site lambda lowering | Modify |
| `src/Sky/Generate/Rust/Builder/ExprEmitter.hs` | At a `Can.Call` FFI site with a direct-`Can.Lambda` closure arg: run the capture-allowlist gate, emit `E4400` or the move-closure | Modify |
| `tools/sky-ffi-inspect-rs/src/main.rs` | Emit per-closure-arg metadata `{argIndex, traitKind, byRef, argTypes, ret}`; coverage tags `closure-by-ref-noclone` / `closure-mut-slot` / `closure-ho-return` / `closure-indirect-noanalysis` | Modify |
| `test/Sky/Build/Rust/FfiCallSpec.hs`, `FfiInstanceSpec.hs` | Unit specs for the new ADT/parse/render + the allowlist + capture-gate | Modify |

---

## Phase 0 — the executable spec (fixture FIRST, TDD red)

The fixture is the integration test. Build it red, then make each phase turn a row green.

### Task 0.1: Scaffold the `49-ffi-closures` hand-stub crate

**Files:**
- Create: `runtime-rust/tests/sky/49-ffi-closures/clo-crate/Cargo.toml`
- Create: `runtime-rust/tests/sky/49-ffi-closures/clo-crate/src/lib.rs`

- [ ] **Step 1: Write the crate manifest**

`clo-crate/Cargo.toml`:
```toml
[package]
name = "clo"
version = "0.0.0"
edition = "2021"

[lib]
name = "clo"
path = "src/lib.rs"
```

- [ ] **Step 2: Write the closure-taking API (covers every spec row)**

`clo-crate/src/lib.rs`:
```rust
//! Closures-FFI hand-stub crate (epic #28). Dependency-free. Exercises every
//! v1 closure shape: by-value Fn, multi-arg comparator, by-ref predicate
//! (owned-clone bridge), fallible return, FnMut slot, FnOnce slot, and the
//! drop shapes (Fn(&mut), -> &U). All bodies call the closure so the bounds
//! are load-bearing.

/// by-value `Fn(A)->B`, multi-call (maps every element).
pub fn map_each<A, B, F: Fn(A) -> B>(xs: Vec<A>, f: F) -> Vec<B> {
    xs.into_iter().map(f).collect()
}

/// by-ref predicate `Fn(&A)->bool`, multi-call → owned-clone bridge.
pub fn keep<A: Clone, F: Fn(&A) -> bool>(xs: Vec<A>, pred: F) -> Vec<A> {
    xs.into_iter().filter(|a| pred(a)).collect()
}

/// multi-arg comparator `Fn(&A,&A)->Ordering`-shaped, returned as i64.
pub fn count_lt<A: Clone, F: Fn(&A, &A) -> i64>(xs: Vec<A>, cmp: F) -> i64 {
    let mut n = 0i64;
    for i in 0..xs.len() {
        for j in (i + 1)..xs.len() {
            if cmp(&xs[i], &xs[j]) < 0 { n += 1; }
        }
    }
    n
}

/// FnMut slot (mutation across calls); a stateless Sky `Fn` satisfies it.
pub fn for_each_count<A, F: FnMut(A)>(xs: Vec<A>, mut f: F) -> i64 {
    let n = xs.len() as i64;
    for x in xs { f(x); }
    n
}

/// FnOnce slot, single-call — a non-`Clone` capture is sound here.
pub fn run_once<T, F: FnOnce() -> T>(f: F) -> T {
    f()
}
```

- [ ] **Step 3: Commit**
```bash
git add runtime-rust/tests/sky/49-ffi-closures/clo-crate
git commit -m "test(rust-ffi): 49-ffi-closures hand-stub crate (closure shapes)"
```

### Task 0.2: Write the kernel.json closure stub (the metadata contract)

**Files:**
- Create: `runtime-rust/tests/sky/49-ffi-closures/ffi-stub/clo.kernel.json`
- Create: `runtime-rust/tests/sky/49-ffi-closures/ffi-stub/clo_bindings.rs` (empty `// no non-generic surface`)

- [ ] **Step 1: Write the stub** — note the new `"closure"` arg shape in `argTypes` (a `TRClosure`-decoding object: `{closure:{kind,byRef,argTypes,ret}}`). This is the contract Phase 1 must parse.

`ffi-stub/clo.kernel.json`:
```json
{
  "moduleName": "Rust.Clo",
  "kernelName": "Rust_Clo",
  "package": "clo",
  "functions": [
    {
      "name": "mapEach",
      "arity": 2,
      "skyType": "List a -> (a -> b) -> Result Error (List b)",
      "generic": {
        "params": ["a", "b"],
        "bounds": {},
        "call": {
          "kind": "function",
          "path": ["::clo"], "method": "map_each",
          "typeArgs": [{"param": 0}, {"param": 1}],
          "args": [0, 1],
          "argTypes": [
            {"ctor": "Vec", "args": [{"param": 0}]},
            {"closure": {"kind": "Fn", "byRef": false,
                         "argTypes": [{"param": 0}], "ret": {"param": 1}}}
          ],
          "ret": {"ctor": "Vec", "args": [{"param": 1}]}
        }
      }
    },
    {
      "name": "keep",
      "arity": 2,
      "skyType": "List a -> (a -> Bool) -> Result Error (List a)",
      "generic": {
        "params": ["a"],
        "bounds": {"a": ["Clone"]},
        "call": {
          "kind": "function",
          "path": ["::clo"], "method": "keep",
          "typeArgs": [{"param": 0}],
          "args": [0, 1],
          "argTypes": [
            {"ctor": "Vec", "args": [{"param": 0}]},
            {"closure": {"kind": "Fn", "byRef": true,
                         "argTypes": [{"param": 0}], "ret": {"prim": "bool"}}}
          ],
          "ret": {"ctor": "Vec", "args": [{"param": 0}]}
        }
      }
    },
    {
      "name": "runOnce",
      "arity": 1,
      "skyType": "(() -> a) -> Result Error a",
      "generic": {
        "params": ["a"],
        "bounds": {},
        "call": {
          "kind": "function",
          "path": ["::clo"], "method": "run_once",
          "typeArgs": [{"param": 0}],
          "args": [0],
          "argTypes": [
            {"closure": {"kind": "FnOnce", "byRef": false,
                         "argTypes": [], "ret": {"param": 0}}}
          ],
          "ret": {"param": 0}
        }
      }
    }
  ]
}
```

- [ ] **Step 2: Write the empty bindings file**
```
// 49-ffi-closures: all surface is generic (closure wrappers); no non-generic bindings.
```

- [ ] **Step 3: Commit**
```bash
git add runtime-rust/tests/sky/49-ffi-closures/ffi-stub
git commit -m "test(rust-ffi): 49-ffi-closures kernel.json closure stub"
```

### Task 0.3: Write `setup.sh`, `sky.toml`, and `Main.sky` (the assertions)

**Files:**
- Create: `runtime-rust/tests/sky/49-ffi-closures/setup.sh` (copy `48-ffi-generics/setup.sh`, rename `box1`→`clo`, crate dir `clo-crate`, cache `49-ffi-closures-crate`)
- Create: `runtime-rust/tests/sky/49-ffi-closures/sky.toml` (copy 48's, point the `file://` dep at `49-ffi-closures-crate`)
- Create: `runtime-rust/tests/sky/49-ffi-closures/src/Main.sky`

- [ ] **Step 1: Write `Main.sky` — the green-path assertions**
```elm
module Main exposing (main)

import Sky.Core.Prelude exposing (..)
import Sky.Core.Result as Result
import Rust.Clo as Clo
import Std.Log exposing (println)


-- by-value Fn(A)->B over a multi-call slot.
mapped : Result Error (List Int)
mapped =
    Clo.mapEach [ 1, 2, 3 ] (\x -> x * 10)


-- by-ref predicate Fn(&A)->Bool (owned-clone bridge).
kept : Result Error (List Int)
kept =
    Clo.keep [ 1, 2, 3, 4 ] (\x -> modBy 2 x == 0)


main : Task Error ()
main =
    let
        m = Result.withDefault [] mapped
        k = Result.withDefault [] kept
        _ = println ("mapped sum -> " ++ String.fromInt (List.foldl (+) 0 m))
        _ = println ("kept len   -> " ++ String.fromInt (List.length k))
    in
    if List.foldl (+) 0 m == 60 && List.length k == 2 then
        println "[ALL OK]"
    else
        println "[FAIL]"
```

- [ ] **Step 2: Run the fixture build — verify it FAILS (red baseline)**

Run: `cd runtime-rust/tests/sky/49-ffi-closures && bash setup.sh && sky build --backend rust src/Main.sky`
Expected: FAIL — the closure arg `(\x -> x * 10)` hits `FfiInstance.hs:267` (`TLambda -> Left "function type"`) → the `mapEach` instance is unbindable / the `closure` argType fails to parse. This is the red the epic turns green.

- [ ] **Step 3: Commit**
```bash
git add runtime-rust/tests/sky/49-ffi-closures/{setup.sh,sky.toml,src}
git commit -m "test(rust-ffi): 49-ffi-closures Main.sky assertions (red baseline)"
```

---

## Phase 1 — `Call` AST closure support (`FfiCall.hs`)

### Task 1.1: Add the `TRClosure` TypeRef variant

**Files:**
- Modify: `src/Sky/Build/Rust/FfiCall.hs` (the `TypeRef` ADT, ~line 121)
- Test: `test/Sky/Build/Rust/FfiCallSpec.hs`

- [ ] **Step 1: Write the failing decode test** (`FfiCallSpec.hs`):
```haskell
it "#28: decodes a closure argType" $ do
    let j = "{\"closure\":{\"kind\":\"Fn\",\"byRef\":false,\
            \\"argTypes\":[{\"param\":0}],\"ret\":{\"param\":1}}}"
    A.decode j `shouldBe`
        Just (TRClosure FnKind False [TRParam 0] (TRParam 1))
```

- [ ] **Step 2: Run it — verify FAIL** (`TRClosure`/`FnKind` not defined)

Run: `cabal test --test-options='--match "#28: decodes a closure argType"'`
Expected: FAIL (build error: not in scope).

- [ ] **Step 3: Implement the ADT + a `ClosureKind` + `FromJSON`** in `FfiCall.hs`:
```haskell
data ClosureKind = FnKind | FnMutKind | FnOnceKind
    deriving (Show, Eq)

-- extend TypeRef:
    | TRClosure !ClosureKind !Bool ![TypeRef] !TypeRef
      -- ^ {closure:{kind,byRef,argTypes,ret}} — a closure-typed wrapper arg.
      --   byRef=True ⇒ the foreign param is Fn(&A) (owned-clone bridge).

instance A.FromJSON ClosureKind where
    parseJSON = A.withText "ClosureKind" $ \t -> case t of
        "Fn" -> pure FnKind; "FnMut" -> pure FnMutKind; "FnOnce" -> pure FnOnceKind
        _ -> fail ("unknown closure kind " ++ T.unpack t)

-- in the TypeRef FromJSON object branch, before the ctor/param/prim cases:
        <|> (do c <- o .: "closure"
                TRClosure <$> c .: "kind" <*> c .:? "byRef" .!= False
                          <*> c .: "argTypes" <*> c .: "ret")
```

- [ ] **Step 4: Run — verify PASS**

Run: `cabal test --test-options='--match "#28: decodes a closure argType"'`
Expected: PASS.

- [ ] **Step 5: Commit**
```bash
git add src/Sky/Build/Rust/FfiCall.hs test/Sky/Build/Rust/FfiCallSpec.hs
git commit -m "feat(ffi): TRClosure TypeRef variant + ClosureKind decode (#28)"
```

### Task 1.2: Render a closure arg as a generic `<Fj: …>` wrapper param

The renderer must, for arg `j` whose `argTypes[j]` is a `TRClosure k byRef cargs cret`, (a) introduce a fresh type-param `Fj`, (b) render its bound `Fj: <kind>(<cargs>) -> <cret> [+ Clone]`, (c) use `Fj` as the param's Rust type, (d) for `byRef`, wrap the call-site use in the owned-clone bridge `move |r| { let v = r.clone(); f(v) }`.

**Files:**
- Modify: `src/Sky/Build/Rust/FfiCall.hs` (`renderCall`, `renderArgType`)
- Test: `test/Sky/Build/Rust/FfiCallSpec.hs`

- [ ] **Step 1: Write the failing render test:**
```haskell
it "#28: renders a multi-call Fn closure param as <Fj: Fn(..)+Clone>" $ do
    let call = Call CallFunction ["::clo"] [TRParam 0, TRParam 1]
                 (Just "map_each") Nothing [0,1]
                 [ TRCtor "Vec" [TRParam 0]
                 , TRClosure FnKind False [TRParam 0] (TRParam 1) ]
                 (TRCtor "Vec" [TRParam 1])
    -- the closure param's Rust type is the fresh F-param, its bound carries +Clone
    closureBounds call `shouldBe` ["F1: Fn(A) -> B + ::core::clone::Clone"]
```
(Add a small exposed helper `closureBounds :: Call -> [String]` collecting each closure arg's `<Fj: …>` clause so the wrapper synthesis can splice them into the `<…>` list.)

- [ ] **Step 2: Run — verify FAIL.**
Run: `cabal test --test-options='--match "#28: renders a multi-call Fn"'`  Expected: FAIL.

- [ ] **Step 3: Implement** `closureBounds` + the `renderArgType` closure arm:
```haskell
-- Fn/FnMut get + Clone (multi-call-capable); FnOnce does not.
closureKindStr :: ClosureKind -> String
closureKindStr FnKind = "Fn"; closureKindStr FnMutKind = "FnMut"; closureKindStr FnOnceKind = "FnOnce"

closureNeedsClone :: ClosureKind -> Bool
closureNeedsClone FnOnceKind = False; closureNeedsClone _ = True

-- one `Fj: Kind(args) -> ret [+ Clone]` per closure arg, index j = wrapper-arg index.
closureBounds :: Call -> [String]
closureBounds c =
    [ "F" ++ show j ++ ": " ++ closureKindStr k
        ++ "(" ++ intercalate ", " (map renderTypeRef as_) ++ ") -> " ++ renderTypeRef r
        ++ (if closureNeedsClone k then " + ::core::clone::Clone" else "")
    | (j, TRClosure k _ as_ r) <- zip [0..] (_call_argTypes c) ]

-- renderArgType: a TRClosure arg renders to its fresh F-param name.
renderArgTypeAt :: Int -> TypeRef -> String
renderArgTypeAt j (TRClosure{}) = "F" ++ show j
renderArgTypeAt _ t = renderTypeRef t
```
Thread `renderArgTypeAt` through `renderCall`'s param-list emission; for a `byRef` closure arg, wrap the call-site argument expression in the owned-clone bridge.

- [ ] **Step 4: Run — verify PASS.** Run the same `--match`. Expected: PASS.

- [ ] **Step 5: Commit**
```bash
git add src/Sky/Build/Rust/FfiCall.hs test/Sky/Build/Rust/FfiCallSpec.hs
git commit -m "feat(ffi): render closure args as generic <Fj: Fn(..)+Clone> wrapper params (#28)"
```

---

## Phase 2 — positive `Clone`-allowlist (`FfiInstance.hs`, B5/B1)

### Task 2.1: Add `rustTypeIsClone` (the positive allowlist)

**Files:**
- Modify: `src/Sky/Build/Rust/FfiInstance.hs`
- Test: `test/Sky/Build/Rust/FfiInstanceSpec.hs`

- [ ] **Step 1: Failing test** — the allowlist accepts closed-`Clone` types and rejects f64-only-Clone vs nothing, and rejects non-closed:
```haskell
it "#28: rustTypeIsClone is a positive allowlist over closed Clone types" $ do
    map rustTypeIsClone ["i64","String","bool","char","()","Vec<i64>","SkyMaybe<i64>"]
        `shouldBe` replicate 7 True
    rustTypeIsClone "f64" `shouldBe` True          -- f64 IS Clone (only Hash/Eq/Ord fail)
```

- [ ] **Step 2: Run — verify FAIL.** Run: `cabal test --test-options='--match "#28: rustTypeIsClone"'`  Expected: FAIL.

- [ ] **Step 3: Implement** — reuse `traitsOfRustType` (already computes the `{Hash,Eq,Ord,Clone,Default}` set per closed type, incl. recursive `Vec<T>`/`SkyMaybe<T>`):
```haskell
-- | A capture is admissible into a multi-call Fn slot ONLY when its
-- monomorphised Rust type is positively Clone (B5: never a denylist).
-- Built on the SAME closed-set machinery as the bound check, so a capture
-- type that isn't even closed is rejected here too (Left → not Clone).
rustTypeIsClone :: String -> Bool
rustTypeIsClone rustTy = rustTypeHasTrait rustTy "Clone"

skyCaptureIsClone :: Can.Type -> Bool
skyCaptureIsClone ty = case skyTypeToRustClosed ty of
    Right rustTy -> rustTypeIsClone rustTy
    Left _       -> False     -- not in the closed set ⇒ not provably Clone ⇒ reject
```

- [ ] **Step 4: Run — verify PASS.** Expected: PASS.

- [ ] **Step 5: Commit**
```bash
git add src/Sky/Build/Rust/FfiInstance.hs test/Sky/Build/Rust/FfiInstanceSpec.hs
git commit -m "feat(ffi): positive Clone-allowlist for closure captures (B5, #28)"
```

### Task 2.2: The capture-gate `E4400` diagnostic constructor

**Files:**
- Modify: `src/Sky/Build/Rust/FfiInstance.hs` (mirror `mkUnmodellableBoundError`)

- [ ] **Step 1: Failing test** — a non-`Clone` capture into a multi-call slot yields a `Diagnostic` with code `E4400`, the call-site region, and a hint naming the capture:
```haskell
it "#28: non-Clone capture into a multi-call Fn slot ⇒ E4400 (not cargo-fail)" $ do
    let d = mkCaptureNotCloneError reg "myFile.sky" "task0" "Task Error ()"
    Diag._diag_code d `shouldBe` "E4400"
    T.isInfixOf "must be Clone" (Diag._diag_message d) `shouldBe` True
```

- [ ] **Step 2: Run — verify FAIL.** `--match "#28: non-Clone capture"`. Expected: FAIL.

- [ ] **Step 3: Implement** `mkCaptureNotCloneError :: A.Region -> FilePath -> String -> String -> Diag.Diagnostic` — same `Diag.Diagnostic` shape as `mkUnmodellableBoundError` (code `E4400`, `CatCodegen`), message: "Capture `<name>` of type `<ty>` is passed into a multi-call closure that Rust requires to be `Fn + Clone`, but `<ty>` is not Clone." Hint: "Use a Clone-able captured value, or restructure so the closure captures nothing." (Region = the call site, threaded by Phase 4.)

- [ ] **Step 4: Run — verify PASS.** **Step 5: Commit** `feat(ffi): E4400 capture-not-Clone diagnostic (#28)`.

---

## Phase 3 — wrapper synthesis: closure params + `catch_unwind` + bridge

### Task 3.1: Emit the closure wrapper body with the panic boundary (B1/B2/B3)

**Files:**
- Modify: `src/Sky/Build/Rust/FfiInstance.hs` (`synthesiseWrapper`/`renderGenericWrapper`), splicing `closureBounds` into the `<…>` clause and wrapping the body call.

- [ ] **Step 1: Failing test** — `synthesiseWrapper` for `mapEach` emits a wrapper whose signature carries the closure F-param and whose body is `catch_unwind`-wrapped:
```haskell
it "#28: closure wrapper carries <F1: Fn..+Clone> and a catch_unwind body" $ do
    let rs = renderGenericWrapperFor mapEachFn   -- fixture GenericFn
    T.isInfixOf "F1: Fn(A) -> B + ::core::clone::Clone" rs `shouldBe` True
    T.isInfixOf "::std::panic::catch_unwind" rs `shouldBe` True
    T.isInfixOf "AssertUnwindSafe" rs `shouldBe` True
```

- [ ] **Step 2: Run — verify FAIL.**

- [ ] **Step 3: Implement** the wrapper shape:
```rust
pub fn rust_clo_map_each<A, B, F1: Fn(A) -> B + ::core::clone::Clone>(arg0: Vec<A>, arg1: F1)
    -> SkyResult<SkyError, Vec<B>>
{
    match ::std::panic::catch_unwind(::std::panic::AssertUnwindSafe(|| {
        ::clo::map_each::<A, B>(arg0, arg1)
    })) {
        Ok(v)  => ok_res(v),
        Err(_) => err_res(SkyError::unexpected("a Sky closure passed to FFI panicked")),
    }
}
```
- **B2 (refuse `panic="abort"`):** in `Project.hs`, when any reached wrapper carries a closure arg, assert the build profile is `panic="unwind"`; hard-error otherwise. Add `[profile.*] panic = "unwind"` is the cargo default — the check is a guard, not a mutation.
- **B3 (Rust-ABI only):** the inspector (Phase 5) only emits closure metadata for `"Rust"`-ABI hosts, so this wrapper is reached only for them; no extra gate here.

- [ ] **Step 4: Run — verify PASS.** **Step 5: Commit** `feat(ffi): synthesise closure wrapper + catch_unwind panic boundary (B1/B2, #28)`.

### Task 3.2: Owned-clone bridge for `Fn(&A)` params (B4)

**Files:**
- Modify: `src/Sky/Build/Rust/FfiCall.hs` (`renderCall`, the `byRef` closure arg).

- [ ] **Step 1: Failing test** — the `keep` wrapper bridges `&A`:
```haskell
it "#28: by-ref closure param bridges &A -> owned clone" $ do
    let rs = renderGenericWrapperFor keepFn
    T.isInfixOf "move |__r| { let __v = __r.clone(); arg1(__v) }" rs `shouldBe` True
```

- [ ] **Step 2: Run — verify FAIL.**

- [ ] **Step 3: Implement** — for a `byRef` closure arg `argN`, instead of passing `argN` directly to the host call, pass the bridge closure. Multi-`&` (`Fn(&A,&B)`) clones each independently (conjunctive `A:Clone ∧ B:Clone`, else the method is dropped in the bindability check). The closed set has no reference arm (`FfiInstance.hs:248-268`) → the Sky closure only ever sees an owned value; identity-escape is structurally impossible (B4 invariant).

- [ ] **Step 4: Run — verify PASS.** **Step 5: Commit** `feat(ffi): owned-clone bridge for Fn(&A) closure params (B4, #28)`.

### Task 3.3: Drop+report the unsound closure shapes

**Files:**
- Modify: `src/Sky/Build/Rust/FfiInstance.hs` (closure bindability check).

- [ ] **Step 1: Failing test** — `Fn(&mut T)`, `-> &U`, `-> impl Fn`, by-ref with non-`Clone` element each produce a coverage drop (not a wrapper, not a cargo-fail):
```haskell
it "#28: Fn(&mut T) / -> &U / non-Clone &A drop with a coverage reason" $ do
    closureDropReason (TRClosure FnMutKind True [TRParam 0] (TRParam 0))  -- &mut shape
        `shouldBe` Just "closure-mut-slot"
```

- [ ] **Step 2: Run — verify FAIL.** **Step 3: Implement** `closureDropReason :: TypeRef -> Maybe String` returning `closure-mut-slot` / `closure-ho-return` / `closure-by-ref-noclone`; the bindability check drops the method + records the reason. **Step 4: PASS. Step 5: Commit** `feat(ffi): drop+report unsound closure shapes (B6, #28)`.

---

## Phase 4 — emitter capture-allowlist gate + trait-kind threading (the keystone)

This is the load-bearing soundness step. The FFI signature knows arg `j` is a `Fn`/`FnMut` (multi-call) closure slot; the call-site Sky lambda's captures must all pass `skyCaptureIsClone`, else `E4400`. **Direct-`Can.Lambda`-only** (Q4): any indirect closure arg drops.

### Task 4.1: Thread the closure-slot trait-kind to the call-site

**Files:**
- Modify: `src/Sky/Build/Compile.hs` (where the FFI call's declared arg types are available) → pass a `Map ffiArgIndex ClosureKind` (or `Nothing` for non-closure args) to the emitter context for that `Can.Call`.
- Modify: `src/Sky/Generate/Rust/Builder/ExprEmitter.hs` (`EmitCtx` gains an optional per-call closure-slot map; `Can.Call` at line 133 consults it).

- [ ] **Step 1: Failing test** — a unit spec over the emitter helper that, given a `Can.Call` to an FFI fn with arg1 a `Can.Lambda` capturing a `String` (Clone) into a multi-call `Fn` slot, emits the move-closure; capturing a `Task`-typed binding emits the E4400 path. (Drive via a small `gateClosureArg :: ClosureKind -> [(String, Can.Type)] -> Either Diag.Diagnostic ()` pure helper so the gate is unit-testable without full codegen.)
```haskell
it "#28: gate passes all-Clone captures, rejects a non-Clone capture (multi-call)" $ do
    gateClosureArg FnKind [("name", tString)] `shouldBe` Right ()
    isLeft (gateClosureArg FnKind [("t", tTaskErrorUnit)]) `shouldBe` True
    gateClosureArg FnOnceKind [("t", tTaskErrorUnit)] `shouldBe` Right ()  -- FnOnce: no gate
```

- [ ] **Step 2: Run — verify FAIL.** **Step 3: Implement** `gateClosureArg`:
```haskell
gateClosureArg :: ClosureKind -> [(String, Can.Type)] -> Either Diag.Diagnostic ()
gateClosureArg FnOnceKind _ = Right ()                       -- single-call: move-in OK
gateClosureArg _ captures =                                  -- Fn/FnMut: all captures Clone
    case [ (n, ty) | (n, ty) <- captures, not (skyCaptureIsClone ty) ] of
        []          -> Right ()
        ((n, ty):_) -> Left (mkCaptureNotCloneError {- region threaded by caller -} ... n (renderSkyType ty))
```
The lambda's captures = its free variables minus its params (the emitter already computes the capture set for `ecCloneVars`, `ExprEmitter.hs:585`); each capture's `Can.Type` comes from the solved region types (`globalRegionTypes`).

- [ ] **Step 4: PASS. Step 5: Commit** `feat(ffi): closure-slot trait-kind threading + capture gate helper (B5/Q4, #28)`.

### Task 4.2: Wire the gate into `Can.Call` lowering; drop indirect closures

**Files:**
- Modify: `src/Sky/Generate/Rust/Builder/ExprEmitter.hs` (`Can.Call fn args` arm, line 133; `argToRustString`, line 576).

- [ ] **Step 1: Failing test** — the fixture: `Clo.mapEach [1,2,3] (\x -> x*10)` builds; a variant fixture row `let f = (\x -> x*10) in Clo.mapEach xs f` (indirect) drops with `closure-indirect-noanalysis`.
- [ ] **Step 2: Run the 49 fixture — verify the direct case still FAILS** (gate not wired). 
- [ ] **Step 3: Implement** — in the `Can.Call` arm, when `fn` resolves to an FFI binding and `args[j]` is a **direct** `Ann.At _ (Can.Lambda ps body)` landing in a closure slot (kind from the threaded map): run `gateClosureArg`; `Left d` → emit `d` (E4400) and abort codegen; `Right ()` → lower the lambda to the move-closure as today. If `args[j]` for a closure slot is NOT a syntactic `Can.Lambda`, record a `closure-indirect-noanalysis` drop and skip the binding.
- [ ] **Step 4: Run the fixture — verify the direct mapEach/keep rows now BUILD + RUN `[ALL OK]`.** **Step 5: Commit** `feat(ffi): wire capture gate into Can.Call; direct-lambda-only (#28)`.

---

## Phase 5 — inspector emits closure metadata (`sky-ffi-inspect-rs`)

Until now everything runs off the hand-stub kernel.json. Phase 5 makes a REAL crate's closure fns emit that same shape — so the proof generalises past the fixture.

### Task 5.1: Read the closure trait-kind + emit the `closure` argType

**Files:**
- Modify: `tools/sky-ffi-inspect-rs/src/main.rs` (the generic-fn arg classifier near `main.rs:3813`, where closures currently drop).
- Test: an inline `#[test]` in `main.rs` over a rustdoc-JSON fixture snippet.

- [ ] **Step 1: Failing Rust unit test** — a param whose bound trait name ∈ {Fn,FnMut,FnOnce} over closed-set arg/ret emits `TRClosure`-shaped JSON `{closure:{kind,byRef,argTypes,ret}}`; `Fn(&A)` sets `byRef:true`; a non-Rust-ABI host emits nothing (B3).
```rust
#[test]
fn closure_param_emits_closure_argtype() {
    let v = classify_closure_param(/* Fn(i64)->bool bound, by-ref */);
    assert_eq!(v["closure"]["kind"], "Fn");
    assert_eq!(v["closure"]["byRef"], true);
}
```

- [ ] **Step 2: Run — verify FAIL.** Run: `cd tools/sky-ffi-inspect-rs && cargo test closure_param_emits`. Expected: FAIL.

- [ ] **Step 3: Implement** `classify_closure_param` — recognise the `Fn`/`FnMut`/`FnOnce` trait name on a generic-param bound or `impl Trait` node (reuse the existing trait-name extraction, ~`main.rs:3463`/`3608`); read the parenthesised input types + the `Output =` assoc binding; map each through the existing closed-set resolver; `&A` input ⇒ `byRef:true`. Gate the whole emission on host ABI `== "Rust"` (B3). Emit the `closure` object into the fn's `argTypes`.

- [ ] **Step 4: PASS. Step 5: Commit** `feat(inspect-rs): emit closure argType metadata for Rust-ABI hosts (#28)`.

### Task 5.2: Coverage tags for every closure drop

**Files:**
- Modify: `tools/sky-ffi-inspect-rs/src/main.rs` (`GenericDrop` reasons + `emit_generic_coverage`).

- [ ] **Step 1: Failing test** — `Fn(&mut T)` / `-> impl Fn` / non-Rust-ABI host / non-`Clone` `&A` each record a distinct reason string in the coverage report.
- [ ] **Step 2: FAIL. Step 3: Implement** — add `closure-mut-slot`, `closure-ho-return`, `closure-by-ref-noclone`, `closure-nonrust-abi`, `closure-indirect-noanalysis` to the drop taxonomy; they flow through the existing `emit_generic_coverage`. **Step 4: PASS. Step 5: Commit** `feat(inspect-rs): closure coverage drop tags (#28)`.

---

## Phase 6 — integration: sweep wiring + real-crate proof

### Task 6.1: Wire `49-ffi-closures` into the fixture runner

**Files:**
- Modify: `runtime-rust/scripts/ffi-fixtures-test.sh` (add `49-ffi-closures`, assert stdout `[ALL OK]` + assert the negative rows produce `E4400` / coverage drops, not cargo-fails).

- [ ] **Step 1:** Add the fixture to the runner's list with an expected-stdout assertion `[ALL OK]` and the inspector-freshness guard (the `48` pattern). 
- [ ] **Step 2: Run** `bash runtime-rust/scripts/ffi-fixtures-test.sh 49-ffi-closures`. Expected: PASS (`[ALL OK]`).
- [ ] **Step 3: Commit** `test(rust-ffi): wire 49-ffi-closures into the sweep (#28)`.

### Task 6.2: Real-crate closure proof + coverage (CI-weight)

**Files:**
- Create: `runtime-rust/tests/sky/49b-closures-realcrate/` (a tiny Sky project that `sky add`s a real crate with a FREE or INHERENT by-value/`&A:Clone` closure API — candidate: a `Lazy::new(FnOnce)` (`once_cell`) or a retry-style `Fn()->Result` free fn; pick at impl time by running the inspector + reading `<crate>.coverage.md`).

- [ ] **Step 1:** Pick the crate by running the demand harness against 2–3 candidates: `cd /tmp/ffi-demand && <add the candidate to run.sh CRATES> && bash run.sh`, then `rg FFI_COVERAGE` — choose the one with the most `Rust`-ABI by-value/`&A:Clone` closure fns bound.
- [ ] **Step 2:** Write the Sky project binding one such closure fn end-to-end; assert the runtime output.
- [ ] **Step 3: CI** builds it (do NOT run the full build locally — disk). Read `.skycache/ffi/rust/<crate>.coverage.md`; confirm the trait-method surface is reported `waits-on-#21`.
- [ ] **Step 4: Commit** `test(rust-ffi): real-crate closure binding proof + coverage (#28)`.

### Task 6.3: Guardian-final on the full diff + push

- [ ] **Step 1:** Run `git diff` of the epic; dispatch the `security-soundness-guardian` for the final blocking review — focus: the positive-allowlist gate is the ONLY capture oracle (no `ecNoCloneVars` leak), `catch_unwind` covers every closure host, no `Fn` bound emitted without a passed gate, Go-byte-identical (every path gates on a `closure` argType Go never emits).
- [ ] **Step 2:** Address any blocking finding; re-verify the targeted specs + the `49` fixture.
- [ ] **Step 3:** Light local verify green → `bash runtime-rust/scripts/push.sh` (fork only). CI runs the full suite + real-crate proof.
- [ ] **Step 4:** Mark task #28 completed only after CI is green (the verification gate — "authored" ≠ "fixed").

---

## Self-review notes
- **Spec coverage:** scope (Phase 0 fixture + 1–4) · 6 constraints B1 (Task 3.1 AssertUnwindSafe-by-value) B2 (Task 3.1 panic=unwind guard) B3 (Tasks 3.1/5.1 Rust-ABI-only) B4 (Task 3.2 bridge) B5 (Tasks 2.1/4.1 positive allowlist) B6/borrow-escape (Task 3.3) · owned-clone bridge (3.2) · drop granularity (2.2 E4400 user-side, 3.3/5.2 method-side coverage) · direct-lambda-only (4.2) · inspector metadata (5) · proof bar fixture+real-crate (0, 6.2). All mapped.
- **No placeholders:** the one deliberate deferral is the real-crate CHOICE (Task 6.2 Step 1 names the selection procedure + candidates), not a code gap.
- **Type consistency:** `TRClosure ClosureKind Bool [TypeRef] TypeRef`, `ClosureKind {FnKind,FnMutKind,FnOnceKind}`, `skyCaptureIsClone`, `gateClosureArg`, `mkCaptureNotCloneError`, `closureDropReason`, `closureBounds` used consistently across Phases 1–4.
