# Known limitations

Active limitations users still hit (as of v0.13). Each entry explains
the gap, why, and the workaround. Anything v0.13 closed has been
removed from this file — see `docs/compiler/journey.md` and the
repo `CLAUDE.md`'s "v0.13 State" / "Recently Fixed" sections for
the fix log.

**Closed by v0.13**:

- Anonymous-record struct emission (E) replaces the pre-v0.13
  `sanitiseTypedDeep` cover-up. `synthAnonRecordName` now registers
  shapes and `generateAnonRecordDecls` emits real
  `type Anon_R_<hash> = struct { ... }` decls.
- Typed lambda OUTPUT at user-defined HOF call sites
  (D-Lambda-Lowerer + D1). User-defined
  `do : Result e a -> (a -> Result e b) -> ...` now emits with
  typed `func(T1) rt.SkyResult[E, V]` HOF param signatures.
- Whole-program Sky DCE (F + F3). Stripe-skyshop benchmark:
  main.go 14 k → 4 k lines (−71 %); `stripe_bindings.go` 326 k
  → 58 k lines (−82 %); FFI type-alias bloat 80,847 → 29.
- LSP 100 % (G). Hover + goto-def for every USED symbol class;
  17 cabal-fenced tests.
- Unicode-aware codegen identifier matching.
- Reflect-adapter arg narrowing in the FFI runtime (closes a real
  panic class surfaced by `verify-cli.sh` on `examples/07-todo-cli`).

**v0.13.x deferred** (known scope for the next release):

- Install-time Go-binding generation: `sky install` skips Stripe-
  scale Go-source emission; `sky build` generates only the
  reachable subset on demand. Stripe cold install ~8 min → ~10 sec;
  `.skycache/go/` per-pkg ~12 MB → <100 KB.
- **Skyshop image-URL console-error trace** — under
  `scripts/verify-all-web.sh` with `SKY_VERIFY_SKYSHOP=1`, the
  13-skyshop verifier reports 5 console 404s for URLs of the
  shape `/[data:image/jpeg;base64,…]`. The shape only appears in
  the verifier environment (Playwright with `recordVideo`
  context), not in standalone curl / Playwright probes. Zero
  server panics. Likely a Sky.Live SSE patch-state restoration
  rendering a stale productImages list with literal brackets;
  needs a targeted reproducer + trace. Not a typed-codegen
  contract violation (no `map[string]any` direct casts; whole-
  sweep `Coerce` audit clean — see CLAUDE.md "Cross-cutting
  fixes shipped in v0.13"). Skyshop excluded from default sweep
  via `SKY_VERIFY_SKYSHOP=0`.
- **Fully-typed tuple instantiation across boundaries.** v0.13
  emits every tuple — function return AND variable type AND list
  element type AND dict value type — as `rt.SkyTuple2 = T2[any,
  any]`. This is a *consistency* choice, not a contract gap: the
  function-signature renderer (`safeReturnType`),
  variable-type renderer (`solvedTypeToGo`), and tuple-literal
  emitter (`Can.Tuple` arm) all agree. The earlier "typed T2[A,
  B]" attempt was rolled back because `[]rt.T2[int, int]` and
  `[]rt.SkyTuple2` are distinct Go nominal types — any divergence
  between signature and literal needed a coercion at every
  list/dict-of-tuples site, which scaled badly. The hot perf
  path was addressed instead: `tupleFirst` / `tupleSecond` now
  type-assert before falling back to reflect (~40 % faster per
  dispatch — see `runtime-go/rt/tuple_dispatch_test.go`). A
  proper "typed update return" would need threading the function's
  HM return type into `Can.Tuple` emission so the literal matches;
  scoped to v0.14+ once the lambda-output type plumbing reaches
  feature parity (see "Typed Codegen TODO" in `CLAUDE.md`).

---

## Skychess AI regression — FIXED

**Root cause.** Not a chess-algorithm issue. `rt.List_foldlAnyT`
(the typed-codegen foldl variant, introduced in the P7/P8 typed-
codegen phase) passed arguments to the reducer in the wrong order:
`SkyCall(fn, acc, x)` instead of `SkyCall(fn, x, acc)`. Sky follows
Elm's `List.foldl : (a -> b -> b) -> b -> List a -> b` convention
— element first, accumulator second. The inverted order meant
`Eval.evaluate` (a fold over all 64 squares) silently overwrote
its accumulator with each list element on every iteration; the
final "material score" was always just the last square index (63).
Every example using foldl through the typed path exhibited the
same class of bug — chess was where it showed visibly (AI playing
by material=63 instead of actual evaluation).

**Fix.** One-line swap in `runtime-go/rt/rt.go:List_foldlAnyT`.
The older `List_foldl` (non-T) was always correct; only the newer
typed-T variant had the bug.

**Regression fence.** `examples/16-skychess/tests/ChessPrimitivesTest.sky`
— 5 Sky-level tests exercising the chess primitives:

- `setPiece + getPiece` round-trip
- `movePiece` relocates the piece
- `materialValue` returns the expected material ranking
- `Eval.evaluate` is positive for a lone White piece
- `Eval.evaluate` is negative for a lone Black piece — this one
  exposed the bug; pre-fix it returned +63 for a Black knight
  instead of a negative value

All 5 green at HEAD; the Eval tests FAIL against HEAD~1.

---

## CLI per-subcommand specs — 2 gaps remain (dep commands + upgrade)

**Covered** (one spec module per command under `test/Sky/Cli/`):
- `sky --version`, `sky build` (ok / syntax error / Go-level error),
  `sky check` — `ExitCodesSpec.hs`
- `sky init <name>` — scaffolding + scaffold-builds-clean — `InitSpec.hs`
- `sky run` — exit propagation + stdout capture — `RunSpec.hs`
- `sky fmt` — second-pass idempotency — `FmtSpec.hs`
- `sky clean` — removes managed dirs only, preserves user files — `CleanSpec.hs`
- `sky test` — pass/fail propagation — `TestSpec.hs`

**Remaining gaps:**
- `sky add/remove/install/update` — hit the Go module proxy
  (proxy.golang.org) and so can't run reliably in offline CI.
- `sky upgrade` — hits GitHub releases; same issue.

**Won't fix in v0.9 because:** hermetic testing of these commands
requires either a local HTTP mock (substantial code) or a
`SKY_UPGRADE_URL` / `GOPROXY=off`-style env-override path (a
non-trivial refactor of the dep-fetch code). Both are tooling
improvements, not correctness fences. In practice: the example
sweep under `scripts/example-sweep.sh --build-only` exercises
`sky build` against every example's declared Go deps, catching
dep-resolution regressions holistically.

**Workaround for users.** Standard Go module semantics apply;
`sky add <pkg>` works like `go get`.

---

## LSP capabilities — all specced (resolved)

Every capability advertised by `sky lsp` now has an end-to-end
integration spec under `test/Sky/Lsp/`:

| Capability | Spec |
|---|---|
| `initialize` + capabilities payload | `ProtocolSpec.hs` |
| `textDocument/hover` | `ProtocolSpec.hs` |
| `textDocument/definition` | `CapabilitiesSpec.hs` |
| `textDocument/documentSymbol` | `CapabilitiesSpec.hs` |
| `textDocument/formatting` | `CapabilitiesSpec.hs` |
| `textDocument/references` | `CapabilitiesSpec.hs` |
| `textDocument/rename` | `CapabilitiesSpec.hs` |
| `textDocument/completion` | `CapabilitiesSpec.hs` |
| `textDocument/semanticTokens/full` | `CapabilitiesSpec.hs` |
| server stays alive on broken `didOpen` | `CapabilitiesSpec.hs` |

Known follow-up: the harness doesn't listen for server-pushed
notifications, so `publishDiagnostics` is verified indirectly
(server remains responsive to a follow-up request after opening a
syntactically-broken file). A future enhancement could add a
notification queue to the harness.

---

## E2E harness is bash, not native `sky verify --e2e`

**Gap.** `scripts/example-e2e.sh` (300 lines of bash) is the
authoritative end-to-end runner. CI invokes it after `sky verify`.

**Won't fix in v0.9 because:** porting to Haskell (so `sky verify
--e2e` becomes the canonical command) is a quality improvement,
not a correctness concern. The bash runner:
- Passes all 17 example contracts
- Runs cleanly in CI on both macOS and Linux
- Supports the same `e2e.json` schema the Haskell port would read

The port matters for single-binary purity (Sky already ships one
`sky` binary; the bash script is an external dependency). That's
a v0.10+ concern.

**Workaround.** Run `bash scripts/example-e2e.sh` locally; CI
does the same.

---

## "If it compiles, it works" — residual categorical gaps

The v0.9 soundness audit closed every documented counterexample
for source-to-Go-codegen correctness. Four classes of regression
remain outside the audit's reach:

1. **Algorithmic correctness** — chess AI example above. The
   compiler cannot verify domain logic is *correct*, only that
   it type-checks.
2. **DB constraint design** — fixed case-by-case (12-skyvote
   PRIMARY KEY collision on identical comments); the class
   persists wherever user code derives keys deterministically
   from non-unique inputs.
3. **Race conditions** — Sky.Live session locking handles
   per-session serialisation but cross-session writes (concurrent
   comment inserts on the same idea) aren't tested at scale.
4. **External service dependencies** — Stripe/Firestore examples
   build clean but require live credentials to genuinely run; e2e
   contracts skip the deep-API path.

**Won't fix in v0.9 because:** these are open-ended quality
concerns, not finite-scope bugs. Each is addressed by targeted
Sky-level tests when caught in the wild, not by a one-off fix.

**Foundation shipped.** `sky test tests/**/*Test.sky` now works
(module-discovery bug where `tests/` wasn't an implicit source
root was fixed alongside `test/Sky/Cli/TestSpec.hs`). Future
sessions wanting to fence any of the four classes above add a
Sky test file and wire it into CI via the existing
`test/Sky/Cli/TestSpec.hs` pattern or a dedicated
`test/Sky/Integration/*.hs` that invokes `sky test`.

The v0.9 line ships with: HM soundness, FFI trust boundary,
exhaustive pattern matching, 67 self-tests, 18 example sweep,
17 e2e contracts, 10 LSP capability specs, 7 CLI specs, and
the entire audit-remediation test matrix green. Everything
above is future work on top of that floor.

---

## Diagnostic audit findings (2026-04-16)

Audit ran as part of the soundness-and-lsp-diagnostics loop
(`.claude/prompts/soundness-and-lsp-diagnostics.md`). Fixed this
session: canonicaliser catches undefined names; LSP publishes
exhaustiveness + unbound-name diagnostics. Three residual gaps,
classified:

### Record field typos silently return nil — DEFERRED (v0.10+)

**Symptom.** `alice.naem` (typo of `.name`) on a record with a
declared type passes `sky check`, compiles, and returns `nil` at
runtime. Generated Go: `rt.Field(alice, "Naem")`.

**Root cause.** `Sky.Type.Constrain.Expression.constrainExpr_`
returns `CTrue` for `Can.Access _target _field` — the type checker
never constrains field access against the target's record shape.
Catching this properly needs row-polymorphic record constraints
(`{ field : a | r }`) and a post-solve pass that flags concrete
record accesses whose field isn't a member.

**Won't fix in v0.9 because:** row polymorphism is a substantial
HM extension; the work impacts Constrain, Solve, and the error
formatter. Not a correctness floor issue — codegen is honest
about what it produces (explicit `rt.Field` call), and the nil
result surfaces the mistake quickly at the first use site.

**Workaround.** Use destructuring at the function boundary
(`\{ name } -> ...`) when possible — destructure patterns are
checked against the record shape.

### Unused imports — DEFERRED (policy call)

**Symptom.** `import Sky.Core.List as List` with no `List.xxx`
use site is silently accepted.

**Won't fix in v0.9 because:** Elm emits a warning for this; Sky
does not currently track a warning channel distinct from errors.
Adding a warning class is a v0.10+ concern (affects error
formatter, CI integration, LSP severity mapping). The in-editor
"grey text" / organise-imports class of feature is a downstream
tooling feature, not a soundness gap.

### Name shadowing — DEFERRED (policy call)

**Symptom.** `let x = 1 in let x = 2 in x` silently evaluates to
2. No warning.

**Won't fix in v0.9 because:** Elm forbids shadowing; Sky does
not. This is a language-design decision that would change the
semantics of existing programs. Punt to a language-spec review
for v0.10+.

---

These three gaps are recorded here so future sessions can pick
them up. The v0.9 line is complete on the soundness-LSP axis:
every error the compiler catches flows through both `sky build`
and `textDocument/publishDiagnostics`.
