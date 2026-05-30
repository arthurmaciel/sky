# Sub-A.9 — Codegen-completeness fixes for the headline gate — Design

**Date:** 2026-05-29
**Status:** Approved (brainstorming) — ready for implementation plan
**Scope:** Three root-cause fixes in `src/Sky/Generate/Rust/Builder.hs` for the codegen-shape bugs identified after sub-A.8.
**Branch:** `feat/runtime-rust`
**Builds on:** Sub-A.8 commits (`1c5a1596..9ecb33f1`, all on `origin/feat/runtime-rust`).

---

## 1. Context

After sub-A.8 shipped 54 runtime kernels, `examples/00-standard-libs` on
`target=rust` compiles down to **~70 cargo errors** (from 232 pre-plan,
116 post-codegen-completion, ~70 post-sub-A.8). All "kernel not found"
errors are gone — every kernel name the codegen emits resolves. The
remaining errors are codegen-shape bugs in `Builder.hs` itself.

Three of those bugs cluster as ROOT-CAUSE issues — each fix unblocks a
chunk of dependent errors. This sub-plan closes the three; remaining
errors (likely ~20 Json.Decode-pipeline-specific) get a follow-on.

## 2. Goal

After this work:

1. `examples/00-standard-libs` on `target=rust` cargo error count drops
   from ~70 to ≤20.
2. The three categories below produce zero errors in the generated code.
3. 16/16 `examples/rust/*` continue to build and run.
4. Go path byte-identical.

## 3. Non-goals (explicit)

- **No new runtime kernels.** Sub-A.8 closed the kernel coverage.
- **No Json.Decode pipeline reshape.** ~20 errors localised to
  `sky_core_json_decode.rs` come from how Sky's pipeline-style decoder
  composition (`Decoder.succeed f |= required "x" string`) lowers to
  nested `Fn` types in Rust. Deeper change; deferred to sub-A.10.
- **No Sky.Test refactor.** A small `Sky.Test` issue may surface after
  the three fixes; addressed if blocking the gate, otherwise deferred.
- **Go backend untouched.**

## 4. Verified bug catalogue (grounded in cargo output)

### B1 — `("Std.X", ...)` kernelToRust mirror arms cause wrapper bypass

**Symptom:** User code calling `Money.format m` resolves to the runtime
kernel `money_format(m)` instead of the Sky-generated wrapper
`std_money_format(m)`. The wrapper exists and does the
`StdMoneyMoney → (String, Decimal)` conversion before invoking the
kernel — but the kernelToRust arm overrides it.

**Error count:** ~10 errors in `std_money.rs`, `std_decimal.rs`
(latent — works today by signature coincidence).

**Generated code (current):**
```rust
// main.rs (test calling Money.format m):
sky_test_equal("$100.00".to_string(), money_format(m))
//                                    ^^^^^^^^^^^^ bypasses std_money_format
```
`money_format` takes `(code: String, amount: Decimal)`; test passes
`StdMoneyMoney` and only one arg → E0061 + E0308.

**Root cause:** In `Builder.hs` at line ~1096, `Can.VarTopLevel` resolves
the symbol via:
```haskell
kernelName = kernelToRust modName name
in if fnName /= kernelName && not ("ffi_kernel" `isPrefixOf` kernelName)
   then kernelName    -- ← bypass: emits the kernel name, skips the wrapper
   else ...
```

For `Std.Money.format`:
- `fnName = "std_money_format"` (Sky-source wrapper)
- `kernelName = kernelToRust "Std.Money" "format" = "money_format"` (sub-A.8 arm)
- Different → emit `money_format` → wrapper bypassed.

**Fix:** Remove every `("Std.X", ...) -> "<kernel>"` mirror arm from
`kernelToRust`. Keep the bare `("X", ...) -> "<kernel>"` arms — those
are used by the `Ffi.callPure` peephole's `splitKernelName` lookup
(which always produces a bare module name like `"Money"`, not `"Std.Money"`).

After the fix, `Std.Money.format` resolves to:
- `fnName = "std_money_format"`
- `kernelName = "std_money_format"` (snake-cased default)
- Equal → else branch → emits `std_money_format` → wrapper called correctly.

The wrapper's body uses `Ffi.callPure "Money_format" [...]` which
peephole-rewrites to `money_format(code, amount)`. End-to-end correct.

**Applies to:** Std.Decimal (15 arms), Std.Money (12 arms), Std.Time (7
arms). KEEP arms for kernel-only modules (Sky.Core.Math/String/Dict/
Basics/List use `Ffi.kernel` which Stage-4-rewrites to `Can.VarKernel`,
hitting a different codegen arm that needs the kernelToRust lookup).

### B2 — Zero-arg call sites lose `()` when kernelToRust fires

**Symptom:** `StdMoneyMoney::Money(decimal_zero, c)` — `decimal_zero`
is the function reference (`fn() -> Decimal`), should be `decimal_zero()`
(call producing `Decimal`).

**Error count:** ~3-5 errors. Largely subsumed by B1 (once `Std.Decimal`
arms removed, `Dec.zero` routes to `std_decimal_zero` which has the
`ecZeroArgDefs` check at the else branch).

**Root cause:** At line 1102-1109 in `Builder.hs`:
```haskell
in if fnName /= kernelName && not ("ffi_kernel" `isPrefixOf` kernelName)
   then kernelName                            -- ← no ecZeroArgDefs check
   else case Map.lookup (modName, name) (ecKernelAliases ctx) of
       ...
       Nothing ->
           if Set.member (modPrefix, name) (ecZeroArgDefs ctx)
               then fnName ++ "()"             -- ← check only in else
               else fnName
```

The else branch correctly appends `()` for zero-arg defs. The "then"
branch (kernelName fires) doesn't.

**Fix:** B1 closes most of this. For completeness, also extend the "then"
branch with the same `ecZeroArgDefs` check applied to the resolved
kernel name — handles edge cases like Ffi.kernel-aliased zero-arg
bindings.

### B3 — PCtor function parameters drop to `_`, body loses bindings

**Symptom:**
```rust
pub fn std_money_amount(_: StdMoneyMoney) -> StdDecimalDecimal {
    d   // <- E0425: cannot find value `d` in this scope
}
```

**Sky source:**
```elm
amount : Money -> Decimal
amount (Money d _) = d
```

**Error count:** ~5 errors (Std.Money `amount` / `currency`, similar in
other Sky modules using constructor-pattern params).

**Root cause:** `patternToRustParam` at line 856-862:
```haskell
patternToRustParam (Ann.At _ pat) = case pat of
    Can.PVar n -> rustSafeIdent n
    Can.PAnything -> "_"
    Can.PTuple ... -> ...
    _ -> "_"     -- ← any constructor / record / cons pattern drops here
```

For `Can.PCtor` (constructor patterns), the function emits `"_"`,
discarding the bound variables. The function body then references those
variables which are now unbound.

**Fix:** Extend `patternToRustParam` to return both a Rust parameter
name AND a let-bind prelude string for non-trivial patterns:
- `PCtor "Money" [PVar "d", PAnything]` → param name `__p_<n>`, prelude
  `let StdMoneyMoney::Money(d, _) = __p_<n>; `.
- Threading prelude through `defToRustItem` to prepend it to the body.

Rust's `let <pattern> = expr;` is irrefutable; single-variant enums
(`Money` has only one constructor `Money`) qualify. The compiler
accepts it.

For multi-variant pattern args (rare in Sky surface — most pattern-arg
functions are over single-constructor types like Money/User), fall back
to `match`:
```rust
match __p_<n> {
    SkyCoreErrorError::Error(k, info) => { /* body uses k, info */ }
    _ => panic!("unreachable — non-exhaustive pattern arg")
}
```
The `panic!` arm is unreachable because the Sky type-checker already
proved exhaustiveness on the calling side; we trust that here.

### B6 — `Can.Binop "++"` emits `format!` regardless of operand type

**Symptom:**
```rust
SkyCoreJwtClaims::Claims(format!("{}{}", kvs, vec![(k, v)]))
//                       ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
//                       E0308: expected Vec<(String, Value)>, found String
```

**Sky source:**
```elm
withClaim k v c =
    case c of
        Claims kvs -> Claims (kvs ++ [(k, v)])
```

**Error count:** ~24 errors localised to `sky_core_jwt.rs`. Each
cascades from the wrong `++` lowering — once the codegen sees `kvs:
String`, every subsequent type check is wrong.

**Root cause:** In `exprToRustInner` at line 1138:
```haskell
| op == "++" -> "format!(\"{}{}\", " ++ exprToRustString ctx a ++ ", " ++ exprToRustString ctx b ++ ")"
```

`++` in Sky polymorphically handles both `String -> String -> String`
AND `List a -> List a -> List a`. The codegen ALWAYS emits `format!`
(string concat), which only works for strings.

**Fix:** Dispatch on the inferred type of the operands.
`taskExprInnerType (ecSolvedTypes ctx) a` already returns the Rust-side
type as a string. Branch:
```haskell
| op == "++" ->
    let lhsTy = taskExprInnerType (ecSolvedTypes ctx) a
    in if "Vec<" `isPrefixOf` lhsTy
       then "{ let mut __r = " ++ exprToRustString ctx a ++ ".clone(); __r.extend(" ++ exprToRustString ctx b ++ "); __r }"
       else "format!(\"{}{}\", " ++ exprToRustString ctx a ++ ", " ++ exprToRustString ctx b ++ ")"
```

`{ let mut __r = a.clone(); __r.extend(b); __r }` is a Rust expression
that concats two Vecs. Works for any `Vec<T: Clone>`.

If `taskExprInnerType` can't pin the type (returns empty), default to
`format!` (string concat) — that's the existing behaviour, no regression.

## 5. Design — single-file edits

All three fixes are in `src/Sky/Generate/Rust/Builder.hs`:

| Bug | Function / area | Edit shape |
|---|---|---|
| B1 | `kernelToRust` (lines ~1960-2200) | Delete the `("Std.X", ...) -> "..."` mirror arms |
| B2 | `Can.VarTopLevel` arm (~line 1096-1109) | Add `ecZeroArgDefs` check to the "then" branch |
| B3 | `patternToRustParam` (~line 856), `defToRustItem` (~line 514) | Extend pattern emission to return (paramName, prelude); thread prelude into body |
| B6 | `Can.Binop "++"` arm (~line 1138) | Branch on `taskExprInnerType`; emit chain-extend for Vec |

Estimated diff: ~80 lines added, ~50 lines removed.

## 6. Soundness gate

- B1: each removed arm is a regression risk if any current build relies
  on the bypass. Sub-A.8's tests verified the wrappers are correctly
  generated AND working — they just weren't being called. Removing the
  arms routes calls through the wrappers; the wrappers do the right
  thing. Net positive.
- B2: the fix is a strict superset (adds parens where none existed).
  Cannot create a wrong-arity call from a correct one.
- B3: the prelude-emit is added before the existing body. Non-PCtor
  patterns unchanged (they still hit PVar/PAnything/PTuple arms).
- B6: branches on type info that's already available; falls back to
  current behaviour when type info is absent. Cannot regress.

## 7. Verification

1. **Per-fix sanity build.** After each fix, `cabal build exe:sky` +
   the 16-example Rust regression must still pass.

2. **`examples/00-standard-libs` cargo error count** at each milestone:
   - Start: ~70 errors
   - After B1: expect ~50 (Std.Money bypass closed, std_money_amount
     still broken)
   - After B2 (small): expect same or -1-2 (B1 likely subsumed)
   - After B3: expect ~40 (PCtor params fixed)
   - After B6: expect ~15 (Jwt cascade closed)

3. **Cross-target regression.**
   - `examples/01-hello-world` on `target=go` builds clean.
   - `cabal test --test-options='--match "FfiGen" --match "Toml" --match "Kernel"'` → 27/0.
   - 16/16 `examples/rust/*` build + run from a wiped slate.

4. **Final headline-gate snapshot.** Run `examples/00-standard-libs` on
   target=rust one last time; capture error count + categorisation.
   If ≤20 (down from 70), proceed to status-doc update + push.

## 8. Risks & mitigations

| Risk | Mitigation |
|---|---|
| B1's arm removal breaks a working example | 16-example Rust regression sweep after each commit; rollback specific arms if needed |
| B3's `let <Pattern> = expr;` rejected by Rust borrow-checker on certain shapes | Use `match { Ctor(...) => body, _ => panic!() }` form for safety; the `_` arm is unreachable but satisfies the borrow checker |
| B6's `taskExprInnerType` returns wrong type for nested `++` chains | Defaults to `format!` on unknown; preserves current behaviour for ambiguous cases |
| A removed `Std.X` arm leaves a kernel inaccessible from another call path | Audit: the only paths that use Std.X arms are `Can.VarTopLevel` in user code. Peephole uses `("X", ...)`. Stage-4 emits `Can.VarKernel "X" _`. Both unaffected. |

## 9. Out of scope (queued for sub-A.10 or follow-up)

- **Json.Decode pipeline closure typing** (~7-10 errors). Decoder
  composition `Decoder.succeed f |= required "x" string` produces
  nested `Fn(A) -> Fn(B) -> Fn(C) -> ...` types that Rust's static
  trait system can't ergonomically express. Needs an architectural
  approach (boxed closures, macros, or runtime decoder objects).
- **Math.min/max polymorphic monomorphisation edge cases** (if any
  surface during the sweep) — current `<T: PartialOrd>` shape should
  cover everything in 00-standard-libs.
- **Sky.Test assertion-message stringification** — if a test failure
  message-format issue surfaces, document and defer.

## 10. Cross-backend safety

All changes inside `src/Sky/Generate/Rust/Builder.hs` — single file.
No runtime files, no Go files, no `FfiGen.hs` / `Compile.hs` / shared
thin-seam files. Go path: byte-identical.

`examples/01-hello-world` (target=go) is the regression canary —
clean-build it after every commit.
