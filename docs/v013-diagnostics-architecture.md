# v0.13 — Diagnostics & Compiler Soundness Architecture

Status: Planning (branch `perf/v0.13`)
Started: 2026-05-12
Target: solid foundation, not a patch series

## Why this exists

v0.12.x shipped 26 examples + Sky.Live + Sky.Tui + typed-codegen
foundations. But the pattern of v0.12.0 → v0.12.1 patches surfaced
deeper architectural cracks:

1. Errors leak. The compiler is sound on what HM CAN check, but
   codegen-stage bugs (Issue #52's `List.drop` coercion, the
   `Dict_fromListT[string]` panic on heterogeneous lists) surface as
   cryptic Go-build errors or runtime panics. The user can't tell
   compiler bugs from their own mistakes.

2. Error messages are strings. Each phase (parse, canonicalise, HM,
   exhaustiveness, codegen, go build, runtime) emits its own ad-hoc
   format. There's no unified `Diagnostic` value flowing through the
   pipeline. v0.12.1 added rendering improvements (filename prefix,
   source-context snippet, recursive type-diff) but each is a
   string-parsing hack on top of the previous string-parsing hack.

3. LSP doesn't catch what `sky check` catches. The LSP runs Parse +
   Canonicalise + HM. Codegen + `go build` validation never reach the
   editor. Users hit the same bugs at command-line that the LSP
   silently approved.

4. Standard library opacity. `String.fromInt`, `List.map`, `Dict.*`
   etc. are hand-written Go in `runtime-go/rt/*.go`. When they panic
   the user sees Go stack traces with no Sky line numbers. Hard to
   extend, debug, or reason about.

## The guarantee v0.13 will deliver

**"Sky's compiler will never be the source of a runtime panic on
type-correct Sky source."**

Specifically:
- Every error the type system, canonicaliser, exhaustiveness checker,
  OR codegen-stage validator CAN determine is caught, surfaced in
  LSP, and reported with Elm-quality diagnostics.
- The error format is structured (`Diagnostic` AST), uniform across
  phases, machine-parseable (LSP, IDE quick-fix), and human-readable
  (CLI source-context snippet).
- The `sky check` command and the LSP report identical errors —
  identical set, identical text, identical regions.
- Compiler-introduced runtime panics (Issue #52 class — typed
  monomorphisation with any-typed source) cannot escape codegen
  validation.

What this guarantee does NOT cover (and won't, by any compiler):
- User-invoked `Sky.Ffi.call` escape hatches (intentional `any`-typed
  bypass; user accepts loss of type safety, same as Haskell's
  `unsafeCoerce` / Rust's `unsafe`).
- Semantic logic bugs (`x + 1` when user meant `x - 1` —
  type-correct but wrong-behaving).
- Runtime resource issues (OOM, goroutine leaks, stack overflow).

These limits are honest; no compiler can promise more.

## Out of scope (deferred to v0.14+)

- Full type monomorphisation (0 `any` in emitted Go). v0.13 increases
  the typed surface but does NOT eliminate `func(any) any` for
  lambdas — that requires lambda lowering with end-to-end HM type
  preservation, a multi-week refactor on its own.
- Sky.Gui (gio) — independent track on `exp/sky-gui-gio`.
- Mobile / cross-platform — depends on Sky.Gui maturity.
- Performance optimisation beyond what Layer 3 surfaces.
- Sky → Haskell → Go intermediate (explicitly rejected — see below).

## Approach rejected: Sky → Haskell → Go

The user proposed using Haskell as an intermediate compilation target,
reasoning that Haskell's mature type system would catch errors that
Go misses. **Rejected** for these reasons:

1. **No production reference.** GHC's Go backend was a research
   experiment that stalled. Haskell-to-Go translation is research-
   level because Haskell's lazy/pure model doesn't map cleanly to
   Go's strict/imperative model. We'd be the first to ship.
2. **Doubles failure surface.** Errors come from Sky AST, OR Haskell
   type-check, OR Haskell-to-Go translation. Three places for bugs
   to hide.
3. **Trades known HM for unknown HM.** Sky's HM solver is small and
   we control it. Switching to GHC's HM means inheriting its quirks
   (let-generalisation, value restriction, deferred type errors)
   and losing the ability to customise error rendering.
4. **Doesn't solve the root cause.** The opacity is in the runtime
   stdlib (hand-written Go), not in the compilation path.

The Sky compiler's HM is not the problem. The error pipeline is.

---

## The four-layer architecture

### Layer 1: Diagnostic AST (the foundation)

Replace string-based errors with a structured `Diagnostic` value.
Every phase emits these. ONE renderer for CLI + LSP.

```haskell
data Diagnostic = Diagnostic
    { _diag_file     :: !FilePath
    , _diag_region   :: !Region              -- primary source range
    , _diag_severity :: !Severity            -- Error | Warning | Info
    , _diag_category :: !Category            -- Parse | Canonical | Type | …
    , _diag_message  :: !String              -- short summary
    , _diag_related  :: ![RelatedRegion]     -- secondary highlights
    , _diag_hints    :: ![Hint]              -- "Try X" suggestions
    , _diag_code     :: !(Maybe DiagCode)    -- stable code (E0001 etc.)
    }

data RelatedRegion = RelatedRegion
    { _rel_file    :: !FilePath
    , _rel_region  :: !Region
    , _rel_message :: !String
    }

data Hint = Hint
    { _hint_message       :: !String
    , _hint_suggested_fix :: !(Maybe SuggestedFix)
    }

data SuggestedFix = SuggestedFix
    { _fix_description :: !String
    , _fix_edits       :: ![TextEdit]   -- LSP-compatible edits
    }
```

#### Phase migration

Each phase currently emits a `String`. Migrate to produce
`[Diagnostic]`:

| Phase | Current | Target |
|---|---|---|
| Parse | `Either String Module` | `Either [Diagnostic] Module` |
| Canonicalise | `Either String Module` | `Either [Diagnostic] Module` |
| HM Solve | `SolveResult` with String error | `SolveResult` with `[Diagnostic]` |
| Exhaustiveness | `String` error | `[Diagnostic]` |
| Codegen-validation (NEW — Layer 2) | n/a | `[Diagnostic]` |
| Go build wrapper | string-pattern detection in `runGoBuildWithDiagnostics` | `[Diagnostic]` |
| Runtime panic recovery | bare panic | `[Diagnostic]` from `defer recover` |

#### Renderer: CLI

`renderCli :: Diagnostic -> String` — produces the Elm-style block:

```
-- TYPE MISMATCH ----------------------------------- src/Main.sky:47:9

The 1st argument to `Live.app` is not what I expect:

48|         , update = update
                       ^^^^^^
This `update` value has type:

    Msg -> { i : Int, n : String } -> ...

But `Live.app` needs:

    Msg -> { i : Int, n : Int } -> ...

Hint: I see that `n` is assigned a String here:

42|     ( { model | n = String.fromInt ... }, Cmd.none )
                       ^^^^^^^^^^^^^^^^^^

Try removing the `String.fromInt` if `n` should stay an Int, or
update the Model alias if `n` should be a String.
```

#### Renderer: LSP

`renderLsp :: Diagnostic -> LspDiagnostic` — produces the JSON shape:

```json
{
  "range": { "start": {"line": 47, "character": 9}, "end": ... },
  "severity": 1,
  "code": "E2003",
  "source": "sky",
  "message": "Type mismatch in field `update` ...",
  "relatedInformation": [
    {
      "location": { "uri": "file:///.../Main.sky", "range": {...} },
      "message": "`n` is assigned a String here"
    }
  ]
}
```

Editor jumps via `relatedInformation` work for free in VS Code +
Neovim's native LSP client.

#### Diagnostic codes

Each error class gets a stable code (`E0001` = parse error,
`E1003` = undefined name, `E2003` = type mismatch, etc.). Codes:
- Stable across versions (cabal tests grep by code, not message)
- Documented at `docs/diagnostics/E0001.md` etc.
- Usable in `// sky: allow E2003` overrides (future)

---

### Layer 2: Codegen-stage validation

Currently codegen produces Go via string templates with no Sky AST
traceability. When `go build` rejects the output, the user sees a Go
error with no path back to Sky source.

**Change**: every emitted Go expression carries `Origin :: Maybe Region`
(the Sky source region that produced it). A post-codegen validation
pass walks the typed Go output looking for known compiler-bug shapes
and emits `Diagnostic`s with the Sky region — BEFORE handing to
`go build`.

#### Origin tracking

Currently:
```go
rt.List_dropT[int](i, rt.AsListT[int](xs))
```

Target:
```go
rt.List_dropT[int](i, rt.AsListT[int](xs)) // sky: src/Main.sky:42:18-29
```

The comment is preserved through `go build`. When Go errors on a
line, we parse the trailing `// sky:` comment and emit a Diagnostic
with the Sky region.

#### Validation patterns

Known compiler-bug shapes to catch BEFORE go build:

1. **Typed kernel call with any-typed primitive arg**:
   `rt.List_dropT[int](anyVar, ...)` where `anyVar` has no
   `rt.AsInt` wrap. Issue #52's class.
2. **`rt.Coerce[ConcreteType]` on a known-incompatible source**:
   if the source's HM type doesn't structurally match the target.
3. **Generic instantiation with unresolved type vars**: emitting
   `rt.X[any, T]` where T came from solver fallback.
4. **FFI boundary mismatch**: passing wrong number of args to a
   typed FFI wrapper.

Each pattern → specific Diagnostic with code (E3001 etc.) + Sky
region (from origin tracking).

#### Implementation

Validation pass runs AFTER Go IR is built but BEFORE the Go source
is written. Walks the IR tree, applies pattern matchers, accumulates
Diagnostics. If non-empty: writes nothing, returns the diagnostics
to the user.

This means the user never sees a `go build` error from a
compiler-introduced bug class. The bug is caught + reported in Sky
terms BEFORE Go sees the code.

#### What stays in the `go build` path

Real Go errors (third-party FFI binding issues, Go SDK changes) that
codegen validation can't predict — these go through the existing
`runGoBuildWithDiagnostics`. The "compiler bug detected" footer stays
but should fire less often (Layer 2 catches most cases pre-emptively).

---

### Layer 3: Sky-written stdlib

Move `String.*`, `List.*`, `Dict.*`, `Maybe.*`, `Result.*`,
`Set.*` from `runtime-go/rt/*.go` to `sky-stdlib/Std/*.sky`.

Keep `runtime-go/rt/primitives.go` for the bottom layer: Go-syscall
helpers (file IO, time, crypto, allocator). The stdlib functions
become Sky source compiled to Go via normal codegen.

#### Bootstrapping

Sky compiler needs stdlib to compile USER code. If stdlib is in Sky,
what compiles the stdlib?

**Two-pass build**:
1. Pass 1: compile sky-stdlib using a MINIMAL kernel registry (only
   the primitive Go FFI bindings). Output: typed Go for stdlib.
2. Pass 2: user code compiles against the stdlib's typed Go output.

The compiler caches Pass 1 output. End users never see it; they only
see Pass 2.

#### Migration order

Per-module priority (small surface first, find bugs early):
1. `Std.Set` (16 functions) — smallest, well-typed
2. `Std.Maybe` / `Std.Result` (20 functions each)
3. `Std.Dict` (~30 functions)
4. `Std.List` (~40 functions) — hottest path
5. `Std.String` (~50 functions) — biggest, complex (uniseg etc.)

Each module migrated with:
- Sky source under `sky-stdlib/Std/X.sky`
- Bottom-layer Go FFI in `runtime-go/rt/primitives_x.go` (or shared)
- Per-function performance benchmark
- All existing tests passing

#### Performance budget

Sky-compiled stdlib may be slower than hand-written Go due to
remaining `any` overhead. Budget:
- ≤ 10% regression on `cabal test` runtime (currently ~22 min)
- ≤ 5% regression on `scripts/example-sweep.sh --build-only`
- Per-function: ≤ 2× slowdown vs current

Mitigation: if a specific function regresses past 2×, keep it in Go
with a comment explaining why. Document the exceptions.

---

### Layer 4: LSP runs the full pipeline

Currently the LSP stops after HM. Extend it to:
- Run codegen (cached per-module — incremental)
- Run Layer 2's validation pass
- Surface ALL Diagnostics via `textDocument/publishDiagnostics`
- Skip the actual `go build` (still too slow for per-keystroke)

#### Incremental compilation

Re-running codegen on every keystroke is too expensive (skyshop's
codegen is ~3s cold). Use `.skycache/lowered/` (already exists) to
skip per-module work that hasn't changed.

Cache key: hash of (module source + dep sigs + compiler version).
Cache hit → skip codegen for that module. Only the changed module
re-runs.

#### Diagnostic publishing

LSP's `publishDiagnostics` is a per-file array. Diagnostics from
ALL phases (parse, canonicalise, HM, exhaustiveness, codegen-
validation) get merged per file and pushed.

#### "Run go build" trigger

Per-keystroke `go build` is too slow. But on `textDocument/didSave`
we can run a full `sky build` in the background and surface any
remaining errors. This catches the 5% of bugs Layer 2 doesn't
pre-emptively catch (real Go SDK changes, etc.).

---

## Self-grill: what could go wrong

### 1. Diagnostic AST coupling

Risk: AST becomes too coupled to Sky internals, can't be reused for
external tooling (IDEs, doc generators).

Mitigation: keep `Diagnostic` PURE (no compiler-internal types
exposed). Use file paths + strings everywhere; never expose `T.Type`
in the AST.

### 2. LSP performance

Risk: per-keystroke validation slows the editor to unusable.

Mitigation: per-module cache + budget — if validation takes >500ms
for a module, skip and log a warning. Validation is best-effort,
not blocking.

### 3. Test fixture churn

Risk: every error-text-matching cabal test (`isInfixOf` checks)
breaks when we move to structured Diagnostics with new format.

Mitigation:
- New tests assert on `Diagnostic.code` (stable) not `_message`
- Legacy tests keep string match against the new renderer's output
- Migration done one phase at a time so test breakage is localised

### 4. Stdlib bootstrapping bug surface

Risk: Sky-written stdlib has subtle bugs that didn't exist in the
hand-written Go. Could break user programs unexpectedly.

Mitigation:
- Per-function test suite (existing rt/*_test.go ports to
  sky-stdlib/Test/*.sky)
- Migrate smallest modules first; validate against examples before
  next module
- Keep the hand-written Go around for one release as fallback
  (`SKY_STDLIB_LEGACY=1` env var). Removed in v0.14.

### 5. Sky.Ffi.call deprecation

Risk: deprecating raw `Sky.Ffi.call` breaks user code that relies on
it.

Mitigation: don't remove it. Keep as escape hatch. Just push users
toward typed `foreign import` declarations via documentation +
LSP-emitted info-level diagnostics ("consider replacing Sky.Ffi.call
with a typed foreign import").

### 6. Origin tracking overhead

Risk: tracking Sky region for every emitted Go expression bloats
generated code with comments, slows go build.

Mitigation: tracking is COMPILE-TIME only (not runtime). The `//
sky:` comments are stripped by go's parser during build — zero
runtime overhead.

### 7. Codegen-validation false positives

Risk: validation rejects valid Go that codegen produced because the
pattern matcher is too broad.

Mitigation:
- Each pattern matcher has a dedicated regression test
- `SKY_CODEGEN_VALIDATION=warn` env var downgrades errors to
  warnings during development
- Validators ship as opt-in initially (`--strict-codegen`), promoted
  to default once stable

### 8. Multi-week timeline

Risk: 8-12 weeks is a long time without intermediate ships.

Mitigation: layer-by-layer release.
- v0.13.0 — Layer 1 + Layer 2 (the soundness floor)
- v0.13.1 — Layer 3 (stdlib migration, can be partial)
- v0.13.2 — Layer 4 (LSP full pipeline)

Each layer is independently useful + shippable.

### 9. Compiler self-host risk

Risk: Sky-written stdlib means the compiler depends on its own
output to compile. A bug in codegen breaks the bootstrap.

Mitigation:
- Keep hand-written Go fallbacks tagged with build flags
- CI runs both `--with-sky-stdlib` and `--with-go-stdlib` paths
- Bisect cleanly when regressions hit

### 10. The "good enough" trap

Risk: Elm-quality error attribution is iterative. First cut won't
match Elm. There's pressure to ship "partial Elm" that confuses
users worse than current.

Mitigation:
- The four layers are scoped INDEPENDENTLY of Elm-quality wording.
  Layer 1 = AST is structural. Layer 2 = catches bugs.
- Error message wording is a separate dimension. We tune it per
  diagnostic code, ship incrementally, and DON'T claim "Elm parity"
  until specific codes are polished.

---

## Success criteria

### Layer 1 — Diagnostic AST
- [ ] `Diagnostic` type defined in `Sky.Reporting.Diagnostic` module
- [ ] CLI renderer produces Elm-style output for at least Parse,
      Canonicalise, HM errors
- [ ] LSP renderer produces valid JSON with related-information
- [ ] All existing tests pass (with updated message expectations
      where needed)
- [ ] Diagnostic code registry started: at least 20 codes documented

### Layer 2 — Codegen validation
- [ ] Origin tracking on every emitted Go expression
- [ ] At least 4 validation patterns implemented:
      - typed-kernel-with-any-arg
      - rt.Coerce-on-known-incompatible
      - generic-instantiation-with-unresolved-tvar
      - FFI-arity-mismatch
- [ ] Issue #52's `List.drop` regression case caught at codegen
      stage (not go build stage)
- [ ] `runGoBuildWithDiagnostics` falls back to source-mapped errors
      via origin comments

### Layer 3 — Sky-written stdlib
- [ ] `Std.Set` migrated; tests pass
- [ ] `Std.Maybe` / `Std.Result` migrated
- [ ] `Std.Dict` migrated
- [ ] `Std.List` migrated
- [ ] `Std.String` migrated
- [ ] Performance budget met (≤ 10% cabal test regression, ≤ 5%
      example sweep regression)
- [ ] LSP hover works on stdlib functions (Sky source, not Go)
- [ ] `SKY_STDLIB_LEGACY=1` flag available for one release

### Layer 4 — LSP full pipeline
- [ ] LSP runs codegen + validation per `textDocument/didChange`
- [ ] Diagnostics surface in editor before save
- [ ] Issue #52's `List.drop` class visible as red squiggle BEFORE
      `sky build`
- [ ] Performance: per-keystroke validation under 500ms p99 on
      skyshop-scale projects
- [ ] `textDocument/didSave` triggers background `sky build` for
      remaining gap classes

### Overall guarantee
- [ ] Test suite: a new `test/Sky/Diagnostics/CoverageSpec.hs` runs
      every fixture in `test/fixtures/diagnostics/` (one per error
      class) and asserts:
      1. Sky CLI reports the diagnostic with correct code + region
      2. LSP publishes a matching diagnostic
      3. Runtime never sees the program (caught pre-codegen or at
         codegen-validation)
- [ ] No regression in any v0.12.x example
- [ ] `cabal test` green
- [ ] `scripts/example-sweep.sh --build-only` green across all
      examples
- [ ] Deep Playwright sweep (all Live apps) green
- [ ] `runtime-go/rt/*_test.go` green

---

## Concrete next actions

1. ✅ Plan doc written (this file)
2. Branch already exists: `perf/v0.13`
3. Layer 1 — week 1-2:
   - `src/Sky/Reporting/Diagnostic.hs` (the AST)
   - `src/Sky/Reporting/Render.hs` (CLI renderer)
   - `src/Sky/Reporting/Lsp.hs` (LSP JSON serialiser)
   - Migrate Parse + Canonicalise phases first (smallest surface)
   - Add `test/Sky/Reporting/DiagnosticSpec.hs` regression fence
4. Layer 2 — week 2-3 (overlaps Layer 1 final week):
   - Origin tracking in Go IR
   - Validation patterns
   - Issue #52 regression test from Sky stage
5. Layer 3 — week 3-6 (overlaps Layer 2 final week):
   - Bootstrap two-pass build
   - Per-module migration
   - Performance benchmarks
6. Layer 4 — week 6-8:
   - LSP pipeline extension
   - Incremental codegen cache
   - Editor-side smoke tests (VS Code + Neovim)
7. v0.13.0 release: Layer 1+2 (the soundness floor)
8. v0.13.1: Layer 3 (partial OK)
9. v0.13.2: Layer 4 (LSP full pipeline)

Each layer = independent ship-able milestone. No big-bang.
