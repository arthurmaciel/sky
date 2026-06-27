# Full-auto FFI: opaque-handle threading + concrete-impl monomorphization (master) — #52

**Goal.** Make a realistic async-generic op with an OPAQUE CLIENT handle bind shim-free — the
firestore/stripe shape. Composes on #44(async)/#45(generic-Self)/#46(UFCS)/#47(serde)/#51(features).
Guardian-cleared design (APPROVE-WITH-CONSTRAINTS, 2026-06-25) + real-crate probe folded in.

**Primary proof = a hand-stub fixture** that mirrors the real stack and binds + cargo-builds +
runs end-to-end. Real-crate (firestore, same-crate, one impl) is the stretch; stripe's extra gaps
(cross-crate impl index, version-pin, builder-params) are documented residual.

## The fixture (the target) — `runtime-rust/tests/sky/74-ffi-opaque-client/`
Dep-free crate (`tokio`+`futures` deps for the async):
```rust
pub struct Db { _conn: String }                 // OPAQUE handle, NOT Clone (holds a resource)
impl Db { pub fn new(url: &str) -> Db { Db { _conn: url.into() } } }
pub trait Wire: Send + Sync {}                   // SINGLE-impl bound trait (the POSITIVE op)
impl Wire for Db {}                               // the ONE concrete impl (same-crate)
pub trait Transport: Send + Sync {}              // 2-impl bound trait (the ambiguous NEGATIVE)
impl Transport for Db {}
pub struct Req { field: String }
impl Req {
    pub fn new() -> Req { Req { field: String::new() } }
    pub fn with_field(mut self, v: &str) -> Req { self.field = v.into(); self }   // builder
    pub async fn send<C: Wire>(&self, client: &C) -> Result<String, String> {  // the op (single-impl C → Db)
        Ok(format!("sent {} via db", self.field))
    }
    // NEGATIVE (ambiguous): C: Transport has 2 impls (Db, Db2) → drops AMBIGUOUS
    pub async fn send_ambiguous<C: Transport>(&self, client: &C) -> Result<String, String> { /* … */ }
}
// NEGATIVE rows (must DROP, not cargo-fail):
pub struct Db2; impl Transport for Db2 {}        // → 2 concrete impls → send_ambiguous drops AMBIGUOUS
pub struct NotSend { _p: std::rc::Rc<u8> }       // !Send (separate trait, single impl) → async drops
```
Main.sky (importing `Rust.Opaqueffi74 as O`; auto-FFI `<verb>_from_<type>` binding scheme):
`db = O.new_from_db "u"; req0 = O.new_from_req (); req = O.with_field_from_req req0 "hi";
O.send_from_req req db |> Task.run` → asserts `"sent hi via db"` + prints `[ALL OK]`. (For the
2-impl ambiguous + !Send rows: assert the ops are ABSENT from bindings.)

## Impl — 3 coupled steps (TDD, each guardian-final on the diff)

### Step 1 — opaque-dependency-handle by-value (the prerequisite)
Admit a NON-modellable, possibly-NON-Clone, public-path-nameable struct as a move-by-VALUE owned
arg AND owned return handle, carried as its concrete qualified Rust type (NO `dyn Any` — the
monomorphised wrapper names the type). Constraints:
- **MOVE-ownership only, NEVER `.to_owned()`/clone-of-borrow** (a non-Clone dep struct → `.to_owned()`
  is E0599, the #22 class). The Sky value owns the handle; the wrapper takes it by value or borrows
  the Sky-owned value in place (`&arg`).
- Today `is_clone_opaque_name` is crate-LOCAL + Clone-only (main.rs:~4807). Add an opaque-VALUE admit
  for a nameable struct (crate-local OR dependency, via the public-path map) used as a by-value param
  / owned return / `&T` param (borrow the owned Sky value) — gated on `type_is_nameable` + reachable
  public path. NO field extractors required (opaque — Sky never inspects it).
- The Sky surface type = an opaque newtype/handle (the existing struct-binding path, minus getters).
- Fixture sub-proof: `Db::new(&str)->Db` binds (returns opaque), `Db` threads as `&C` after mono.

### Step 2 — concrete-impl monomorphization (#52 core)
For a generic param `C: SomeTrait` (SomeTrait NOT in modellable/serde/Fn/Iterator sets):
- Scan for concrete `impl SomeTrait for T`. **EXACTLY ONE** nameable+reachable+NON-generic `T` →
  monomorphize `C = T`. **0 / >1 / generic-T / blanket `impl<X> _ for X`** → DROP
  `trait-bounded-param-ambiguous` (never guess).
- **Same-crate first** (firestore + the fixture). Cross-crate (stripe's facade impl): the cross-crate
  concrete-impl index SHIPPED in WALL-G (#84, fixture 91) — a global canonical-path-keyed impl index
  across all project crates resolves the bound; if the concrete impl isn't reachable in any project
  crate's rustdoc → drop (sound miss).
- **Ordering (constraint 3):** run resolve+substitution `C→T` BEFORE the serde occurrence census —
  `&C` is `Inadmissible` to the census as a `{generic}` node; after subst it's a concrete `&T` and
  escapes the generic walk. Wrong order → every `&C` op drops.
- Render: `Req::send::<::crate::Db>(&self, client)` (turbofish the concrete on the method).
- **DEFECT-3 sub-proof (sync mono'd-opaque param reborrow).** After `C→Db` subst the raw Rust param
  is `&Db` (borrowed) but the Sky surface is the OWNED `Db`. Pre-fix codegen keeps `&Db` in the
  wrapper sig → Sky passes owned `Db` → E0308. Fix: emit an OWNED param + reborrow (`&arg`) at the
  call. Fixture: `Req::tag<C: Wire>(&self, &C) -> String` (sync, `Result Error String`).

### Step 3 — Send-proof for the threaded opaque (fix the over-drop)
The async arg-Send gate (`param_send_ok`/`is_async_send_output`, ecc6f934) admits only
primitives+String → it would OVER-DROP a legitimately-Send opaque handle. Extend: an opaque concrete
type proven `Send` (a `impl Send for T` exists, OR — common — the type is `Send` by auto-derivation
which rustdoc doesn't state, so prove via: the trait bound `SomeTrait: Send` (the fixture's
`Transport: Send + Sync`) OR an explicit `impl Send`/`unsafe impl Send`, OR all fields Send — be
CONSERVATIVE: admit only when Send is provable, else keep dropping `async-future-not-send`). The
`!Send` negative row (`Rc`-bearing) must still DROP.
- **DEFECT-1 sub-proof (async SELF-RECEIVER Send proof).** The async wrapper captures the receiver
  BY-MOVE into `async move { arg0.m().await }`, so an async instance method on a `Clone + !Send`
  (Rc-backed) receiver yields a non-Send future → E0277 at `tokio::task::spawn`. The param-Send gate
  explicitly SKIPPED `self` (WRONG — it IS captured), so pre-fix such a method BOUND and cargo-failed.
  Extend the Send-proof to the receiver. Fixtures: `RcClient::ping(&self)` over a Clone + !Send `Rc`
  receiver must DROP; `SendClient::pong(&self)` over an all-fields-Send receiver must BIND (no
  over-drop).

## Constraints (guardian — blocking)
1. No `.to_owned()`/clone on a non-Clone opaque (move-by-value only). 2. Unique-impl trio:
nameable+reachable+non-generic; >1/blanket → drop. 3. Resolve+subst BEFORE census. 4. Send-proof
conservative (provable-Send only; !Send drops). 5. No panic/unwrap/index in the resolver
(`.get`/count, never `[0]`). 6. Negative fixtures blocking: 2-impl→drop, generic-T→drop,
!Send→drop, non-Clone-dep-handle→BINDS-by-value (no clone regression). 7. Real-crate CI: a `cargo
build` (not just `sky` type-check) must pass — type-checks-but-cargo-fails hides here.

## Firestore stretch (after the fixture is green)
Re-add firestore (same-crate, one `impl Firestore*Support for FirestoreDb` each). Confirm: the
`FirestoreDb` opaque handle binds (Step 1), the async `FirestoreDb::new` ctor binds (#44), the
Support-trait methods bind (#46 UFCS + #47 serde T + the opaque receiver). Measure the op-level
coverage delta. Document what still drops.

## Stripe residual (document, file follow-ons)
(a) ~~cross-crate concrete-impl index (`impl StripeClient for Client` in facade, `send<C>` in resource
crate)~~ — CLOSED: WALL-G (#84, fixture 91) ships the cross-crate unique-impl index; WALL-K (#92,
fixture 96) extends it to an EXTERNAL trait bound (the 3-crate triangle). (b) `sky add name@version`
prerelease pin (rc crates unreachable); (c) builder-params (fluent
`with_*` setters, not a serde struct — #45 generic-Self builder chain, not #47). File each.
