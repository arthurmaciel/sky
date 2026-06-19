# Rust codegen — `Ffi.callPure` peephole + runtime-provided opaque types — Design

**Date:** 2026-05-29
**Status:** Approved (brainstorming) — ready for implementation plan
**Scope:** Sky compiler Rust codegen. TargetRust-gated; Go path byte-identical.
**Branch:** `feat/runtime-rust`
**Builds on:** Sub-project A Tasks 1-16 (commits `04ba135c..c899b9d5`, all on origin).

---

## 1. Context

Sub-project A's headline gate — `examples/00-standard-libs` on `target=rust`
passing the Crypto/Jwt/Encoding/Std.Decimal/Std.Time/Std.Money suites — is
blocked by two independent codegen issues identified at the end of the
autonomous run (commit `41342802`, status doc `docs/runtime-rust/sub-A-stdlib-parity-result.md`):

| # | Issue | Effect | Root cause |
|---|---|---|---|
| 2 | Rust codegen has no `("Ffi", "callPure")` arm in `kernelToRust` | `Std.Decimal`, `Std.Time`, `Std.Money` wrappers emit calls to an undefined `ffi_call_pure(name, args)` function | The Go target has `rt.Ffi_callPure` (`src/Sky/Generate/Go/Kernel.hs:126`); the Rust target was never given an equivalent — falls through `kernelToRust`'s snake-case default |
| 3 | Sky-declared opaque types are stubbed as `pub enum Std<X>Stub { __Internal(f64) }` | Even after Issue 2 is fixed, kernel return types (e.g. `sky_runtime::Decimal`) don't match codegen-emitted signatures (`StdDecimalDecimal`); precision is also wrong for monetary data | Codegen has no registry of which Sky types are runtime-backed |

The two issues are **gated together**: fixing one without the other still
leaves the example unbuildable. This spec proposes a paired solution.

Issue 1 — `mod.rs` regeneration missing the new sub-A modules — was already
fixed in `c899b9d5`.

## 2. Goal

After this work:

1. `examples/00-standard-libs` on `target=rust` builds cleanly and runs.
2. The Crypto/Jwt/Encoding/Std.Decimal/Std.Time/Std.Money suites print the
   **same per-test pass/fail outcomes** as `target=go`.
3. All 16 `examples/rust/*` continue to build and run (no regression).
4. The Go path is byte-identical (Cross-backend rule 5 preserved).
5. Sub-project A's headline gate is met; sub-projects B-F can begin.

## 3. Non-goals (explicit)

- **`Ffi.callTask` is deferred to sub-project D.** Sub-D introduces the
  `Sky.Http.Server` runtime which needs Task-emitting kernels anyway; the
  same peephole pattern extends naturally there. Until then, `Ffi.callTask`
  calls still drop through the snake-case default to a `ffi_call_task` symbol
  that doesn't exist — that's an acceptable boundary because no
  Crypto/Jwt/Encoding/Std.Decimal/Std.Time/Std.Money code uses `callTask`.
- **No runtime registry / `Box<dyn Any>` dispatch** for `Ffi.callPure`. The
  peephole covers 100 % of current stdlib + example usage (every observed
  call has a string-literal kernel name + literal args list).
- **No Sky-language annotation** for opaque types — keep the bridge as
  compile-time registry data (Approach A from brainstorming).
- **No new opaque-type entries beyond `Std.Decimal.Decimal`** in this spec.
  Sub-projects B-F add their own entries as their runtime types land.
- **Go backend untouched.**

## 4. Verified codebase state (grounding)

From reading the tree at HEAD `c899b9d5`:

- **`Builder.hs:1841` — `kernelToRust :: String -> String -> String`** is the
  flat dispatch table mapping `(skyModule, skyName)` to a Rust function name.
  Default fallthrough at the bottom snake-cases the input: `("Ffi", "callPure")` → `"ffi_call_pure"`.
- **`Builder.hs:2152` — `("Ffi", "kernel") -> "ffi_kernel_polyfill"`** — the
  Ffi.kernel value path already has a polyfill stub. The infrastructure for
  emitting an empty/panicking dispatch exists.
- **`Builder.hs:1720-1734` — `kernelHelperSection`** — where the
  `fn ffi_kernel_polyfill<T>(...) -> T { panic!(...) }` stub is injected
  into the generated `main.rs`. New polyfill stubs land here.
- **`Type/Constrain/Expression.hs:1162-1195`** — type-checks `Ffi.callPure`,
  `Ffi.callTask`, `Ffi.call` (deprecated alias), and `Ffi.toAny`. Confirms
  the signatures:
  - `Ffi.callPure : String -> List any -> a`
  - `Ffi.callTask : String -> List any -> Task Error a`
  - `Ffi.toAny    : a -> any`
- **`Generate/Go/Kernel.hs:126`** — Go reference: each Ffi entry registers
  with the Go runtime by name + arity. The Rust analogue at codegen level
  is what this spec adds.
- **Generated `std_decimal.rs`** (from `examples/00-standard-libs/sky-out/rust/src/`)
  literally contains:
  ```rust
  pub fn std_decimal_from_int(n: i64) -> StdDecimalDecimal {
      ffi_call_pure("Decimal_fromInt".to_string(), vec![n])
  }
  ```
  Confirming the breakage shape exactly.
- **Generated `main.rs`** contains the opaque-type stub:
  ```rust
  pub enum StdDecimalDecimal { Decimal__Internal(f64) }
  ```
  Confirming Issue 3.

## 5. Design

### 5.1 Issue 2 — Compile-time peephole for `Ffi.callPure` / `Ffi.toAny`

**Approach B (peephole).** In the Rust codegen's call-emission path, before
the existing `kernelToRust` lookup, recognize this AST shape:

```
Can.Call (Can.VarTopLevel "Ffi" "callPure") [stringLit "<KernelName>", Can.List elems]
```

When matched, parse `<KernelName>` (a `_`-separated Sky-style identifier like
`"Decimal_fromInt"`) as `(skyModule, skyFn)`, look up
`kernelToRust skyModule skyFn`, and emit a direct call:

```
<resolvedRustFn>(<emit(elem1)>, <emit(elem2)>, …)
```

This produces, for `Std.Decimal.fromInt`:

```rust
// Sky source:  Ffi.callPure "Decimal_fromInt" [n]
// Emits:        decimal_from_int(n)
```

Identical to what user-code call sites already emit (e.g. `main.rs:280`
already has `decimal_from_int(3)`), so the wrapper bodies become consistent
with the call sites — both route through the runtime kernels declared via
the existing `kernelToRust` arms (Tasks 8, 12, 14 of the prior plan).

**Ffi.toAny becomes compile-time identity.** Since the peephole eliminates
the type-erasure indirection entirely, `Ffi.toAny x` is no longer needed in
the emission. The peephole rewrites `Ffi.toAny x` (as a sub-expression of a
peephole-matched `Ffi.callPure` args list) to `emit(x)` — the value passes
through untouched, retaining its concrete Rust type.

When `Ffi.toAny` appears OUTSIDE a peephole-matched context (free-standing,
or in a non-matched `Ffi.callPure` call), it routes to a runtime polyfill
that's compile-time identity:
```rust
fn ffi_to_any_polyfill<T>(x: T) -> T { x }
```

**Fallback for non-literal callPure.** If the AST shape doesn't match the
peephole (kernel name is a variable, args list isn't a literal), emit a
panic stub:
```rust
fn ffi_call_pure_polyfill<T>(_name: String, _args: Vec<T>) -> T {
    panic!("Ffi.callPure: dynamic dispatch with non-literal kernel name is \
            not supported on target=rust; use Ffi.kernel \"<name>\" instead")
}
```

This catches surprises early with a clear actionable message.

### 5.2 Issue 3 — `runtimeOpaqueTypes` registry

**Approach A (compile-time registry).** Add to `Builder.hs`:

```haskell
-- | Sky opaque types whose Rust representation lives in `sky_runtime`.
-- When the codegen would otherwise emit a placeholder enum
-- `pub enum <CodegenName>Stub { __Internal(f64) }`, look up `(skyModule,
-- skyType)` here and emit
--     `pub use <rustPath> as <codegenName>;`
-- instead. The runtime's type IS the canonical representation; the
-- codegen-stub was a temporary placeholder.
runtimeOpaqueTypes :: Map.Map (String, String) String
runtimeOpaqueTypes = Map.fromList
    [ (("Std.Decimal", "Decimal"), "sky_runtime::Decimal")
    -- Sub-projects B-F add entries here as their runtime types land.
    ]
```

In the opaque-type emission path (location pinned in Task 0 — see §7), check
the registry and branch:

```haskell
emitOpaqueTypeDecl :: (String, String) -> [String]
emitOpaqueTypeDecl (skyMod, skyTy) =
    let codegenName = camelCase (skyMod ++ "_" ++ skyTy)  -- "StdDecimalDecimal"
    in case Map.lookup (skyMod, skyTy) runtimeOpaqueTypes of
        Just rustPath -> [ "pub use " ++ rustPath ++ " as " ++ codegenName ++ ";" ]
        Nothing       -> existingPlaceholderEmit codegenName
```

**Sky-side requirement.** The Sky source for `Std.Decimal` declares
`Decimal` as an opaque type (it has no constructors visible in the source —
the entire API is `Ffi.callPure` calls). The codegen already detects this
case and emits the placeholder; we're hooking the same detection point.

### 5.3 What does NOT change

- `kernelToRust`'s existing arms (Encoding/Regex/Crypto/Time/Decimal/Money,
  etc., already added in sub-A Tasks 2/4/8/12/14). The peephole calls
  `kernelToRust` to resolve names — same data, same arms.
- `runtime-rust/src/sky_runtime/` kernel implementations (encoding.rs,
  regex_kernel.rs, crypto.rs, jwt.rs, time.rs, decimal.rs). They're complete
  for sub-A.
- `Project.hs`'s `mod.rs` generation (already fixed in `c899b9d5` to declare
  the new modules).
- Go target codepaths. `Generate/Go/Kernel.hs:126`'s `rt.Ffi_callPure` arm,
  `runtime-go/rt/`, the generated `kernel.json`, anything Go-related.

## 6. Soundness gate

The peephole is purely additive — it adds an arm BEFORE the existing
fallback. Any AST shape it doesn't match falls through to the prior path.
Existing Sky.Core.* kernel emission (which works today) is unaffected.

The opaque-type registry is also additive — only `("Std.Decimal", "Decimal")`
gets the new bridge; every other Sky opaque type still emits the placeholder
enum exactly as today.

Cross-backend invariant: every change is inside `src/Sky/Generate/Rust/Builder.hs`
and possibly the kernelHelperSection. No Go file. No shared upstream-merge
surface that the thin-seam refactor protected.

## 7. Outstanding investigation (Task 0 — must precede implementation)

Two file/line ranges aren't pinned by this spec and must be located before
Tasks 3 and 6 can be implemented with exact code:

1. **The call-emission site for `Can.Call` AST nodes in Builder.hs.** The
   peephole inserts here. Search for `Can.Call`, `Can.VarTopLevel`,
   `emitCall`, `emitApp`, or similar. The peephole arm wraps the existing
   path.
2. **The opaque-type emission site in Builder.hs.** Probably near
   `userTypeSection` (line ~1737 from the earlier read), or in a
   `typeDefToString` helper. Search for `__Internal`, `f64` placeholder,
   `pub enum`, or `userTypes`.

Task 0's deliverable is a one-line breadcrumb naming each file:line where
Tasks 3 and 6 will edit. With those pinned, both tasks become straight
mechanical inserts.

## 8. Verification

1. **Cabal-level codegen tests** (existing `test/Sky/Build/` infrastructure):
   - Add a test fixture: Sky source containing `Ffi.callPure "Decimal_fromInt" [42]`
     and assert the generated Rust contains exactly `decimal_from_int(42)`
     (NOT `ffi_call_pure("Decimal_fromInt".to_string(), vec![42])`).
   - Add a fixture for `Ffi.toAny x` inside an Ffi.callPure args list →
     assert the toAny is elided.
   - Add a fixture for Sky `Std.Decimal.Decimal` → assert the generated
     code contains `pub use sky_runtime::Decimal as StdDecimalDecimal;`
     (NOT `pub enum StdDecimalDecimal`).

2. **Inspector + runtime unit tests** unchanged — they already pass; this
   spec doesn't touch them.

3. **Cross-target regression sweep** (must remain green after every commit):
   - `examples/01-hello-world` builds with `target=go`. (Go regression.)
   - `cabal test --test-options='--match "FfiGen" --match "Toml" --match "Kernel"'`
     → 27 pass / 0 fail.
   - All 16 `examples/rust/*` build + run from a clean slate.

4. **Headline gate — `examples/00-standard-libs` on `target=rust`:**
   - `cd examples/00-standard-libs && rm -rf sky-out .skycache`
   - Temporarily add `target = "rust"` to `sky.toml`.
   - `../../sky-out/sky run src/Main.sky 2>&1 | tail -40`
   - Expected: same per-suite pass/fail output as `target=go` for these
     suites: String, List, Dict, Maybe, Result, Math, Crypto, Jwt,
     Encoding, Json, Std.Decimal, Std.Money, Std.Time.
   - Out-of-scope suites (Std.Auth needs sub-C; Std.Db needs sub-B; Live needs
     sub-E; etc.) are expected to fail with clear errors documenting which
     sub-project covers them — that's NOT a regression.
   - Restore the original `sky.toml` after verification.

5. **Coverage doc update.** Update `docs/runtime-rust/sub-A-stdlib-parity-result.md`
   with the actual per-suite pass count + list of suites achieving parity.

## 9. Risks & mitigations

| Risk | Mitigation |
|---|---|
| Peephole misses a real AST shape variant (e.g. let-bound kernel name) | Fallback polyfill panics with a clear "use Ffi.kernel instead" message; widen the peephole if a stdlib case requires it |
| Peephole AST pattern doesn't match the actual canonicalized form (Ffi.callPure may be inlined / curried by an earlier compile pass) | Task 0's investigation includes printing a sample AST for `Ffi.callPure "X" [y]`; pattern adapted to whatever canonicalisation produces |
| `kernelToRust` arms missing for a kernel referenced via `Ffi.callPure` | Peephole falls back to polyfill with the unresolved kernel name in the panic message → discoverable; add the missing arm |
| Opaque-type registry collides with user-defined types | Registry is keyed on `(Sky module, Sky type)` — user's `MyModule.Decimal` doesn't collide with `Std.Decimal.Decimal` |
| Other opaque types still emit broken stubs (Std.Time may have one) | Registry is additive — add entries as discovered; the headline-gate run will surface them |
| Inconsistent existing `ffi_to_any` emission in the generated code | Peephole completely replaces the existing emit path for matched calls; the leftover non-peephole paths drop through to the polyfill (which is now compile-time identity for toAny) |

## 10. Cross-backend safety

All changes:

- **`src/Sky/Generate/Rust/Builder.hs`** — Rust-target-only logic (`kernelToRust`,
  `kernelHelperSection`, the call-emission path, opaque-type emission path).
- **`runtime-rust/src/sky_runtime/`** — possibly a new `ffi_polyfills.rs`
  with the panic stubs and `ffi_to_any_polyfill` identity. Pure Rust runtime.

**Untouched:** `src/Sky/Build/FfiGen.hs`, `src/Sky/Build/Compile.hs`,
`src/Sky/Build/Rust/Ffi.hs`, `src/Sky/Generate/Go/`, `runtime-go/`,
`.skycache/ffi/*.kernel.json` at root, `app/Main.hs`, any `.sky` file.
Go backend is byte-identical.

## 11. Out of scope / follow-on specs

- `Ffi.callTask` Rust-target support — folded into sub-project D
  (`Sky.Http.Server`), which needs Task-emitting kernels for its handlers.
  Same peephole pattern, same registry hook; trivially symmetric.
- Adding more entries to `runtimeOpaqueTypes` as sub-projects B-F land:
  - B: `Std.Db.Connection`, `Std.Db.Row` (if they need runtime backing).
  - C: `Std.Auth.Token`, `Std.Money.Money` (if Money becomes runtime-backed
    instead of Sky-side ADT).
  - D: HTTP-related opaques (Request/Response).
  - E: Sky.Live session-store opaques.
  - F: Sky.Tui terminal-handle opaques.
- Sky-language `Ffi.opaqueType` annotation (Approach B from brainstorming) —
  deferred unless the registry grows past ~10 entries and becomes annoying
  to maintain.
