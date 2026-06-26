# WALL 5 — Firestore ground constructor: empirical design spec

- **Task:** #63 (the gating firestore blocker)
- **Date:** 2026-06-26
- **Branch / HEAD context:** `feat/runtime-rust`, firestore re-measured at HEAD `cadb5c60` (all walls in)
- **Inspector under test:** `tools/sky-ffi-inspect-rs` (release), rustdoc JSON `format_version` 57, firestore `0.49.0`
- **Mode:** read-only investigation + design. No code edits, no commits.

---

## 0. Executive summary — VERDICT: **TRACTABLE (Path A)**

Firestore 0.49 exposes a ground constructor that auto-FFI can bind **without any
`Box<dyn>`, trait-`Self`, or unmodellable-bound obstacle**:

```rust
// firestore::db::FirestoreDb
pub async fn with_options(options: FirestoreDbOptions) -> FirestoreResult<Self>
pub async fn for_default_project_id() -> FirestoreResult<Self>
```

Both are async, carry **no generic params, no where-clause bounds, no `Box<dyn>`,
no `impl Trait`**, take only concrete owned args, and return
`FirestoreResult<Self>` = `Result<FirestoreDb, FirestoreError>`. `FirestoreDb`
carries a synthetic **positive** `impl Send` (it is `Send`), and
`FirestoreDbOptions::new(String) -> Self` already binds today as a pure
constructor with a working `with_*` builder chain.

These constructors are **currently dropped for a single, precise reason that is
NOT any of the three the re-measure named**: the inspector does not see through
the crate's **generic** type alias `FirestoreResult<T> = Result<T, FirestoreError>`.
The unresolved `FirestoreResult<FirestoreDb>` then fails the async-Send output
gate's `Result<…>`-unwrap, and the gate drops the function as
`async-future-not-send` (a drop reason that is invisible in the `--audit`
histogram because it is not in the printed reason allowlist).

The re-measure's "FirestoreDb::new drops 3-way" is a **misattribution caused by a
name-collision in the coverage report** (the report rows carry no receiver
context, so the three different `new` fns on three different types collapse to
three bare `new` rows). See §1.3.

**The fix is a constrained, sound generic-alias see-through for the canonical
`AliasName<…> = Result<…>` shape.** Once the alias resolves, both constructors
bind as `Task Error FirestoreDb`, and every downstream firestore CRUD producer
(`clone_with_session_params`, `with_session_params`, `db_field`, the fluent API)
gets its ground `FirestoreDb` and type-checks. This unblocks WALL 4 (#64,
dyn-trait) and WALL 3a-&I (#65), which are dead code without a `FirestoreDb`
value.

---

## 1. Empirical constructor inventory

Method: generated firestore 0.49 rustdoc JSON
(`cargo +nightly rustdoc -p firestore -- -Zunstable-options --output-format json`
→ `~/.cache/sky-rust-target/doc/firestore.json`), enumerated every associated fn
on `FirestoreDb` (id 1173) and `FirestoreDbOptions` (id 3584), dumped each full
signature, and cross-checked against the inspector's bound output and drop
accounting.

### 1.1 Construction-shaped associated fns on `firestore::db::FirestoreDb`

| fn | async | generics / where | args | return | binds today? | obstacle |
|---|---|---|---|---|---|---|
| `new` | yes | `<S> where S: AsRef` | `google_project_id: S` | `FirestoreResult<Self>` | **no** | **unmodellable-bound** (`S: AsRef`) → `resolve_generics` drops. The single real obstacle, NOT Box/Self/Listen. |
| `with_options` | yes | none | `options: FirestoreDbOptions` | `FirestoreResult<Self>` | **no** | **generic-alias non-resolution** of `FirestoreResult<Self>` → async-Send output gate drop (§2). NO Box/dyn/Self/bound. **← TRACTABLE TARGET** |
| `for_default_project_id` | yes | none | (none) | `FirestoreResult<Self>` | **no** | same generic-alias non-resolution (§2). Cleanest possible shape. **← TRACTABLE TARGET (secondary)** |
| `with_options_service_account_key_file` | yes | none | `options: FirestoreDbOptions`, `service_account_key_path: std::path::PathBuf` | `FirestoreResult<Self>` | **no** | same alias non-resolution; plus `PathBuf` param needs the Wall-3b/owned-path admit to be in-set (secondary). |
| `with_options_token_source` | yes | none | `options: FirestoreDbOptions`, `token_scopes: Vec<String>`, `token_source_type: gcloud_sdk::token_source::TokenSourceType` | `FirestoreResult<Self>` | **no** | alias non-resolution; plus a foreign-crate opaque param (`TokenSourceType`) → out of scope for v1. |

There is **no** `FirestoreDb` overload requiring a `Box<dyn …>` options arg. The
"only Box<dyn> ctor" hypothesis (Path B) is **empirically false**.

### 1.2 `firestore::db::options::FirestoreDbOptions` — the options builder (already bound)

| fn | kind | args | return | binds today? |
|---|---|---|---|---|
| `new` | inherent ctor | `google_project_id: String` | `Self` | **yes** (pure) — confirmed in inspector bound output |
| `with_google_project_id` | by-value builder | `String` | `Self` | yes |
| `with_database_id` | by-value builder | `String` | `Self` | yes |
| `with_max_retries` | by-value builder | `usize` | `Self` | yes |
| `with_firebase_api_url` | by-value builder | `String` | `Self` | yes |
| `google_project_id` / `database_id` / `max_retries` / `firebase_api_url` | `&mut Self -> &mut Self` fluent setters | … | `&mut Self` | yes (own-threaded) |
| `for_default_project_id` | inherent | (none) | `Option<FirestoreDbOptions>` | yes |

Fields: `google_project_id: String`, `database_id: String`, `max_retries: usize`,
`firebase_api_url: Option<String>`. **The builder chain the re-measure expected is
present and binds today.** No obstacle on the options side.

`FirestoreResult` confirmed: `core::result::Result<T, firestore::errors::FirestoreError>`;
`FirestoreError` is a 10-variant enum (maps cleanly to a Sky opaque / error).

### 1.3 Why the re-measure said `FirestoreDb::new` drops 3-way — name collision in the coverage report

The coverage report (`.skycache/ffi/rust/firestore.coverage.md`) lists drops as
`| <bare-fn-name> | <reason> | <detail> |` with **no receiver/type qualifier**.
There are many `new` fns across firestore's types, so three unrelated rows read as
"three drops of `new`":

| report line | reason | detail | actual owning type |
|---|---|---|---|
| 1048 | `unmodellable-bound` | `FirestoreListenSupport` | a **listener** type's `new`, not `FirestoreDb` |
| 1623 | `not-bindable` | `undeclared type-var Self` | a different type's `new` |
| 2821 | `trait-object-unsupported` | `Box<>` | **`firestore::errors::FirestoreErrorInTransaction::new`** (carries a `Box<dyn …>` param) |

Cross-checked against the rustdoc: the only `new` fns carrying these obstacles are
`FirestoreErrorInTransaction::new` (Box<dyn>) and various listener/error types —
**`FirestoreDb::new`'s sole obstacle is `where S: AsRef`** (unmodellable-bound).
`FirestoreDb` itself is never dropped for Box<dyn> or for a trait-`Self`.

> **Lesson for the implementer + guardian-final:** the coverage report's bare-name
> rows are not safe to attribute to a type by name. Always confirm an attributed
> drop against the rustdoc `impl … for <Type>` block (the inspector's DBG2 line
> carries `self_rust`, which is authoritative).

### 1.4 What binds today that RETURNS a `FirestoreDb` — all take a `FirestoreDb` already

Inspector bound output, every bound fn whose `recvType == FirestoreDb`:

```
get_database_path        (FirestoreDb) -> String                         pure
get_documents_path       (FirestoreDb) -> String                         pure
parent_path              (FirestoreDb,String,String) -> FirestoreResult ParentPathBuilder  pure
get_options              (FirestoreDb) -> FirestoreDbOptions             pure
get_session_params       (FirestoreDb) -> FirestoreDbSessionParams       pure
clone_with_session_params      (FirestoreDb,FirestoreDbSessionParams) -> FirestoreDb  pure
with_session_params            (FirestoreDb,FirestoreDbSessionParams) -> FirestoreDb  pure
clone_with_consistency_selector (FirestoreDb,FirestoreConsistencySelector) -> FirestoreDb pure
```

Every one of these **consumes** a `FirestoreDb` as `arg0`. Plus `db_field`
accessors on the batch writers return `FirestoreDb` but are likewise reached only
from an existing `FirestoreDb`. **No bound fn mints a `FirestoreDb` from ground.**
This is exactly the gating condition: no firestore CRUD call site can type-check
without a ground constructor binding first.

---

## 2. Root-cause of the `with_options` / `for_default_project_id` drop (the make-or-break)

Traced end-to-end through `parse_fn_item` (`tools/sky-ffi-inspect-rs/src/main.rs`).
For `with_options` / `for_default_project_id`:

1. `is_async = true`.
2. Not `unsafe`; `resolve_generics` returns `Some(empty)` (no generic params) — **not** the drop.
3. No `impl Trait`, no `dyn` object — passes 2773–2817.
4. **Output rendering (line 2874–2882).** Output JSON is
   `resolved_path { path: "FirestoreResult", id: 1137, args: <Self> }`.
   Both `rustdoc_type_to_rust_str` and `rustdoc_type_to_sky` call `resolve_alias`,
   which is backed by `collect_aliases` — and **`collect_aliases` skips GENERIC
   aliases** (`src/main.rs` ~3942: `if generic { continue; }`). `FirestoreResult<T>`
   is generic, so it is NOT in `ALIAS_MAP`. The converters therefore render it
   **opaquely** as `FirestoreResult<FirestoreDb>` (rust) and `FirestoreResult FirestoreDb`
   (sky) — the alias is never expanded to `Result<FirestoreDb, FirestoreError>`.
   `subst_self` then maps `Self -> FirestoreDb` inside that opaque shell.
5. `classify_effect` → `effectful` (async).
6. **Async-Send OUTPUT gate (3107–3159).** `ret.rust_type = "FirestoreResult<FirestoreDb>"`.
   The gate tries `strip_prefix("Result<")` to unwrap the `T` of a fallible async
   return — this **fails** (the string starts with `FirestoreResult<`, not `Result<`),
   so `inner_rt` falls back to the whole `"FirestoreResult<FirestoreDb>"`.
   `is_async_send_output` (primitives+String only) = false; `is_async_send_seq` =
   false; `is_provably_send_opaque_return` **rejects any string containing `<`** →
   false. `output_is_send = false` → `return None`.
   The drop is recorded as `record_tail_drop("async-future-not-send", …)` — but
   `"async-future-not-send"` is **not** in the `--audit` histogram's printed reason
   list, so the drop is silent in the audit summary (this is why the re-measure
   could not see it and reached for the coverage report's misleading bare-`new` rows).

**Conclusion:** the obstacle is **NOT** `is_async_send_output` failing on the
opaque return per se (`FirestoreDb` *is* provably Send and *would* pass), **NOR**
a borrowed `&str`, **NOR** the options struct, **NOR** a Box<dyn> bundling. The
obstacle is purely that the **generic Result-alias is never expanded**, so the
gate's Result-unwrap can't reach the `FirestoreDb` it would happily admit.

Verified facts feeding this conclusion:
- `FirestoreResult` alias body = `Result<T, FirestoreError>`, one generic param `T`.
- `FirestoreDb` (id 1173) has a synthetic, non-negative `impl Send` and `impl Sync`
  → it lands in `PROVABLY_SEND_RECV_NAMES` via `collect_synthetic_send_type_ids`
  → `is_provably_send_opaque_return("FirestoreDb")` = **true**.
- DBG run confirms both fns reach `parse_fn_item` (inherent, concrete Self,
  `generic_bearing=false`) and return `None`.

---

## 3. Constrained implementation design (Path A)

### 3.1 The single inspector change — see through a generic `… = Result<…>` alias

Today `collect_aliases` records only **non-generic** aliases (rationale: a generic
alias body references the alias's own type params, which the converters can't bind
positionally). That rationale is correct in general but **over-broad**: a generic
alias whose body is a `Result<T, E>` (or any shape into which the call site's
concrete args substitute 1:1) is safely expandable once we substitute the alias's
type-params with the **actual angle-bracketed args at the use site**.

**Design — narrow, sound see-through (do NOT widen `collect_aliases` blanket):**

1. Add a `GENERIC_ALIAS_MAP: id -> (params: Vec<String>, body: TypeJson)` populated
   for crate-local generic aliases whose body is a `resolved_path` named `Result`
   (`core::result::Result`) — i.e. the canonical crate-Result-alias shape. Keep the
   admit set **tight**: only expand when the body's outermost constructor is
   `Result` (and, as a forward-compatible option, `Option`), and when the alias's
   arity matches the use-site arg count. This avoids re-introducing the
   "generic-alias body references unbindable own params" hazard for arbitrary
   wrappers.
2. In `rustdoc_type_to_rust_str` / `rustdoc_type_to_sky`, BEFORE the existing
   non-generic `resolve_alias` see-through, when `rp.id` is in `GENERIC_ALIAS_MAP`,
   **substitute** the alias's declared params with the use-site
   `angle_bracketed.args` into the body JSON, then recurse on the substituted body.
   For `FirestoreResult<FirestoreDb>` this yields
   `Result<FirestoreDb, FirestoreError>` (rust) and the corresponding Sky
   `Result FirestoreDb FirestoreError` / `Task`-fallible shape the downstream
   machinery already understands.
3. Substitution must be **position-correct and total**: walk the body JSON,
   replacing each `{"generic": "<paramName>"}` node with the matching use-site arg
   JSON. A param with no matching use-site arg (arity mismatch) → **do not expand**
   (fail closed to the current opaque rendering, never emit a half-substituted
   body).

**Why this is the right altitude:** the crate-Result-alias (`type Result<T> =
std::result::Result<T, MyError>`) is one of the most common idioms in real Rust
crates. Firestore is simply the first wall-gating consumer. A targeted, sound
see-through here pays off across the whole ffi-audit sample, not just firestore.

### 3.2 What this unblocks once the alias resolves

- Output of `with_options` becomes `Result<FirestoreDb, FirestoreError>` → async
  gate's `strip_prefix("Result<")` succeeds → `inner_rt = "FirestoreDb"` →
  `is_provably_send_opaque_return("FirestoreDb") = true` → **gate PASSES**.
- `with_options` binds: `FirestoreDbOptions -> Task Error FirestoreDb`
  (compose #44 async→Task + #61 provably-Send opaque return).
- `for_default_project_id` binds: `() -> Task Error FirestoreDb`.
- `FirestoreDbOptions::new` + `with_*` builder already bind → Sky can construct the
  options value and feed `with_options`.
- All `FirestoreDb`-consuming producers (`with_session_params`,
  `clone_with_session_params`, fluent API) now have a ground value → CRUD call
  sites type-check → WALL 4 (#64) and WALL 3a-&I (#65) cease to be dead code.

### 3.3 Composition with prior walls (no new mechanism needed beyond §3.1)

| concern | mechanism | status |
|---|---|---|
| async → `Task Error a` wrapper (`tokio::task::spawn`) | #44 | shipped |
| opaque `FirestoreDb` Send-safe to spawn as the future Output | #61 `is_provably_send_opaque_return` (synthetic-Send-keyed) | shipped; **already returns true for FirestoreDb** |
| `FirestoreDbOptions` by-value param | ordinary concrete owned struct param | already bound |
| `&str` project-id (WALL 3b) | borrowed-`&str`→owned-String coercion | shipped (only relevant to `new<S: AsRef>`, which stays dropped — see §3.4) |
| **generic `Result`-alias return** | **NEW §3.1 see-through** | **the only missing piece** |

### 3.4 Explicitly OUT of scope for WALL 5 v1 (record, do not attempt)

- **`FirestoreDb::new<S: AsRef>`** — its `where S: AsRef` is an unmodellable bound
  (`AsRef` with no target type-arg resolvable to a single concrete) → stays dropped
  by `resolve_generics`. `with_options` / `for_default_project_id` are the binding
  path; `new` is a convenience overload we deliberately skip. (A future Wall-3b-style
  `AsRef<str>`-specialization could bind it, but it is not on the WALL 5 critical
  path — `with_options` is sufficient to mint a `FirestoreDb`.)
- **`with_options_token_source`** — foreign-crate opaque param
  `gcloud_sdk::token_source::TokenSourceType` (not crate-local, not modellable) →
  stays dropped. Not needed; `with_options` covers auth via the options struct +
  ambient ADC.
- **`with_options_service_account_key_file`** — depends on the owned-`PathBuf`
  param admit being in-set; secondary, can follow once `with_options` lands.

---

## 4. Hand-stub proof fixture (mirrors the firestore shape)

Model the fixture on `runtime-rust/tests/sky/76-ffi-borrowed-ref` (a local
`file://` git crate staged by `setup.sh`, `["rust.dependencies"]` in `sky.toml`,
a `Main.sky` that exercises each bound fn and prints `[ALL OK]`).

### 4.1 The hand-stub crate — `wall5-result-alias-crate`

Reproduce the exact gating shape: an async constructor returning a **crate-defined
generic `Result` alias** of an owned, Send opaque handle, plus a pure options
builder.

```rust
// wall5-result-alias-crate/src/lib.rs
//
// WALL 5 proof: an async constructor that returns a crate-defined GENERIC
// type alias `type DbResult<T> = Result<T, DbError>` — the firestore
// `FirestoreResult<T> = Result<T, FirestoreError>` shape. Pre-fix, the inspector
// does not see through the generic alias, so the async-Send output gate cannot
// unwrap the Result and drops the constructor (async-future-not-send). Post-fix
// (§3.1), the alias expands to Result<Db, DbError>, the gate unwraps to `Db`,
// `Db` is provably Send (synthetic impl Send), and the ctor binds as
// `Task Error Db`.

#[derive(Debug)]
pub enum DbError { NotFound, Backend(String) }

pub type DbResult<T> = Result<T, DbError>;   // GENERIC crate Result alias

#[derive(Clone)]
pub struct DbOptions { project: String, retries: usize }

impl DbOptions {
    pub fn new(project: String) -> Self { Self { project, retries: 3 } }
    pub fn with_retries(mut self, n: usize) -> Self { self.retries = n; self }
}

pub struct Db { project: String }            // owned, Send opaque handle

impl Db {
    // THE gating shape: async, concrete owned arg, returns the generic alias.
    pub async fn with_options(options: DbOptions) -> DbResult<Self> {
        Ok(Self { project: options.project })
    }
    // No-arg variant (firestore::for_default_project_id mirror).
    pub async fn connect_default() -> DbResult<Self> {
        Ok(Self { project: "default".to_string() })
    }
    // A consumer that takes a Db (mirrors with_session_params) — proves the
    // ground value flows into downstream producers.
    pub fn project(&self) -> String { self.project.clone() }
}
```

Notes that make the proof load-bearing:
- `Db` must be **Send** (no `Rc`/`Cell` fields) so rustdoc emits a synthetic
  positive `impl Send` → `is_provably_send_opaque_return` true → the gate passes
  *only because of* the §3.1 alias see-through, isolating the variable under test.
- `DbError` is a plain enum (the firestore `FirestoreError` analogue).
- Keep a **negative control** in the same crate to prove the fix stays narrow:
  add `pub async fn boxed(opt: DbOptions) -> DbResult<Box<dyn std::fmt::Debug + Send>>`
  and assert it STILL drops (the alias expands, but the inner `Box<dyn …>` is a
  trait object → `trait-object-unsupported`). This guards against the see-through
  over-admitting.

### 4.2 `Main.sky` — the binding proof

```elm
module Main exposing (main)

import Sky.Core.Prelude exposing (..)
import Sky.Core.Task as Task
import Sky.Core.Error as Error
import Rust.Wall5_result_alias_crate as W
import Std.Log exposing (println)

-- with_options : DbOptions -> Task Error Db   (post-fix binding)
checkWithOptions : Task Error ()
checkWithOptions =
    let opts = W.with_retries_from_db_options (W.new_from_db_options "proj") 5 in
    W.with_options_from_db opts
        |> Task.andThen (\db ->
            if W.project_from_db db == "proj" then
                println "with_options=ok"
            else
                Task.fail (Error.unexpected "with_options=UNEXPECTED"))

-- connect_default : () -> Task Error Db
checkConnectDefault : Task Error ()
checkConnectDefault =
    W.connect_default_from_db ()
        |> Task.andThen (\db ->
            if W.project_from_db db == "default" then
                println "connect_default=ok"
            else
                Task.fail (Error.unexpected "connect_default=UNEXPECTED"))

main : Task Error ()
main =
    checkWithOptions
        |> Task.andThen (\_ -> checkConnectDefault)
        |> Task.andThen (\_ -> println "[ALL OK]")
```

(Exact generated binding names follow the inspector's `recvType`/`methodName`
emission — confirm against `*.skyi` after a build; the names above use the
fixture's observed `<method>_from_<recvtype>` convention.)

### 4.3 The 1-line firestore proof

After the fixture is green, add a real-crate assertion that the inspector now
binds the firestore ground ctor (no network, inspection only):

```bash
# expect: with_options AND for_default_project_id present, returning Task Error FirestoreDb
$SKY_FFI_INSPECTOR_RS firestore \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); c=d[0] if isinstance(d,list) else d; \
    fs=[f for f in c["functions"] if f.get("recvType")=="FirestoreDb" and f.get("name") in ("with_options","for_default_project_id")]; \
    print("\n".join(f"{f[\"name\"]} -> {[r.get(\"skyType\") for r in f[\"results\"]]} effect={f[\"effect\"]}" for f in fs)); \
    assert len(fs)==2, "WALL5 NOT bound"'
```

Pre-fix this prints nothing and asserts; post-fix it prints two lines binding to
`Task Error FirestoreDb` (effect `effectful`).

---

## 5. Make-or-break + constraint list for the implementer & guardian-final

### 5.1 The make-or-break (answered)

> *Does firestore 0.49 expose ANY async constructor that auto-FFI can bind WITHOUT
> a `Box<dyn>` / trait-`Self` / unmodellable-bound obstacle?*

**Yes.** `FirestoreDb::with_options(FirestoreDbOptions) -> FirestoreResult<Self>`
and `FirestoreDb::for_default_project_id() -> FirestoreResult<Self>`. The **only**
thing standing between them and a binding is the inspector's generic-`Result`-alias
non-resolution (§2). Path A is open; Path B (wrapper-shim) is **not required**.

### 5.2 Numbered constraints (implementer)

1. **Scope the alias see-through to the canonical Result-alias shape only.** Expand
   a crate-local *generic* alias **iff** its body's outermost constructor is
   `core::result::Result` (optionally `core::option::Option`). Do NOT blanket-widen
   `collect_aliases` to all generic aliases — that re-opens the "generic body
   references unbindable own params" hazard the original guard exists for.
2. **Substitution must be position-correct and TOTAL.** Replace each
   `{"generic":"<param>"}` in the alias body with the matching use-site
   angle-bracketed arg JSON. Arity mismatch (params ≠ use-site args) → **fail closed**
   to the current opaque rendering; never emit a half-substituted body (that would
   produce an ill-typed wrapper that type-checks in `sky build` but cargo-fails).
3. **Apply the see-through in BOTH converters** (`rustdoc_type_to_rust_str` and
   `rustdoc_type_to_sky`) identically, BEFORE the existing non-generic
   `resolve_alias` call, so the rust string the async-Send gate reads and the sky
   string the surface reads agree. A divergence here is the classic
   type-checks-but-cargo-fails class.
4. **Do not weaken the async-Send gate.** The fix is upstream of the gate; the gate
   stays exactly as tight (`is_provably_send_opaque_return` keyed on synthetic-Send).
   Confirm `FirestoreDb` is admitted by the gate *because it is genuinely Send*
   (synthetic positive `impl Send`), not by any relaxation.
5. **Keep `new<S: AsRef>` dropped.** Its unmodellable `AsRef` bound is out of scope;
   binding it is NOT required to mint a `FirestoreDb`. Do not attempt to special-case
   `AsRef<str>` as part of WALL 5.
6. **Negative control in the fixture (mandatory).** The hand-stub crate MUST include
   an async ctor returning `DbResult<Box<dyn …>>` and the test MUST assert it STILL
   drops (`trait-object-unsupported`). This proves the alias see-through expands the
   *outer* Result without admitting an unbindable *inner* type.
7. **Add a generic-alias arity/shape unit test.** Cover: (a) `DbResult<Db>` →
   `Result<Db, DbError>` expands; (b) `DbResult<Box<dyn>>` expands the Result but the
   inner still drops; (c) a non-Result generic alias is NOT expanded (stays opaque);
   (d) arity mismatch → no expansion.
8. **Confirm Go-byte-identity is irrelevant here (Rust-only path)** but keep the
   inspector's existing output contract: only the rendered type strings change for
   the affected fns; no schema field added/removed.

### 5.3 Numbered checks (guardian-final)

1. **Re-grep the see-through for arity holes.** Prove the substitution cannot leave
   a residual `{"generic": …}` node (would render an undeclared type-var → cargo
   E0412). Adversarial inputs: alias with 2 params used with 1 arg; alias body with
   a nested generic (`Result<Vec<T>, E>`).
2. **Prove fail-closed.** On any non-Result alias body or arity mismatch, the output
   must be byte-identical to the pre-fix opaque rendering (no partial expansion).
3. **Confirm the gate still drops genuinely-non-Send async returns.** Add/keep a
   fixture row where the opaque handle is `Rc`-backed (`!Send`) returned through the
   alias — it MUST still drop (`async-future-not-send`). The alias see-through must
   not become a Send-bypass.
4. **Verify the real firestore proof binds exactly two ctors** (`with_options`,
   `for_default_project_id`) and NOT `new` / `with_options_token_source` /
   `with_options_service_account_key_file` (the latter only if its PathBuf param
   admit is separately landed).
5. **Run the full ffi unit + fixture suite** (not DCE-on only) — a generic-alias
   change can shift rendering across the whole sample; confirm no previously-bound
   fn regresses and no secret/opaque leaks into a binding.
6. **Audit-histogram visibility (process bug, file it).** `async-future-not-send`
   (and any other `record_tail_drop` reason not in the printed allowlist) is invisible
   in `--audit`. This is why the re-measure misdiagnosed WALL 5. Recommend adding the
   async-future reason to the histogram reason list so future walls don't chase
   coverage-report name-collisions. (Non-blocking for WALL 5, but it caused this
   entire investigation detour.)

---

## 6. The single most important finding

`FirestoreDb::with_options` / `for_default_project_id` are **already shape-clean**
(async, concrete args, owned-Send `Result<Self>` return) and the *only* reason they
drop is that the inspector does not see through the crate's **generic** alias
`FirestoreResult<T> = Result<T, FirestoreError>`. The re-measure's "3-way
`FirestoreDb::new` drop (Box<dyn> / Self / FirestoreListenSupport)" was a
**name-collision artifact of the receiver-less coverage report** — those three
drops belong to three *other* types' `new`. WALL 5 is a small, sound, broadly
useful generic-Result-alias see-through, **not** a wrapper-crate escape hatch.
