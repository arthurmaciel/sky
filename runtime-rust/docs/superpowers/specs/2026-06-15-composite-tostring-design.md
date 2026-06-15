# Composite `Basics.toString` (record / ADT → Go `%v`) — design

**Divergence id:** `composite-tostring`
**Disposition:** `DOCUMENT_BLOCKED`
**Boundary:** would be Rust-codegen-only IF it were achievable + verifiable; it is neither.

## Problem

Go's `Basics.toString` / `Debug.toString` (the `{{interp}}` stringifier)
routes through `rt.Debug_toString` (`runtime-go/rt/rt.go:1087`):

```go
func Debug_toString(v any) any {
    v = derefPointer(unwrapAny(v))
    if s, ok := v.(string); ok { return s }
    return fmt.Sprintf("%v", v)   // reflection
}
```

Rust's `basics_to_string<T: Display>` (`runtime-rust/src/sky_runtime/basics.rs`)
matches Go exactly for **scalars** (`Display` == `%v` for Int/Float/Bool/String).
A **record/ADT** argument has no `Display` impl → clean compile-time `E0277`,
never a runtime panic. The asker asks whether to build a type-directed renderer
that reproduces Go's `%v` shape.

## What Go `%v` actually renders (empirically captured — the parity oracle)

Sky values lower to Go as: record → anonymous struct sorted by `_fieldIndex`
(`Generate/Go/Type.hs:goRecordType`); ADT → a **single flattened struct** with a
`Tag int` field plus every variant's payload fields (`Generate/Go/Builder.hs`).
`Debug_toString` deref's pointers first, then `Sprintf("%v")`:

| Sky shape | Go `%v` output | Notes |
|---|---|---|
| record `{ x = 1, y = "hi" }` | `{1 hi}` | brace-wrapped, space-joined **values**, no field names, no type name, `_fieldIndex` order |
| nested record-in-record | `{{2 z} 9}` | inner struct recursively `%v`'d |
| **nullary** ADT variant | `{0 0}` | leaks `Tag` int + zero-valued payload slots of OTHER variants |
| **payload** ADT variant | `{1 42}` | `{tag payload…}` — constructor NAME never appears |
| List | `[1 2 3]` | space-joined, square brackets |
| `nil` pointer / Nothing | `<nil>` | |
| non-nil pointer | deref'd to its value (`Debug_toString` deref's) | |
| tuple | `{1 q}` | same as a 2-field struct |
| Dict / map | `map[a:1 b:2]` | `map[k:v …]`, Go-sorted keys |
| **function-typed field** | `0x<addr>` | **non-deterministic** address |

The decisive facts:

1. **Parity is defined as matching this string**, NOT Rust's `#[derive(Debug)]`
   (`Name { field: v }` — different field names, braces, separators). Rust's
   `errorToString` already uses `{:?}` and therefore already diverges from Go on
   composites — that's the sibling README row, "shared / Go-side".
2. **The ADT shape is a Go-reflection artifact**: `{1 42}` exposes the flattened
   Go struct memory layout (Tag integer + zero-init inactive-variant fields). It
   carries no Sky-level semantic — the constructor name is absent.

## Answers to the asker's questions

**Q1 — byte-for-byte Go `%v` per shape.** Captured in the table above. Record =
field-name-less / type-name-less `{v…}` in `_fieldIndex` order; ADT =
`{tag payload…}` leaking the Go layout; List `[…]`; Dict `map[…]`; tuple == struct.

**Q2 — renderer vs Debug vs document.** Reusing `Debug` (b) is a real divergence
(field names + `Name {}` braces). Building a Go-`%v`-shaped `SkyShow` (a) would
require a **per-type codegen pass** emitting a renderer for every struct/enum —
turning a "small kernel tweak" into a codegen-wide one. So the IMPLEMENT framing
in triage is wrong about scope.

**Q3 — call-site type availability.** `solveArgType` (`ExprEmitter.hs`) is
**best-effort**, returning `""` / `"String"` defaults at many shapes and having
no concrete type for a genuinely polymorphic helper (`f : a -> String` calling
`toString` on its own type parameter). A fully-general sound fix would have to
thread a `T: SkyShow` **trait bound** through every generic signature that can
transitively reach `toString` — including parametric record aliases (`Cfg_R[T1]`
needing `T1: SkyShow`). That is itself a codegen-wide epic and risks breaking
unrelated monomorphisations that never call `toString`.

**Q4 — function-typed-field structs (Emitter.hs ~387-401).** Those derive only
`Clone`. Go renders such a field as `0x<addr>` — a **non-deterministic** process
address (same class already reclassified out of equiv for `35-composite-generics`
non-determinism). Rust cannot reproduce a Go func address deterministically, so
this subset is unmatchable by construction.

**Q5 — soundness of a `SkyShow` mechanism.** Provable-by-construction `SkyShow`
for every emitted type is plausible for records, but the **ADT case has no
matching Rust value** (Rust enums are sum types; there is no Tag-int +
zero-init-inactive-fields struct to render `{1 42}` from). Reproducing it means
the renderer *fabricates* Go's flattened layout — Go-layout emulation with no
semantic, masking the difference rather than matching a meaning.

**Q6 — verification.** **Zero** upstream `examples/` interpolate or `toString` a
record/ADT into stdout (all `{{…}}` sites are pre-stringified scalars:
`countStr`, `jid`, `running`, …). The `equiv-sweep` parity oracle **does not
exist**, and `examples/` is off-limits to edit. We cannot prove Go-parity for
the ADT shape here.

**Q7 — boundary.** Record-only rendering would be inside `src/Sky/Generate/Rust/`
+ `runtime-rust/src/` (no shared-stdlib / Go-side change). The blocker is not the
boundary — it is the ADT shape (unmatchable + non-deterministic func-field
subset) plus the missing verification oracle.

## Disposition rationale: DOCUMENT_BLOCKED

Ordered by the principle hierarchy (security > correctness > soundness >
efficiency > Go-parity):

- **Correctness / Go-parity:** the headline value claimed in triage
  (record/ADT renders "like Go `%v`") is **unattainable for the ADT shape** —
  `{1 42}` is a Go-memory-layout leak with no Rust equivalent, and the
  function-field subset prints a **non-deterministic** address. Matching it would
  mean fabricating Go's struct layout (symptom-masking, not a root-cause fix).
- **Soundness:** the only *fully general* fix (covering polymorphic helpers) is a
  `SkyShow` bound threaded through every generic signature — a codegen-wide epic
  that risks breaking `toString`-free monomorphisations. `solveArgType` is not a
  complete type oracle, so a call-site-only fix is unsound at the polymorphic
  shape. No `Box<dyn Any>` / downcast path is permissible (the no-`Any` rule that
  is this backend's reason to exist).
- **Verifiability:** no upstream example exercises composite `toString`; the
  equiv-sweep cannot diff it, and `examples/` is read-only. We must **never ship
  what we cannot verify**.
- **Current behavior is the correct floor:** scalars match Go exactly; a composite
  `toString` is a **clean compile-time `E0277`, never a runtime panic** — which is
  *more* in line with "no runtime errors from well-typed Sky code" than Go's
  runtime reflection. There is no demonstrated demand (no example, no stdlib
  surface) for the composite shape.

This is not a deferral excuse: if an upstream example later interpolates a Sky
**record** (not ADT) into stdout, the record-only sub-case becomes a verifiable,
in-boundary IMPLEMENT (a `_fieldIndex`-ordered `{v…}` renderer behind the
solved-type call site) and should be promoted then. The ADT shape stays blocked
until/unless Go stops leaking its struct layout (an upstream Go-backend change,
out of our boundary).

## Principle check

No shared-stdlib edit, no Go-backend edit, no Sky-source edit, no `examples/`
edit. No `Box<dyn Any>`, no downcast, no `unwrap`/`panic` introduced. The chosen
course **adds nothing to generated code** — it documents that the existing
clean-compile-error floor is the principled boundary and records the exact reason
the ADT shape cannot reach verified Go-parity here.

## Executor decomposition

DOCUMENT disposition — spec written (this file). Remaining: clarify the README
row + add a non-`examples/` fixture that locks the current floor.
