# Wall #3 — inspector emits parametric generic stubs (design, Scheme A)

Status: DESIGNED (brainstorm-approved 2026-06-22). Final wall of the demand-driven generic
Sky→Rust FFI epic (#20/#24). Gated on Walls #1 (parametric foreign `TType`, 235d9032) +
#2 (generic-wrapper codegen + bindability gate, bcc6cda2). INCLUDES a rework of Wall #2's
synthesis from the `{hole}` string template to the **Scheme A typed call-AST** (so the
inspector↔codegen contract is parse-don't-validate end-to-end).

## Purpose
Make REAL generic crates (IndexMap, etc.) bind with zero hand stubs: the inspector, for a
bindable generic type/fn, emits the parametric Sky sig + a typed call-AST + the FULL-UNION
bound metadata — instead of dropping it or pinning one arbitrary instantiation. Every
unbindable item is reported, never silently dropped.

## Rendering — Scheme A (typed call-AST; parse-don't-validate)
The inspector emits the call as a STRUCTURE, not a string template. Generic params are
first-class (indexed refs), so illegal param placement is UNREPRESENTABLE; Wall #2 renders
Rust by walking the structure (no string substitution, no `{hole}` gate).
```json
"generic": {
  "params": ["a", "b"],
  "bounds": { "a": ["Clone"] },
  "call": {
    "kind": "method",
    "path": ["mycrate", "Pair"],
    "typeArgs": [ {"param":0}, {"param":1} ],
    "method": "left",
    "receiver": { "arg": 0, "by": "ref" },
    "args": [],
    "ret": { "param": 0 }
  }
}
```
The leaves are names (`"mycrate"`, `"Clone"`) placed in structurally-fixed slots — data, not
control. A small closed `Call` ADT (Rust serde + Haskell `FromJSON`) + a `renderCall` walker
in Wall #2. **Drift test** keeps the two serde definitions in lock-step (the only real cost
of the AST vs a string — bounded, one-time). This REPLACES Wall #2's `{hole}` template +
coverage gate (the weakest, stringly mechanism) — a net deletion of code.

## Q1 — bindable subset (emit; drop the rest "for now")
EMIT a parametric stub for: generic FREE functions; generic STRUCT methods (`impl<K,V>
IndexMap<K,V> { … }`); generic STRUCTS as parametric Sky types. ELIGIBILITY: every generic
param is a simple TYPE param, and every arg/return is closed-set-or-one-of-those-params.
DROP (+ report) for now: generic enums, const generics, closure/`Borrow`-style fn-introduced
params, lifetime/borrowed-generic returns, trait-object/`impl Trait` params. (These ride
later epics.)

## Q2 — FULL-UNION bound computation (the soundness crux)
The wrapper body `::crate::Type::<K,V>::method` needs the union of bounds from sources that
live on DIFFERENT rustdoc items: the enclosing **impl block's** generics + `where_predicates`
(where `K: Hash+Eq` lives), the **struct definition's** generics + `where_predicates`, and
the **method's** own generics + `where_predicates`. For each USED type-param, emit the union
of its trait NAMES (not the retired Alt-1 concrete resolution). The inspector already walks
impl blocks (methods are inside them) so the impl-level generics are in scope — thread them
down. **COMPLETENESS-OR-DROP:** if a bound on a used param is a shape that won't reduce to a
plain trait name (associated-type bound `K::Item: …`, higher-ranked `for<'a>`, an unparseable
`where`), DROP the method (+ report); NEVER emit a partial-bounds stub. The asymmetry is
deliberate — under-emitting a bound = cargo-fail (forbidden); dropping a method = recoverable
coverage loss.

## Q3 — inspector is the SINGLE drop-decision point + coverage report
Branch at the inspector's generic-handling site (retiring Alt-1's concrete monomorphisation
for generic-bearing symbols):
- non-generic → existing path, unchanged.
- generic + bindable + every full-union bound is a MODELLABLE trait (`Hash/Eq/Ord/Clone/
  Default` — a set SHARED with Wall #2 as one source of truth) → emit the parametric stub.
- generic + bindable but a bound is a real trait yet UNMODELLABLE (`FromStr`, `Serialize`, a
  crate trait) → drop + report `unmodellable-bound (X)`.
- generic + NOT bindable → drop + report the specific reason.
Keep the bound-parsing helpers (`bound_to_concrete` → repurposed to extract trait NAMES, the
`where_predicates` gathering); drop only Alt-1's "resolve to one concrete" step. Because the
inspector knows the modellable set, it is the single drop point → the coverage report is
COMPLETE at `sky add`; Wall #2's unmodellable-skip becomes defense-in-depth.
**Coverage report (no silent drops):** ALWAYS a one-line terminal summary at `sky add` /
first generic-crate build — `FFI indexmap: bound 55/93 · 38 unbindable (closure ×15,
Q:Borrow ×17, unmodellable-bound ×4, const-generic ×2) — report: .skycache/ffi/rust/
indexmap.coverage.md`; the full per-symbol report (each dropped symbol + reason + signature)
written to `.skycache/ffi/rust/<crate>.coverage.md` (follow the bindings layout — inside a
per-crate folder if one exists). Reuses the existing `--audit` drop machinery, surfaced by
default. Covers EVERY drop reason.

## Q4 — parametric Sky sig + the typed call
Reuse the inspector's existing method-rendering (receiver threading, `Result`/`Maybe`/`Option`
wrapping, arg ordering) — and render a generic param as a lowercased Sky type-var in the sig
(`K → k`) and as an indexed `{param: i}` ref in the call-AST. Receiver `IndexMap<K,V>` →
Sky `IndexMap k v` (Wall #1 parametric type) + `receiver:{arg:n,by:…}` in the AST. Parametric
foreign types in arg/return render recursively (Sky `Maybe v`; AST `{ctor:"Option",args:
[{param:1}]}`). Param naming round-trips: lowercase Sky tyvar ↔ Wall #2's `mangleTVar k → K`
for the Rust `<K: …>` clause.

## Wall #2 rework (folded into this slice)
Replace `synthesiseGenericWrapper`'s `{hole}` string substitution + the hole-coverage gate
with `renderCall` over the typed `Call` ADT. Net deletion of the stringly path; the bindability
check + the static trait table + E4400 stay. Re-verify the hand-stub fixture (48-ffi-generics)
under the AST contract.

## Soundness
- parse-don't-validate: the `Call` ADT makes illegal param placement unrepresentable; no
  string substitution to leave unfilled or misplace.
- the floor: bound-completeness-or-drop (under-emit forbidden); Wall #2's modellable check is
  the second layer.
- transparency: every drop is reported (no silent caps).
- Go-byte-identical: every path gates on `_ffn_generic = Just`; Go never emits a `generic`
  block (drops generics at the producer).

## Testing
- REAL-crate proof: bind `IndexMap<String,i64>` end-to-end with NO hand stub; read the
  coverage report; re-probe bind% (was 5/138).
- DRIFT TEST: a round-trip/parity test asserting the Rust `Call` serde and the Haskell
  `FromJSON Call` agree on the schema (a fixed corpus of `Call` JSON decodes in Haskell to
  the expected ADT, and the inspector emits exactly that shape) — fails if either side drifts.
- Extend 48-ffi-generics under the AST contract; light local verify (cabal build + targeted
  specs + 1 fixture); full suite + real-crate on CI.
- Guardian design review (this plan) + guardian-final (the diff), per the settled rule.

## Boundary
Shared (the `Call` ADT `FromJSON`, the Wall #2 `renderCall`, the bound-union gather feeding
the check) + Rust (the inspector: stub emission, bound-union, coverage report, the `Call`
serde) + tools. NOT the Go inspector / `src/Sky/Generate/Go` / `runtime-go` / `sky-stdlib` /
author `examples/`.

## GUARDIAN-LOCKED constraints (design review 2026-06-22 — APPROVE-WITH-CONSTRAINTS)
BLOCKING (must be in the implementation before code):
- **C1 (floor)** — thread the OWNING impl-block + struct-def generics + `where_predicates`
  into the bound-union alongside the method's, for every USED type-param. (`main.rs:728`
  currently drops `impl_data["generics"]` — where `K: Hash+Eq` lives.) Union BEFORE
  trait-name extraction.
- **C2 (floor, the silent under-emit)** — the where-pred gather keys on `bp.type.generic`
  (`{"generic":NAME}`). An associated-type projection `<K as Foo>::Item: Bar` arrives as a
  `qualified_path`, not `{generic}`, and is silently skipped → under-emit → cargo-fail.
  RULE: ANY `bound_predicate` on a USED param whose `type` is not a plain `{generic:NAME}`
  ⇒ DROP+report. Never skip-and-continue.
- **C3 (floor, super-traits)** — a trait is "modellable for stub" only if IT AND its full
  super-trait closure are in the modellable-5 (or the super is a no-constraint marker). A
  modellable `Foo: Bar` with an unmodellable `Bar` is a hole ⇒ drop+report.
- **C4 (floor, defaulted params)** — `IndexMap<K,V,S=RandomState>` hides `S: BuildHasher`.
  If a struct/impl has defaulted type params carrying bounds the stub doesn't bind, DROP+
  report unless the default is provably erased.
- **C5 (floor, impls)** — gather bounds ONLY from the impl block that OWNS the walked method
  (`main.rs:687`); cross-impl/blanket availability is out of scope ⇒ drop.
- **4a (drift, the modellable-5 set)** — `{Hash,Eq,Ord,Clone,Default}` lives in Haskell
  (`FfiInstance.hs:276`); the inspector has NO such constant (its `MARKER_TRAITS` is a
  13-elem SUPERSET for a different purpose — do NOT reuse). SINGLE SOURCE OF TRUTH (emit
  the 5-set from one place both consume) OR a guard test parsing both literals + asserting
  set-equality. The drift test MUST cover this constant, not only the Call schema.
- **4b (drift, the Call schema)** — round-trip corpus PLUS negative cases: unknown
  `kind`/`by`, out-of-range `param`, missing required field ⇒ Haskell `FromJSON` REJECTS
  (no silent default); Rust serde refuses to emit. Drift = either side accepting what the
  other rejects.
REQUIRED at write-time:
- **#2 (Scheme A validity at PARSE)** — validate in `FromJSON Call`, not at render: every
  `{param:i}` index < |params|; `receiver` present iff the method has a self input; all
  `ret`/arg param-refs ⊆ declared params. `renderCall` is then total over the validated
  ADT. The retired `{hole}` contiguity gate is replaced by this structural validity — prove
  no gap leaks via a fixture.
- **#6 (coverage path)** — validate the crate name (`[A-Za-z0-9_-]`; reject `/`, `..`, NUL)
  before interpolating into the `.coverage.md` path. "Always show summary" fires on an EMPTY
  drop set too (`bound N/N · 0 unbindable`) — no silent-skip branch.
LOW:
- **#3 (Alt-1 regression transparency)** — the coverage report tags `was-Alt-1-bound, now
  parametric` and `was-Alt-1-bound, now dropped (reason)` so the bind% delta is auditable.

The net gather contract that keeps the floor: **union(method, owning-impl, struct,
defaulted-params) of bounds on USED params, where every contributing predicate reduces to a
plain trait name on a `{generic}` AND every such trait + its super-closure is in the
modellable-5; ANY shape that doesn't fully reduce ⇒ DROP+report.** Under-emit forbidden;
over-drop acceptable.

## Dependencies
- Blocked on: Walls #1 (235d9032) + #2 (bcc6cda2).
- Completes the generics keystone (#20). Then: the feasibility sketch of the rest of the arc
  (closures, iterators, trait-objects) before those epics.
