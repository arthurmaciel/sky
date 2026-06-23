# Universal-FFI arc — feasibility sketch + empirical demand ordering

Status: ANALYSIS (2026-06-22). Read-only sketch of the rest of the safe-API auto-FFI
arc after the generics keystone (Walls #1–#3, #20). Answers, per remaining feature:
*is there a sound shape? what's the hardest unknown? does it ride the demand-driven
framework? showstopper?* — then orders the work from **empirical demand** measured on
five real crates. Under the settled guardian-supervision rule.

## Empirical demand (the ordering input)

Method: generated rustdoc JSON for `itertools`, `regex`, `chrono`, `indexmap`,
`petgraph`; classified every public fn/method by the arc feature it would require to
auto-bind. Closures/iterators hidden as generic bounds (`F: FnMut(..)`,
`I: IntoIterator`) are counted in their feature, not as "plain generic" (the v1 lens
missed this and reported itertools as having ~1 closure — corrected).

| Feature (share of public fns) | itertools | indexmap | petgraph | regex | chrono |
|---|--:|--:|--:|--:|--:|
| **closures / HOF** | **24%** | 9% | 3% | 0% | 0% |
| iterator param (`IntoIterator`) | 9% | 1% | 2% | 1% | 1% |
| iterator return (`impl Iterator`) | 0% | 0% | 1% | 0% | 0% |
| **any arc feature** (closure/iter/trait-obj) | **31%** | 11% | 4% | 1% | 2% |
| **borrowed-ref return** (#22) | 3% | **25%** | 8% | **21%** | 2% |
| assoc-type projection (`I::Item`) | 35% | 20% | 27% | 2% | 5% |
| plain generic type-param fn | 3% | 10% | 5% | 2% | 5% |
| **trait-object (`dyn`)** | 0 | 0 | **1** | 0 | 0 |
| const generic | 1% | 0% | 1% | 1% | 0% |

### Reading it
- **`dyn` trait-objects: demand ≈ 0** (1 method in ~3900). Not an epic.
- **closures dominate the functional-collection family** (itertools 24%) and are
  meaningful in collections (indexmap 9%); near-zero in leaf-data crates
  (regex/chrono). They are THE arc keystone.
- **iterators are real but coupled to closures** (you map/filter a closure over an
  iterator); modest standalone share.
- **borrowed-ref return (#22) is the biggest *independent* demand** — gates plain
  methods on regex (21%) and indexmap (25%) regardless of the arc.
- **assoc-type projection looks huge but is mostly a *consequence*** of
  iterator/generic signatures (`I::Item`, `Self::Item`), not a feature the user calls
  directly. Much of it dissolves once closures + iterators pin the element type. It is
  a residue to re-measure, not a standalone epic.

## Feasibility — per feature

### 1. Closures / HOFs — VIABLE (rides the framework + an already-proven seam)
**Sound shape.** Emit the generic wrapper exactly per the Wall #2 (A)-model, generic
over the closure: `pub fn rust_x<F: Fn(A) -> B>(f: F, ..)`. The Sky lambda argument
lowers to a Rust `move |a| ..` closure — **the identical lowering the stdlib HOFs
already use**: `list.rs` kernels take `impl Fn(A)->B + Clone` and codegen already
feeds Sky lambdas to them. So the runtime/codegen seam exists and is proven; the only
gate is that `FfiInstance.hs:267` currently classifies a Sky `TLambda` arg as
`Left "function type"` (dropped). Lifting that one classification + rendering the
arrow type into the wrapper's `Fn(..)` bound is the work.
**Hardest unknown (guardian-corrected — the `Fn`-by-construction claim was overstated).**
A Sky lambda's Rust trait kind is decided by **what its body does to captures**, not by
Sky purity. It is `Fn` *only because* of the emitter's clone-on-capture discipline
(`ExprEmitter.hs:582`); a lambda that captures a **non-`Clone`** value (`SkyTask`,
`Decoder`, a future) is *moved-in* → it is **`FnOnce`**, sound for a single call only
(`ExprEmitter.hs:2047`). So the closures epic carries six BLOCKING soundness
constraints (guardian-locked):
1. **`Fn`/`FnMut` wrapper sound only when every capture is `Clone`.** A non-`Clone`
   capture in a multi-call slot ⇒ DROP+REPORT (E4400), never emit — else `E0525`/
   `E0382` cargo-fail (the type-checks-but-cargo-fails floor breach).
2. **Render `+ Clone` on `F`** whenever the API/body calls or stores the closure >1×
   (exactly why `list_foldl`/`list_filter` carry `+ Clone`). `Clone` iff all captures
   are `Clone` — same gate as #1.
3. **`Fn ⊆ FnMut ⊆ FnOnce` subtyping** is claimable only *after* #1 proves genuine `Fn`
   — not universally.
4. **Panic/unwind across the foreign closure boundary (the most serious gap).** A Sky
   closure body can still panic (div-by-zero, Coerce); unguarded, it unwinds through
   foreign frames — breaches the no-runtime-panic thesis and is UB across any
   no-unwind frame. The wrapper MUST `catch_unwind`→`SkyError` around the Sky-closure
   invocation (the `Ffi.callTask` `runWithRecover` discipline).
5. **Higher-order return (`-> impl Fn`): defer is SAFE** (return-position `TLambda`
   hits the same `Left` drop — no leak). Keep the drop.
6. **Borrowed-ref escape has THREE shapes, not one:** drop+report a closure that
   captures an escaping `&T`, OR takes a reference param `Fn(&T)`, OR returns a
   reference `-> &U` — the Sky closure ABI is strictly by-value (`list.rs:120`).
**Framework fit.** Direct (A)-model reuse; rustc monomorphises `F`; bindability gate +
E4400 + coverage report all apply unchanged.
**Showstopper.** None — but #1, #2 and #4 are floor-level and MUST be in the spec.

### 2. Iterators — VIABLE (eager floor), builds on closures
**Sound shape (guardian-corrected — only the param direction is sound in v1):**
- `IntoIterator` **param** → SOUND. A Sky `List` is a `Vec`, which already *is*
  `IntoIterator`; the wrapper is generic `<I: IntoIterator<Item = A>>` and the call
  passes the Vec. The inspector already resolves `IntoIterator<Item=X>` to a concrete
  `X` (`sky-ffi-inspect-rs/src/main.rs:3463,4729`). Rides the (A)-model. **This is the
  v1 iterators epic.**
- `impl Iterator` **return** → **DROP+REPORT in v1.** Eager `.collect()` is NOT sound:
  rustdoc exposes only `impl Iterator<Item=X>` with **no finiteness metadata**, and the
  source (`0..10` vs `iter::repeat`/`cycle`) lives in the opaque body the inspector
  never sees — so "collect only finite iterators" is **undecidable** from metadata and
  `.collect()` on an unbounded return would hang. Collecting returns is later work
  needing an explicit per-fn allowlist or a bounded `.take(N)` cap, not inference.
**Hardest unknown.** Laziness / collecting returns safely (deferred per above).
**Framework fit.** Same wrapper synthesis; the assoc-type `Item` projection resolves
once the element type is pinned by the call site — which dissolves much of the
"assoc-type projection" demand bucket.
**Showstopper.** None for the `IntoIterator`-param floor. (Returns + laziness deferred.)

### 3. Trait-objects (`dyn Trait`) — SHAPE EXISTS, but no epic (demand ≈ 0)
**Sound shape (narrow).** The only satisfiable `dyn Trait` from Sky is `dyn Fn..` — a
boxed closure — which **is** the closures epic (`Arc<dyn Fn>` is already the Sky
fn-value representation). For an arbitrary `dyn UserTrait`, Sky has no trait-impl
mechanism to synthesise a vtable, so there is nothing sound to hand across.
**Hardest unknown / showstopper.** General `dyn Trait` needs Sky→Rust vtable synthesis
from a Sky record-of-functions — real work, and there is **no measured demand** to
justify it. Verdict: **fold `dyn Fn` into the closures epic; drop every other `dyn`
with a coverage report.** No standalone trait-objects epic.

## Recommended order (feasibility × demand)

1. **Finish #22 — borrowed-ref / owned-copy return** (already in flight). Biggest
   *independent* plain-method demand (regex 21%, indexmap 25%); no arc dependency;
   nearly done. Unblocks the "boring but essential" surface first.
2. **Closures / HOFs** — the top NEW epic. Functional-collection keystone (itertools
   24%); rides the (A)-model and the proven Sky-lambda→Rust-closure seam; lift the
   `TLambda` drop, render the arrow into an `Fn(..)` bound. **← brainstorm this next.**
3. **Iterators (`IntoIterator` param only, v1)** — builds directly on #2: pass the Sky
   `List` `Vec` into a `<I: IntoIterator<Item=A>>` wrapper. `impl Iterator` **returns**
   are dropped+reported in v1 (finiteness undecidable from rustdoc). Dissolves much
   assoc-type residue.
4. **Re-measure the assoc-type-projection residue** after 2+3 — expected to shrink
   sharply; scope only what remains.
5. **Trait-objects** — no epic; `dyn Fn` absorbed by #2, the rest dropped+reported.

const generics and non-`dyn-Fn` trait objects stay in the reported-drop tail.

## Net verdict
The arc is **viable with no showstopper** for the features that have demand. Closures
are the keystone and ride an already-proven seam; iterators ride closures; `dyn`
trait-objects have ~0 demand and need no epic. Borrowed-ref return (#22) is the largest
independent demand and is already in flight. Proceed: finish #22, then build closures.
```
Measurement harness: /tmp/ffi-demand/{run.sh,classify.py}; rustdoc JSON cached under
the shared target dir. Re-runnable; read-only wrt the Sky repo.
```
