# Std.Ui Rust-Parity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `Std.Ui` render byte-identical HTML on `--target rust` vs the Go backend, unlocking the Live Std.Ui examples (19-skyforum, 26-ui-showcase, 37, 38).

**Architecture:** Corpus-driven bottom-up. A render-diff harness (`scripts/ui-parity.sh`) builds tiny per-primitive Sky fixtures (`main = Io.writeStdout (Html.toString (Ui.layout [] view))`) on both backends and byte-diffs stdout. Each mismatch/crash is root-cause-fixed in Layer 1 (Rust codegen, `src/Sky/Generate/Rust/Builder/*`) or Layer 2 (Rust runtime serializer, `runtime-rust/src/sky_runtime/live/html.rs`) to match Go. The four examples are the integration gate.

**Tech Stack:** Haskell (GHC 9.6, the Sky compiler / Rust codegen), Rust (the `sky_runtime` crate), bash (the harness), Sky (the fixtures). Go is the reference and is NEVER modified.

---

## Conventions for every task

- **Build env (always):** `export PATH="$HOME/.ghcup/bin:$PATH"` before any `cabal`; `export CARGO_TARGET_DIR=$HOME/.cache/sky-rust-target RUSTC_WRAPPER=sccache` before any Rust build; use `SKY=$(cabal list-bin exe:sky)` (the symlink `sky-out/sky` points at it — do NOT `sky build` from the repo root).
- **Codegen edits** (`src/Sky/Generate/Rust/**`, `src/Sky/Build/**`) require `cabal build exe:sky` to take effect. **Runtime edits** (`runtime-rust/src/sky_runtime/**`) are copied into the generated project at `sky build` — no cabal rebuild needed.
- **Verify a cabal build really succeeded:** `cabal build exe:sky 2>&1 | grep -iE "error:|rror: \[GHC|Linking"` — a bare `| tail` hides `command not found`.
- **Regression gate before EVERY commit:** `SKY_BIN=$(cabal list-bin exe:sky) bash scripts/rust-sweep.sh` must report **20 in-scope build, zero failing**. Never regress the conquered set.
- **Root cause only.** Add the correct emitter arm — never a `_ ->` catch-all (project AST-walker discipline). Never touch the Go backend.
- **Commit cadence:** per tier / per integration example, after a clean sweep.

---

## File Structure

- Create `scripts/ui-parity.sh` — the render-diff runner (build Go+Rust per fixture, byte-diff stdout).
- Create `tests/ui-parity/harness/sky.toml` + `tests/ui-parity/harness/src/` — a single reusable mini-project; the runner copies each fixture into `src/Main.sky` so the warm `.skycache` makes per-fixture rebuilds fast.
- Create `tests/ui-parity/corpus/T0-*.sky … T5-*.sky` — the fixtures (complete `module Main` files).
- Create `tests/ui-parity/golden/<fixture>.html` — committed Go reference output (the goldens).
- Modify `src/Sky/Generate/Rust/Builder/ExprEmitter.hs` (and siblings as gaps surface) — Layer 1.
- Modify `runtime-rust/src/sky_runtime/live/html.rs` (and siblings) — Layer 2.
- Modify `scripts/rust-sweep.sh:26` (`OUT_OF_SCOPE`) — drop 19/26/37/38 at the integration gate.
- Modify `runtime-rust/README.md` + `runtime-rust/docs/rust-example-conquest-registry.md` — final docs.

---

## Task 1: Render-diff harness scaffold

**Files:**
- Create: `tests/ui-parity/harness/sky.toml`
- Create: `tests/ui-parity/harness/src/Main.sky` (placeholder, overwritten per fixture)
- Create: `tests/ui-parity/corpus/T0-text.sky`
- Create: `scripts/ui-parity.sh`

- [ ] **Step 1: Write the harness project sky.toml**

`tests/ui-parity/harness/sky.toml`:
```toml
name = "ui-parity"
version = "0.1.0"
entry = "src/Main.sky"

[source]
root = "src"
```

- [ ] **Step 2: Write the first T0 fixture (the failing case)**

`tests/ui-parity/corpus/T0-text.sky`:
```elm
module Main exposing (main)

import Sky.Core.Prelude exposing (..)
import Sky.Core.Io as Io
import Std.Ui as Ui
import Std.Html as Html


main =
    Io.writeStdout (Html.toString (Ui.layout [] view))


view : Ui.Element msg
view =
    Ui.text "hello"
```

- [ ] **Step 3: Write the runner `scripts/ui-parity.sh`**

```bash
#!/usr/bin/env bash
# Render-diff harness: build each corpus fixture on Go AND Rust, byte-diff stdout.
# Go is the reference (golden). Usage:
#   scripts/ui-parity.sh                 # diff every fixture against committed goldens
#   scripts/ui-parity.sh --update-golden # (re)capture Go output as the golden
#   scripts/ui-parity.sh T2-font-size    # one fixture
set -uo pipefail
cd "$(dirname "$0")/.."
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$HOME/.cache/sky-rust-target}"
export RUSTC_WRAPPER="${RUSTC_WRAPPER:-sccache}"
SKY="${SKY_BIN:-$PWD/sky-out/sky}"
H="tests/ui-parity/harness"; CORPUS="tests/ui-parity/corpus"; GOLD="tests/ui-parity/golden"
mkdir -p "$GOLD"
UPDATE=0; FILTER=""
for a in "$@"; do case "$a" in --update-golden) UPDATE=1;; *) FILTER="$a";; esac; done

build_run() { # $1=go|rust -> stdout (or empty on failure); writes nothing else
  ( cd "$H" && rm -rf sky-out .skycache .skydeps ) >/dev/null 2>&1
  if [ "$1" = go ]; then
    ( cd "$H" && timeout 300 "$SKY" build src/Main.sky ) >/tmp/uip-build.log 2>&1 || return 1
    ( cd "$H" && ./sky-out/app ) 2>/dev/null
  else
    ( cd "$H" && timeout 300 "$SKY" build src/Main.sky --target rust ) >/tmp/uip-build.log 2>&1 || return 1
    ( cd "$H" && cargo build --release --manifest-path sky-out/Rust/Cargo.toml ) >/tmp/uip-cargo.log 2>&1 || return 1
    find "$H/sky-out/Rust/target/release" -maxdepth 1 -type f -executable | head -1 | xargs -r -I{} {} 2>/dev/null
  fi
}

pass=0; fail=0; failed=()
for f in "$CORPUS"/*.sky; do
  name=$(basename "$f" .sky); [ -n "$FILTER" ] && [ "$name" != "$FILTER" ] && continue
  cp "$f" "$H/src/Main.sky"
  if [ "$UPDATE" = 1 ]; then
    go_out=$(build_run go) || { echo "GOLDEN-FAIL(go) $name (see /tmp/uip-build.log)"; fail=$((fail+1)); continue; }
    printf '%s' "$go_out" > "$GOLD/$name.html"; echo "golden $name"; continue
  fi
  [ -f "$GOLD/$name.html" ] || { echo "NO-GOLDEN $name (run --update-golden)"; fail=$((fail+1)); failed+=("$name"); continue; }
  rust_out=$(build_run rust) || { echo "RUST-BUILD-FAIL $name (see /tmp/uip-build.log /tmp/uip-cargo.log)"; fail=$((fail+1)); failed+=("$name"); continue; }
  if [ "$rust_out" = "$(cat "$GOLD/$name.html")" ]; then echo "PASS $name"; pass=$((pass+1));
  else echo "DIFF $name:"; diff <(cat "$GOLD/$name.html") <(printf '%s' "$rust_out") | head -20; fail=$((fail+1)); failed+=("$name"); fi
done
echo "---- ui-parity: $pass pass / $fail fail ----"
[ ${#failed[@]} -gt 0 ] && echo "failed: ${failed[*]}"
[ "$fail" -eq 0 ]
```

- [ ] **Step 4: Make it executable + capture the T0 golden from Go**

Run:
```bash
chmod +x scripts/ui-parity.sh
SKY_BIN=$(export PATH="$HOME/.ghcup/bin:$PATH"; cabal list-bin exe:sky) scripts/ui-parity.sh --update-golden T0-text
```
Expected: prints `golden T0-text`; `tests/ui-parity/golden/T0-text.html` now contains Go's rendered HTML (a `<div>…hello…</div>` page wrapper). If `GOLDEN-FAIL(go)`, the fixture has a Sky error — fix the fixture first.

- [ ] **Step 5: Run the harness on Rust — verify it FAILS at the known crash**

Run:
```bash
SKY_BIN=$(export PATH="$HOME/.ghcup/bin:$PATH"; cabal list-bin exe:sky) scripts/ui-parity.sh T0-text
```
Expected: `RUST-BUILD-FAIL T0-text`; `/tmp/uip-build.log` ends with `ExprEmitter.hs:(283,32)-(320,29): Non-exhaustive patterns in case`. This is the discovery artifact for Task 2.

- [ ] **Step 6: Commit the harness**

```bash
git add scripts/ui-parity.sh tests/ui-parity/harness tests/ui-parity/corpus/T0-text.sky tests/ui-parity/golden/T0-text.html
git commit -m "test(rust): Std.Ui render-diff harness + T0-text fixture (captures the ExprEmitter crash)"
```

---

## Task 2: T0 smoke — foundational Std.Ui codegen (REVISED per Task-1 discovery)

> **Plan correction (2026-06-11):** the original premise (a `collectVarLocals`
> non-exhaustive crash at `ExprEmitter.hs:283-320`) was **stale** — measured on
> 26-ui-showcase before a compiler rebuild. With the current binary the trivial
> `T0-text` fixture (`Ui.text "hello"`) lowers fine and the crash does NOT fire;
> instead `cargo build` reports **~140 Rust errors** dominated by three
> *systematic, foundational* codegen gaps (each likely one root-cause fix, not N
> individual ones). This task closes them so `T0-text` byte-matches Go. The
> `collectVarLocals` arm fix may still be needed later (a richer fixture can
> trigger it); add it then, with the fixture that surfaces it.

**Files:**
- Modify: `src/Sky/Generate/Rust/Builder/*` (ADT/type emitter + constructor emitter)
- Modify: `runtime-rust/src/sky_runtime/live/*` (provide `Attribute`/`Event`/`Html` types + `html_render_` if missing)
- Create: `tests/ui-parity/corpus/T0-el.sky`, `tests/ui-parity/corpus/T0-empty.sky`

The three foundational gaps (from `/tmp/uip-build.log` + a fresh `cargo build` of
the `T0-text` harness output `tests/ui-parity/harness/sky-out/Rust/`):

- [ ] **Step 1 — Recursive ADT boxing (E0072 ×1, E0391 cycle ×2).** `StdUiLength`
  (`Length = … | Minimum Int Length | Maximum Int Length`) emits as
  `enum StdUiLength { …, Min(i64, StdUiLength), … }` — infinite size. The Rust ADT
  emitter must `Box<…>` the *recursive back-edges* (fields whose type is the enum
  being defined, directly or via a cycle). Find the union/ADT emitter in
  `src/Sky/Generate/Rust/Builder/TypeEmitter.hs` (or wherever `pub enum` is
  emitted); detect self/mutually-recursive field types and wrap them
  `Box<T>` at the field, with matching `Box::new(...)` at construction and `*`/
  deref at the match sites. Rebuild `cabal build exe:sky`, regen the harness,
  confirm E0072/E0391 are gone.

- [ ] **Step 2 — Polymorphic ADT-constructor type-param inference (E0282 ×73,
  E0283 ×34 — the dominant cluster).** Constructors of a phantom-polymorphic ADT
  emit bare: `StdUiElement::Empty` / `StdUiElement::Text(s)` where Rust cannot
  infer `msg` (rustc's own hint is the turbofish `StdUiElement::<msg>::Empty`).
  Root cause: a nullary/`msg`-free constructor of `Element msg` / `Html msg` /
  `Attribute msg` is emitted without propagating the enclosing function's generic
  `msg`. Fix in the constructor emitter so a phantom-typed constructor either (a)
  carries the enclosing fn's type param (`::<MsgParam>`) when one is in scope, or
  (b) emits an explicit turbofish from the expected type. This is the same
  type-param-scoping machinery used for parametric record aliases (`LowerCtx`
  enclosing-typeParams, the #521 family) — extend it to ADT constructors. One
  systematic fix should clear most of the 107.

- [ ] **Step 3 — Missing types + render kernel (E0412 ×3, E0425 ×5, E0433 ×2,
  E0790/E0609).** `cannot find type Attribute/Event/Html in sky_runtime` and
  `cannot find function html_render_`. Determine whether the Std.Html/Std.Ui
  ADTs (`Html msg`, `Attribute msg`, `Event msg`) should be emitted as user types
  (preferred — they're pure-Sky stdlib ADTs) or provided by `sky_runtime`, and
  make the reference site agree with the definition site. Provide / wire
  `html_render_` (the `htmlRender` kernel — `live/mod.rs:798` already maps the
  name; ensure the function exists and is in scope for generated code). The
  E0609 `no field` + E0308 mismatches are likely downstream of Steps 1-2; re-check
  after them.

- [ ] **Step 4 — Iterate `T0-text` to a clean cargo build, then byte-match.**
  After Steps 1-3, `SKY_BIN=$(cabal list-bin exe:sky) scripts/ui-parity.sh T0-text`
  should reach `PASS` or `DIFF`. Drive any `DIFF` to `PASS`: Layer-1 (structure)
  → `src/Sky/Generate/Rust/Builder/*`; Layer-2 (style/attr/escaping bytes) →
  `runtime-rust/src/sky_runtime/live/html.rs` to match Go's `HtmlRender`. The Go
  golden is `<div style="min-height: 100vh; display: flex; flex-direction: column;"><style>html,body{min-height:100%;margin:0;padding:0}</style>hello</div>`.

- [ ] **Step 5 — Add the rest of T0 + goldens.** `tests/ui-parity/corpus/T0-el.sky`
  (`view = Ui.el [] (Ui.text "x")`) and `T0-empty.sky` (`view = Ui.none`). Capture
  goldens (`--update-golden`), drive both to `PASS`.

- [ ] **Step 6 — Regression gate + commit.**
```bash
SKY_BIN=$(cabal list-bin exe:sky) bash scripts/rust-sweep.sh   # MUST be 20 in-scope, 0 failing
git add src/Sky/Generate/Rust/Builder runtime-rust/src/sky_runtime/live tests/ui-parity/corpus/T0-*.sky tests/ui-parity/golden/T0-*.html
git commit -m "feat(rust): foundational Std.Ui codegen (recursive-box + poly-ctor msg + Html types/kernel) — T0 byte-identical"
```

> **Note for the implementer:** Steps 1-3 are interdependent foundational
> codegen — approach with a capable model and verify each against a fresh
> `cargo build` of the regenerated harness. If Step 2 (the 107-error cluster)
> proves to be more than one root cause, report `DONE_WITH_CONCERNS` after
> clearing what one systematic fix covers, and the controller will sub-slice it.

---

## Task 3: T1 layout (row / column / el / spacing / padding / alignment)

**Files:**
- Create: `tests/ui-parity/corpus/T1-row.sky`, `T1-column.sky`, `T1-spacing.sky`, `T1-padding-xy.sky`, `T1-align.sky`
- Modify (as gaps surface): `src/Sky/Generate/Rust/Builder/*`, `runtime-rust/src/sky_runtime/live/html.rs`

- [ ] **Step 1: Write the T1 fixtures**

Each is the Task-1 scaffold (`module Main`, the `main`, a typed `view : Ui.Element msg`) with these views:
```elm
-- T1-row.sky
view = Ui.row [ Ui.spacing 8 ] [ Ui.text "a", Ui.text "b" ]
-- T1-column.sky
view = Ui.column [ Ui.padding 16 ] [ Ui.text "a", Ui.text "b" ]
-- T1-spacing.sky
view = Ui.row [ Ui.spacing 12 ] [ Ui.el [] (Ui.text "x"), Ui.el [] (Ui.text "y") ]
-- T1-padding-xy.sky
view = Ui.el [ Ui.paddingXY 8 16 ] (Ui.text "p")
-- T1-align.sky
view = Ui.row [ Ui.spacing 4 ] [ Ui.el [ Ui.alignRight ] (Ui.text "r"), Ui.el [ Ui.centerX ] (Ui.text "c") ]
```

- [ ] **Step 2: Capture goldens from Go**

Run: `for n in T1-row T1-column T1-spacing T1-padding-xy T1-align; do SKY_BIN=$(cabal list-bin exe:sky) scripts/ui-parity.sh --update-golden $n; done`
Expected: `golden T1-*` for each. Any `GOLDEN-FAIL(go)` = a fixture error; fix the fixture.

- [ ] **Step 3: Run on Rust, fix each gap to PASS**

Run: `SKY_BIN=$(cabal list-bin exe:sky) scripts/ui-parity.sh` (runs all). For each `DIFF`/`RUST-BUILD-FAIL`: root-cause it (Layer 1 if a Haskell crash or wrong structure; Layer 2 if a style/attr byte diff vs Go's `HtmlRender` — note `style="…"` declaration order is Go's emission order), fix, re-run the single fixture (`scripts/ui-parity.sh T1-row`) until PASS. Repeat until all T0+T1 PASS.

- [ ] **Step 4: Regression gate + commit**

```bash
SKY_BIN=$(cabal list-bin exe:sky) bash scripts/rust-sweep.sh   # 20 / 0
git add src/Sky/Generate/Rust/Builder tests/ui-parity/corpus/T1-*.sky tests/ui-parity/golden/T1-*.html runtime-rust/src/sky_runtime/live 2>/dev/null
git commit -m "feat(rust): Std.Ui T1 layout (row/column/spacing/padding/align) byte-identical"
```

---

## Task 4: T2 styling (Background / Border / Font inline styles)

**Files:**
- Create: `tests/ui-parity/corpus/T2-bg-color.sky`, `T2-border.sky`, `T2-font-size.sky`, `T2-font-weight.sky`, `T2-rgb.sky`
- Modify (as gaps surface): `runtime-rust/src/sky_runtime/live/html.rs` (likely the dominant Layer-2 tier), `src/Sky/Generate/Rust/Builder/*`

- [ ] **Step 1: Write the T2 fixtures**

Add the imports each needs (`import Std.Ui.Background as Background`, `Std.Ui.Border as Border`, `Std.Ui.Font as Font`) to the scaffold; views:
```elm
-- T2-bg-color.sky
view = Ui.el [ Background.color (Ui.rgb 255 102 0) ] (Ui.text "bg")
-- T2-border.sky
view = Ui.el [ Border.width 2, Border.rounded 4, Border.color (Ui.rgb 0 0 0) ] (Ui.text "b")
-- T2-font-size.sky
view = Ui.el [ Font.size 24 ] (Ui.text "f")
-- T2-font-weight.sky
view = Ui.el [ Font.bold ] (Ui.text "w")
-- T2-rgb.sky
view = Ui.el [ Font.color (Ui.rgb 16 32 48), Background.color (Ui.rgb 240 240 240) ] (Ui.text "rgb")
```

- [ ] **Step 2: Capture goldens, run on Rust, fix to PASS**

`for n in T2-bg-color T2-border T2-font-size T2-font-weight T2-rgb; do SKY_BIN=$(cabal list-bin exe:sky) scripts/ui-parity.sh --update-golden $n; done` then `SKY_BIN=$(cabal list-bin exe:sky) scripts/ui-parity.sh`. The expected dominant work here is Layer 2: `style="background-color:rgb(255,102,0);…"` must match Go byte-for-byte — colour formatting (`rgb(r,g,b)` spacing), declaration order, and units. Compare against `runtime-go/rt/live.go` `HtmlRender` + the Std.Ui `Background`/`Border`/`Font` Sky modules (they emit the style strings; the serializer joins them). Fix `html.rs` until all T0–T2 PASS.

- [ ] **Step 3: Regression gate + commit**

```bash
SKY_BIN=$(cabal list-bin exe:sky) bash scripts/rust-sweep.sh   # 20 / 0
git add tests/ui-parity src/Sky/Generate/Rust/Builder runtime-rust/src/sky_runtime/live 2>/dev/null
git commit -m "feat(rust): Std.Ui T2 styling (Background/Border/Font) byte-identical"
```

---

## Task 5: T3 sized elements (button / link / image / input / form)

**Files:**
- Create: `tests/ui-parity/corpus/T3-button.sky`, `T3-link.sky`, `T3-image.sky`, `T3-input.sky`, `T3-form.sky`
- Modify (as gaps surface): `src/Sky/Generate/Rust/Builder/*`, `runtime-rust/src/sky_runtime/live/html.rs`

- [ ] **Step 1: Write the T3 fixtures**

These need a `Msg` type (events). Use a minimal one (`type Msg = Clicked | Changed String`) and `import Std.Ui.Input as Input`:
```elm
-- T3-button.sky  (view : Ui.Element Msg)
view = Ui.button [] { onPress = Just Clicked, label = Ui.text "go" }
-- T3-link.sky
view = Ui.link [] { url = "/x", label = Ui.text "L" }
-- T3-image.sky
view = Ui.image [] { src = "/a.png", description = "alt" }
-- T3-input.sky
view = Input.text [] { onChange = Changed, text = "v", placeholder = Nothing, label = Input.labelHidden "n" }
-- T3-form.sky
view = Ui.form [ Ui.onSubmit Clicked ] [ Ui.text "f" ]
```
(Cross-check the exact `Input.text` record shape against `sky-stdlib/Std/Ui/Input.sky` before writing — adjust field names to match. The harness `main` ignores `Msg`, so events render as wired attrs, not dispatched.)

- [ ] **Step 2: Capture goldens, run on Rust, fix to PASS**

Same loop. Expect both layers: void-element handling for `<input>`/`<img>` (self-closing + the v0.15.57 sibling-`<style>` hoist for pseudo-classes on void elements) in `html.rs`, and any event-attribute / record-lowering gaps in codegen. Drive all T0–T3 to PASS.

- [ ] **Step 3: Regression gate + commit**

```bash
SKY_BIN=$(cabal list-bin exe:sky) bash scripts/rust-sweep.sh   # 20 / 0
git add tests/ui-parity src/Sky/Generate/Rust/Builder runtime-rust/src/sky_runtime/live 2>/dev/null
git commit -m "feat(rust): Std.Ui T3 sized elements (button/link/image/input/form) byte-identical"
```

---

## Task 6: T4 advanced (nearby / pseudo-classes / media-query / transition / animation / grid / Lazy / Keyed)

**Files:**
- Create: `tests/ui-parity/corpus/T4-nearby.sky`, `T4-hover.sky`, `T4-breakpoint.sky`, `T4-transition.sky`, `T4-animation.sky`, `T4-grid.sky`, `T4-lazy.sky`, `T4-keyed.sky`
- Modify (as gaps surface): `runtime-rust/src/sky_runtime/live/html.rs` (the `<style data-sky-pc/mq/tr/anim>` blocks), `src/Sky/Generate/Rust/Builder/*`

- [ ] **Step 1: Write the T4 fixtures**

One primitive each (imports as needed: `Std.Ui.Transition`, `Std.Ui.Animation`, `Std.Ui.Grid`, `Std.Ui.Lazy`, `Std.Ui.Keyed`):
```elm
-- T4-nearby.sky
view = Ui.el [ Ui.above (Ui.text "tip") ] (Ui.text "anchor")
-- T4-hover.sky
view = Ui.el [ Background.hoverColor (Ui.rgb 50 50 200) ] (Ui.text "h")
-- T4-breakpoint.sky
view = Ui.breakpoint Ui.mobile [ Background.color (Ui.rgb 18 18 24) ] (Ui.text "m")
-- T4-transition.sky  (Transition.attribute [ Transition.property "background-color", Transition.duration 200 ])
-- T4-animation.sky   (a small Animation.attribute spec)
-- T4-grid.sky        (Ui.gridColumns 3 over 3 Ui.text children)
-- T4-lazy.sky        (Lazy.lazy <fn> <arg>)
-- T4-keyed.sky       (Keyed.column over [("k", Ui.text "x")])
```
(Cross-check each module's exact public signatures in `sky-stdlib/Std/Ui/<Module>.sky` before writing.)

- [ ] **Step 2: Capture goldens, run on Rust, fix to PASS**

Same loop. The dominant work is Layer 2: the sky-id-scoped `<style data-sky-pc="…">` / `data-sky-mq` / `data-sky-tr` / `data-sky-anim` blocks must match Go's emission exactly (selector text, `@media (hover:hover)` auto-wrap, `@media (prefers-reduced-motion…)` wrap, keyframe-name sky-id suffixing). Compare against `runtime-go/rt/live.go`. Drive all T0–T4 to PASS.

- [ ] **Step 3: Regression gate + commit**

```bash
SKY_BIN=$(cabal list-bin exe:sky) bash scripts/rust-sweep.sh   # 20 / 0
git add tests/ui-parity src/Sky/Generate/Rust/Builder runtime-rust/src/sky_runtime/live 2>/dev/null
git commit -m "feat(rust): Std.Ui T4 advanced (nearby/pseudo/media/transition/animation/grid/lazy/keyed) byte-identical"
```

---

## Task 7: T5 semantic (Region landmarks / Responsive)

**Files:**
- Create: `tests/ui-parity/corpus/T5-region-heading.sky`, `T5-region-nav.sky`, `T5-responsive.sky`
- Modify (as gaps surface): `runtime-rust/src/sky_runtime/live/html.rs`, `src/Sky/Generate/Rust/Builder/*`

- [ ] **Step 1: Write the T5 fixtures**

`import Std.Ui.Region as Region`:
```elm
-- T5-region-heading.sky
view = Ui.el [ Region.heading 1 ] (Ui.text "H")
-- T5-region-nav.sky
view = Ui.row [ Region.navigation ] [ Ui.text "n" ]
-- T5-responsive.sky  (a Std.Ui.Responsive.classifyDevice/adapt-driven view; cross-check the module)
```

- [ ] **Step 2: Capture goldens, run on Rust, fix to PASS**

Same loop. Layer 2: Region landmarks route to `<h1..h6>`/`<main>`/`<nav>`/`<aside>`/`<footer>` + `aria-*` — verify the tag mapping in `html.rs` matches Go. Drive all T0–T5 to PASS.

- [ ] **Step 3: Regression gate + commit**

```bash
SKY_BIN=$(cabal list-bin exe:sky) bash scripts/rust-sweep.sh   # 20 / 0
git add tests/ui-parity src/Sky/Generate/Rust/Builder runtime-rust/src/sky_runtime/live 2>/dev/null
git commit -m "feat(rust): Std.Ui T5 semantic (Region/Responsive) byte-identical — corpus complete"
```

---

## Task 8: Integration gate — 26-ui-showcase

**Files:**
- Modify (as gaps surface): `src/Sky/Generate/Rust/Builder/*`, `runtime-rust/src/sky_runtime/live/html.rs`

- [ ] **Step 1: Build 26-ui-showcase on Rust**

```bash
export CARGO_TARGET_DIR=$HOME/.cache/sky-rust-target RUSTC_WRAPPER=sccache
SKY=$(export PATH="$HOME/.ghcup/bin:$PATH"; cabal list-bin exe:sky)
(cd examples/26-ui-showcase && rm -rf sky-out .skycache .skydeps && "$SKY" build src/Main.sky --target rust 2>&1 | tail -20)
```
Expected: with the corpus complete, this should lower; any remaining crash/`E0xxx` is an interaction the unit corpus missed — root-cause-fix it and **add a minimal corpus fixture reproducing it** (so it stays gated), then re-run `scripts/ui-parity.sh`.

- [ ] **Step 2: Byte-match the rendered page vs Go**

26-ui-showcase is a Live app. Run it on both backends on a fixed port (`SKY_LIVE_PORT=… ./app &`), `curl -s http://127.0.0.1:$PORT/` on each, and `diff` the page HTML. Drive Layer-1/Layer-2 fixes until the `<body>` content matches (the page wrapper's sky-id/inline-JS bytes are runtime-identical by construction; if a wrapper byte legitimately differs, document the normalization in the spec's "Risks" policy).

- [ ] **Step 3: Regression gate + commit**

```bash
SKY_BIN=$(cabal list-bin exe:sky) bash scripts/rust-sweep.sh   # 20 / 0 (26 still in OUT_OF_SCOPE here)
git add src/Sky/Generate/Rust/Builder runtime-rust/src/sky_runtime/live tests/ui-parity 2>/dev/null
git commit -m "feat(rust): 26-ui-showcase renders byte-identical on --target rust"
```

---

## Task 9: Integration gate — 19-skyforum

**Files:**
- Modify (as gaps surface): `src/Sky/Generate/Rust/Builder/*`, `runtime-rust/src/sky_runtime/live/html.rs`

- [ ] **Step 1: Build + render-match 19-skyforum on Rust**

Same procedure as Task 8 (build; run both backends; `curl` + `diff` the page). 19-skyforum is the canonical 8-module Std.Ui app (State/Update/View split) — it stresses multi-module Std.Ui lowering. Root-cause every gap; add a corpus fixture for any new primitive interaction.

- [ ] **Step 2: Regression gate + commit**

```bash
SKY_BIN=$(cabal list-bin exe:sky) bash scripts/rust-sweep.sh   # 20 / 0
git add src/Sky/Generate/Rust/Builder runtime-rust/src/sky_runtime/live tests/ui-parity 2>/dev/null
git commit -m "feat(rust): 19-skyforum renders byte-identical on --target rust"
```

---

## Task 10: Integration gate — 37 + 38, sweep scope, docs

**Files:**
- Modify: `scripts/rust-sweep.sh:26` (`OUT_OF_SCOPE`)
- Modify: `runtime-rust/README.md`, `runtime-rust/docs/rust-example-conquest-registry.md`

- [ ] **Step 1: Build + render-match 37-composite-live-shop and 38-composite-ui-multibackend**

Same procedure as Task 8 for each. 38 is the multibackend composite — verify the Std.Ui view renders identically (the web path). Root-cause every gap; add corpus fixtures for new interactions.

- [ ] **Step 2: Move the four examples out of OUT_OF_SCOPE**

Edit `scripts/rust-sweep.sh:26` — remove `19`, `26`, `37`, `38` from the `OUT_OF_SCOPE` string. Run the full sweep:
```bash
SKY_BIN=$(cabal list-bin exe:sky) bash scripts/rust-sweep.sh
```
Expected: **24 in-scope build, zero failing** (the prior 20 + 19/26/37/38).

- [ ] **Step 3: Update docs**

In `runtime-rust/docs/rust-example-conquest-registry.md` and `runtime-rust/README.md`, record: Std.Ui web-HTML render parity shipped; 19/26/37/38 now in-scope and byte-identical; the `scripts/ui-parity.sh` corpus is the parity gate; Tui (22–24) + Webview (31) are the next slices.

- [ ] **Step 4: Final gate + commit**

```bash
SKY_BIN=$(cabal list-bin exe:sky) bash scripts/rust-sweep.sh   # 24 / 0
git add scripts/rust-sweep.sh runtime-rust/README.md runtime-rust/docs/rust-example-conquest-registry.md examples 2>/dev/null
git commit -m "feat(rust): Std.Ui web-HTML render parity complete — 19/26/37/38 in-scope (24 build), corpus-gated"
```

---

## Self-review notes (for the implementer)

- **The codegen-fix steps are discovery-driven by design** — the spec's corpus-driven approach means each gap is *found* by a fixture, then root-cause-fixed. The plan gives the exact first fix (Task 2, the `collectVarLocals` arms) and the repeatable loop (write fixture → golden → diff → root-cause Layer-1/Layer-2 → gate → commit) for the rest. When a fix's shape isn't knowable in advance, the fixture that surfaces it IS the spec for that fix.
- **Always add a corpus fixture for any gap an integration example surfaces** (Tasks 8–10) — that keeps the parity gate complete and prevents regressions.
- **Never** add a `_ ->` catch-all to an emitter case, and **never** edit the Go backend or `runtime-go/`.
