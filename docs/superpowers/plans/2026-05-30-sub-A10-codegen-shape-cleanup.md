# Sub-A.10 — Codegen-shape cleanup — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development or superpowers:executing-plans.

**Goal:** Close 26 of the remaining 36 cargo errors on `examples/00-standard-libs` target=rust (deferring 10 JsonDecoder pipeline errors to sub-A.11).

**Architecture:** Six surgical fixes — C1-C6 from `docs/superpowers/specs/2026-05-30-sub-A10-codegen-shape-cleanup-design.md`.

---

## Preconditions

- Branch `feat/runtime-rust` at `4221a1eb` (after spec commit).
- `mem-guard.sh` running. Clean working tree.
- 16/16 `examples/rust/*` build clean.

---

## Task 1: C1 — `Sky.Core.Json.Encode.Value` → `sky_runtime::JsonVal`

**Files:** `src/Sky/Generate/Rust/Builder.hs`

- [ ] **Step 1:** Add `(("Sky.Core.Json.Encode", "Value"), "sky_runtime::JsonVal")` entry to `runtimeOpaqueTypes`.

- [ ] **Step 2:** Extend `ffiPlaceholder` to consult a reverse-keyed map:

```haskell
ffiPlaceholder :: String -> String
ffiPlaceholder name =
    case Map.lookup name reverseRuntimeOpaque of
        Just path -> "pub use " ++ path ++ " as " ++ name ++ ";"
        Nothing   -> "type " ++ name ++ " = String;"
  where
    reverseRuntimeOpaque = Map.fromList
        [ (toCamelCase (modPrefix ++ "_" ++ ty), path)
        | ((mod', ty), path) <- Map.toList runtimeOpaqueTypes
        , let modPrefix = map (\c -> if c == '.' then '_' else c) mod'
        ]
```

- [ ] **Step 3:** Build + smoke test + measure error count. Commit.

---

## Task 2: C2 — Std.Time return wrapping

**Files:** `runtime-rust/src/sky_runtime/time.rs`

- [ ] **Step 1:** Convert `time_from_parts`, `time_zone_offset`, `time_zone_name` to return `SkyResult<E, T>`:

```rust
pub fn time_from_parts<E: From<String>>(y: i64, m: i64, d: i64, h: i64, mi: i64, s: i64, ms: i64) -> SkyResult<E, i64> {
    match NaiveDate::from_ymd_opt(y as i32, m as u32, d as u32)
        .and_then(|day| day.and_hms_milli_opt(h as u32, mi as u32, s as u32, ms as u32)) {
        Some(naive) => SkyResult::Ok(Utc.from_utc_datetime(&naive).timestamp_millis()),
        None => SkyResult::Err(format!("invalid date parts: {}-{}-{} {}:{}:{}.{}", y, m, d, h, mi, s, ms).into()),
    }
}
```

Similar for `time_zone_offset` and `time_zone_name`.

- [ ] **Step 2:** Update existing unit tests to use `SkyResult<String, T>`.

- [ ] **Step 3:** Build, test, commit.

---

## Task 3: C3 — `Dict.empty` + `Math.pi`/`e` zero-arg kernels

**Files:** `src/Sky/Generate/Rust/Builder.hs`

- [ ] **Step 1:** Add entries to `zeroArgKernelDefs`:

```haskell
zeroArgKernelDefs = Set.fromList
    [ ("JsonDec", "string"), ("JsonDec", "int"), ("JsonDec", "float"), ("JsonDec", "bool"), ("JsonDec", "null")
    , ("Dict", "empty"), ("Sky.Core.Dict", "empty")
    , ("Math", "pi"), ("Math", "e"), ("Sky.Core.Math", "pi"), ("Sky.Core.Math", "e")
    ]
```

- [ ] **Step 2:** Build, smoke test, commit.

---

## Task 4: C4 — Monomorphise decoders

**Files:** `runtime-rust/src/sky_runtime/encoding.rs`

- [ ] **Step 1:** Convert `base64_decode`, `url_decode`, `encoding_hex_decode` from generic `<E: From<String>>` to concrete error type. The runtime defines `SkyError` only at use site; safer is to keep `From<String>` but pin via codegen turbofish.

Simpler approach: change runtime to use a concrete public type alias `SkyRtError` that user code can re-alias.

Actually simplest: keep the generic, but when called from codegen, the kernel call should be wrapped in a context where E is inferable. Looking at how the rust codegen emits the call sites — `base64_decode(encoded)` doesn't pin E. The Sky-source wrapper `Encoding.base64Decode : String -> Result Error String` does have a typed return. The wrapper's body calls the kernel; the kernel's E should unify with `SkyError`.

Best approach: pin in codegen via turbofish at the peephole site. When peephole rewrites `Ffi.callPure "Encoding_base64Decode" [s]`, emit `base64_decode::<SkyError>(s)` if the result type is constrained.

For sub-A.10, the simpler approach: monomorphise these three functions in the runtime — they're only called from codegen-generated code anyway. Replace generic E with concrete `String` (rust's most flexible String-based error).

Actually — the runtime tests use `SkyResult<String, String>` which is what String impl. The codegen uses `SkyResult<SkyError, T>`. These don't match.

**Final plan:** Make the runtime kernel return `SkyResult<String, T>` (concrete). Then codegen call sites have type `SkyResult<String, T>` which mismatches the wrapper's `SkyResult<SkyError, T>`. The wrapper needs a `.map_err(SkyError::from)` or similar.

Actually the cleanest fix: introduce a runtime-side `to_sky_error` conversion in the runtime crate. The `From<String>` impl for `SkyError` is part of the generated code (`str_err`). So the generic `<E: From<String>>` IS the right signature — call sites should unify E with `SkyError`.

The `E0283 type annotations needed` error fires because Rust doesn't have enough context to pick a single E. The Sky wrapper might be using the result in a `match` that doesn't constrain.

Quick fix: emit a turbofish in the codegen at the peephole. When peephole fires for `Encoding_base64Decode` etc., emit `base64_decode::<SkyError>(s)`.

- [ ] **Step 1 (revised):** Extend the codegen peephole to emit `::<SkyError>` turbofish for kernels with `<E: From<String>>` signatures. Build a small list of kernel names that need this:

```haskell
peepholeNeedsErrorPin :: String -> Bool
peepholeNeedsErrorPin "base64_decode"      = True
peepholeNeedsErrorPin "url_decode"         = True
peepholeNeedsErrorPin "encoding_hex_decode" = True
peepholeNeedsErrorPin _ = False
```

And modify the peephole arm:
```haskell
Can.Call (Ann.At _ (Can.VarKernel "Ffi" fnName))
         [Ann.At _ (Can.Str kernelName), Ann.At _ (Can.List argExprs)]
    | fnName == "callPure" || fnName == "call" ->
        let (skyMod, skyFn) = splitKernelName kernelName
            rustFn = kernelToRust skyMod skyFn
            args = map (peepholeArg ctx) argExprs
            tf = if peepholeNeedsErrorPin rustFn then "::<SkyError>" else ""
        in rustFn ++ tf ++ "(" ++ intercalate ", " args ++ ")"
```

Hmm wait — these aren't called via `Ffi.callPure`. They're called directly as kernel functions through `kernelToRust` arm dispatch (Sky.Core.Encoding.base64Decode uses Ffi.kernel, not Ffi.callPure). Different code path.

The right place: emit turbofish at the `Can.VarKernel` arm when the kernel function needs it. But the call wrap is at the outer `Can.Call` arm. Need to either:
- Modify `Can.VarKernel` to include the turbofish in the callee string
- Modify `emitDefaultCall` to detect and inject

Simpler: monomorphise the runtime. Replace `<E: From<String>>` with concrete `String`:

```rust
pub fn base64_decode(s: String) -> SkyResult<String, String> { ... }
```

Wait but the codegen call expects `SkyResult<SkyError, String>`. Different.

OK let me just take the pragmatic path: extend kernelToRust to a non-existent suffix like `_skyerr` for these kernels, and provide both monomorphised variants in the runtime — `base64_decode<E>` (generic, kept for runtime tests) and `base64_decode_skyerr` (mono for codegen). Then codegen arms route to `_skyerr` versions.

Actually the simplest is: ADD the SkyError concrete versions to the runtime, route codegen arms to them, leave the generic versions for runtime tests.

- [ ] **Alt Step 1:** Add monomorphised SkyError versions to encoding.rs:
```rust
pub fn base64_decode_se(s: String) -> SkyResult<SkyError, String> { base64_decode(s) }
pub fn url_decode_se(s: String) -> SkyResult<SkyError, String> { url_decode(s) }
pub fn encoding_hex_decode_se(s: String) -> SkyResult<SkyError, String> { encoding_hex_decode(s) }
```

But `SkyError` is defined in the generated code, not in runtime-rust. Can't reference it.

OK, monomorphise to a runtime-defined type. Define `SkyRtError = String` in runtime, change generics to use that:

This is getting complex. **Pragmatic approach for sub-A.10:** patch the codegen to wrap decoder calls in a turbofish. When emitting a call to base64_decode etc., add `::<SkyError>`. This is a focused codegen patch.

- [ ] **Step 1 (final plan):** Add a turbofish-injection arm in `Builder.hs` at the call-emit path. After the existing `Can.Call` arms, detect kernel calls that need error-type pinning and inject the turbofish before the args.

Build, smoke test, commit.

---

## Task 5: C5 — CurrencyRaw &str → String

**Files:** `src/Sky/Generate/Rust/Builder.hs` (case-arm emission)

- [ ] **Step 1:** Find the case-arm emission for `PStr` literal cases with PVar fallthrough. When emitting `match str_val { "USD" => ..., other => CurrencyRaw(other) }`, the `other` is `&str`. Insert `.to_string()` conversion when the wildcard is bound to a `&str` and used as a `String` constructor arg.

This needs investigation — find the codegen path.

- [ ] **Step 2:** Build + smoke + commit.

---

## Task 6: C6 — Inner closure m.clone()

**Files:** `src/Sky/Generate/Rust/Builder.hs`

- [ ] **Step 1:** Investigate the codegen for nested Sky lambdas where the outer captures a non-Copy var and the inner uses it. Identify the `Can.Lambda` arm path.

- [ ] **Step 2:** Inject `.clone()` in the inner closure body for captured non-Copy vars.

- [ ] **Step 3:** Build + smoke + commit.

---

## Task 7: Full sweep + headline gate

- [ ] **Step 1:** Install fresh binary, 16-example regression sweep.
- [ ] **Step 2:** Run binaries.
- [ ] **Step 3:** Go regression.
- [ ] **Step 4:** Targeted cabal test.
- [ ] **Step 5:** Final headline-gate snapshot — expect 0 errors or ≤10 (JsonDecoder pipeline).
- [ ] **Step 6:** If 0 errors, run binary: `120 passed, 0 failed`.
- [ ] **Step 7:** Update status doc.

---

## Task 8: Hygiene + report

- [ ] **Step 1:** Background-task cleanup.
- [ ] **Step 2:** `git log --oneline 4221a1eb..HEAD`.
- [ ] **Step 3:** Do NOT push (await user).
