# Task 0 — Investigation notes

Pins for the codegen-completion plan (`docs/superpowers/plans/2026-05-29-rust-codegen-ffi-callpure-opaque-types.md`).

## Insertion points

### Peephole (Tasks 3 + 4) — call-emission

**File:** `src/Sky/Generate/Rust/Builder.hs`
**Function:** `exprToRustInner :: EmitCtx -> Can.Expr_ -> String`
**Outer line:** 1093-1094 (definition)
**`Can.Call fn args` arm:** **line 1146**

The existing arm dispatches via `emitDefaultCall ctx fn calleeName args` after special-casing `succeed`-currying and `println`. The peephole goes BEFORE this arm — pattern-match the Ffi shape first, fall through if it doesn't match.

The `Ffi.toAny` peephole (Task 4) inserts a `Can.Call (Ann.At _ (Can.VarKernel "Ffi" "toAny")) [inner]` arm at the same scope, also before the existing arm.

### Opaque-type registry swap (Task 6)

**File:** `src/Sky/Generate/Rust/Builder.hs`
**Construction site:** `unionToRustTypeDef`, **line 705-711**

```haskell
unionToRustTypeDef :: Map.Map String String -> String -> String -> Can.Union -> RustTypeDef
unionToRustTypeDef recordMap modPrefix typeName (Can.Union _ alts _ _) =
    REnumDef (toCamelCase (modPrefix ++ "_" ++ typeName)) (map ctorToRust alts)
```

**Caller:** `buildProgram` at **line 1557-1559**, passing `moduleNameToRust (Can._name m)` as the prefix (mangles dots → underscores).

**Emission site:** `typeDefToString` at **line 1812-1817** — flat dispatch over RustTypeDef.

### How `Std.Decimal.Decimal` actually emits today

The Sky source declares:
```elm
type Decimal
    = Decimal__Internal Float
```
(`sky-stdlib/Std/Decimal.sky:39-40`).

So it's a `Can.Union` with one constructor `Decimal__Internal` carrying a `Float` argument. `unionToRustTypeDef` produces:
```haskell
REnumDef "StdDecimalDecimal" [("Decimal__Internal", Just "f64")]
```
…and `typeDefToString` renders the placeholder:
```rust
pub enum StdDecimalDecimal {
    Decimal__Internal(f64)
}
```

That's exactly what shows up at `examples/00-standard-libs/sky-out/Rust/src/main.rs:112-114`. The "placeholder" isn't a special-case — it's the regular union path with a Sky-side phantom `Float` field that's only there to give the constructor a slot.

## Can.Call AST shape for `Ffi.callPure`

`Ffi.callPure` is registered as a kernel in `src/Sky/Canonicalise/Module.hs:1308`:
```haskell
, ("Ffi",     ["call", "callPure", "callTask", "has", "isPure", "toAny", "kernel"])
```
…which makes every reference to it land as `Env.VarKernel "Ffi" "callPure"` (Module.hs:554, 571), and in the canonical AST as **`Can.VarKernel "Ffi" "callPure"`**.

Type signature (`src/Sky/Type/Constrain/Expression.hs:1162-1167`):
```haskell
("Ffi", "callPure") ->
    Just $ T.Forall ["a"]
        (T.TLambda stringType
            (T.TLambda
                (T.TType ModuleName.list "List" [T.TVar "any"])
                (T.TVar "a")))
```

Concrete AST shape (after canonicalisation + curried-call resolution):
```haskell
Can.Call (Ann.At _ (Can.VarKernel "Ffi" "callPure"))
         [ Ann.At _ (Can.Str "Decimal_fromInt")
         , Ann.At _ (Can.List [ Ann.At _ <argExpr1>, … ])
         ]
```

## Relevant constructors (verified against `src/Sky/AST/Canonical.hs:72-97`)

| Constructor | Shape | Use in peephole |
|---|---|---|
| `Can.VarKernel String String` | module, fn — both literal strings | Match `Ffi.callPure`, `Ffi.callTask`, `Ffi.toAny` callees |
| `Can.VarTopLevel ModuleName.Canonical String` | qualified module, fn | NOT used by Ffi — those are VarKernel |
| `Can.Str String` | string literal | Match peephole's first arg (kernel name) |
| `Can.List [Expr]` | list literal | Match peephole's second arg (args list) |
| `Can.Call Expr [Expr]` | application | Outer shape; expr arg is `Ann.At _ Expr_` |

## How `Ffi.toAny` emits today (free-standing)

`Can.VarKernel "Ffi" "toAny"` dispatches through `kernelToRust "Ffi" "toAny"` which currently has no arm — it falls through the snake-case default to `ffi_to_any`, an undefined symbol. Task 1 adds the arm pointing to `ffi_to_any_polyfill` (Task 2's runtime stub). Task 4 then short-circuits the `Can.Call (Can.VarKernel "Ffi" "toAny") [inner]` AST shape directly to `emit(inner)`.

## Sub-A modules using `Ffi.callPure`

- `sky-stdlib/Std/Decimal.sky` (most — every wrapper)
- `sky-stdlib/Std/Time.sky` (zone math)
- `sky-stdlib/Std/Cmd.sky`
- `sky-stdlib/Std/Log.sky`
- `sky-stdlib/Std/PubSub.sky`

The Std.Decimal + Std.Time wrappers are the ones the sub-A headline gate needs working.

## What this confirms for the plan

- The peephole pattern in Tasks 3 + 4 matches `Can.VarKernel` (not `Can.VarTopLevel` — that path is for user-defined functions).
- Task 6's registry hook is best placed inside `unionToRustTypeDef`: pre-check the registry on `(skyModName, typeName)` and either produce a new `RPubUseAlias` variant or the existing `REnumDef`. The caller (`buildProgram`, line 1557-1559) needs to thread the original Sky module name (`ModuleName._name (Can._name m)`) alongside the mangled prefix.
- Adding `RPubUseAlias String String` as a new `RustTypeDef` variant is a smaller diff than threading conditional logic through every typedef call site, and centralises the new emission in `typeDefToString`.
