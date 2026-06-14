# FFI builder-setters + lifetime-elided copies — design

**Status:** approved (brainstorm 2026-06-14) · **Branch:** `feat/runtime-rust`
**Scope:** Rust backend only (`tools/sky-ffi-inspect-rs/`, `src/Sky/Build/Rust/`).
No Go, no shared `sky-stdlib`.

## 1. Why — the measurement that redirected here

The original "FFI-tail" item (borrowed/nested/tuple slice **element** coercion,
e.g. `&[&str]`) was **refuted by measurement**, not deferred. A new diagnostic
`--audit` mode on the inspector (tags every tail-filter `return None` with
reason + whether the dropped fn is constructable) was run over the full
50-crate `ffi-audit` sample:

| metric | value |
|---|---|
| functions auto-bound | 2552 |
| `array_slice` drops | 69 (28 "valuable") |
| …addressable by element coercion | **1** (redis `&[Vec<u8>]`) |
| `&[&str]` borrowed-element drops, all crates | **0** |
| `lifetime` drops | 1377 (152 valuable) |
| `result_borrow` drops | 742 (12 valuable + the bulk of builder setters) |

**Conclusion:** element coercion is worth ~1/2552 functions → closed as
*intentionally-unsupported sound floor*. The real lost surface is the
**builder / borrowed-handle class**, dominated by lifetime/borrow-typed core
APIs. This spec targets the **tractable** part of that class.

## 2. Goal / non-goals

**Goal — recover two sound, in-boundary surfaces:**
1. **Self-returning + in-place setters** (the builder unlock) — `&mut self`/`self`
   methods that return the receiver (`Self`/`&mut Self`/`RecvType`) **or `()`**.
2. **Lifetime-elided owned copies** — `&'lt str`/`&'lt [u8]`/`&'lt OsStr`/`&'lt Path`
   dropped only for an explicit lifetime token.

**Non-goals (separate epics, recorded in README FFI-reach, not built here):**
- Lifetime-bound *handles* that borrow a live parent (`Statement<'_>`,
  `Transaction<'_>`, `EntityCommands<'a>`, `OccupiedEntry<'a>`) → Sky-native
  modules (Alt-3) or self-referential machinery.
- Borrowed-view *iterators* (`StreamDeserializer`, `PathSegmentsMut`).
- Config-record facade grouping (rejected — see §6).

## 3. Soundness ground truth

| Fact | Source | Consequence |
|---|---|---|
| Sky var used ≥2× emits `.clone()`; opaque FFI values are owned, threaded by Clone | `ExprEmitter.hs:89,348` | owned-threading wrapper **moves** the receiver → needs **no** Clone, no lifetime |
| Inspector already drops non-coercible borrows/arrays *pre-codegen* | `main.rs:719-755` | the floor is sound; we are **relaxing** specific drops, never loosening into broken bindings |
| `&str`→`String`, `&[u8]`→`Vec<u8>` copy-to-owned already exist | `Ffi.hs:413-418, 377-395` | Piece 2 needs **zero** codegen change |

The existential guarantee (no panic / no runtime error from well-typed Sky) is
preserved: every new path is `match`/move-only, no `unwrap`/`expect`/`Any`.

## 4. Piece 1 — owned-threading setters

### 4.1 Detection (inspector, `parse_fn_item`)

A function is a **self-returning setter** when the receiver is **`&mut self`**
(not `self`, not `&self`) **and** the result is one of:
- `&mut Self` / `&mut RecvType` — a *mutable reference back to the receiver*
  (the unambiguous fluent-setter shape), **or**
- `()` — an in-place setter.

**Why only `&mut Self`, never a by-value `-> Self`:** a by-value
`fn split_off(&mut self, at) -> Self` (e.g. `bytes::Bytes`) returns a *new*
value (the split-off tail) while mutating self — own-threading it would
silently discard that return. So by-value `-> Self` / `-> RecvType` keeps the
normal owned-return path; only a `&mut Self` reference (which can only ever be
the receiver) is safe to own-thread. `&self -> &Self` (borrowed view), a
consuming `self -> ()`, and `build()` terminals (result ≠ receiver) are all
excluded.

The inspector **normalizes the result to the owned receiver type** for tagged
setters, so the Sky signature is `Recv -> args.. -> Recv` (essential for the
`()` case, which otherwise has no result) and the borrow/lifetime/array filters
see an ordinary owned type. Tag survivors with a new `Function.self_returning:
bool` field (serialized to the kernel JSON; decoded Haskell-side as
`_fnSelfReturning`).

### 4.2 Codegen body shapes (`Ffi.hs`, `emitRustFnSimple`)

| Rust shape | Generated wrapper body |
|---|---|
| `fn s(&mut self, a) -> &mut Self` | `ok_res({ arg0.s(a); arg0 })` |
| `fn s(&mut self, a) -> ()` (in-place) | `ok_res({ arg0.s(a); arg0 })` |

`arg0` is already declared `mut arg0` (every instance receiver is), so calling
the `&mut self` method auto-borrows it; the borrowed `&mut Self`/`()` return is
discarded at the `;`, then the owned `arg0` is returned. Wrapper signature:
`pub fn <name>(arg0: RecvType, args…) -> SkyResult<SkyError, RecvType>` (the
`retInner` is forced to `head paramTypes` so the return type matches `arg0`
exactly). Effect = `pure` (`&mut self -> &mut Self`/`()` classify as pure;
async/fallible can't match). Verified end-to-end with a hermetic builder crate
(`new |> with_size 42 |> power_on |> size == 42`; in-place `power_on` mutation
persists through the chain).

### 4.3 Sky-side shape

`setterName : RecvType -> Arg -> RecvType` — chains via `|>`. Linear chains emit
zero clones; aliasing a non-Clone builder yields the pre-existing
opaque-used-twice compile error (clear, compile-time, never runtime).

## 5. Piece 2 — lifetime-elided owned copies

### 5.1 Inspector normalizer (allowlist, conservative)

Before the `touches_lifetime` filter, rewrite **immutable** borrows of an
allowlisted copy-to-owned base by stripping the lifetime token:

```
&'lt str    → &str         &'lt [u8]  → &[u8]
&'lt OsStr  → &OsStr       &'lt Path  → &Path
&'lt String → &String
```

`has_lifetime` then no longer trips → kept. **Not** rewritten (stay dropped):
`Foo<'a>` handles, `&'a mut _`, `&'a [T]` (generic element), `&'a [Struct]`.

### 5.2 Codegen

None. The normalized `&str`/`&[u8]` flow through existing copy-to-owned paths.

## 6. Rejected alternatives

| Alternative | Why rejected |
|---|---|
| Config-record facade (`build : {opts} -> T`) | heavy builder-family grouping + heuristic setter↔field mapping; brittle; no generalization beyond builders |
| Mutable-handle ABI (interior mutability / index registry) | breaks Sky value semantics; shared mutable state; threading hazards |
| Element coercion (`&[&str]`) | measured 1/2552; sound floor already in place |

## 7. Affected files

| File | Change |
|---|---|
| `tools/sky-ffi-inspect-rs/src/main.rs` | `--audit` mode (committed `759a6256`); `self_returning` detection + result normalization + struct field; `strip_elidable_lifetime` normalizer |
| `src/Sky/Build/Rust/Ffi.hs` | owned-threading body + `retInner = head paramTypes` for `_fnSelfReturning` fns |
| `src/Sky/Build/FfiGen.hs` | new `_fnSelfReturning :: Bool` on the shared `FnInfo` + decode (Go-neutral; see README Modification-boundaries note) |

## 8. Testing (as performed)

- **End-to-end (hermetic crate):** a local `gadget` builder crate (`&mut self ->
  &mut Self` setter `with_size`, `&mut self -> ()` setter `power_on`) built +
  run via `--target rust`: `new |> with_size 42 |> power_on |> size == 42`,
  `power_on |> is_on == True`. ✅
- **`--audit` re-run:** csv 41→66 (35 setters recovered, qualified receivers);
  bytes `split_off`/`split_to` correctly **excluded** (by-value `-> Self`).
- **No regression:** build-sweep PASS (32/32 examples); 10 FFI test crates
  (chrono/semver/rand/uuid/bytesize/crc32fast/config/retry/lipsum/titlecase)
  rebuild clean from a wiped cache.
- **Soundness:** a non-Clone builder aliased mid-chain → clean *compile* error
  (`Gadget: Clone` from `Result.andThen`), never a runtime fault. Real builders
  (csv `ReaderBuilder`, regex `RegexBuilder`) derive `Clone`.

## 9. Risks / edge cases — and the gaps this surfaced (feed the next FFI plan)

- In-place `&mut self -> ()` synthesis changes the apparent return (unit→Self).
  Deliberate; broadly useful (fluent `push`/`clear`).
- Detection keys strictly on *receiver* identity (`&mut Self`), so `split_off`
  and `-> OtherType` are never mis-tagged.
- Normalizer is allowlist-only; a blanket lifetime-strip would resurrect
  borrowed handles into broken bindings.
- **Unsized receiver (`bytes::buf::UninitSlice`)**: own-threading takes the
  receiver by value → `!Sized` → bindings don't compile. Pre-existing class
  (any by-value method on an unsized type fails the same way); not a *gated*
  regression. → next-plan candidate: a Sized gate on by-value receivers.
- **Crate-name collisions** found while testing (next-plan candidates):
  `csv` (crate name vs `use crate::*` → `csv` ambiguous), `bytes::Bytes` (vs
  Sky's builtin `Bytes`→`Vec<u8>`), regex `RegexBuilder` (unqualified receiver
  dropped by nameability), `url` set_* (`Option<&str>` / `Option<u16>` param
  coercion gap). These block whole-crate usability and are the highest-value
  follow-on FFI fixes.
