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

A function is a **self-returning setter** when:
- `recv` is `Some(..)` and the receiver is `self` or `&mut self` (not `&self`), **and**
- result type, after stripping a leading `&mut `/`&`, is `Self` or the receiver
  rust type — **or** the result is `()` **and the receiver is `&mut self`**
  (in-place setter). A *consuming* `self -> ()` is excluded — synthesizing a
  receiver return would use the moved value.

`&self -> &Self` (borrowed view) and `build()`-style terminals (result ≠
receiver) are **excluded**. Tag survivors with a new `Function.self_returning:
bool` field (serialized to the kernel JSON; decoded Haskell-side).

### 4.2 Codegen body shapes (`Ffi.hs`, `emitRustFnSimple`)

| Rust shape | Generated wrapper body |
|---|---|
| `fn s(&mut self, a) -> &mut Self` | `let mut r = arg0; r.s(a); r` |
| `fn s(self, a) -> Self` (consuming) | `arg0.s(a)` |
| `fn s(&mut self, a) -> ()` (in-place) | `let mut r = arg0; r.s(a); r` |

Wrapper signature: `pub fn <name>(arg0: RecvType, args…) -> RecvType`. Effect =
non-effectful (referentially transparent input→output). The discarded `&mut
Self` return is intentional; we return the owned local.

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
| `tools/sky-ffi-inspect-rs/src/main.rs` | keep `--audit` (committed separately); add `self_returning` detection + tag; add lifetime-elided normalizer |
| `src/Sky/Build/Rust/Ffi.hs` | owned-threading body emission for `self_returning` fns |
| Haskell `Function` decode (FFI JSON) | new `self_returning` field |

## 8. Testing

- **Regression crates** under `runtime-rust/tests/sky/`: a fixture that
  `sky add`s a builder-bearing crate (regex / csv) and chains setters →
  builds + runs.
- **`--audit` re-run** on regex/csv/reqwest: confirm setter drops fall, kept
  count rises; no new `array_slice`/handle resurrection.
- **build-sweep** (`sky-rust-backend:build-sweep`): no regression on the
  gated examples.
- **Soundness spot-check**: alias a non-Clone builder in a fixture → expect a
  clean *compile* error, never a runtime fault.

## 9. Risks / edge cases

- In-place `&mut self -> ()` synthesis changes the apparent return (unit→Self).
  Deliberate; documented. Broadly useful (fluent `push`/`clear`).
- A method returning `&mut OtherType` (not the receiver) must NOT be detected as
  a setter — detection keys strictly on *receiver* identity.
- Normalizer must be allowlist-only; a blanket lifetime-strip would resurrect
  borrowed handles into broken bindings.
