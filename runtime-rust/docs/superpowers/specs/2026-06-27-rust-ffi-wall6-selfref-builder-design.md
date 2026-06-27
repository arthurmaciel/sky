# WALL 6 — Firestore fluent API & the self-borrowing-builder circumvention

> **Status:** DESIGN (guardian gate pending). Task #68. Branch `feat/runtime-rust`.
> Firestore `0.49.0`, rustdoc `format_version` 57. User explicitly authorized a
> LOCAL real-crate investigation of #68 (overrides no-local-sweeps for this item)
> and asked to *innovatively circumvent* the "borrowed/lifetime-tied types can't
> be owned Sky values" limitation, guardian-designed + reviewed, 6 principles
> held tight (security > correctness > soundness > efficiency > completeness >
> readability).

---

## 0. Executive summary — TWO findings, TWO deliverables

**Finding A (decisive, from rustdoc JSON).** The firestore **query / list / aggregate
capability is reachable through an OWNED API that auto-FFI already targets** — the
fluent builder is pure sugar over it:

- `FirestoreQueryParams::new(FirestoreQueryCollection) -> Self` + `with_*(Self, X) -> Self`
  by-value builders for **every** field (all fields `pub`). Fully owned-constructible.
- `FirestoreDb::query_doc(&self, FirestoreQueryParams) -> async FirestoreResult<Vec<Document>>`
  and `query_obj(&self, FirestoreQueryParams) -> async FirestoreResult<Vec<T>>` —
  async-trait methods (WALL 4) taking the **owned** params struct, `&self` elided
  borrow (WALL 3b), provably-Send return (WALL 5/#61). Same shape as the already-bound
  CRUD ops (`get_obj`/`create_obj`/`update_obj`/`delete_by_id`).
- Same for `list_doc(FirestoreListDocParams)`, `aggregated_query_doc(FirestoreAggregatedQueryParams)`.

⇒ **Dropping the borrowing fluent builders costs ZERO capability.** Every fluent
chain (`db.fluent().select().from(c).limit(n).obj::<T>().query()`) has an exact
owned equivalent (`db.query_obj(FirestoreQueryParams::new(c).with_limit(n))`).
The soundest circumvention of the borrow limitation is: **don't bind the borrow —
bind the owned API that does the same thing.** This is not a workaround; it is the
literal lower-level API the fluent layer is built on.

**Finding B (the fluent shape itself).** `fluent(&self) -> FirestoreExprBuilder<'_, D>`
returns a builder that **borrows** `&'a self`. Every downstream builder is
`Builder<'a, D[, T]>` carrying that lifetime. The `touches_lifetime` filter
(`main.rs:3774`) drops every one — a SOUND fail-closed drop today. The *innovation*
the user asked for is to bind these borrowing chains as owned Sky values.

**Deliverable 1 (CORRECTNESS/COMPLETENESS — the real capability win).**
Confirm + close whatever blocks the OWNED firestore path (`*_doc`/`*_obj(Params)` +
the `FirestoreQueryParams`/`…Order`/`…Collection`/`…Filter` builders) from binding
cleanly. Prove with a fixture mirroring the owned params→query shape. This makes
firestore fully usable from Sky shim-free, independent of the fluent layer.
(Overlaps #73 — the firestore SKY_DCE=0 residuals.)

**Deliverable 2 (the INNOVATION — general self-borrowing-builder mechanism).**
A sound mechanism to bind a self-borrowing builder chain
(entry `&self -> B<'_>` on a **Clone** receiver; chain `B<'_> -> C<'_>` self-by-value;
terminal `X<'_> -> Owned`, incl. async) as an owned, `'static`, Send Sky value via a
**self-referential owned bundle**: an owned (boxed) clone of the receiver carried
alongside the lifetime-laundered builder. Closes not just firestore but the **#71
universal sound-drop class** (Entry APIs, `ParseOptions`, `BorrowedFormatItem`, every
lifetime-borrowing builder). This carries **`unsafe`** → guardian-critical.

---

## 1. The self-referential owned bundle — mechanism & soundness

### 1.1 The shape we bind

```rust
// Receiver R: Clone (cheap; firestore FirestoreDb is Arc-backed).
impl R { fn fluent(&self) -> B<'_> }              // ENTRY: &self -> Builder<'_>
pub struct B<'a> { /* &'a R + owned spec */ }      // single lifetime param, borrows R
impl<'a> B<'a> {
    fn select(self) -> C<'a>;                       // CHAIN: self-by-value -> Next<'a>
    fn limit(self, n: u32) -> Self;                 // CHAIN (self-returning)
    async fn query(self) -> FirestoreResult<Vec<X>>; // TERMINAL: self-by-value -> Owned
}
```

### 1.2 The generated bundle (per entry/builder type)

```rust
// Field order is LOAD-BEARING: `dep` declared first ⇒ dropped first ⇒ releases
// its borrow of *owner BEFORE owner is freed. Default drop glue suffices; no
// explicit Drop impl. `owner` is boxed ⇒ stable heap address ⇒ moving the bundle
// (a Box pointer move) never invalidates dep's borrow of the pointee.
struct SkyFluent_B { dep: B<'static>, owner: Box<R> }

// ENTRY wrapper — the ONLY unsafe site (one transmute, concrete types).
fn fluent_from_r(r: R) -> SkyFluent_B {
    let owner = Box::new(r);
    // SAFETY: dep borrows *owner; owner is boxed (stable), kept in the same
    // bundle, and dropped AFTER dep (field order). The erased 'static is never
    // observed beyond *owner's lifetime: dep is always paired with owner and
    // consumed/dropped together. transmute is layout-identity (same type modulo
    // lifetime ⇒ identical size/layout). See §1.3 obligations.
    let dep: B<'static> = unsafe { ::core::mem::transmute::<B<'_>, B<'static>>(owner.fluent()) };
    SkyFluent_B { dep, owner }
}

// CHAIN step — SAFE (no new unsafe): move owner (pointer) along, transform dep.
fn select_from_b(b: SkyFluent_B) -> SkyFluent_C {
    let SkyFluent_B { dep, owner } = b;             // Box move = pointer move; pointee stable
    SkyFluent_C { dep: dep.select(), owner }        // B<'static> -> C<'static>, real referent still *owner
}
fn limit_from_b(b: SkyFluent_B, n: u32) -> SkyFluent_B {
    let SkyFluent_B { dep, owner } = b;
    SkyFluent_B { dep: dep.limit(n), owner }
}

// TERMINAL — SAFE: run while owner alive, return owned, drop bundle.
async fn query_from_b(b: SkyFluent_B) -> FirestoreResult<Vec<X>> {
    let SkyFluent_B { dep, owner } = b;
    let out = dep.query().await;   // borrows *owner, alive here
    drop(owner);                   // explicit for clarity; out is owned
    out
}
```

Sky sees `SkyFluent_B`/`SkyFluent_C` as opaque `'static` handles threaded through
the chain — exactly like any other opaque FFI value.

### 1.3 Soundness argument (guardian, please adjudicate)

The mechanism is the documented self-referential-struct pattern (`ouroboros` /
`self_cell` / `yoke` make the identical argument). Soundness rests on FOUR
invariants, all enforceable from rustdoc:

1. **Stable owner address.** `owner: Box<R>` — the pointee never moves while
   borrowed; moving the bundle moves only the Box pointer. ✓ by construction.
2. **Drop order.** `dep` before `owner` in field order ⇒ dep's Drop cannot observe
   a freed owner. ✓ by construction (and no explicit Drop is emitted to perturb it).
3. **No borrow escape (THE per-API gate).** The erased `'static` must never reach
   Sky. Every bound method on a builder must return EITHER (a) another builder we
   re-bundle, OR (b) a **fully-owned** value (no lifetime tied to `'a`). A method
   returning `&'a T` / `X<'a>` that is *not* a recognized chain successor would leak
   the borrow → **DROP it** (fail closed). Terminal returns must be owned
   (firestore terminals return `Vec<T>`/`Option<T>`/`()` — ✓; the `stream_query`
   variants return `BoxStream<'a, _>` borrowing `'a` → **DROP**, they leak).
4. **Send.** Bundle is Send iff `R: Send` and `B<'static>: Send`. `&R: Send`
   needs `R: Sync`. FirestoreDb is Send+Sync (synthetic, WALL 5). The existing Send
   oracle must confirm BOTH the owner and the builder are Send before admitting an
   async terminal (spawned on tokio).

**Variance note.** The transmute *lengthens* `'a → 'static` (unsound as a safe
coercion regardless of variance), but safety here does NOT rest on variance — it
rests on invariants 1–3 guaranteeing the runtime referent outlives every use, and
invariant 3 guaranteeing no `'static`-tagged borrow is ever observed past `*owner`.
This is the same basis `self_cell` uses. Guardian: please confirm this reasoning
and whether invariant 3's static check (drop any non-chain method whose return
carries the builder's lifetime) is sufficient to prevent all escape.

### 1.3a MIRI-FOUND invariants 5 & 6 (the proof's real payload, 2026-06-27)

The hand-written proof (`runtime-rust/tests/selfref-builder-proof/`, MIRI-green
under BOTH Stacked AND Tree Borrows) forced out two preconditions invariants 1-4
MISSED — both make the "obvious" generated form UB:

5. **ALIASABLE OWNER.** A plain `Box<R>` is wrong: under Stacked Borrows, *moving*
   the `Box` (e.g. destructuring the bundle in a chain step) asserts UNIQUE access
   to the pointee → invalidates `dep`'s outstanding shared borrow → UB. The owner
   must be a raw-pointer-backed *aliasable* box (no `noalias`), like
   `self_cell`/`ouroboros`'s `AliasableBox`, so its move performs no unique retag.
6. **OWNER FREED OUT-OF-FRAME.** The terminal must NOT free the owner inside a
   by-value function: a by-value argument keeps `dep`'s borrow STRONGLY PROTECTED
   until the function returns, and freeing protected memory in-frame is UB (both
   models). A *read* of the pointee (`dep.run()`) is fine; the free is not. The
   terminal HANDS the owner back (or, for the async terminal, the owner lives with
   the spawned future and drops when it completes — naturally out-of-frame). Even
   `std::mem::drop(bundle)` is UB for the same reason — bundles must drop via
   scope-end glue, never the `drop()` function. (A re-thunk/discard codegen of a
   bundle would have to obey this too.)

These two — on top of unverifiable covariance (invariant 4) — are the concrete,
machine-checked reason auto-emission is REJECT-FOR-NOW: a codegen emitting the
obvious self-referential form ships UB three different ways.

### 1.4 Why not safe alternatives

- **`Box::leak` to `&'static`** — leaks the receiver on every entry call →
  unbounded growth → DoS. **REJECTED** (principle 1).
- **`yoke::Yokeable`** — requires `unsafe impl Yokeable` for each foreign builder
  (orphan rule needs a newtype) AND covariance we cannot prove from rustdoc.
  Strictly more unsafe-assertion than the localized transmute. **REJECTED.**
- **Bind only the owned API (Finding A)** — this IS done as Deliverable 1; it gives
  full capability with ZERO unsafe. Deliverable 2 adds the fluent *ergonomics* and
  the *general* mechanism for crates that lack an owned path.

---

## 2. Scope decomposition (what lands this session vs. files)

The full firestore fluent API stacks THREE hard dimensions on the bundle:
generic `D` (db type — monomorphize to FirestoreDb), generic `T`
(serde target on `.obj::<T>()`), and **closure params** (`.filter(FN)` /
`.aggregate(FN)` take a closure of a *borrowed* builder — the #28 closure-arc ∘
borrowed-arg, the hardest case). Sound single-session delivery:

- **S1 — Deliverable 1 (owned path):** confirm/close; fixture. *No unsafe.*
- **S2 — Deliverable 2 core:** inspector recognition + codegen of the bundle for
  the SOUND CORE shape (non-generic Clone-receiver entry → non-generic chain →
  owned terminal), invariant-3 escape gate, Send gate; minimal-stub fixture that
  **binds automatically**. Guardian-reviewed unsafe.
- **S3 — filed:** generic-`T` obj-terminals, generic-`D`, closure-filter steps,
  `BoxStream` terminals (sound-drop). Documented: firestore queries fully usable
  via the owned path (Deliverable 1) meanwhile.

If S2's auto-emission cannot be delivered SOUNDLY in-session, fall back to: land the
recognition + the documented codegen template + a guardian-blessed proof, and file
emission — never ship rushed `unsafe`.

---

## 3. Live audit (real firestore 0.49.0, `--audit firestore`, 2026-06-27)

`bound 1139` · `tail_dropped 162`. Relevant drops:

- `reason=lifetime total=72 valuable=4` — **the fluent builders**:
  `FirestoreSelectDocBuilder<'a,D>×9`, `FirestoreTransaction<'a>×8`,
  `FirestoreListingDocBuilder<'a,FirestoreDb>×6`, `FirestoreListCollectionIdsBuilder×4`,
  `FirestoreAggregatedQueryDocBuilder×4`, … All borrow `&'a db`. SOUND drop today.
- `reason=result_borrow total=5 valuable=0` — `&GoogleApi`, `&Span`, `&Vec<…>` (sound).
- `reason=not_in_closed_set total=52` — `Option<DateTime<Utc>>`, `Option<FirestoreQueryCursor>`,
  `Option<Duration>`, `BTreeMap<String,Value>` returns (owned but outside the coercion set).
- `reason=setter_narrowing total=23` — usize/u32 fail-closed numerics (#82 class).

**Owned path — CONFIRMED BOUND (Deliverable 1 already satisfied):**

| bound fn | recv | effect | → |
|---|---|---|---|
| `FirestoreQueryParams::new` | FirestoreQueryParams | pure | FirestoreQueryParams |
| `with_limit/offset/filter/order_by/collection_id/parent/…` (13 `with_*`) | FirestoreQueryParams | pure | FirestoreQueryParams |
| `query_obj` | FirestoreDb | effectful | FirestoreResult |
| `aggregated_query_obj` | FirestoreDb | effectful | FirestoreResult |
| `list_doc` | (FirestoreDb) | effectful | FirestoreResult |
| `get_obj` / `create_obj` / `update_obj` / `delete_by_id` | FirestoreDb | effectful | FirestoreResult |

⇒ `db.query_obj(FirestoreQueryParams.new(c) |> with_limit 10 |> with_filter f)` is a
complete, idiomatic Sky pipeline. The 72 fluent drops cost no capability.
(`query_doc` (raw `Vec<Document>`) drops on the transitive `gcloud_sdk` Document type —
the typed `query_obj` is the useful path and binds; raw-Document is a minor residual → #73.)

---

## 4. Proof fixtures

- **Owned path:** minimal stub mirroring `Params::new(c).with_limit(n)` +
  `db.query_obj(params) -> async Vec<T>` (async-trait + owned param + serde-T).
- **Self-ref bundle:** minimal stub crate `selfref-builder-crate` with the §1.1
  shape (Clone receiver, `entry(&self) -> B<'_>`, chain `B<'_> -> C<'_>`, owned
  terminal). Assert the chain binds + runs end-to-end (`[ALL OK]`).
  - **Negative controls (mandatory):** (a) a builder method returning `&'a str`
    (non-chain borrow) MUST drop (invariant 3); (b) a terminal returning
    `BoxStream<'a,_>` MUST drop; (c) a non-Clone receiver MUST drop (can't own the
    cart); (d) an `!Send` receiver under an async terminal MUST drop.

---

## 5. OUTCOME (shipped 2026-06-27) — guardian-gated

**Guardian design-gate ruling (verbatim disposition):**
- Owned-path Deliverable 1 — **APPROVED**.
- Self-ref unsafe bundle AUTO-EMISSION — **REJECT-FOR-NOW** (soundness-blocking:
  foreign-type covariance unverifiable at codegen without breaking the
  `sky build ⇒ cargo build` floor; zero capability gain over the owned path).
- Bundle proof-stub + recognition — **APPROVE-WITH-CONSTRAINTS** (MIRI, negatives,
  no codegen behavior change).

**Shipped:**
1. **D1 (owned path locked).** Fixture `runtime-rust/tests/sky/104-ffi-owned-query-builder/`
   — owned `QueryParams::new |> with_*` builder chain feeding an `#[async_trait]`
   `run_query(QueryParams) -> Task Error (List String)`, builds + runs `[ALL OK]`;
   the borrowing `fluent() -> Builder<'_>` entry DROPS (reason=lifetime, asserted
   absent). Wired into `ffi-fixtures-test.sh` (`run_owned_query_builder`). Proves
   firestore's full query/CRUD capability is reachable from Sky shim-free via the
   OWNED API — the sound circumvention of the borrow limitation.
2. **D2 (mechanism proof).** `runtime-rust/tests/selfref-builder-proof/` — a
   standalone, MIRI-verified (Stacked + Tree Borrows, 3/3) existence proof that the
   self-referential bundle CAN be sound for a covariant builder, plus the 6
   invariants (incl. the MIRI-found aliasable-owner + out-of-frame-free). NOT wired
   into codegen.

**Filed (not rushed):** auto-emission stays blocked on the gating research item —
**covariance verification for a foreign builder type without a cargo-fail** — plus
the generic-`D`, generic-`T` serde terminal, closure-filter steps, and `BoxStream`
terminals. Revisit only if a real, in-demand crate with NO owned path appears.

**Net for #68:** RESOLVED. firestore is fully usable from Sky via the owned path
(audit-confirmed: 1139 bound incl. `query_obj` + `FirestoreQueryParams` builders +
CRUD); the fluent layer is sound-dropped sugar; the borrow-binding circumvention is
designed, MIRI-proven sound, and gated behind covariance verification.
