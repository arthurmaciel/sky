# Closures / HOFs auto-FFI — design (the arc keystone)

Status: BRAINSTORM-APPROVED; GUARDIAN-CLEARED for v1 with multi-call `Fn` (user-required).
Path: guardian-final APPROVE-WITH-CONSTRAINTS on the FnOnce-floor cut → user required
multi-call `Fn` → guardian REJECTED the denylist gate (`ecNoCloneVars` incomplete) →
spec inverted to a POSITIVE `Clone`-allowlist → guardian cleared to APPROVE-WITH-CONSTRAINTS
once C-Q1/Q2/Q4/Q5 committed (now folded in). Pending user review, then writing-plans. The
blocking guardian amendments (B1–B5) are folded in below. Top NEW epic of the universal safe-API auto-FFI arc, selected by empirical
demand (closures = 24% of itertools, 9% of indexmap public fns — see
`runtime-rust/docs/analysis/2026-06-22-universal-ffi-arc-feasibility.md`). Builds on the
generics keystone (Walls #1–#3, #20) and reuses its (A)-model wholesale. Task #28.

## Purpose
Let a Rust FFI function/method that takes a **closure argument** bind and run with a Sky
lambda passed across the boundary — zero hand stubs, sound by construction, any misuse a
first-class Sky compile error. The machinery is the Wall #2 (A)-model (one generic
wrapper per fn, rustc monomorphises); the new work is (1) lifting the `TLambda`-arg drop,
(2) rendering a Sky arrow type into the wrapper's `Fn(..)`-bounded type-param, (3) the
owned-clone bridge for by-ref closure params, and (4) the panic boundary.

## Proven seam (why this rides existing machinery)
- `src/Sky/Build/Rust/FfiInstance.hs:267` currently classifies a Sky `TLambda` FFI arg
  as `Left "function type"` (dropped). **This single line is the gate to lift.**
- `runtime-rust/src/sky_runtime/list.rs` HOF kernels already take `impl Fn(A)->B + Clone`
  and codegen already lowers a Sky lambda to a Rust `move |..| { body }` closure
  (`src/Sky/Generate/Rust/Builder/ExprEmitter.hs:661`, clone-prelude `:563`). So the
  Sky-lambda→Rust-closure lowering is proven; closures FFI reuses it for the call-site
  argument and only adds the wrapper signature + gates.

## Scope (v1) — decided in brainstorm
**BIND:** a foreign fn/method with one or more closure args of shape `Fn(A1..An) -> R`
where every `Ai` and `R` is already-bindable closed-set (primitive / `String` / `Vec<T>`
/ `Option<T>` / `Result<E,T>` / `bool` / derived-`Clone` opaque foreign), **any arity**,
**any closed-set return including `bool` / `Maybe` / `Result`** (covers map, filter,
filter_map, fold, position, partition, sort_by-shaped comparators). **All three trait
kinds bind in v1 — `FnOnce` (single-call), and multi-call `Fn`/`FnMut`** — the latter
gated by the load-bearing emitter capture-Clone gate (see B5; the user requires multi-call
`Fn` in v1). By-value closure args bind directly; **by-reference closure args (`Fn(&Ai)`)
bind via the owned-clone bridge** (below) when `Ai: Clone`.

**DROP + REPORT (coverage report; out of v1):** closures that capture/return/take an
escaping borrow not covered by the owned-clone bridge; `FnMut(&mut T)` mutation slots;
higher-order returns (`-> impl Fn`); closure args whose A/R fall outside the closed set;
trait-method hosts that wait on #21 (named explicitly in the report). Const generics,
non-`dyn-Fn` trait objects stay in the existing reported tail.

## The six guardian-locked soundness constraints (BLOCKING)
A Sky lambda's Rust trait kind depends on **what its body does to captures**, not Sky
purity. These are floor-level; the codegen MUST satisfy all six or DROP+REPORT:

1. **`Fn`/`FnMut` bound sound only when every captured var is `Clone`.** A non-`Clone`
   capture (e.g. a captured `SkyTask`/`Decoder`, the emitter's `ecNoCloneVars` set,
   `ExprEmitter.hs:2047`) used in a multi-call slot ⇒ DROP or call-site E4400 — never
   emit, else `E0525`/`E0382` cargo-fail (the type-checks-but-cargo-fails floor breach).
2. **Render `+ Clone` on the closure type-param `F`** whenever the adaptor/body may call
   or store it more than once (the reason `list_foldl`/`list_filter` carry `+ Clone`).
   The Sky move-closure is `Clone` iff all captures are `Clone` — same gate as #1.
3. **`Fn ⊆ FnMut ⊆ FnOnce`** is claimed only *after* #1 proves a genuine `Fn`; a
   single-call slot may accept an `FnOnce` Sky closure (non-`Clone` capture OK there).
4. **Panic boundary (the most serious gap).** A Sky closure body can still panic
   (div-by-zero, Coerce). The wrapper MUST ensure the panic NEVER produces UB across
   foreign frames and surfaces as a `SkyError`. See "Panic boundary" below — the #1
   guardian-final question.
5. **Higher-order return (`-> impl Fn`): stays dropped** (return-position `TLambda` hits
   the same `Left` — no leak path). Keep it.
6. **Borrowed-ref escape has THREE shapes:** an escaping `&T` capture, a reference param
   `Fn(&T)`, and a reference return `-> &U`. Param `Fn(&T)` is rescued by the owned-clone
   bridge (when `T: Clone`); the capture-escape and `-> &U` shapes DROP+REPORT.

## Owned-clone bridge (by-ref closure params)
For a foreign closure param `Fn(&A) -> R` with `A: Clone`, the generated wrapper closure
is `move |a_ref: &A| { let a = a_ref.clone(); sky_closure(a) }` — the Rust adaptor passes
`&A`, the bridge clones to an owned `A`, the Sky by-value closure consumes it. Same
owned-copy philosophy already blessed for #22 (borrowed returns). Sound for
inspection-only closures (predicates, comparators): the clone is read, the original is
untouched. **Gate:** DROP+REPORT when `A` is not `Clone`, or when `R` carries a reference
whose identity is tied to the original `&A` (identity-escape). Multi-`&` args
(`Fn(&A,&B)`, e.g. `sort_by`) clone each independently.

## Panic boundary — COMMITTED design (guardian-ruled: boundary-wrap, + B1/B2/B3)
**Wrap the whole adaptor call at the WRAPPER boundary in
`std::panic::catch_unwind(AssertUnwindSafe(|| ..))` → on `Err`, return the wrapper's
`SkyError` channel.** The inner Sky closure panics normally and unwinds through the
*unwind-safe ordinary-Rust* adaptor frames (map/sort_by/retain are plain Rust, not
`extern "C"`); the boundary catch converts to `SkyError`.
- `AssertUnwindSafe` is justified: on panic we discard the entire wrapper result (any
  partial adaptor mutation is on a value we drop), so no broken invariant is observed.
- **Assumption: the crate is built `panic = "unwind"`** (cargo default). Under
  `panic = "abort"` no catch is possible — the process aborts uniformly (no UB),
  documented as a known limitation.
- **Drop rule:** if the foreign fn is itself `extern "C"`/no-unwind (rare; a C-FFI shim),
  unwinding through it IS UB — DROP+REPORT when the inspector can detect the ABI; treat
  undetected as the documented edge.

**Alternative the guardian may prefer (inner-wrap):** `catch_unwind` around each inner
Sky-closure *invocation*, store the panic payload in a per-call `Cell`, feed the adaptor
a benign default, and poison the wrapper result afterward. Rejected as the default
because it needs a sound default value for the closure's return type — unavailable for
value-returning (`-> B`) mapping closures without a `Default` bound. Kept as fallback for
the `extern "C"` adaptor case where boundary-unwind is UB but a predicate/comparator
return has a benign default.

→ **RULED: boundary-wrap is the floor, gated by B1 (by-value precondition), B2 (refuse
`panic="abort"`), B3 (Rust-ABI-only host allowlist). Inner-wrap rejected.**

## Error model — drop granularity (decided)
Split by who owns the unsoundness, mirroring Wall #2/#3:
- **Crate-side shape** (the foreign API takes `Fn(&mut T)`, `-> &U`, non-`Clone` `&A`,
  `-> impl Fn`, out-of-closed-set A/R, or an `extern "C"` no-unwind host) → **method-level
  DROP + coverage report** (`.skycache/ffi/rust/<crate>.coverage.md`), reason tagged
  (`closure-by-ref-noclone`, `closure-mut-slot`, `closure-ho-return`, …).
- **User-lambda-side** (the user's specific lambda captures a non-`Clone` value into a
  multi-call slot) → **first-class Sky `E4400` at the call site** (`_ci_region`, hint),
  never a codegen drop — same DX as Wall #2's instantiation diagnostics.

## Architecture / data flow (reuses Wall #2 (A)-model)
```
HM solve → Mono.reachableInstances (carries closure arg/capture types + _ci_region)
  → Compile.hs threads the FFI-closure subset to generateRustProject
  → BINDABILITY CHECK (per instance): every closure A/R ∈ closed set; by-ref ⇒ A: Clone;
    captures: multi-call slot ⇒ all captures Clone (else E4400 / drop); no -&U / -impl Fn
  → GENERIC-WRAPPER SYNTHESIS: one wrapper `pub fn rust_x<F: Fn(A..)->R [+ Clone]>(f: F, ..)`
    body: [owned-clone bridge closure if by-ref] + catch_unwind(AssertUnwindSafe(|| ::crate::..))
  → TypeRenderer: Sky arrow `A1 -> .. -> R` → Rust `Fn(A1,..,An-1) -> An` bound
  → call site unchanged (rustc infers F, monomorphises); Sky lambda lowers to move-closure
  → <crate>_generics.rs (same sentinel-wrapped S4 tree-shake, kept iff base ref reached)
```
New vs Wall #2: the arrow→`Fn(..)`-bound TypeRenderer arm, the capture-Clone gate fed by
the monomorphiser's capture-type info, the owned-clone bridge body, the catch_unwind body.

## Boundary
- **Shared/epic (authorized):** `Compile.hs` (thread closure subset), the bindability
  check + its `Diagnostic` (`Sky.Reporting`), the arrow→`Fn` TypeRenderer arm, the Call
  AST if the wrapper body grows a closure-bridge node.
- **Rust:** `FfiInstance.hs`/`Ffi.hs`/`Project.hs` (wrapper synthesis, bridge, catch),
  the inspector (emit a `"closure"` arg shape + capture/ABI metadata, coverage tags), the
  fixture, the sweep wiring. NOT the Go inspector / `src/Sky/Generate/Go/` / `runtime-go/`
  / `sky-stdlib/` / author `examples/`.

## Go-byte-identical
Every new path gates on an FFI binding carrying a closure-arg shape; Go's inspector drops
function-typed args at the producer, so no Go kernel.json carries one → all new logic is
dead for Go. Decode additive (`.:?`). Go `.skyi`/kernel.json/codegen byte-identical.

## Testing
- **Hand-stub fixture** `runtime-rust/tests/sky/49-ffi-closures/` (no inspector): a tiny
  local crate + `kernel.json` closure-arg stubs proving — by-value `Fn(A)->B` map; multi-
  arg `Fn(A,A)->Ordering` comparator with `+Clone`; by-ref `Fn(&A)->bool` predicate via
  owned-clone bridge; `Fn(A)->Result/Maybe` fallible; **the multi-call `Fn` ALLOWLIST
  gate: all-`Clone` captures into a multi-call `Fn` slot ⇒ builds + runs; an `FnMut` slot
  (`retain`-shaped) ⇒ builds + runs; and E4400 (NOT cargo-fail) for a non-`Clone` capture
  of EACH escaping species — opaque-non-`Clone`, `Decoder`, captured `FnOnce`** (these are
  the rows that prove the positive allowlist is in force, not just the denylist species);
  a `FnOnce` slot with a non-`Clone` capture ⇒ builds + runs (no gate); an **indirect
  closure arg (let-bound lambda) ⇒ drop + `closure-indirect-noanalysis` coverage line**;
  **`Fn(&mut T)` / `-> &U` ⇒ drop + coverage line**; **a panicking Sky closure ⇒
  `SkyError`, not abort/UB**.
- **Real-crate proof:** bind a real crate's FREE functions / INHERENT closure methods
  end-to-end (candidate chosen at impl time — a by-value or `&A:Clone` inherent/free
  closure API such as a `Lazy::new(FnOnce)` / retry-style `Fn()->Result` / inherent
  `sort_by`); read the coverage report; the trait-method surface (itertools `Itertools`)
  is reported as `waits-on-#21`.
- Targeted `--match` unit specs for the arrow→`Fn` renderer + the capture-Clone gate +
  the bridge. **Light local verify only** (disk-constrained box): `cabal build exe:sky`
  + targeted specs + ONE fixture build; full suite + real-crate on CI.
- Guardian design review (this spec) + guardian-final (the diff), per the settled rule.

## Guardian-final amendments (BLOCKING — fold into writing-plans)
Both escalated decisions ruled APPROVE-WITH-CONSTRAINTS; these 5 tighten rules the spec
already gestured at (no redesign):

- **B1 — `AssertUnwindSafe` precondition is a GATE, not a comment.** Boundary-wrap is
  sound *only because* the Sky closure ABI is strictly by-value: the adaptor's working
  set is wrapper-frame-owned and dropped on unwind. Emit the boundary `catch_unwind` ONLY
  when the closure args + the adaptor's other args are by-value/owned; if any wrapper
  input is `&mut` Sky-owned state the wrapper returns on the ok-path, DROP+REPORT.
- **B2 — refuse under `panic="abort"`, don't just document it.** Under abort,
  `catch_unwind` is a no-op and a Sky-closure panic aborts the process → breaks the
  no-runtime-panic thesis. The build MUST pin/require `panic="unwind"` for any project
  that binds a closure-taking FFI fn (assert the profile; hard error otherwise), not a
  prose caveat.
- **B3 — denylist non-`"Rust"` ABI hosts (allowlist by construction).** Only synthesise a
  closure wrapper when the host fn's ABI is `"Rust"`; DROP+REPORT every `extern "C"`/other
  ABI host — this makes the no-unwind UB path *unreachable* rather than
  detect-the-bad-case. Conservative floor when the inspector can't read the ABI: treat as
  non-Rust ⇒ drop.
- **B4 — owned-clone bridge: the closed set having NO reference arm is the load-bearing
  invariant.** Identity-escape is precluded by construction because `FfiInstance.hs`'s
  closed set (≈:255-268) admits no `&`-type — Sky gets an owned clone, the original `&A`
  is structurally unreachable. Restate this as the invariant, add a regression assert that
  the closed set stays reference-free, and gate multi-`&` (`sort_by(&A,&B)`)
  **conjunctively** (every ref arg's element `Clone`, else drop the whole method).
- **B5 (highest priority, now LOAD-BEARING in v1 — multi-call `Fn` required) — the
  capture-Clone gate (C1) is built up front, not deferred.** Verified: there is no
  `Mono`-carried capture metadata, but `ExprEmitter.hs` already computes capture
  Clone-ness (`ecCloneVars`/`ecNoCloneVars`/`ecCopyVars`, :566,:668), and the inspector
  reads the param's trait kind (`Fn`/`FnMut`/`FnOnce`) the same way it reads any generic
  bound trait name. **v1 mechanism (the new plumbing the plan MUST build + test):**
  1. **Inspector** emits per-closure-arg metadata `{ argIndex, traitKind: Fn|FnMut|FnOnce,
     byRef, argTypes, ret }` (closures currently land in the dropped tail at
     `main.rs:3813` — stop dropping the closed-set ones).
  2. **Wrapper synthesis** renders one type-param per closure arg with the bound from the
     trait kind: `Fn`/`FnMut` ⇒ `<Fi: Fn(A..)->R + Clone>` (multi-call-capable),
     `FnOnce` ⇒ `<Fi: FnOnce(A..)->R>` (no `Clone`).
  3. **Emitter gate — POSITIVE `Clone`-ALLOWLIST, not a denylist (guardian re-bless,
     the load-bearing correction).** `ecNoCloneVars` MUST NOT gate this — it is a
     *denylist* holding exactly ONE species (a let-bound single-use `SkyTask`;
     `ExprEmitter.hs:560-562,2047`), so it would pass every other non-`Clone` capture
     (non-derive-`Clone` opaque foreign, captured `Decoder` = `Box<dyn Fn>`, captured
     `FnOnce`, moved-in non-`Clone` `Vec`) → `E0599`/`E0525` cargo-fail (already observed
     in `sky-playground`, per `runtime-rust/CLAUDE.md`). Instead, gate on each capture's
     **monomorphised type** (solved per-region type, data already in hand):
       - **`Fn`/`FnMut` (multi-call) slot:** REQUIRE every capture's type be **positively
         `Clone`** — i.e. in the reference-free closed set (`FfiInstance.hs:248-268`, all
         `Clone`) OR an inspector-*confirmed* derived-`Clone` opaque foreign. Every
         capture in the allowlist ⇒ emit (`Fn + Clone`). ANY capture not provably in it
         ⇒ **E4400 at the call site** — never emit, so `E0525`/`E0599` is structurally
         unreachable.
       - **`FnOnce` (single-call) slot:** no capture gate (move-in is sound).
       - **Hard precondition (B1 restated):** emit `Fn + Clone` ONLY for a by-value
         capture closure (the panic-boundary `AssertUnwindSafe` and the `Clone` story both
         depend on it); any `&mut`/by-ref capture ⇒ drop.
  4. **Direct-lambda-only (guardian Q4).** Trait-kind threading is reliable only when the
     closure arg is a **syntactic `Can.Lambda` at the `Can.Call` site** (`argToRustString`,
     `:576`). Indirect shapes — a let-bound lambda var, a call-produced closure, a
     point-free reference — decouple capture-analysis from the slot kind ⇒ **DROP+REPORT
     `closure-indirect-noanalysis`**. v1 binds the direct-lambda shape only.
  5. **Regression proof (gates the epic) — the both-directions fixture must exercise the
     ALLOWLIST, not just the one denylist species.** Required rows: all-`Clone`-capture
     multi-call `Fn` slot ⇒ builds+runs; an `FnMut` slot (`retain`-shaped) ⇒ builds+runs;
     and E4400 (NOT cargo-fail) for a non-`Clone` capture of EACH escaping species —
     **opaque-non-`Clone`, `Decoder`, captured `FnOnce`** (these passing as E4400 is the
     real proof the allowlist is in force; a `SkyTask`-only negative would only sample the
     denylist species and miss the Q1 holes).
  **No `Fn`/`FnMut` bound is ever emitted unless every capture is positively in the
  `Clone`-allowlist.** That positive invariant — never a denylist membership — is what
  makes multi-call `Fn` sound in v1.

## Dependencies
- **Blocked on:** nothing new — reuses Walls #1–#3 ((A)-model, bindability gate, coverage
  report, Call AST) all shipped. Sequenced AFTER #22 (borrowed-ref, in flight) per the
  arc order.
- **Unblocks/feeds:** iterators (`IntoIterator`-param) next; folds in `dyn Fn` trait
  objects; the itertools trait-method surface lights up once #21 lands.

## Decisions log (brainstorm 2026-06-22)
- v1 scope → **full closed-set, any arity, incl. Bool/Maybe/Result returns**.
- proof bar → **hand-stub fixture (all 6 gates) + a real free/inherent closure API**;
  coverage names the #21-blocked surface.
- by-ref closure params → **owned-clone bridge when `A: Clone`**, else drop+report.
- drop granularity → crate-side ⇒ method-level coverage drop; user-lambda-side ⇒ E4400.
- panic boundary → RULED boundary-level `catch_unwind` + B1/B2/B3 gates.
- capture-Clone gate → **multi-call `Fn`/`FnMut` bind in v1** (user-required) via a
  POSITIVE `Clone`-allowlist on each capture's monomorphised type (NOT the `ecNoCloneVars`
  denylist — guardian REJECT then re-bless); direct-lambda-only; expanded negative
  fixtures prove the allowlist (B5).
