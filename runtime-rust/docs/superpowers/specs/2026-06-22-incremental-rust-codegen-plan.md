# Incremental Sky→Rust codegen for `sky watch` — plan (guardian-reviewed)

Status: SCOPED (not started). Guardian soundness review: 2026-06-22.
Cardinal hazard: a stale cache producing a WRONG build (a miscompile that type-checks).
Every stage below is gated on the soundness invariants + the equivalence backstop (I5).

## Goal
Make a `sky watch --backend rust` rebuild cost proportional to *what changed*, not the
whole program + stdlib. Today (post batch-28) a one-file edit rebuild is ~4.3s; the
residual is the Haskell-side full re-parse/typecheck/lower, dominated by reprocessing the
**unchanging stdlib** every rebuild ("HM infer (deps): 338 functions typed" each time).

## Current architecture (verified)
- Pipeline: Parse → Canonicalise (dep fixpoint) → **HM Solve (whole-program, global
  unification)** → Monomorphise → Generate Rust (per-module `.rs` + `main.rs`) → rustfmt
  → cargo build.
- The stdlib (`sky-stdlib/`, immutable during a session) is materialised, discovered,
  re-parsed, re-canonicalised, re-typechecked, and re-lowered on EVERY build. No
  per-module IR/type persistence exists.
- A whole-project short-circuit exists (`.skycache/source.hash`) but is **Go-only**
  (`cacheHit` requires `outDir/main.go`, which a Rust build never writes) → the Rust
  backend always does the full compile, even when source is unchanged.
- `source.hash` is a NON-cryptographic rolling hash (`length + foldl (\a c -> a*31+c)`),
  `Compile.hs:758-764`.

## Soundness invariants (apply to every stage)
- **I1 — key completeness.** A cached artifact's key captures EVERY input affecting it:
  own content + transitive deps' INTERFACE hashes + compiler-build-tag + every
  codegen-affecting config. A missed input = stale miscompile.
- **I2 — conservative invalidation.** When affect-analysis is uncertain, RECOMPILE
  (over-approximate the dirty set). Never reuse on doubt.
- **I3 — compiler tag in every key.** Use the build/git hash (NOT a hand-bumped string),
  so a rebuilt compiler never reuses prior-compiler artifacts.
- **I4 — fail-safe.** Any cache read error / corruption / version or config mismatch →
  fall back to a FULL compile. Never a partial/wrong build.
- **I5 — EQUIVALENCE GATE (the backstop).** The incremental build's output MUST be
  byte-identical to a from-scratch (`SKY_NO_INCR=1`) build of the same source. Enforced
  by: (1) an edit-corpus equivalence test (incremental-output == clean-output, byte for
  byte) and (2) a random-edit fuzz over the example corpus. This gate is what makes the
  whole effort safe to ship incrementally — land it FIRST (with S0).
- **I6 — atomic writes.** Cache writes go to a temp file + atomic rename. `mem-guard`
  can OOM-kill the compiler mid-build; a half-written cache entry must never be read as
  valid (the fingerprint/manifest is the last thing renamed in).
- **I7 — closed-enumerated config key + guard test.** The set of codegen-affecting config
  (backend selector, driver, env-prefix, DCE on/off, static-alloc, feature flags, …) is
  enumerated explicitly and hashed into the key; a guard test fails if a new
  codegen-affecting `SkyConfig` field is added without being added to the key.

## Stages

### S0 — Extend the whole-project short-circuit to Rust  — **GO** (after the hash fix)
- Add a Rust reuse branch: `existingOutput = outDir/rust/src/main.rs`; on a `source.hash`
  match, skip Sky codegen, re-copy runtime if needed, hand off to cargo (itself
  incremental). Wire `SKY_NO_INCR=1` to force the full path (needed by I5).
- **Blocking prerequisite:** replace the `*31+c` rolling hash with **SHA-256**. It is a
  realistic collision/silent-miscompile vector and it ALREADY gates the shipped Go
  short-circuit — fix it there in the same commit (no-deferral).
- Effect: a no-op rebuild (touch / whitespace-only save that re-hashes equal, or an
  unrelated-file save) skips Sky codegen entirely. Does NOT help the content-edit case.
- Soundness: reuses the already-trusted coarse key; risk low once the digest is real.
- First test: edit→revert→build twice, assert 2nd build hits the cache AND output ==
  clean build (I5 on the trivial case).

### S1a — Cache stdlib TYPE INTERFACES, reuse in Solve  — **NEEDS-EVIDENCE-FIRST**
- The high-value, salvageable half. Cache the stdlib's canonicalised modules + solved
  type interfaces, keyed on `STDLIB_FINGERPRINT = sha256(all sky-stdlib sources) +
  compiler-build-tag + config-key`. On rebuild, reuse them and only
  parse/canon/typecheck the USER project modules, solving them AGAINST the frozen stdlib
  interfaces (separate compilation of the stdlib's front-end).
- Why sound *in principle* (guardian): the stdlib is FULLY TYPE-ANNOTATED, so the HM
  generalization boundary means a user call site cannot narrow/influence a stdlib
  binding's inferred type; and Sky has no typeclasses/HKT, so there is no global
  instance-coherence state that whole-program solve would resolve differently.
- **Evidence gate before prototype:** prove that solving user-modules-against-frozen-
  stdlib-types yields BYTE-IDENTICAL user-region solved types vs a whole-program solve,
  across the example corpus (dump + diff the region-type maps). If any divergence → a
  user call IS influencing stdlib inference (annotation gap) → STOP, fix the annotation
  or abandon S1a.
- What the cached interface must capture (I1): every exported binding's generalised
  type scheme, exported ADTs/aliases + their constructors/fields, and any global solver
  state the user solve consumes (region seeds, the `_stPerModuleEnv` ledger entries for
  stdlib). Under-capture = miscompile.

### S1b — Cache stdlib LOWERED Rust output  — **BLOCKED as drafted**
- Verified: the A4 monomorphiser emits per-user-call-site specialised copies of
  polymorphic stdlib callees, so the lowered stdlib `.rs` is **user-code-dependent**.
  Caching it on a stdlib-only fingerprint is a guaranteed I1 stale miscompile.
- Gate to unblock: monomorphiser instrumentation must report ZERO stdlib-callee
  specialisations for the target program class before any prototype; otherwise only the
  user-independent subset (if cleanly separable) is cacheable, which is likely not worth
  the complexity. Default: do NOT pursue S1b; rely on S1a (skip re-typecheck) +
  batch-28's writeFileIfChanged (cargo already skips unchanged emitted `.rs`).

### S2 — Per-user-module incremental typecheck + lower  — **NEEDS-EVIDENCE-FIRST**
- On a 1-file edit, recompile only modules whose content OR transitive dep-interface
  changed (module interface hashing + dep graph + dirty-set propagation). Hardest: HM is
  global within the user program too.
- Evidence gate: an interface-changing-edit fuzz proving the computed dirty-set is a
  conservative SUPERSET of all affected modules (a missed dependent = miscompile).
- Likely deferred until S0+S1a land and the residual cost justifies it.

## Soundness-risk ranking (lowest → highest)
S0 (coarse key reuse) < S1a (frozen-stdlib solve) < S2 (per-module dirty-set) < S1b
(user-dependent lowered cache — blocked).

## Verification & rollout
1. Land I5 (the equivalence harness + `SKY_NO_INCR=1`) FIRST — it backstops everything.
2. S0 + the SHA-256 hash fix (one focused, guardian-reviewed batch).
3. S1a behind the evidence gate (region-type-equivalence proof) + the kill switch; ship
   only when the equivalence fuzz is green across the corpus.
4. Re-measure watch rebuild; pursue S2 only if the residual still warrants it.
- Kill switch: `SKY_NO_INCR=1` disables all incremental caching → always full compile.
- Every stage is in-boundary (`src/Sky/Build/*`, `src/Sky/Generate/Rust/*`,
  `runtime-rust/`); each lands with its pre-fix-failing regression + the I5 gate.

## Effort (rough)
- S0 + hash fix: small (1 session).
- I5 harness: small–medium.
- S1a: large (separate-compilation front-end + the equivalence evidence) — multi-session.
- S2: XL.

---

## Evidence & decision (2026-06-22, guardian-reviewed) — HOLD

Read-only probes (instrumentation reverted; tree clean). Measured on sky-playground,
`--backend rust`, `SKY_RUST_FMT=0`, warm; ~4.1s rebuild:
- parse+canon+setup ~0.80s · dep-solve **fixpoint ~0.75s (×10 rounds, re-solves ALL deps
  incl. stdlib, "1039 dep functions typed")** · codegen+emit ~0.65s (front-end ~1.55s;
  Haskell ~2.2s) · **cargo ~1.88s — irreducible from the Sky side, dominant chunk.**

Soundness precondition for S1a (frozen-stdlib solve ≡ whole-program solve): **MET** — the
stdlib is fully type-annotated (1588 bindings / 1515 sigs = multi-clause gap; zero
unsigned top-level bindings), Sky has no typeclasses/HKT/consumer-resolved dictionaries,
and row-poly is resolved at the consumer, not the library. So a user call can't refine a
stdlib binding's annotated type.

The two implementable slices and their verdicts:
- **B2 — cache stdlib SOLVE, exclude from the fixpoint** (the ~20% win): requires a seam in
  the dep-solve fixpoint (`solveRound`). **Guardian: inherently NOT autonomous-safe** — an
  equivalence/Go-identity corpus gate samples program *strings*, but a fixpoint-convergence
  bug can pass on an unsampled *dep-graph topology* (e.g. mutually-recursive user modules
  over a stdlib binding frozen at a too-early iteration). The correctness argument is
  human-review-shaped; gates downgrade it to "ship behind review + kill switch", never
  autonomous. **RECOMMEND-HOLD.**
- **B1 — cache stdlib parse+canon in-memory** (~10%, ~0.4s): semantically sound (stdlib
  canon is closed over {stdlib ∪ kernel} — it never imports user modules, so user `DepInfo`
  entries are inert). BUT canon is a **monolithic fixpoint** over all deps; reuse needs
  restructuring it to seed cached-stdlib + iterate only user modules — not the clean memo
  that would make it low-risk. Per the guardian's own tree, that pushes B1's risk up while
  its value stays modest + cargo-capped. **HOLD.**

DECISION: **HOLD on autonomous implementation.** No slice is BOTH autonomous-safe AND clears
the value/risk bar (B2 unsafe-autonomous; B1 modest + needs fixpoint restructuring). The
Sky-side ceiling is ~20% of a rebuild that stays >3s because cargo (~1.9s) + user codegen
are irreducible.

Prerequisite for ANY future incremental work (and the price of admission for a later
human-reviewed B2): build the **I5 equivalence harness** (incremental output ==
`SKY_NO_INCR=1` full output, byte-for-byte, over the example corpus + a random-edit fuzz)
and a **Go-byte-identical gate**. These are reusable and load-bearing; the theory never
substitutes for them. Both live in the shared build path → an upstream/author conversation.
