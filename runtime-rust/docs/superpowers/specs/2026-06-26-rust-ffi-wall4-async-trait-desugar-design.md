# WALL 4 (#64) — `#[async_trait]` desugar recognition → route through #44 async→Task

**Status:** DESIGN (read-only review). **Verdict: TRACTABLE-WITH-CONSTRAINTS.**
**Date:** 2026-06-26. **Author:** Security & Soundness Guardian (design gate).
**Scope:** `tools/sky-ffi-inspect-rs/src/main.rs` (inspector only — no Haskell
codegen change required; the existing #44 async wrapper and #54/#61/#65 Send +
serde machinery are reused verbatim once the de-async'd signature reaches them).

The firestore CRUD trait methods (`create_obj` / `update_obj` / `get_obj` /
`get_doc` / `query_obj` / `delete_by_id`) drop with `not-bindable: dyn_trait`.
Root cause is **proven below against a real rustdoc JSON**: firestore uses the
`#[async_trait]` proc-macro, which rewrites every `async fn m(..) -> T` into a
**plain non-async** `fn m(..) -> Pin<Box<dyn Future<Output = T> + Send +
'async_trait>>`. Two independent inspector gates then drop that shape before the
#44 async path can run. This single recognition fix unblocks all firestore CRUD
at once and generalises to every `#[async_trait]` SDK (rs-firebase-admin-sdk,
async-stripe).

---

## 1. The exact rustdoc node shape (cited, empirically confirmed)

Probe crate (`/tmp/at-probe`, async-trait 0.1.89, rustdoc format via
`cargo +nightly rustdoc -- -Z unstable-options --output-format json`):

```rust
#[async_trait]
pub trait Store { async fn op(&self, x: String) -> Result<i64, String>; }
pub struct Db;
#[async_trait]
impl Store for Db { async fn op(&self, _x: String) -> Result<i64, String> { Ok(1) } }
```

The `op` function item (both the trait-decl id 0 AND the impl id 8 are
byte-identical in the return node) carries:

```jsonc
"header": { "is_const": false, "is_unsafe": false, "is_async": false, "abi": "Rust" }
//                                                  ^^^^^^^^^^^^^^^^^  <-- DESUGAR ERASES async
"sig": { "output": {
  "resolved_path": {
    "path": "::core::pin::Pin", "id": 2,
    "args": { "angle_bracketed": { "args": [ { "type": {
      "resolved_path": {
        "path": "Box", "id": 3,
        "args": { "angle_bracketed": { "args": [ { "type": {
          "dyn_trait": {
            "traits": [
              { "trait": {
                  "path": "::core::future::Future", "id": 4,
                  "args": { "angle_bracketed": {
                    "args": [],
                    "constraints": [ {
                      "name": "Output", "args": null,
                      "binding": { "equality": { "type": {
                        "resolved_path": { "path": "Result", "id": 5, "args": {
                          "angle_bracketed": { "args": [
                            { "type": { "primitive": "i64" } },
                            { "type": { "resolved_path": { "path": "String", "id": 1 } } }
                          ] } } }
                      } } }
                    } ]
                  } },
                  "generic_params": []
              } },
              { "trait": { "path": "::core::marker::Send", "id": 6, "args": null },
                "generic_params": [] }
            ],
            "lifetime": "'async_trait"
          }
        } } ] } }
      }
    } } ] } }
  }
} }
```

Precise facts established (these answer the make-or-break questions):

1. **`header.is_async == false`** for the desugared item. Every inspector path
   that keys async-ness on `header.is_async` (`classify_effect`'s `is_async`
   arm, line 2761; the parametric receiver-Send gate `host_is_async`, line 7218)
   is therefore BLIND to an async_trait method. This — not the dyn-trait gate
   alone — is the structural root cause: even if the dyn-trait drop were lifted,
   the method would be classified `pure`/`fallible` and the Send gates would not
   fire.
2. **The principal trait path is `::core::future::Future`** (full canonical
   path; last segment `Future`). `dyn_trait.traits[0].trait.path`.
3. **`+ Send` is reliably present** as `dyn_trait.traits[1].trait.path ==
   "::core::marker::Send"`. This is the Send proof the multi-thread tokio Task
   needs. (async-trait emits `+ Send` by default; the `?Send` opt-out
   `#[async_trait(?Send)]` omits it — see constraint C7.)
4. **`Output = T` lives in `traits[0].trait.args.angle_bracketed.constraints[]`**
   — an array of `{ "name": "Output", "binding": { "equality": { "type": <T> }}}`.
   It is NOT under `bindings` and NOT under `args`. The existing helper
   `extract_binding_type` (line 5011) reads `.get("bindings")` and returns
   `b["binding"]["equality"]` (the wrapper, not `.type`) — it is **stale for
   this format** and would return `None`/`()` here. The working code at lines
   5783 / 6798 already reads `constraints`; the new code MUST follow those, not
   `extract_binding_type`.
5. **`'async_trait` lifetime is in `dyn_trait.lifetime`, OUTSIDE the trait
   array.** It does NOT interfere with Output extraction or the Send-trait scan
   (both walk `traits[]`). It must be ignored, never threaded into a typeref
   (a lifetime type-arg already drops at `type_to_typeref` line 6471 — but we
   never reach that arm because we consume the `dyn_trait` node wholesale).

---

## 2. Where the two drops happen (real lines)

The firestore CRUD methods are **concrete-Self trait methods** on
`FirestoreDb`'s impl. Routing (lines 1196-1247):

```
is_concrete_trait_method = !is_inherent_impl && trait_self_concrete   // true
take_parametric = (… || is_concrete_trait_method) && !serde_reducible // true
→ try_parametric_stub(...)                                            // PARAMETRIC PATH
```

So the firestore keystone path is the **parametric/UFCS path**, and the drop is
in `try_parametric_stub`:

* `try_parametric_stub` → `type_to_typeref(&sig["output"], …)` at **line 7391**.
* `type_to_typeref` recurses `Pin` (resolved_path, binds via
  `resolved_path_is_bindable` — `::core::pin::Pin` is a reachable external
  type) → `Box` (ALWAYS_NAMEABLE, line 4208) → `dyn_trait` node → falls through
  every arm to **line 6529-6531**: `Err(NotBindable(describe_type_shape(val)))`
  = the literal `not-bindable: dyn_trait` drop the prompt cites.

The SECOND drop site, for an **inherent** async_trait method (or a free
async_trait fn — `parse_fn_item` path), is the #26 gate at **lines 2825-2835**:

```rust
let output_dyn = if is_dyn_trait_object_including_fn(output) { Some(output) } else { None };
if let Some(offending) = … { record_generic_drop(TraitObjectDrop…); return None; }
```

`dyn_trait_object_present` (line 8738) recurses into `Pin<Box<…>>`, finds the
`dyn_trait` node, principal `Future` is not Fn-family → returns `true` → drop.

**Both sites must be handled.** The firestore CRUD methods hit the FIRST
(parametric); inherent async_trait methods and any free
`fn -> Pin<Box<dyn Future>>` hit the SECOND. A fix to only one leaves the other
class silently dropped.

---

## 3. The recognition algorithm (sound)

Introduce one predicate + one extractor, shared by both gates.

### 3.1 `async_trait_future_output(node) -> Option<&Value>`

Returns the `Output = T` type node IFF `node` is the canonical async_trait
desugar shape, else `None`. **Fail-closed**: any deviation returns `None` (the
node then drops exactly as today — no relaxation of the #26 gate for genuine
non-Future dyn objects).

```
async_trait_future_output(node):
  # 1. peel Pin<...> (resolved_path, last-seg "Pin", crate path core::pin)
  let inner = peel_resolved_path(node, "Pin")?            # single angle-bracketed type arg
  # 2. peel Box<...> (resolved_path, last-seg "Box")  — REQUIRED (heap future)
  let boxed = peel_resolved_path(inner, "Box")?
  # 3. boxed MUST be a dyn_trait node
  let dt = boxed.get("dyn_trait")?
  let traits = dt.get("traits")?.as_array()?
  # 4. PRINCIPAL trait (traits[0]) MUST canonically be core::future::Future.
  #    Gate on the CANONICAL path id/path, NOT the last segment (#25 class):
  #    require trait.path == "::core::future::Future" OR id resolves to the
  #    std Future (a crate-local trait literally named `Future` must NOT match).
  let principal = traits[0].get("trait")?
  require is_canonical_std_future(principal)              # see C2
  # 5. + Send MUST be among the auto-trait bounds (traits[1..]).
  require traits[1..].any(|t| is_canonical_std_send(t.trait))   # see C7 / make-or-break #1
  # 6. extract Output from principal.args.angle_bracketed.constraints[]
  let out = constraint_equality_type(principal.args, "Output")?   # reads `constraints`, NOT `bindings`
  Some(out)                                              # the de-async'd return T node
```

Helpers:
* `peel_resolved_path(v, name)`: `v.resolved_path` with last-seg `== name`,
  return its single `angle_bracketed.args[0].type`; `None` on shape mismatch,
  >1 type arg, or any non-type (lifetime/const) arg.
* `constraint_equality_type(args, "Output")`: walk
  `args.angle_bracketed.constraints[]`, match `name == "Output"`, return
  `binding.equality.type`. (This is the corrected reader; `extract_binding_type`
  stays unused / should be retired — see C9.)
* `is_canonical_std_future` / `is_canonical_std_send`: see C2/C7.

### 3.2 De-async transform: rewrite the signature, set `is_async`, route to #44

When `async_trait_future_output(output)` is `Some(out_node)`:

1. **Replace the function's `sig.output` with `out_node`** (the unwrapped
   `Result<i64, String>` / `T`) — produce a `fn_data_owned` clone, exactly the
   `mono_owned` clone pattern already used at line 1115. Do NOT mutate the
   shared index node.
2. **Force `header.is_async = true`** in the clone. This is load-bearing: it
   makes `classify_effect` return `effectful` (line 2657) AND makes the
   parametric receiver-Send gate `host_is_async` fire (line 7218) AND makes the
   #44 codegen emit the `tokio::task::spawn(async move { call.await })` wrapper.
   Setting the flag is sound precisely because the desugar's `+ Send` bound is
   the same Send guarantee a native `async fn` carries.
3. Hand the cloned `fn_data` to the **existing** path:
   * Parametric path: `try_parametric_stub(method_name, &fn_data_clone, …)` —
     `type_to_typeref` now sees the unwrapped `Result<i64,String>` return (binds),
     and the receiver-Send gate at 7225-7233 (`recv_provably_async_send`) fires
     because `host_is_async` is now true.
   * `parse_fn_item` path: the de-async clone is passed in; the #26 gate at 2826
     no longer sees a `dyn_trait` in the (now unwrapped) output, and
     `classify_effect` → `effectful` triggers the param/output Send gates at
     3124-3265.

### 3.3 Order (critical)

The recognition MUST run BEFORE the existing dyn-trait drops at each site:

* **`parse_fn_item`**: at the TOP of the fn, after `sig`/`output` are bound and
  BEFORE line 2790 (`impl_traits_resolvable`) and BEFORE 2825 (#26 dyn gate),
  build the de-async clone if `async_trait_future_output(output).is_some()`, and
  proceed with the clone for the rest of the function. (Putting it before
  `impl_traits_resolvable` also lets the de-async'd `T` get its normal
  impl-trait/serde treatment.)
* **Routing block (line ~1104)**: build the de-async clone of `fn_data`
  immediately after `mono_owned` resolution (before `method_is_generic_bearing`
  / the `take_parametric` decision), so `try_parametric_stub` and the serde-
  reducibility checks all see the unwrapped signature. Compose the clone with
  the existing `mono_owned` (de-async runs on whatever `mono_owned` produced).

This ordering supersedes the #26 drop for THIS shape only; every genuine
non-Future `dyn Trait` object still falls through to the unchanged drop.

---

## 4. Composition with #44 / #54 / #59 / #65 / #60 / #61

Trace `create_obj(&self, &I: Serialize) -> Pin<Box<dyn Future<Output =
Result<(), E>> + Send>>` end to end after de-async:

1. **De-async** → `sig.output = Result<(), E>`, `header.is_async = true`.
2. **Routing**: concrete-Self trait method → `take_parametric`. The `&I:
   Serialize` param is still present; `method_all_serde_reducible` (#65) runs on
   the de-async'd `fn_data` and reduces `I → serde_json::Value`; the param
   becomes `TypeRef::SerdeValueRef` (line 6494) — `&I` → Sky `String`, `&sv_j`
   at the call site. **#65 composes** because it operates on the param node,
   which de-async leaves untouched.
3. **`try_parametric_stub`** → `type_to_typeref(output = Result<(),E>)` binds
   (Result is ALWAYS_NAMEABLE; `()` Ok arm via line 6524; E is the SkyError
   path). **No dyn_trait reaches the drop.**
4. **#54 receiver Send gate** (7225-7233): `host_is_async` now true,
   `recv_is_self` true → `recv_provably_async_send("FirestoreDb")` must hold
   (FirestoreDb is `Clone + Send + Sync` in firestore 0.49 → in
   `PROVABLY_SEND_RECV_NAMES`). If a receiver is NOT provably Send, the gate
   drops `async generic method … receiver not provably Send` — fail-closed,
   correct.
5. **#44 codegen** lifts the `effectful` wrapper → Sky `Task Error ()`.
6. **#61 opaque-return Send** (`is_provably_send_opaque_return`, line 3165) and
   **#60 borrowed** and **#22 owned-copy** all act on the unwrapped `T` and so
   compose unchanged.
7. **#59 serde return** (`TypeRef::SerdeValue` for a `get_obj<T:
   DeserializeOwned> -> T` shape): the de-async'd return `T` flows into the
   serde-reduction census exactly as a sync serde return would; `get_obj` binds
   as `Task Error String` (JSON). Composes.

For an INHERENT async_trait method the same holds via `parse_fn_item`: de-async
clone → `classify_effect` effectful → the param/output Send gates at 3124-3265
fire on the unwrapped `T` (the existing #44 + #54 + #61 logic), and #65 serde
param reduction happens via `resolve_generics` / `method_all_serde_reducible`
upstream.

---

## 5. Hand-stub fixture (positive + negatives + firestore proof)

A new inspector unit module `async_trait_desugar` (alongside the existing
`tests` mod). The fixtures are rustdoc-JSON nodes (the codebase's test style —
see `dyn_trait_node` helper at line 11857), so no real crate build is needed in
CI; the real-rustdoc shape in §1 is the source of truth they encode.

### Positive — async_trait method binds as Task

`#[async_trait] trait T { async fn op(&self, x: String) -> Result<i64,String>; }`
+ concrete `impl T for Db`. Encode the §1 return node verbatim.
Assert: `async_trait_future_output(output)` is `Some(Result<i64,String> node)`;
after de-async + route, a `Function` named `op` is produced with
`effect == "effectful"`, Sky result type `Task String i64` (Result E A → Task),
receiver `Db`, and NO `TraitObjectDrop` / `NotBindable("dyn_trait")` recorded.

### Negative A — genuine non-Future dyn object STAYS dropped

`fn make(&self) -> Box<dyn OtherTrait + Send>`. Principal trait
`OtherTrait` (not canonical Future) → `async_trait_future_output` returns
`None` → unchanged `not-bindable: dyn_trait` (parametric) /
`TraitObjectDrop` (#26 gate). Assert the drop still fires.

### Negative B — `Box<dyn Stream>` / `Box<dyn Iterator>` STAY dropped

`-> Pin<Box<dyn Stream<Item = i64> + Send>>` and
`-> Box<dyn Iterator<Item = i64>>`. Principal is `Stream` / `Iterator`, NOT
`core::future::Future`, even though `Stream` carries an associated `Item` and
sits under `Pin<Box<…>>`. `async_trait_future_output` returns `None` (the
canonical-Future gate, make-or-break #3). Assert dropped, never de-async'd.

### Negative C — `Future` WITHOUT `+ Send` STAYS dropped (fail-closed Send)

`-> Pin<Box<dyn Future<Output = i64>>>` (no `Send` in `traits[]`).
`async_trait_future_output` returns `None` at step 5 → drop
`async-future-not-send`. (A multi-thread tokio Task needs `Send`; binding this
would be E0277. This is the `#[async_trait(?Send)]` case.)

### Negative D — crate-local trait literally named `Future` STAYS dropped

A `dyn_trait` whose principal `trait.path` last segment is `Future` but whose
id resolves to a crate-local trait (crate_id 0, in LOCAL_TYPE_IDS), NOT
`::core::future::Future`. `is_canonical_std_future` rejects it (#25 class) →
`None` → drop. (Prevents a name-collision mis-recognition.)

### Real firestore 1-line proof (manual, post-implement)

After the fix, run the inspector on firestore 0.49 (or the existing
`examples/rust/skyshop-rs/wrappers/sky-firestore-shim` deps) and confirm the
`FirestoreDb` CRUD trait methods (`create_obj` / `get_obj` / `query_obj` /
`delete_by_id`) now appear in the bindings JSON with `effect: "effectful"`
instead of in the `not-bindable: dyn_trait` tail-drop ledger. (Bench-only, not
a CI fixture — see "no local sweeps" memory; push and let CI verify.)

---

## 6. Numbered constraints for the implementer

* **C1 (fail-closed predicate).** `async_trait_future_output` returns `None` on
  ANY shape deviation (missing Pin, missing Box, >1 type arg, lifetime/const
  arg in the peeled position, non-Future principal, absent Send, absent/non-
  equality Output constraint). A `None` leaves every existing drop intact.
  Default-drop is the safe direction; default-bind is the bug.
* **C2 (canonical Future gate, #25 class).** Match the principal trait on its
  CANONICAL identity: `trait.path == "::core::future::Future"` OR the trait
  `id` resolves (via the existing reachable-path / external-type-id machinery)
  to std's `core::future::Future`. NEVER the bare last segment `Future`. A
  crate-local `trait Future` (crate_id 0) must NOT match (Negative D).
* **C3 (Send required, make-or-break #1).** Require a `::core::marker::Send`
  bound in `traits[1..]`. Matched canonically (same discipline as C2; a crate-
  local `Send` must not satisfy it). No Send → drop `async-future-not-send`.
* **C4 (Output reader, the silent-corruption trap).** Read `Output` from
  `traits[0].trait.args.angle_bracketed.constraints[]` →
  `binding.equality.type`. Do NOT use `extract_binding_type` (it reads the stale
  `bindings` key and returns the un-unwrapped `equality` object). A wrong reader
  yields a silent `Task Error ()` for every async_trait method — a correctness
  defect that compiles. Add an assertion in the positive fixture that the
  extracted T is exactly `Result<i64,String>`, not `()`.
* **C5 (clone, never mutate).** Produce a `fn_data` clone with rewritten
  `sig.output` and `header.is_async = true` (the `mono_owned` pattern, line
  1115). The shared `index` node must remain untouched (other impls / re-exports
  read it).
* **C6 (both gates).** Apply the recognition at BOTH the `parse_fn_item` top
  (before line 2790/2825) AND the routing block (line ~1104, after `mono_owned`,
  before `take_parametric`). Compose with `mono_owned` (de-async runs on its
  output).
* **C7 (`'async_trait` lifetime ignored).** Consume the `dyn_trait` node
  wholesale; never thread `dyn_trait.lifetime` into a typeref. (It would
  otherwise hit the lifetime-arg drop at 6471 — but we never recurse there.)
* **C8 (order vs serde / Send).** De-async runs FIRST so the unwrapped `T`
  receives the normal `impl_traits_resolvable` / serde-reduction / Send-gate
  treatment. Confirm `method_all_serde_reducible` and `resolve_generics` are
  called on the de-async'd clone, not the original.
* **C9 (retire the stale reader).** `extract_binding_type` (line 5011) is dead
  for the modern `constraints` format and its only callers are the existing
  (also-dead, gate-shadowed) `Future`/`Pin` arms at 4914-4932. Either fix it to
  read `constraints` + `binding.equality.type` and reuse it, or delete it and
  the unreachable `Pin`/`Future` arms. Do not leave two divergent readers.
* **C10 (no #26 relaxation).** The change must NOT widen
  `dyn_trait_object_present` / `is_dyn_trait_object_including_fn`. Those keep
  dropping every non-Future dyn object. Recognition is a PRE-pass that consumes
  the Future shape before the gate sees it — the gate's contract is unchanged.
* **C11 (no unsafe surface).** The desugar never exposes an `unsafe fn`
  (the unsafe-flag gate at 2771-2777 still runs on the de-async'd clone, whose
  `header.is_unsafe` is copied unchanged). Confirm the clone preserves
  `is_unsafe`.

## 7. Guardian-final checks (run before APPROVE-FOR-PUSH)

1. **Both drop sites closed**: grep the bindings ledger for firestore — zero
   `not-bindable: dyn_trait` AND zero `TraitObjectDrop` for the CRUD methods;
   they appear as `effect: effectful`.
2. **Negatives A–D still drop** (unit fixtures green): non-Future dyn,
   `Box<dyn Stream>`, `Box<dyn Iterator>`, `Future`-without-Send, crate-local
   `Future`. A regression here = an unsound over-bind (E0277/E0308/E0599).
3. **Output not corrupted to `()`** (C4 assertion): positive fixture asserts
   `Task String i64`, not `Task Error ()`.
4. **`is_async = true` actually fires the Send gates**: assert the positive
   method routed through `recv_provably_async_send` (a `!Send` receiver fixture
   drops `receiver not provably Send`), and that a non-Send by-value param drops
   via the param-Send gate (3183-3265). De-async without the Send gates would
   compile to an E0277 at the host.
5. **No panic / no unwrap introduced**: the new helpers use `?`/`Option`
   throughout (no `[i]`, no `.unwrap()`); `peel_resolved_path` and
   `constraint_equality_type` are total over malformed JSON (return `None`).
6. **Clone isolation** (C5): the shared index node is unmutated — verify by
   re-reading the same `op` id after processing yields the original
   `Pin<Box<dyn Future>>` output.
7. **Full inspector unit suite + the 6 gated examples build** (CI, not local);
   the existing async fixture (#44) and trait-method fixtures (#21/#31/#52) stay
   green — de-async must be additive (it only fires on the canonical Future
   shape; every prior path is byte-identical when the predicate returns `None`).

## 8. THE single make-or-break

**The Output type MUST be read from the `constraints[]` array via
`binding.equality.type`, and the method MUST be re-flagged `is_async = true`.**

Both are confirmed against the real rustdoc JSON (§1). Getting the reader wrong
(reusing the stale `extract_binding_type`, which targets `bindings` and returns
the `equality` wrapper) silently de-asyncs every async_trait method to
`Task Error ()` — a correctness defect that compiles clean and ships wrong
results. Forgetting `is_async = true` leaves the method classified `fallible`,
skips the #54/#61 Send proofs, and emits a wrapper that cargo-fails with E0277
on the spawned future. The recognition is otherwise sound: the `+ Send` bound
(reliably present, C3) is exactly the Task-spawn Send proof, and the canonical-
Future gate (C2) keeps every genuine `dyn Trait` / `dyn Stream` / `dyn Iterator`
object on its existing drop path.

---

### Verdict: TRACTABLE-WITH-CONSTRAINTS

The fix is inspector-local, reuses the entire #44/#54/#59/#61/#65 stack
unchanged, drops fail-closed on every deviation, and does not relax the #26
dyn-trait gate. Implement under C1–C11; gate with the §7 guardian-final checks;
the make-or-break in §8 is the one place a silent correctness defect can hide.
