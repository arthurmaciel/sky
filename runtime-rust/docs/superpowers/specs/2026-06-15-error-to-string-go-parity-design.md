# errorToString Go-parity — design

**Divergence id:** `error-to-string-dumps-struct`
**Disposition:** **DOCUMENT_BLOCKED** (the IMPLEMENT below was attempted, then
reverted — it does not compile; see "Verification correction").
**Date:** 2026-06-15

## Verification correction (supersedes the IMPLEMENT below)

Re-bounding `basics_error_to_string` from `T: Debug` to `T: Display` **fails to
compile**. `Sky.Test.debugShow v = errorToString v` is `debugShow : a -> String`
— **generic** — so `sky_test.rs` calls `basics_error_to_string(v)` on a bare
type parameter `a` that has no `Display` bound → `E0277: 'a' doesn't implement
Display` (sky_test.rs:44), breaking every `Sky.Test` program (standard-libs's
131 assertions failed to compile). This is the *same* blocker as composite
`Basics.toString`: the only fully-general fix threads a `SkyShow` bound through
every generic signature (a codegen-wide epic), and `Debug` is retained precisely
because it is total for any type — the universal-stringifier requirement
`debugShow : a -> String` imposes. The String-quoting divergence (`"hi"` vs
`hi`) is therefore **DOCUMENT_BLOCKED**, not implementable in-boundary. The
Debug-based runtime is restored unchanged.

---
*(Original IMPLEMENT analysis retained below for the divergence write-up — its
disposition is wrong; the divergence is real but blocked.)*

## Problem

The triage filed this as DOCUMENT_AT_PARITY: *"Both backends dump the error
record (Rust `Debug`, Go `%v`). Not Rust-specific."* That premise is **false**.

| Backend | `errorToString` impl | `errorToString "hi"` | `errorToString 42` |
|---|---|---|---|
| Go (`rt.go:1522` `Basics_errorToString`) | `switch x.(type)`: `string`→verbatim, `error`→`.Error()`, default→`%v` | `hi` | `42` |
| Rust (`basics.rs:34` `basics_error_to_string`) | unconditional `format!("{:?}")` (Debug) | `"hi"` (quoted) | `42` |

Go is **not** a plain `%v` dump — it special-cases `string` and `error` and
only falls back to `%v` for composites. Rust Debug-formats unconditionally, so
the **String path diverges observably**: `"hi"` (quoted) vs `hi` (unquoted).
The committed test `test_error_to_string_string` (basics.rs:73) even *asserts*
the quoted output — the divergence is baked into the test, not incidental.

### Why the String path is load-bearing, not a corner case

`sky-stdlib/Sky/Test.sky:293` defines `debugShow v = errorToString v`. So this
kernel is the single universal stringifier behind:

- every `Sky.Test.assertEqual` / `assertNotEqual` failure message
  (`"expected " ++ debugShow expected ++ " but got " ++ debugShow actual`)
- every `Result.mapError errorToString` in user code

A failing `assertEqual "ok" "no"` prints `expected "ok" but got "no"` on Rust
vs `expected ok but got no` on Go. That is exactly the equiv-sweep silent-diff
class the Rust backend exists to eliminate.

## Answers to the asker's questions

**Q1 — real divergence or remove from the list?**
Real, observable, Rust-specific on the String path. Triage verdict is wrong;
disposition is IMPLEMENT.

**Q2 — precedence of the three sibling stringifiers; does `errorToString` need
Debug?**

| Sky fn | Rust impl today | Go reference | Correct Rust |
|---|---|---|---|
| `Basics.toString` | `Display` (`basics_to_string`) | `%v` | unchanged — correct |
| `Debug.toString` (interp) | `Display` (`debug_to_string`) | `String→s` else `%v` | unchanged — correct |
| `errorToString` / `debugShow` | **Debug** (`basics_error_to_string`) | `string`→verbatim, `error`→`.Error()`, default→`%v` | **must become string-verbatim + Display-fallback** |

`errorToString` does **not** need Debug semantics. Go never quotes the string
arm. The Debug bound was the wrong choice; it should be `Display`-based with the
string arm preserved verbatim (which `Display` on `String` already gives —
`format!("{}", s)` is `s`). No call site needs structural Debug dumping that
`Display` can't provide: `debugShow` on a record/ADT already had no `Display`
on Rust, and that composite case is governed by the separate "composite
`Basics.toString`" divergence (type-directed lowering), not this one.

**Q3 — fixable purely in-boundary?**
Yes. Routing lives in `src/Sky/Generate/Rust/Builder/Kernel.hs:299-300` +
`ExprEmitter.hs:1835` (`genFnArgType … = Just "SkyError"`); impl lives in
`runtime-rust/src/sky_runtime/basics.rs`. No shared-stdlib edit
(`Sky/Test.sky`, `Sky/Core/Error.sky` untouched), no Go edit. The fix is a
**trait-bound + body change on `basics_error_to_string`** — `Debug` → `Display`.
No new type-directed routing at codegen is required because the codegen already
emits a single monomorphic call; only the runtime function's contract changes.

**Q4 — monomorphised Rust vs Go's runtime `switch x.(type)`; is there an
`error` arm?**
Rust knows the concrete `T` at each call site (no `dyn Any`). The three-way Go
branch collapses to a **two-way** one in Rust:

- Go's `string` arm and `default %v` arm both become `format!("{}", v)` under a
  `T: Display` bound — `Display` on `String` is verbatim (matching the `string`
  arm) and `Display` on a scalar matches `%v`. **One bound covers both arms.**
- Go's `error` arm (`x.Error()`) **collapses**. Sky's `Error` lowers to a
  concrete Rust type — either the `SkyCoreErrorError` ADT or
  `type SkyError = String` (`Emitter.hs:298/306`), never a `dyn Error`. There
  is no Rust trait-object `error` to dispatch on. The `Error` ADT's rendering
  is `Error.toString`'s job in Sky source, not this kernel's. So no `error`
  arm is needed.

**Q5 — composite/record parity: byte-identical or readable dump?**
Not byte-identical, and **not in scope here**. Go `%v` on the `Error` ADT
(`{Io {...}}`) vs Rust `{:?}` (`Error(Io, ErrorInfo { ... })`) will always
differ in separators/tags — that is the *separate* "composite `Basics.toString`"
divergence (needs type-directed lowering to a derived renderer). The parity
contract that real programs hit via `Result.mapError errorToString` and
`Sky.Test.debugShow` is the **String / scalar path**, and that is what this fix
pins. After the fix, the composite case still differs but the dominant
String/scalar path is byte-identical to Go.

**Q6 — existing fixture? precondition?**
No equiv-sweep example currently exercises `errorToString`/`debugShow` on a
String. Per "never ship something you cannot verify", the fix **must land with**
a `runtime-rust/tests/` regression that pins the Go-reference output. The
existing `test_error_to_string_string` asserts the *wrong* (quoted) value and is
updated to the Go-reference (unquoted) value as part of the fix — that flipped
assertion is itself the regression lock.

## Disposition + rationale

**IMPLEMENT.** A root-cause fix exists entirely within
`runtime-rust/src/sky_runtime/basics.rs`. Re-bound `basics_error_to_string`
from `T: Debug` (`{:?}`) to `T: Display` (`{}`), so the String arm is verbatim
(Go-parity) and scalars match `%v`. No codegen change is strictly required —
the kernel name routing already exists; only `genFnArgType`'s `SkyError` hint
must stay valid, which it does (`SkyError` impls `Display` whether it aliases
`String` or the `SkyCoreErrorError` ADT — see verification note). This is a
behavioral-Go-parity correctness fix at the highest applicable principle tier
(correctness/Go-parity) with no security/soundness cost.

## Principle check

- **No shared-stdlib / Go edit:** confirmed — change is in
  `runtime-rust/src/sky_runtime/basics.rs` + its test only. `Sky/Test.sky`,
  `Sky/Core/Error.sky`, `runtime-go/`, `src/Sky/Generate/Go/` untouched.
- **No `Any` / no panic:** `format!("{}", v)` over a `Display` bound — total,
  no downcast, no `unwrap`. Composites without `Display` fail at **compile**
  time (E0277), never at runtime — same total-by-construction guarantee the
  sibling `basics_to_string` already documents.
- **Verifiable here:** Rust unit test in `runtime-rust/tests/` (or the
  in-file `#[cfg(test)]` mod) pins the Go-reference output; an equiv-sweep CLI
  example can additionally diff Go≡Rust stdout.

## Root-cause change (exact)

`runtime-rust/src/sky_runtime/basics.rs`:

```rust
// before: pub fn basics_error_to_string<T: std::fmt::Debug>(v: T) -> String { format!("{:?}", v) }
pub fn basics_error_to_string<T: std::fmt::Display>(v: T) -> String {
    format!("{}", v)
}
```

Doc-comment updated: the kernel mirrors Go's `Basics_errorToString` string-
verbatim / `%v`-fallback (Display), NOT `{:?}` Debug. The `error`-interface arm
of Go collapses because Sky's `Error` is always a concrete Rust type here.

Test update (`basics.rs` `#[cfg(test)]`):

```rust
#[test] fn test_error_to_string_string() {
    // Go-parity: Basics_errorToString returns the string verbatim (unquoted).
    assert_eq!(basics_error_to_string("hi".to_string()), "hi");
}
```

(`test_error_to_string_i64` stays `"42"`; `test_error_to_string_vec` is
removed/replaced — `Vec` has no `Display`, so it would not compile under the new
bound, which is the intended total-by-construction behavior. A composite render
is the separate type-directed-lowering divergence, not this kernel's job.)

## Verification plan

1. `cargo test -p sky-runtime basics::tests::test_error_to_string_string`
   (and the `i64` scalar test) — pins Go-reference unquoted output.
2. Confirm `SkyError` satisfies `Display` in a generated project: when the
   Error ADT is present, the emitted `SkyCoreErrorError` must derive/impl
   `Display`; if it only derives `Debug`, the `genFnArgType … SkyError` hint at
   a `errorToString err` call site would fail to compile — that compile error is
   caught at build time, not runtime (no-panic preserved). Verification:
   `sky build --target rust` on an example that calls `errorToString` on an
   `Error` value. If E0277 surfaces, the follow-up is a `Display` impl for the
   Error ADT in the Rust emitter (still in-boundary) — track as a sub-item, not
   a blocker for the String-path fix.
3. Optional equiv-sweep CLI example: `Result.mapError errorToString` on a
   String error → diff Go≡Rust stdout (`/sky-rust-backend:equiv-sweep`).
4. README divergence row flipped to resolved with this rationale.
