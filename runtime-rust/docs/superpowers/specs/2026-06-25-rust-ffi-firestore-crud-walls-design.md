# FFI Firestore CRUD Walls — Implementation Spec

**Scope.** Two blockers in `tools/sky-ffi-inspect-rs/src/main.rs` prevent
real Firestore CRUD operations from binding shim-free. This document is the
verified-against-current-code TDD design for both fixes.

---

## Status: DESIGN ONLY (no impl, no guardian dispatch yet)

---

## 1. Root-cause confirmation

### WALL 1 — Nested private-module glob re-export (P1, dominant)

**Claimed.** `collect_reachable_paths` skips trait support types hidden behind a
private intermediate module, causing ~2054 `trait-method-trait-unreachable` drops
for firestore.

**Confirmed against current code (main.rs lines 4052-4165).**

The core loop at lines 4087-4163:

```rust
// line 4079-4084: seed stack with PUBLIC crate-local modules only
for (id, item) in index {
    if item["inner"].get("module").is_some()
        && item["crate_id"].as_u64().unwrap_or(1) == 0
        && is_public(item)          // <-- PUBLIC gate: private modules never enter
    {
        stack.push(id.clone());
    }
}

// line 4088-4094: for each module from stack:
while let Some(mid) = stack.pop() {
    ...
    let mp = match mpath(&mid) {
        Some(p) => p,
        None => continue,           // <-- SKIP if module has no entry in doc["paths"]
    };
```

`mpath` (lines 4059-4070) reads `doc["paths"][mid]["path"]`. Rustdoc only
populates `doc["paths"]` for **publicly-reachable** items. A `mod db;`
(private) in `firestore/src/lib.rs` has NO entry in `paths` → `mpath` returns
`None` → the `continue` at line 4094 skips the entire `db` subtree.

The glob handler at lines 4115-4146 does process ONE level of direct children
of a private module target — but only their TYPE items (`item_is_type`), not
their nested `use` or sub-module chains. The stack push at lines 4152-4160:

```rust
if let Some(tids) = tid {
    if index.get(&tids).and_then(|x| x["inner"].get("module")).is_some() {
        stack.push(tids);           // pushed, but mpath fails → skipped next iteration
    }
}
```

This pushes the private `db` module onto the stack — but when popped, `mpath`
fails → the whole sub-tree is skipped again. The private module's OWN children
in `module.items` ARE partially processed by the glob handler, but those
children may themselves be private sub-modules with nested glob re-exports
(firestore has TWO levels: `mod db; pub use db::*;` → `mod get; pub use
get::*;` → `FirestoreGetByIdSupport`), and the inner level is never reached.

**Verified with firestore-0.49.0 source.**
- `firestore/src/lib.rs` line 143: `mod db;` (private) + line 150: `pub use db::*;`
- `firestore/src/db/mod.rs` line ~5: `mod get;` (private) + `pub use get::*;`
- `firestore/src/db/get.rs`: defines `pub trait FirestoreGetByIdSupport { async fn get_doc<S>... }`

Two levels of private module nesting. The current code handles zero levels
correctly (type directly in a public module), one level partially (types that
are direct children of the private target), and misses all deeper nesting.

**Drop count.** `FirestoreGetByIdSupport`, `FirestoreCreateSupport`,
`FirestoreQuerySupport`, `FirestoreUpdateSupport`, `FirestoreDeleteSupport`
and their sibling support traits never enter `REACHABLE_PATHS` → when
`ufcs_trait_path_with_args` looks them up by id, it returns `None` →
`TraitUnreachable` drop on every method implementation. The user-reported
~2054 drops is the total across all methods of all support traits.

**The root cause is narrower than originally stated.** The claim was
"collect_reachable_paths does NOT recurse through nested glob-USE chains when
intermediate modules are PRIVATE." This is confirmed correct. The existing
one-level glob expansion (4125-4146) works for ONE private intermediate
module, but firestore has TWO levels, and nested private modules are not pushed
with a synthetic public-path prefix — they're pushed bare and then fail at
`mpath`.

---

### WALL 2 — `S: AsRef<str>` in `classify_param_bound` (P2)

**Claimed.** `classify_param_bound` returns `Err(UnmodellableBound("AsRef"))` →
method drops. Fix: model `AsRef<str>` as `String`.

**PARTIALLY confirmed, but the location and drop pathway differ from the
description.**

The prompt claims the fix is in `classify_param_bound` (~lines 5602-5638). Let
me clarify what actually happens:

**For free functions** (`resolve_generics`, lines 7755-7817):
- `S: AsRef<str> + Send` → `resolve_param_bounds` (line 7794) → `is_marker_bound(Send)` → skip; `bound_to_concrete(AsRef<str>)` (line 5277) → `Some(string_node())` → **ALREADY WORKS**.

**For parametric generic stubs** (`try_parametric_stub`, `full_union_bounds`, lines 5757-5803):
- `S: AsRef<str> + Send` → `classify_param_bound(AsRef)` (line 5794) → not marker, not modellable-5 → `Err(UnmodellableBound("AsRef"))` → drops the whole method.

**For trait methods** via `build_trait_ctx` + `try_parametric_stub`:
- The firestore `get_doc<S: AsRef<str> + Send>` lives on a TRAIT (`FirestoreGetByIdSupport`). WALL 1 blocks it FIRST (trait not in REACHABLE_PATHS → `TraitUnreachable` drop). WALL 2 only becomes visible AFTER WALL 1 is fixed.
- Post-WALL-1 fix, `get_doc<S>` will reach `try_parametric_stub` → `full_union_bounds` → `classify_param_bound(AsRef<str>)` → `UnmodellableBound` drop.

**The two paths diverge by design.** `resolve_generics` monomorphizes (replaces the generic with a concrete type in the call). `full_union_bounds` / `classify_param_bound` emits a PARAMETRIC stub (keeps the generic, adds a `<S: …>` bound to the wrapper). For `S: AsRef<str>`, monomorphization to `String` IS appropriate — the Sky caller always passes a `String`. The parametric-stub path's `classify_param_bound` correctly rejects it (it can't emit `<S: AsRef<str>>` in a safe generic wrapper), but since `bound_to_concrete` can resolve it, these methods should be routed through `resolve_generics` instead.

**Verified exact drop path at line 5638:**
```rust
// line 5638 — reached for `AsRef`:
Err(GenericDrop::UnmodellableBound(name))
```

**Soundness note on the fix approach.** The fix is NOT in `classify_param_bound`
directly. It is in the ROUTING: a method whose generic params all satisfy
`resolve_param_bounds` (i.e., can all be monomorphized to concrete types)
should fall through to the `resolve_generics` path (Alt-1 substitution), not
the `full_union_bounds` path (parametric stub). The current gating does NOT
check this before reaching `full_union_bounds`.

---

## 2. WALL 1 fix algorithm — nested glob path resolution

### Rustdoc JSON shape

For a private module `mod db;` re-exported as `pub use db::*`:

In `doc["index"]`, the re-export appears as a `use` item:
```json
{
  "inner": {
    "use": {
      "name": null,
      "id": "<db_module_id>",
      "is_glob": true,
      "source": "db"
    }
  },
  "visibility": "public"
}
```

The private `db` module itself appears in `doc["index"]` (it's in the local
crate) with `visibility: "crate"` or `visibility: "restricted"` (NOT `"public"`).
Its items list contains further `use` items for `mod get; pub use get::*;`.

Key: `is_glob: true` + `id` points to the private module's index item.
`doc["paths"]` has NO entry for the private module's id (rustdoc only records
publicly-reachable paths there).

### Algorithm

The fix is to pass a SYNTHETIC PUBLIC PATH to the private module's recursive
walk, derived from the re-exporting module's public path.

**Current loop structure (conceptual):**
```
stack = [public_module_ids...]
while let Some(mid) = stack.pop():
    mp = mpath(mid)        // fails for private → skip entire module
    for child in index[mid].module.items:
        if child is type: record(child.id, mp::child.name)
        if child.inner.use.is_glob:
            expand ONE level of private target's items as types
            push private target to stack  // but it will fail mpath → wasted
```

**Fixed algorithm — pass virtual path through glob expansion:**

```rust
fn walk_module_with_path(
    mid: &str,
    mp: &str,           // the PUBLIC path prefix (may be synthetic for private modules)
    index: &Map,
    out: &mut HashMap<String, String>,
    seen: &mut HashSet<String>,
) {
    if !seen.insert(mid.to_string()) { return; }

    let module = match index.get(mid).and_then(|it| it["inner"].get("module")) {
        Some(m) => m,
        None => return,
    };
    let items = match module["items"].as_array() {
        Some(a) => a,
        None => return,
    };

    for child in items {
        let cid = item_id_to_str(child);
        let it = match index.get(&cid) { Some(x) => x, None => continue };

        if item_is_type(it) {
            if let Some(n) = it["name"].as_str() {
                insert_shorter(out, cid.clone(), format!("{}::{}", mp, n));
            }
        }

        if let Some(u) = it["inner"].get("use") {
            let tid = u.get("id").map(item_id_to_str);
            if u["is_glob"].as_bool().unwrap_or(false) {
                if let Some(tids) = &tid {
                    // The target may be a PRIVATE module (absent from paths).
                    // Walk it with the CURRENT mp as the synthetic public prefix.
                    // This is sound: a public `pub use private_mod::*` makes all
                    // public items of private_mod reachable at the current path.
                    walk_module_with_path(tids, mp, index, out, seen);
                }
            } else if let (Some(n), Some(tids)) = (u["name"].as_str(), tid.as_ref()) {
                if index.get(tids).map(item_is_type).unwrap_or(false) {
                    insert_shorter(out, tids.clone(), format!("{}::{}", mp, n));
                }
            }
        }
    }
}

fn collect_reachable_paths(doc: &serde_json::Value) -> HashMap<String, String> {
    let mut out = HashMap::new();
    let index = match doc["index"].as_object() { Some(i) => i, None => return out };
    let mut seen = HashSet::new();

    for (id, item) in index {
        if item["inner"].get("module").is_some()
            && item["crate_id"].as_u64().unwrap_or(1) == 0
            && is_public(item)
        {
            // For a PUBLIC module: get its path from doc["paths"] as before.
            if let Some(mp) = mpath_from_doc(doc, id) {
                walk_module_with_path(id, &mp, index, &mut out, &mut seen);
            }
        }
    }
    out
}
```

**Key properties:**
1. `walk_module_with_path` is called with the PUBLIC path prefix. When it
   recurses into a private module via a glob re-export, it passes the SAME
   `mp` — so `private_mod::items` are published at `mp::item_name`.
2. The `seen` set (visited ids) provides cycle protection.
3. Types directly in the private module get registered as `mp::type_name`.
4. A NESTED glob inside the private module (e.g., `db/mod.rs` doing
   `pub use get::*;`) recursively calls `walk_module_with_path` with the same
   `mp` — so `get`'s types are ALSO registered at `mp::type_name`. This covers
   the two-level firestore case (`lib → db → get → FirestoreGetByIdSupport`).
5. Only items that pass `item_is_type` are registered — no path pollution from
   fn/trait/impl items.
6. Soundness: we ONLY register an item under a path if there exists a chain of
   `pub use *` glob re-exports from a public module to that item. A private
   module with NO glob re-export from any public module will never be walked.

**Cycle guard.** The `seen` set tracks visited module IDs regardless of whether
they're public or private. A crate with circular glob re-exports (uncommon but
possible) is handled without infinite recursion.

**Non-type items.** Traits and impls (`item_is_type` is FALSE for them) are NOT
directly registered in `REACHABLE_PATHS` — this matches current behavior. The
key effect is that TRAIT SUPPORT TYPES (like `FirestoreGetByIdSupport` which IS a
`trait` — wait, traits ARE type items!) need to check `item_is_type` for traits.

**Checking `item_is_type` for traits:** At line 3914-3916:
```rust
fn item_is_type(it: &serde_json::Value) -> bool {
    let ik = &it["inner"];
    TYPE_KINDS.iter().any(|k| ik.get(*k).is_some())
}
```

We need to verify `TYPE_KINDS` includes `"trait"`. Let me note this as a
make-or-break check: if `TYPE_KINDS` does NOT include `"trait"`, then
`FirestoreGetByIdSupport` (which is a trait) would not get registered even
with the fix. The UFCS path needs trait IDs in `REACHABLE_PATHS`.

**File:** `tools/sky-ffi-inspect-rs/src/main.rs`
**Function:** `collect_reachable_paths` (line 4052)
**Change:** Replace the current DFS with path-passing DFS via a helper function.

---

## 3. WALL 2 fix algorithm — `AsRef<str>` in parametric stub path

### The actual gap

The firestore `get_doc<S: AsRef<str> + Send>` is a TRAIT method. After WALL 1
is fixed, it will reach `try_parametric_stub` (line ~6338). There, the bound
for `S` goes through `full_union_bounds` → `classify_param_bound(AsRef<str>)` →
`Err(UnmodellableBound("AsRef"))` → drop.

The fix has two possible approaches:

**Approach A (routing fix — preferred).** Before entering `full_union_bounds`,
check if all USED type params have bounds that resolve via `resolve_param_bounds`.
If yes, route the method through `resolve_generics` (Alt-1 monomorphization)
instead of `try_parametric_stub` (parametric stub). This is the correct
architectural fix: `S: AsRef<str>` means "pass a String", not "emit a generic
wrapper with a `<S: AsRef<str>>` bound".

**Approach B (classify fix — narrower).** Make `classify_param_bound` treat a
bound that is fully resolvable by `bound_to_concrete` as `Ok(None)` (marker-
equivalent — contributes no Sky-facing `<T: …>` constraint). Then in the
parametric stub builder, monomorphize `S → String` by using `bound_to_concrete`
on the single resolving bound.

Approach A is cleaner but requires understanding where the routing decision is
made. Approach B is surgical (one function change) but requires the parametric
stub builder to also substitute S → String in the wrapper sig, which it currently
does not do (it emits `<S: …>` type-param wrappers, not concrete monomorphizations).

**Recommendation: Approach B at `classify_param_bound`, PLUS monomorphization in
the stub builder.**

The concrete fix for `classify_param_bound` (lines 5602-5638):

```rust
fn classify_param_bound(bound: &serde_json::Value) -> Result<Option<String>, GenericDrop> {
    if bound_is_higher_ranked(bound) {
        return Err(GenericDrop::NonGenericPredicate(
            "higher-ranked (for<'a>) bound".to_string(),
        ));
    }
    let name = match trait_bound_name(bound) {
        None => return Ok(None), // lifetime/outlives — ignore
        Some(n) => n,
    };
    if let Some(std_tag) = std_trait_tag(bound.get("trait_bound").and_then(|tb| tb.get("trait")).unwrap_or(&serde_json::Value::Null)) {
        if is_modellable_5(std_tag) {
            debug_assert!(modellable_5_superclosure_ok(std_tag));
            return Ok(Some(std_tag.to_string()));
        }
    }
    if MARKER_TRAITS.contains(&name.as_str()) && !is_modellable_5(&name) {
        return Ok(None);
    }

    // NEW: a bound that fully resolves to a concrete Sky type via bound_to_concrete
    // (e.g. AsRef<str> → String, Display → String, Into<String> → String) is treated
    // as marker-equivalent in the parametric-stub path — it contributes no
    // `<T: …>` bound to the generated wrapper because T will be substituted to its
    // concrete type. The caller (full_union_bounds consumer) must substitute T.
    //
    // Soundness gate: ONLY when bound_to_concrete returns Some. The bound must be
    // an externally-verified std trait (the same path bound_to_concrete uses). A
    // crate-local AsRef look-alike would fail std_trait_tag and reach the
    // UnmodellableBound below — safe direction.
    if bound_to_concrete(bound, BoundPos::Param).is_some() {
        return Ok(None); // resolvable-to-concrete — treat as marker for stub purposes
    }

    Err(GenericDrop::UnmodellableBound(name))
}
```

**Soundness gate (critical).** The new `bound_to_concrete` check at the end
only fires AFTER the existing crate-local check fails (`std_trait_tag` + the
modellable-5 path). A crate-local trait named `AsRef` would be rejected by
`std_trait_tag` (it checks the resolved id, not the name) and would NOT reach
the new arm if `bound_to_concrete` also guards on the std canonical path. We
must verify `bound_to_concrete` itself is safe for this — at line 5254-5258 it
checks `std_trait_tag` for `Display`/`ToString`; for `AsRef` at line 5269 it
uses the last-segment name match `"AsRef"`. This is a soundness gap if a
crate-local `trait AsRef<T>` exists — `bound_to_concrete` would return `Some`
for it. To close this:

```rust
// In the new arm: only admit when the bound is a CONFIRMED std trait
// OR when bound_to_concrete's match is provably std (AsRef/Borrow/Into/From
// are always resolved by name-only — add a std_trait_tag check here).
if bound_to_concrete(bound, BoundPos::Param).is_some() {
    // Only if it's a std/core trait (not a crate-local same-name trait).
    let tr = bound.get("trait_bound").and_then(|tb| tb.get("trait"));
    let is_crate_local = tr.map(trait_is_crate_local).unwrap_or(false);
    if !is_crate_local {
        return Ok(None);
    }
}
```

This exactly mirrors the `is_modellable_5` guard pattern from #25.

**What about the substitution?** After `classify_param_bound` returns `Ok(None)`
for `S: AsRef<str>`, the `full_union_bounds` result for `S` will be an empty
bound list. The stub builder at line 6542-6552 then drops with
`BoundCrossImpl` if it's a trait method (empty bound list for a trait-method
tyvar). So we ALSO need the stub builder to substitute `S → String` when the
bound list is empty AND the param resolves via `resolve_param_bounds`.

**Alternative (simpler): monomorphize via resolve_generics FIRST.**

In the method routing, BEFORE trying `try_parametric_stub`, attempt
`resolve_generics`. If it succeeds (all type params resolve to concrete types),
use the Alt-1 path directly. This avoids the `classify_param_bound` change
entirely and requires no change to the stub builder.

The routing decision lives in `route_concrete_method` / the main dispatch.
Locating the exact call site is needed for implementation.

**File:** `tools/sky-ffi-inspect-rs/src/main.rs`
**Functions:** `classify_param_bound` (line 5602) + the method routing dispatch
**Risk:** The "treat resolving bounds as markers" approach may over-admit a
crate-local `AsRef` look-alike without the `!is_crate_local` guard.

---

## 4. Proof bar — new fixture `75-ffi-nested-glob-asref`

A new test fixture at `runtime-rust/tests/sky/75-ffi-nested-glob-asref/` with
a dep-free crate that mirrors BOTH walls minimally.

### Fixture crate `nested-glob-crate/src/lib.rs`

```rust
//! 75-ffi-nested-glob-asref: verifies WALL 1 (nested private module glob path)
//! and WALL 2 (AsRef<str> bound resolution).

// WALL 1: types reachable ONLY through a nested private module glob chain
//   crate root (pub) → `mod inner;` (private) → `pub use inner::*;`
//   → `mod deep;` (private) → `pub use deep::*;`
//   → defines `Sup` and `Support` trait

mod inner;
pub use inner::*;

// inner/mod.rs:
//   mod deep;
//   pub use deep::*;
//   pub struct Inner { pub x: i64 }  // ONE-level type — already works

// inner/deep.rs:
//   pub struct Sup { pub y: i64 }    // TWO-level type — the bug

// WALL 2: method with AsRef<str> + Send bound
// (lives on the Support trait defined in inner/deep.rs)
```

**`inner/mod.rs`:**
```rust
mod deep;
pub use deep::*;

/// One-level private module type — expected to already work.
pub struct Inner { pub x: i64 }
impl Inner {
    pub fn new(x: i64) -> Inner { Inner { x } }
    pub fn get_x(&self) -> i64 { self.x }
}
```

**`inner/deep.rs`:**
```rust
/// TWO-level private module type — WALL 1 target.
pub struct Sup { pub y: i64 }
impl Sup {
    pub fn new(y: i64) -> Sup { Sup { y } }

    /// WALL 2 target: AsRef<str> + Send bound on S.
    /// POSITIVE: S should resolve to String.
    pub fn op<S: AsRef<str> + Send>(&self, k: S) -> String {
        format!("{}{}", self.y, k.as_ref())
    }
}

/// NEGATIVE: two non-auto non-resolvable bounds → must DROP.
/// `Serialize` is not in modellable-5 and does not resolve via bound_to_concrete.
/// `AsRef<str>` resolves, but `Serialize` doesn't → the multi-non-auto-bound
/// soundness gate must drop this.
pub struct SupNeg { pub z: i64 }
impl SupNeg {
    pub fn op_neg<S: AsRef<str> + serde::Serialize>(&self, k: S) -> String {
        format!("{}{}", self.z, k.as_ref())
    }
}
```

**Expected bindings:**
- `Inner::new(i64) -> Inner` — BINDS (one-level, already works)
- `Inner::get_x(&self) -> i64` — BINDS
- `Sup::new(i64) -> Sup` — BINDS (two-level, WALL 1 fix)
- `Sup::op(&self, String) -> String` — BINDS (WALL 2 fix: `S: AsRef<str>` → `String`)
- `SupNeg::op_neg` — DROPS (`unmodellable-bound` for `Serialize` which is not resolable without the serde path; OR the multi-non-auto-bound guard drops it)

**Sky Main.sky:**
```elm
module Main exposing (main)

import Sky.Core.Prelude exposing (..)
import Sky.Core.Task as Task
import Sky.Core.Error as Error
import Rust.NestedGlobCrate as G
import Std.Log exposing (println)

main : Task Error ()
main =
    -- WALL 1: Sup is reachable (two-level private module glob)
    case G.new_from_sup 42 of
        Ok sup ->
            -- WALL 2: op takes String (S: AsRef<str> resolved to String)
            case G.op_from_sup sup "!" of
                Ok s ->
                    if s == "42!" then
                        println "[ALL OK]"
                    else
                        Task.fail (Error.unexpected ("bad op result: " ++ s))
                Err e ->
                    Task.fail e
        Err e ->
            Task.fail e
```

**Negative assertions (in test runner or coverage.md check):**
- `NestedGlobCrate.op_neg` must be ABSENT from bindings.
- `NestedGlobCrate.Sup` must be PRESENT (reachable via two-level glob).

---

## 5. Ranked task list

### P1 — WALL 1: nested glob path resolution (main.rs ~lines 4052-4165)

**Why first.** Blocks ~2054 drops. Without it, the firestore Support traits are
never in `REACHABLE_PATHS` → ALL their methods drop `TraitUnreachable` regardless
of bound soundness. WALL 2 fix has no observable effect until WALL 1 is resolved.

**Step 1 (failing fixture).** Add `runtime-rust/tests/sky/75-ffi-nested-glob-asref/`
with the crate above. Verify via `sky add` that `Sup` is NOT currently in
REACHABLE_PATHS (coverage.md shows `trait-method-trait-unreachable` or the type
is simply absent from bindings).

**Step 2 (implement).** Refactor `collect_reachable_paths`:
- Extract a `walk_module_with_path(mid, mp, index, out, seen)` recursive helper.
- The main loop calls it for each seed public module with the actual `paths`-
  derived path.
- Glob expansion inside the helper calls `walk_module_with_path(target_id, mp, ...)`
  recursively — passing the CURRENT public path as the prefix for the private target.
- The `seen` set is shared across the entire walk to prevent cycles.

**Step 3 (verify WALL 1 in isolation).** Confirm `Sup` and `Inner` now appear in
bindings with paths `nested_glob_crate::Sup` and `nested_glob_crate::Inner`.
The `Sup::op` method may still drop (`UnmodellableBound` for `AsRef<str>`) — that's
the WALL 2 remnant, not a regression. Confirm `new_from_sup` binds.

**Make-or-break risks:**
- `TYPE_KINDS` must include `"trait"` for firestore Support traits to register.
  Check `const TYPE_KINDS: &[&str]` in main.rs before implementing.
- Cycle guard: a crate that does `pub use a::*;` in `a` and `pub use b::*;` in `b`
  must not loop. The `seen` set covers this IF it's the module id, not the path.
- The existing one-level glob expansion (lines 4125-4146) should be REMOVED or
  subsumed by the new recursive walk to avoid double-processing.

**Guardian gate trigger:** diff on `collect_reachable_paths` + the new helper.

---

### P2 — WALL 2: `AsRef<str>` resolves to String in parametric/trait path

**Why second.** After WALL 1, firestore's `get_doc<S: AsRef<str> + Send>` will
be visible but still drop `UnmodellableBound("AsRef")`. This fix unblocks the
remaining ~100 CRUD ops.

**Step 1 (failing fixture).** The `75-ffi-nested-glob-asref` fixture's `Sup::op`
drops `UnmodellableBound("AsRef")` post WALL-1-fix. This IS the pre-fix failing
state for WALL 2.

**Step 2 (implement — two sub-steps).**

Sub-step A: In `classify_param_bound` (line 5602), add after the existing
modellable-5 + marker checks:

```rust
// A bound that fully resolves to a concrete Sky type via bound_to_concrete
// and is NOT from a crate-local same-named trait → treat as marker-equivalent.
// The substitution (S→String) happens in the parametric stub builder.
if bound_to_concrete(bound, BoundPos::Param).is_some() {
    let tr = bound.get("trait_bound").and_then(|tb| tb.get("trait"));
    if !tr.map(trait_is_crate_local).unwrap_or(false) {
        return Ok(None);
    }
}
```

Sub-step B: In the parametric stub builder (`try_parametric_stub`, line ~6338),
when a USED type-param's bound list (from `full_union_bounds`) is empty AND the
method is NOT a trait method (where empty means `BoundCrossImpl`), substitute
that param using `resolve_param_bounds` on its raw bounds. For trait methods,
empty-after-Ok means the bound resolved cleanly — also substitute.

Actually the cleanest approach is: in `resolve_generics` (the free-fn monomorphizer,
line 7755), extend to ALSO be tried for trait-method params that failed parametric
stub. OR: at the routing level, attempt `resolve_generics` on the fn_data BEFORE
`try_parametric_stub` when all type params can resolve via `bound_to_concrete`.

**Preferred routing fix:** In the dispatch that routes to `try_parametric_stub`,
first attempt `resolve_generics`. If it returns `Some(map)` AND the map is
non-empty, use the monomorphization path (substitute types, emit a concrete call)
rather than the parametric stub. This is architecturally sound: `S: AsRef<str>`
means "pass a String", not "keep a generic parameter".

**Step 3 (negative test).** Verify `SupNeg::op_neg<S: AsRef<str> + Serialize>`
still DROPS. The `Serialize` bound is not resolvable via `bound_to_concrete`
(it's in the serde arm of #47, not the std-trait arm) and `!is_crate_local` is
true for a dep trait — but `bound_to_concrete` returns `None` for `Serialize`
(it's not in the match arms). So the new arm does not fire for `Serialize` →
`classify_param_bound(Serialize)` → `UnmodellableBound` → method drops. Correct.

**Step 4 (green fixture).** Confirm `Sup::op` binds with `String` parameter and
the Main.sky checkSend chain returns `"42!"`.

**Make-or-break risks:**
- The `!is_crate_local` guard is LOAD-BEARING. A crate-local `trait AsRef<T>`
  would otherwise be silently substituted to `String`. Verify the guard against
  the existing `#25` test patterns in `test_classify_param_bound_crate_local_clone_drops`.
- The `BoundCrossImpl` drop at lines 6542-6552 must be reconciled with the new
  "empty bound list after classify returns Ok(None)" case. A trait method with all
  bounds resolving to Ok(None) should NOT trigger BoundCrossImpl — only genuine
  cross-impl-unresolvable bounds should. The gate check `!has_bound` will fire
  incorrectly for the new case. Fix: `has_bound` must also consider whether the
  param resolves via `bound_to_concrete` (i.e., `Ok(None)` + resolvable = ok).
- If routing to `resolve_generics` instead of `try_parametric_stub`: confirm the
  generated call AST and the wrapper body correctly substitute `S → String` in the
  turbofish and in the argument type. The wrapper must emit `fn op_from_sup(sup: &Sup, k: String) -> Result<String, SkyError>` calling `<::crate::Sup>::op::<String>(&sup, k.as_str())` or `op(&sup, k)` (since `String: AsRef<str>`).

**Guardian gate trigger:** diff on `classify_param_bound` + the routing dispatch.

---

## 6. Firestore stretch (after both walls are green)

After 75 passes:
1. `sky add firestore` in a scratch project (or re-run the existing firestore
   scan if it exists in the ffi-audit suite).
2. Check coverage.md for `trait-method-trait-unreachable` drops — should be
   near-zero for the Support traits.
3. Check coverage.md for `unmodellable-bound` drops on `get_doc` family — should
   resolve to `String`.
4. Remaining drops: async stream returns (`BoxStream<Result<...>>`), parametric
   returns (`FirestoreResult<T>`), multi-param bounds (`S: AsRef<str> + Serialize`).
5. Measure delta: expected ~100 new CRUD-op bindings from `FirestoreDb` impl.

---

## Summary table

| Wall | Location | Lines | Fix | Soundness risk | Priority |
|---|---|---|---|---|---|
| WALL 1 | `collect_reachable_paths` | 4052–4165 | Recursive `walk_module_with_path` with synthetic public path for private glob targets | Cycle (seen-set), TYPE_KINDS must include trait | P1 |
| WALL 2 | `classify_param_bound` + routing dispatch | 5602–5638 + call sites | Treat `bound_to_concrete`-resolvable bounds as marker-equivalent (Ok(None)); route to `resolve_generics` for fully-monomorphizable methods | `!is_crate_local` guard required; BoundCrossImpl reconciliation | P2 |

**Fixture:** `runtime-rust/tests/sky/75-ffi-nested-glob-asref/` (new)
**File modified:** `tools/sky-ffi-inspect-rs/src/main.rs` (both walls, one file)
