# Std.Ui on the Rust Backend — Go-Parity Design

**Date:** 2026-06-11 · **Branch:** `feat/runtime-rust` · **Status:** approved design

**Goal:** Make `Std.Ui` (the typed, no-CSS layout DSL) render with perfect
Go-backend parity on `--target rust`, in idiomatic Rust — verified by
**byte-identical** rendered HTML — unlocking the web/Live Std.Ui examples
(19-skyforum, 26-ui-showcase, 37-composite-live-shop, 38-composite-ui-multibackend).

## Scope

**In scope:** the shared web-HTML render path — `Std.Ui` →
`layout`/`renderElement` → `Std.Html` ADT → `Html.toString` (`htmlRender`
kernel) → inline-styled HTML string — lowered to Rust and byte-matched to Go.
Unlocks the four Live examples above; Webview (31, reuses the Live renderer) is
re-verified opportunistically.

**Out of scope (deliberate follow-on slices):** the Sky.Tui ANSI-cell renderer
(22-tui-stopwatch-ui, 23-tui-todo, 24-tui-kitchen-sink) — a distinct runtime
subsystem (Html → terminal cells), not the HTML path. 25-sky-console is also
deferred (Tui/console surface). Go-package→Rust-FFI examples remain out of scope
per the standing rule.

## Key finding — this is a codegen problem, not a renderer port

`Std.Ui` is **pure Sky source** (~6,300 lines: `Ui.sky` 3,186 + 13 sub-modules).
`layout`/`renderElement` build a `Std.Html` ADT via plain Sky recursion — no
`Ffi.kernel` in the render path. The front-end already passes for the Std.Ui
examples (type-check, monomorphisation across 39 polymorphic callees, HM infer of
1,101 functions all succeed — shared with Go). The Rust **codegen** is what
fails: building 26-ui-showcase currently panics with
`src/Sky/Generate/Rust/Builder/ExprEmitter.hs:(283,32)-(320,29): Non-exhaustive
patterns in case` — Std.Ui exercises a Sky AST expression shape the Rust emitter
has no arm for, before any Rust is written.

## Architecture — three layers, two need work

```
Std.Ui DSL (pure Sky)  ──lower──▶  Rust that builds an Html ADT value
        │                                      │
   [Layer 1: codegen]                          ▼
   src/Sky/Generate/Rust/Builder/*    Html.toString = Ffi.callPure "htmlRender"
                                               │
                                        [Layer 2: serializer]
                                  runtime-rust/.../live/html.rs (html_render_)
                                               │
                                               ▼
                                  inline-styled HTML  ◀── must equal Go HtmlRender byte-for-byte
```

- **Layer 1 — DSL lowering (dominant work).** Close the Rust codegen gaps Std.Ui
  surfaces (starting with the `ExprEmitter` non-exhaustive crash). Same
  root-cause codegen discipline as the example conquests, at the largest /
  most-polymorphic scale. Lands in `src/Sky/Generate/Rust/Builder/*`.
- **Layer 2 — serializer parity.** The Rust runtime already has scaffolding
  (`live/html.rs`, the `htmlRender → html_render_()` kernel, `render_children`).
  Std.Ui's rich output (inline `style=`, void elements, pseudo-class/media-query
  `<style>` blocks) surfaces wherever `html_render_` diverges from Go's
  `runtime-go/rt/live.go` `HtmlRender`. Lands in
  `runtime-rust/src/sky_runtime/live/`.
- **Layer 3 — the harness (new).** Verifies layers 1+2 emit identical bytes.

**The reference is always Go.** Where Rust diverges, fix the Rust side to match
Go's bytes — do not loosen the comparison. Normalization is reserved for
genuinely-idiomatic diffs (float formatting, style-attr iteration order), each
documented with its justification.

## The render-diff harness

The enabler is `Html.toString : Html msg -> String` (a pure
`Ffi.callPure "htmlRender"`), callable from a plain CLI `main` — **no server, no
ports, fully deterministic**:

```elm
-- tests/ui-parity/corpus/02-row-spacing.sky
main = Io.writeStdout (Html.toString (Ui.layout [] view))
view = Ui.row [ Ui.spacing 12, Ui.padding 16 ] [ Ui.text "a", Ui.text "b" ]
```

- **Runner** (`scripts/ui-parity.sh`): per fixture — build on Go → run →
  capture stdout as the **golden**; build on Rust → run → capture stdout;
  `diff` byte-for-byte. Red on any mismatch, naming the minimal failing fixture.
  Runs under the shared `CARGO_TARGET_DIR` + sccache, `-O0` dev builds.
- **Corpus tiers** (drive the bottom-up sequence):
  - **T0 smoke** — `text`, `el`, empty `layout` (clears the crash).
  - **T1 layout** — row, column, el, spacing, padding, alignment.
  - **T2 styling** — Background, Border, Font (inline `style` attrs).
  - **T3 sized** — button, link, image, input, form.
  - **T4 advanced** — nearby (above/below/inFront), pseudo-classes
    (hover/focus/active), media-query/breakpoint, transition/animation, grid,
    Lazy, Keyed.
  - **T5 semantic** — Region (landmarks → `<h1..h6>`/`<main>`/`<nav>`/…),
    Responsive.
- **Integration gate** — 26-ui-showcase (every primitive) → 19-skyforum (real
  8-module app) → 37, 38 (composite). For full-app examples the diff target is
  the Live GET page (Live port override is the `[live]` sky.toml directive,
  confirmed working).

## Workstream A — DSL lowering (Layer 1)

Each corpus tier surfaces codegen gaps in complexity order; each gap → a
root-cause fix in `src/Sky/Generate/Rust/Builder/*`, regression-gated by the
corpus AND the existing 20-example Rust sweep (never regress the conquered set).

Expected gap classes:
- **Non-exhaustive emitter arms** (the current `283-320` crash) — Std.Ui uses
  expression shapes with no Rust arm. Each is a missing pattern → add the correct
  arm; never a `_ ->` catch-all (per the project's AST-walker discipline).
- **Heavy polymorphism** — `Element msg`/`Html msg` thread a type var through
  ~205 declarations. Expect `Foo_R[any]`-cast and generic-param-scoping issues
  (the #521/#261 family, closed for examples, now at Std.Ui scale).
- **Large `case` / list-of-attrs lowering** — `renderElement`'s tag-dispatch
  `case` and `List (Attribute msg)` folding.

Discipline: each fix is the *correct* arm, not a symptom patch; it lands with the
corpus fixture that discovered it as its regression test.

## Workstream B — serializer parity (Layer 2)

Wherever a T2+ fixture's bytes diverge, fix
`runtime-rust/src/sky_runtime/live/html.rs` (`html_render_` + helpers) to match
Go's `HtmlRender`. Parity-sensitive spots: inline `style="…"` declaration
**order** (Go's emission sequence), attribute order, HTML-escaping rules,
void-element self-closing + the sibling-`<style>` hoist for pseudo-classes on
void inputs (v0.15.57), `<style data-sky-pc/mq/tr/anim>` block formatting, and
float/number formatting. The Rust serializer is written idiomatically but
byte-matched to Go.

## Slicing & "done"

One spec, executed as ordered slices (each independently green):
1. **Harness + T0** — `scripts/ui-parity.sh`, corpus scaffold, clear the
   `283-320` crash, smallest fixtures byte-match.
2. **T1–T3** — layout, styling, sized elements byte-match.
3. **T4–T5** — advanced + Region/Responsive byte-match.
4. **Integration** — 26-ui-showcase, then 19-skyforum, 37, 38 build + render
   byte-match (or documented-normalized); these four move out of the sweep's
   `OUT_OF_SCOPE` (`scripts/rust-sweep.sh`).

**Done** = every corpus fixture byte-identical Go==Rust; the four examples build
and render-match; sweep scope updated; `runtime-rust/README.md` + the conquest
registry updated. Webview (31) re-verified opportunistically; Tui (22–24)
explicitly out of this spec.

## Testing & non-regression

- `scripts/ui-parity.sh` is the new gate (corpus byte-diff).
- Every existing invariant holds: the 20-example Rust sweep stays green before
  each commit; `cabal test` FfiGen/Toml/Kernel byte-identity is unaffected
  (Layer 2 touches only the Rust runtime, never Go); the Go backend is never
  altered.
- Commit cadence: per corpus tier / per conquered example, after a clean sweep.

## Risks & open questions

- **`Ui.sky` HM-heap monolith** (CLAUDE.md Limitation #17): the 3,186-line module
  stresses the type-checker — but it already type-checks (front-end shared), so
  this is a lowering/throughput risk, not a correctness blocker.
- **Float / map-iteration-order diffs**: the most likely "semantic not byte"
  escape hatch — policy is fix-Rust-to-match-Go first, normalize only with
  documented justification.
- **Full-app page-diff noise** (sky-ids, inline JS): mitigated by leading with
  pure `Html.toString` corpus fixtures; full-page diffs only at the integration
  gate, comparing stable wrapper bytes.
