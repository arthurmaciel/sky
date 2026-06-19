# Rust Sky.Live P0 + P1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up the "it's alive" slice of Rust Sky.Live — a static `view : Model -> Html Msg` renders byte-correct full HTML (P0), then a counter increments live over SSE through a real TEA loop (P1).

**Architecture:** Bridge `Std.Html`'s `Html/Attribute/Event` ADTs to runtime *generic* enums (`Html<M>` etc.) via a new `msg`-var generic-alias codegen case; render + diff read structure only (no `Msg`); `live_app::<Model,Msg>` is a thin HTTP+SSE front end over the existing `tea.rs` TEA core (SSE patches replace stdout). Reuse Go's patch schema + embedded client verbatim. Go backend untouched — all changes are `target = rust`-gated.

**Tech Stack:** Haskell codegen (`src/Sky/Generate/Rust/*`), Rust runtime crate (`runtime-rust/`), axum + tokio (already deps via the `server` feature), the shipped `tea.rs` (Cmd/Sub/SubManager), serde_json (already a dep).

**Spec:** `runtime-rust/superpowers/specs/2026-06-07-rust-sky-live-design.md`

---

## File structure

**Runtime (new, under `runtime-rust/src/sky_runtime/live/`):**
- `mod.rs` — re-exports; `live_app`; axum mount; the page wrap (`render_page`)
- `html.rs` — `Html<M>` / `Attribute<M>` / `Event<M>` enums; `FormData`; `assign_sky_ids`; `render_html`
- `diff.rs` — `Patch`; `diff<M>(old, new) -> Vec<Patch>`
- `dispatch.rs` — `HandlerIndex`; build-index walk; `resolve(sky_id, event, args) -> Option<M>`
- `sse.rs` — per-session SSE channel type + `hello`/heartbeat framing
- `session.rs` — `LiveSession<Model,Msg>`; in-memory `LiveStore`
- `client.js` — Go client, ported verbatim (P1)

**Runtime (modified):**
- `runtime-rust/src/sky_runtime/mod.rs` — gate `pub mod live;` under the `server` feature
- `runtime-rust/Cargo.toml` — `live` feature (already-present axum/tokio/serde_json)

**Codegen (modified):**
- `src/Sky/Generate/Rust/Builder.hs` — the `msg`-var generic-alias `unionToRustTypeDef` case; `runtimeOpaqueTypes` entries for `Html`/`Attribute`/`Event`; `live_app` turbofish pin; usage detection (`usesLive`)
- `src/Sky/Generate/Rust/Project.hs` — emit `pub mod live; pub use live::*;` when `usesLive`

**Example (new):**
- `examples/rust/27-live-static/` — P0 gate (static render)
- `examples/rust/28-live-counter/` — P1 gate (live counter)

---

## Conventions for this plan

- **Build the compiler:** `cabal build exe:sky` then `cabal install --overwrite-policy=always --installdir=./sky-out --install-method=copy exe:sky`. Wait for `Copying 'sky'`.
- **mem-guard MUST be running** (`pgrep -f mem-guard.sh` or relaunch per CLAUDE.md).
- **Runtime unit tests:** `cd runtime-rust && cargo test --features server <name>`.
- **Example build/run:** `cd examples/rust/NN-… && rm -rf sky-out .skycache && /full/path/sky-out/sky run src/Main.sky` (servers: `sky build` + curl).
- All `git commit` use the trailer `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.

---

# PHASE P0 — Bridge foundation + static render

## Task 1: `Html<M>` / `Attribute<M>` / `Event<M>` runtime enums

**Files:**
- Create: `runtime-rust/src/sky_runtime/live/html.rs`
- Modify: `runtime-rust/src/sky_runtime/live/mod.rs` (create), `runtime-rust/src/sky_runtime/mod.rs`
- Modify: `runtime-rust/Cargo.toml`

- [ ] **Step 1: Add the `live` feature to Cargo.toml**

In `runtime-rust/Cargo.toml` under `[features]`, add (axum/tokio/serde_json already exist as deps of `server`):

```toml
live = ["server", "http_client"]
```

and add `"live"` to the `full` feature list.

- [ ] **Step 2: Create the module skeleton**

Create `runtime-rust/src/sky_runtime/live/mod.rs`:

```rust
//! Sky.Live on the Rust backend — HTTP-first render + SSE patch loop.
//! Generic over the app's (Model, Msg); no `any`, static dispatch only.
pub mod html;
pub use html::*;
```

In `runtime-rust/src/sky_runtime/mod.rs`, after the `server` block, add:

```rust
#[cfg(feature = "live")]
pub mod live;
#[cfg(feature = "live")]
pub use live::*;
```

- [ ] **Step 3: Write the failing test for the enum shape**

Create `runtime-rust/src/sky_runtime/live/html.rs` with only the test first:

```rust
#[cfg(test)]
mod tests {
    use super::*;
    #[derive(Clone, Debug, PartialEq)]
    enum Msg { Inc }

    #[test]
    fn html_tree_constructs() {
        let t: Html<Msg> = Html::Element(
            "button".into(),
            vec![Attribute::Event(Event::OnMsg("click".into(), Msg::Inc))],
            vec![Html::Text("+".into())],
        );
        match t {
            Html::Element(tag, attrs, kids) => {
                assert_eq!(tag, "button");
                assert_eq!(attrs.len(), 1);
                assert_eq!(kids.len(), 1);
            }
            _ => panic!("expected element"),
        }
    }
}
```

- [ ] **Step 4: Run it — verify it fails to compile (types undefined)**

Run: `cd runtime-rust && cargo test --features live html_tree_constructs`
Expected: FAIL — `cannot find type Html`.

- [ ] **Step 5: Add the enum definitions above the test**

```rust
use std::collections::HashMap;

/// Form data delivered to an `OnForm` handler (lower-cased keys; see dispatch).
pub type FormData = HashMap<String, String>;

#[derive(Clone, Debug, PartialEq)]
pub enum Html<M> {
    Element(String, Vec<Attribute<M>>, Vec<Html<M>>),
    Text(String),
    Raw(String),
}

#[derive(Clone)]
pub enum Attribute<M> {
    Attr(String, String),
    BoolAttr(String, bool),
    Event(Event<M>),
    NoAttr,
}

#[derive(Clone)]
pub enum Event<M> {
    OnMsg(String, M),
    OnString(String, std::sync::Arc<dyn Fn(String) -> M + Send + Sync>),
    OnBool(String, std::sync::Arc<dyn Fn(bool) -> M + Send + Sync>),
    OnForm(String, std::sync::Arc<dyn Fn(FormData) -> M + Send + Sync>),
}
```

> `Arc` (not `Box`) so `Attribute`/`Event` are `Clone` — the diff/index keep
> references but `view` re-runs each commit and the tree is cloned into the
> session. Manual `PartialEq`/`Debug` for `Attribute`/`Event` come next (closures
> aren't `PartialEq`/`Debug`).

- [ ] **Step 6: Add manual `PartialEq` + `Debug` for `Attribute` and `Event`**

Closures compare/printed by event-name + variant tag only (structure is what diff needs):

```rust
impl<M: PartialEq> PartialEq for Attribute<M> {
    fn eq(&self, o: &Self) -> bool {
        use Attribute::*;
        match (self, o) {
            (Attr(a, b), Attr(c, d)) => a == c && b == d,
            (BoolAttr(a, b), BoolAttr(c, d)) => a == c && b == d,
            (Event(a), Event(b)) => a == b,
            (NoAttr, NoAttr) => true,
            _ => false,
        }
    }
}
impl<M> std::fmt::Debug for Attribute<M> {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        match self {
            Attribute::Attr(k, v) => write!(f, "Attr({k:?},{v:?})"),
            Attribute::BoolAttr(k, v) => write!(f, "BoolAttr({k:?},{v})"),
            Attribute::Event(e) => write!(f, "Event({})", e.name()),
            Attribute::NoAttr => write!(f, "NoAttr"),
        }
    }
}
impl<M> PartialEq for Event<M> {
    // Event identity for diffing = (variant kind, event name). Handlers are
    // re-bound every render; the DOM only needs to know the listener exists.
    fn eq(&self, o: &Self) -> bool { self.kind_name() == o.kind_name() }
}
impl<M> Event<M> {
    pub fn name(&self) -> &str {
        match self { Event::OnMsg(n,_)|Event::OnString(n,_)|Event::OnBool(n,_)|Event::OnForm(n,_) => n }
    }
    fn kind_name(&self) -> (u8, &str) {
        match self {
            Event::OnMsg(n,_) => (0,n), Event::OnString(n,_) => (1,n),
            Event::OnBool(n,_) => (2,n), Event::OnForm(n,_) => (3,n),
        }
    }
}
```

- [ ] **Step 7: Run the test — verify it passes**

Run: `cd runtime-rust && cargo test --features live html_tree_constructs`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add runtime-rust/src/sky_runtime/live/ runtime-rust/src/sky_runtime/mod.rs runtime-rust/Cargo.toml
git commit -m "feat(rust): Sky.Live html.rs — Html/Attribute/Event<M> runtime enums"
```

---

## Task 2: `assign_sky_ids` — stable per-element id stamping

**Files:**
- Modify: `runtime-rust/src/sky_runtime/live/html.rs`

- [ ] **Step 1: Write the failing test**

Add to the `tests` module:

```rust
#[test]
fn sky_ids_are_stable_and_pathed() {
    let mut t: Html<()> = Html::Element("div".into(), vec![], vec![
        Html::Element("span".into(), vec![], vec![Html::Text("a".into())]),
        Html::Element("span".into(), vec![], vec![]),
    ]);
    assign_sky_ids(&mut t, "r");
    let ids = collect_ids(&t);
    // root + two spans; text nodes get none. Deterministic across runs.
    assert_eq!(ids, vec!["r", "r_0_span", "r_1_span"]);
    let mut t2 = t.clone();
    assign_sky_ids(&mut t2, "r");
    assert_eq!(collect_ids(&t2), ids);
}

fn collect_ids<M>(n: &Html<M>) -> Vec<String> {
    let mut out = vec![];
    fn go<M>(n: &Html<M>, out: &mut Vec<String>) {
        if let Html::Element(_, attrs, kids) = n {
            for a in attrs { if let Attribute::Attr(k, v) = a { if k == "sky-id" { out.push(v.clone()); } } }
            for c in kids { go(c, out); }
        }
    }
    go(n, &mut out);
    out
}
```

- [ ] **Step 2: Run it — verify it fails**

Run: `cd runtime-rust && cargo test --features live sky_ids_are_stable`
Expected: FAIL — `cannot find function assign_sky_ids`.

- [ ] **Step 3: Implement `assign_sky_ids`**

Add to `html.rs` (mirrors Go `assignSkyIDs`, `runtime-go/rt/live.go:520-548` — path = `<parent>_<index>_<tag>`):

```rust
/// Stamp every Element (not Text/Raw) with a stable `sky-id` attribute derived
/// from its path. Idempotent: an existing sky-id is overwritten with the same
/// value. Text/Raw nodes are unaddressable (Go parity).
pub fn assign_sky_ids<M>(node: &mut Html<M>, path: &str) {
    if let Html::Element(tag, attrs, kids) = node {
        set_attr(attrs, "sky-id", path);
        let mut idx = 0usize;
        for child in kids.iter_mut() {
            if let Html::Element(ctag, _, _) = child {
                let seg = format!("{path}_{idx}_{ctag}");
                idx += 1;
                assign_sky_ids(child, &seg);
            }
        }
    }
}

fn set_attr<M>(attrs: &mut Vec<Attribute<M>>, key: &str, val: &str) {
    for a in attrs.iter_mut() {
        if let Attribute::Attr(k, v) = a { if k == key { *v = val.to_string(); return; } }
    }
    attrs.push(Attribute::Attr(key.to_string(), val.to_string()));
}
```

> `idx` advances only for element children, so text siblings don't shift element
> paths — matches Go's element-only indexing.

- [ ] **Step 4: Run the test — verify it passes**

Run: `cd runtime-rust && cargo test --features live sky_ids_are_stable`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add runtime-rust/src/sky_runtime/live/html.rs
git commit -m "feat(rust): Sky.Live assign_sky_ids — stable element id stamping"
```

---

## Task 3: `render_html` — tree → HTML string

**Files:**
- Modify: `runtime-rust/src/sky_runtime/live/html.rs`

- [ ] **Step 1: Write the failing test**

```rust
#[test]
fn render_escapes_and_emits_attrs_events_void() {
    let t: Html<()> = Html::Element("div".into(),
        vec![Attribute::Attr("class".into(), "x".into())],
        vec![
            Html::Element("input".into(),
                vec![Attribute::Attr("value".into(), "a<b".into()), Attribute::BoolAttr("disabled".into(), true)],
                vec![]),
            Html::Text("1 < 2".into()),
            Html::Raw("<b>ok</b>".into()),
        ]);
    let mut t = t; assign_sky_ids(&mut t, "r");
    let s = render_html(&t);
    assert!(s.contains(r#"<div class="x" sky-id="r">"#), "{s}");
    assert!(s.contains(r#"<input value="a&lt;b" disabled sky-id="r_0_input">"#), "{s}"); // void: no closing tag, no children
    assert!(s.contains("1 &lt; 2"));      // text escaped
    assert!(s.contains("<b>ok</b>"));     // raw NOT escaped
    assert!(s.contains("</div>"));
}

#[test]
fn render_emits_data_event_attr() {
    let t: Html<()> = Html::Element("button".into(),
        vec![Attribute::Event(Event::OnMsg("click".into(), ()))], vec![]);
    let mut t = t; assign_sky_ids(&mut t, "r");
    let s = render_html(&t);
    assert!(s.contains(r#"data-sky-on="click""#), "{s}"); // event presence marker for the client
}
```

- [ ] **Step 2: Run it — verify it fails**

Run: `cd runtime-rust && cargo test --features live render_`
Expected: FAIL — `cannot find function render_html`.

- [ ] **Step 3: Implement `render_html` + escaping**

Mirrors Go `renderVNode` (`runtime-go/rt/live.go:296-460`) + void-element set (`live.go:1415`). Events render as a `data-sky-on="<names>"` marker the client reads (the client posts `{sky_id,event}` on those listeners):

```rust
const VOID: &[&str] = &["area","base","br","col","embed","hr","img","input",
    "link","meta","param","source","track","wbr"];

pub fn render_html<M>(node: &Html<M>) -> String {
    let mut s = String::new();
    render_into(node, &mut s);
    s
}

fn render_into<M>(node: &Html<M>, s: &mut String) {
    match node {
        Html::Text(t) => s.push_str(&escape_text(t)),
        Html::Raw(r) => s.push_str(r),
        Html::Element(tag, attrs, kids) => {
            s.push('<'); s.push_str(tag);
            let mut events: Vec<&str> = vec![];
            for a in attrs {
                match a {
                    Attribute::Attr(k, v) => {
                        s.push(' '); s.push_str(k);
                        s.push_str("=\""); s.push_str(&escape_attr(v)); s.push('"');
                    }
                    Attribute::BoolAttr(k, true) => { s.push(' '); s.push_str(k); }
                    Attribute::BoolAttr(_, false) | Attribute::NoAttr => {}
                    Attribute::Event(e) => events.push(e.name()),
                }
            }
            if !events.is_empty() {
                s.push_str(" data-sky-on=\""); s.push_str(&events.join(" ")); s.push('"');
            }
            if VOID.contains(&tag.as_str()) { s.push('>'); return; }
            s.push('>');
            for c in kids { render_into(c, s); }
            s.push_str("</"); s.push_str(tag); s.push('>');
        }
    }
}

fn escape_text(t: &str) -> String { t.replace('&',"&amp;").replace('<',"&lt;").replace('>',"&gt;") }
fn escape_attr(t: &str) -> String { escape_text(t).replace('"',"&quot;") }
```

- [ ] **Step 4: Run the tests — verify they pass**

Run: `cd runtime-rust && cargo test --features live render_`
Expected: PASS (both).

- [ ] **Step 5: Commit**

```bash
git add runtime-rust/src/sky_runtime/live/html.rs
git commit -m "feat(rust): Sky.Live render_html — tree to HTML with escaping + void + event marker"
```

---

## Task 4: Codegen — the `msg`-var generic-alias bridge case

**Files:**
- Modify: `src/Sky/Generate/Rust/Builder.hs`

**Context:** `unionToRustTypeDef` (Builder.hs ~line 1119) today has two registry-hit
cases: plain `pub use` (no `<`) and instantiated `pub type` (`<SkyError>`). `Html msg`
needs a **third**: a generic alias that *carries the Sky type var through*, e.g.
`pub type StdHtmlHtml<M> = sky_runtime::Html<M>;`. The registry value uses a `{M}`
placeholder so codegen substitutes the union's own `uvars`.

- [ ] **Step 1: Add the registry entries**

In `runtimeOpaqueTypes` (after the `ChunkEvent` entry), add:

```haskell
    -- Sky.Live: Html/Attribute/Event bridge to runtime generic enums, carrying
    -- the app's `msg` var through ({M} = the union's own type var, substituted in
    -- unionToRustTypeDef). render/diff are msg-agnostic; only dispatch uses M.
    , (("Std.Html", "Html"),      "sky_runtime::Html<{M}>")
    , (("Std.Html", "Attribute"), "sky_runtime::Attribute<{M}>")
    , (("Std.Html.Attributes", "Attribute"), "sky_runtime::Attribute<{M}>")
    , (("Std.Html.Attributes", "Event"),     "sky_runtime::Event<{M}>")
```

> Verify the exact Sky module names with:
> `grep -n "^module" sky-stdlib/Std/Html.sky sky-stdlib/Std/Html/Attributes.sky`
> and adjust the keys to match (the registry is keyed on the dotted module name).

- [ ] **Step 2: Add the third case to `unionToRustTypeDef`**

Replace the registry-hit arms (the `Just rustPath | ...` block) with:

```haskell
        Just rustPath
          | '{' `elem` rustPath ->
              -- Generic alias carrying the union's own type vars (Html msg ->
              -- pub type StdHtmlHtml<M> = sky_runtime::Html<M>;). Substitute the
              -- single Sky uvar for the {M} placeholder; the alias IS generic.
              let m = case uvars of (v:_) -> v; [] -> "M"
                  path = substPlaceholder "{M}" m rustPath
                  aliasGens = if null uvars then "" else "<" ++ intercalate ", " uvars ++ ">"
              in RAliasDefGen codegenName aliasGens path
          | '<' `notElem` rustPath -> RPubUseAlias codegenName rustPath
          | otherwise              -> RAliasDef codegenName rustPath
```

Add the helper near `unionToRustTypeDef`:

```haskell
substPlaceholder :: String -> String -> String -> String
substPlaceholder needle replacement haystack = go haystack
  where
    go [] = []
    go s@(c:cs) = case stripPrefix needle s of
        Just rest -> replacement ++ go rest
        Nothing   -> c : go cs
```

- [ ] **Step 3: Add the `RAliasDefGen` constructor + its emission**

In the `RustTypeDef` data type (Builder.hs ~line 283), add:

```haskell
    | RAliasDefGen String String String  -- codegenName, "<M>", rustPathWithVar
```

In `typeDefToString` (where `RAliasDef` is emitted), add:

```haskell
typeDefToString (RAliasDefGen name gens path) =
    "pub type " ++ name ++ gens ++ " = " ++ path ++ ";"
```

- [ ] **Step 4: Build the compiler**

Run: `cabal build exe:sky 2>&1 | grep -iE "error:|Linking" | tail`
Expected: `Linking …/sky` (no `error:`). If `stripPrefix`/`intercalate` unresolved, confirm `import Data.List (stripPrefix, intercalate)` at the top of Builder.hs (intercalate already imported; add stripPrefix if missing).

- [ ] **Step 5: Install + commit**

```bash
cabal install --overwrite-policy=always --installdir=./sky-out --install-method=copy exe:sky
git add src/Sky/Generate/Rust/Builder.hs
git commit -m "feat(rust): codegen — msg-var generic-alias bridge case (Html<M> family)"
```

---

## Task 5: P0 gate — `examples/rust/27-live-static` renders byte-correct HTML

**Files:**
- Create: `examples/rust/27-live-static/sky.toml`, `examples/rust/27-live-static/src/Main.sky`
- Modify: `src/Sky/Generate/Rust/Builder.hs` (usage detection), `src/Sky/Generate/Rust/Project.hs` (module gating)

**Note:** P0 proves the bridge + render in isolation. `Live.app` (the loop) is P1,
so this example calls a P0-only kernel `Live.renderStatic : (Model -> Html msg) -> Model -> Task Error ()` that prints the rendered HTML. (This kernel is temporary scaffolding; P1 Task 11 wires the real `Live.app`. It exercises the exact bridge + render path the loop will use.)

- [ ] **Step 1: Add the `renderStatic` scaffold kernel to the runtime**

In `runtime-rust/src/sky_runtime/live/mod.rs`:

```rust
use crate::sky_runtime::core::{SkyTask, SkyResult};

/// P0 scaffold: render `view(model)` to a full HTML page and print it. Replaced
/// by `live_app` in P1; exists so the bridge + render path is gate-testable now.
pub fn live_render_static<E, Model, Msg, FView>(view: FView, model: Model) -> SkyTask<E, ()>
where
    E: Send + 'static, Model: Send + 'static, Msg: Send + 'static,
    FView: Fn(Model) -> html::Html<Msg> + Send + 'static,
{
    Box::pin(async move {
        let mut tree = view(model);
        html::assign_sky_ids(&mut tree, "r");
        println!("{}", render_page(&html::render_html(&tree)));
        SkyResult::Ok(())
    })
}

/// Minimal page wrap (P0). The full wrap (meta/head/client script) lands in P1.
pub fn render_page(body: &str) -> String {
    format!("<!DOCTYPE html><html><head><meta charset=\"utf-8\"></head><body><div id=\"sky-root\">{body}</div></body></html>")
}
```

- [ ] **Step 2: Map the scaffold kernel + Live.app detection in codegen**

In `Builder.hs` `kernelToRust`, add (Live.renderStatic is scaffold; Live.app is P1):

```haskell
    ("Live", "renderStatic")          -> "live_render_static"
    ("Std.Live", "renderStatic")      -> "live_render_static"
```

Add a `usesLive` flag to `UsedKernels` (bump Semigroup/Monoid/mempty arity like `usesEmail` was), set it in `detectKernelUsage` when `modName == "Live" || "Std.Live" \`isInfixOf\` modName`, and pin the turbofish in `kernelsNeedingErrorPin`:

```haskell
    , ("live_render_static",       "::<SkyError, _, _, _>")
```

- [ ] **Step 3: Gate the `live` module in the generated project**

In `Project.hs`, where modules are listed, add (gated on `usesLive`):

```haskell
        liveMod = if usesLive then ["pub mod live;"] else []
        liveUse = if usesLive then ["pub use live::*;"] else []
```

and splice `liveMod`/`liveUse` into the emitted `mod.rs` list. Also ensure the generated `Cargo.toml` enables the runtime `live` feature when `usesLive` (mirror how `usesHttpServer` enables `server`).

- [ ] **Step 4: Write the example**

`examples/rust/27-live-static/sky.toml`:

```toml
name = "27-live-static"
version = "0.1.0"
entry = "src/Main.sky"
target = "rust"

[source]
root = "src"
```

`examples/rust/27-live-static/src/Main.sky`:

```elm
module Main exposing (main)

import Sky.Core.Prelude exposing (..)
import Sky.Core.Task as Task
import Std.Html as Html
import Std.Html.Attributes as Attr
import Std.Live as Live
import Sky.Core.Error exposing (Error)


type Msg = NoOp


view : Int -> Html.Html Msg
view n =
    Html.div [ Attr.class "card" ]
        [ Html.h1 [] [ Html.text "Sky.Live (rust)" ]
        , Html.p [] [ Html.text ("count = " ++ String.fromInt n) ]
        ]


main : Task Error ()
main =
    Live.renderStatic view 7
```

- [ ] **Step 5: Build the compiler, then build+run the example**

```bash
cabal install --overwrite-policy=always --installdir=./sky-out --install-method=copy exe:sky
cd examples/rust/27-live-static && rm -rf sky-out .skycache
/home/arthur/Documentos/comp/sky/sky-out/sky run src/Main.sky 2>&1 | tail -5
```

Expected: a line of HTML containing
`<div class="card" sky-id="r"><h1 sky-id="r_0_h1">Sky.Live (rust)</h1><p sky-id="r_1_p">count = 7</p></div>`.

- [ ] **Step 6: Verify the bridge emission (sanity)**

Run: `grep -n "pub type StdHtmlHtml" examples/rust/27-live-static/sky-out/rust/src/main.rs`
Expected: `pub type StdHtmlHtml<...> = sky_runtime::Html<...>;` (generic alias, not `pub use`).

- [ ] **Step 7: Commit**

```bash
git add examples/rust/27-live-static src/Sky/Generate/Rust/Builder.hs src/Sky/Generate/Rust/Project.hs runtime-rust/src/sky_runtime/live/mod.rs
git commit -m "feat(rust): P0 gate — 27-live-static renders byte-correct full HTML"
```

---

# PHASE P1 — Core TEA-over-HTTP+SSE loop

## Task 6: `Patch` + minimal `diff`

**Files:**
- Create: `runtime-rust/src/sky_runtime/live/diff.rs`
- Modify: `runtime-rust/src/sky_runtime/live/mod.rs` (add `pub mod diff; pub use diff::*;`)

**Scope:** the counter needs `SetText` + `SetAttr`/`RemoveAttr` + whole-node
`Replace` (`html`) + `Remove`. Keyed reorder is deferred to P6 (the spec marks the
full faithful diff as ongoing; this subset is sufficient for the P1 gate and matches
Go's `Patch` struct exactly).

- [ ] **Step 1: Write the failing tests**

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use crate::sky_runtime::live::html::*;

    fn ids(h: &mut Html<()>) { assign_sky_ids(h, "r"); }

    #[test]
    fn diff_text_change() {
        let mut a: Html<()> = Html::Element("p".into(), vec![], vec![Html::Text("1".into())]);
        let mut b: Html<()> = Html::Element("p".into(), vec![], vec![Html::Text("2".into())]);
        ids(&mut a); ids(&mut b);
        let p = diff(&a, &b);
        assert_eq!(p.len(), 1);
        assert_eq!(p[0].id, "r");
        assert_eq!(p[0].text.as_deref(), Some("2"));
    }

    #[test]
    fn diff_attr_set_and_remove() {
        let mut a: Html<()> = Html::Element("div".into(), vec![Attribute::Attr("class".into(),"x".into())], vec![]);
        let mut b: Html<()> = Html::Element("div".into(), vec![Attribute::Attr("class".into(),"y".into()), Attribute::Attr("title".into(),"t".into())], vec![]);
        ids(&mut a); ids(&mut b);
        let p = diff(&a, &b);
        let attrs = &p[0].attrs;
        assert_eq!(attrs.get("class").map(String::as_str), Some("y"));
        assert_eq!(attrs.get("title").map(String::as_str), Some("t"));
    }

    #[test]
    fn diff_identical_is_empty() {
        let mut a: Html<()> = Html::Element("p".into(), vec![], vec![Html::Text("1".into())]);
        let mut b = a.clone();
        ids(&mut a); ids(&mut b);
        assert!(diff(&a, &b).is_empty());
    }
}
```

- [ ] **Step 2: Run them — verify they fail**

Run: `cd runtime-rust && cargo test --features live diff_`
Expected: FAIL — `cannot find function diff`.

- [ ] **Step 3: Implement `Patch` + `diff`**

Create `runtime-rust/src/sky_runtime/live/diff.rs` (`Patch` field-for-field with Go's, `runtime-go/rt/live.go:1183`):

```rust
use crate::sky_runtime::live::html::*;
use serde::Serialize;
use std::collections::HashMap;

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct Patch {
    pub id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub html: Option<String>,
    #[serde(skip_serializing_if = "HashMap::is_empty", default)]
    pub attrs: HashMap<String, String>,   // "" => remove (Go convention)
    #[serde(skip_serializing_if = "std::ops::Not::not", default)]
    pub remove: bool,
}
impl Patch {
    fn for_id(id: &str) -> Self { Patch { id: id.into(), text: None, html: None, attrs: HashMap::new(), remove: false } }
    fn is_empty(&self) -> bool { self.text.is_none() && self.html.is_none() && self.attrs.is_empty() && !self.remove }
}

/// Structure-only diff (no `M`). Walks matched-by-sky-id elements; on a
/// structural mismatch (tag differs, or element/text kind differs) emits a
/// whole-subtree `html` replace (re-render the new node). Sufficient for the
/// P1 gate; keyed reorder lands in P6.
pub fn diff<M>(old: &Html<M>, new: &Html<M>) -> Vec<Patch> {
    let mut out = vec![];
    diff_node(old, new, &mut out);
    out
}

fn sky_id<M>(n: &Html<M>) -> Option<&str> {
    if let Html::Element(_, attrs, _) = n {
        for a in attrs { if let Attribute::Attr(k, v) = a { if k == "sky-id" { return Some(v); } } }
    }
    None
}

fn diff_node<M>(old: &Html<M>, new: &Html<M>, out: &mut Vec<Patch>) {
    match (old, new) {
        (Html::Element(ot, oa, ok), Html::Element(nt, na, nk)) if ot == nt => {
            let id = sky_id(new).unwrap_or("").to_string();
            let mut p = Patch::for_id(&id);
            diff_attrs(oa, na, &mut p);
            // children: if element-structure matches positionally, recurse;
            // else replace this node's inner HTML wholesale.
            if same_child_shape(ok, nk) {
                if !p.is_empty() { out.push(p); }
                for (c_old, c_new) in ok.iter().zip(nk.iter()) { diff_node(c_old, c_new, out); }
                // text-only child change is caught here:
                diff_text_children(&id, ok, nk, out);
            } else {
                p.html = Some(render_children(nk));
                out.push(p);
            }
        }
        // kind or tag mismatch at a positioned node → replace via parent html.
        // (handled by the parent's same_child_shape=false branch; nothing here)
        _ => {}
    }
}

fn diff_text_children<M>(id: &str, ok: &[Html<M>], nk: &[Html<M>], out: &mut Vec<Patch>) {
    // Single text child whose value changed → SetText on the parent.
    if let ([Html::Text(o)], [Html::Text(n)]) = (ok, nk) {
        if o != n {
            let mut p = Patch::for_id(id);
            p.text = Some(n.clone());
            out.push(p);
        }
    }
}

fn same_child_shape<M>(a: &[Html<M>], b: &[Html<M>]) -> bool {
    a.len() == b.len() && a.iter().zip(b).all(|(x, y)| match (x, y) {
        (Html::Element(t1,_,_), Html::Element(t2,_,_)) => t1 == t2,
        (Html::Text(_), Html::Text(_)) => true,
        (Html::Raw(_), Html::Raw(_)) => true,
        _ => false,
    })
}

fn diff_attrs<M>(old: &[Attribute<M>], new: &[Attribute<M>], p: &mut Patch) {
    let collect = |xs: &[Attribute<M>]| -> HashMap<String,String> {
        let mut m = HashMap::new();
        for a in xs { match a {
            Attribute::Attr(k,v) if k != "sky-id" => { m.insert(k.clone(), v.clone()); }
            Attribute::BoolAttr(k,true) => { m.insert(k.clone(), String::new()); }
            _ => {}
        } }
        m
    };
    let (om, nm) = (collect(old), collect(new));
    for (k, v) in &nm { if om.get(k) != Some(v) { p.attrs.insert(k.clone(), v.clone()); } }
    for k in om.keys() { if !nm.contains_key(k) { p.attrs.insert(k.clone(), String::new()); } } // "" => remove
}

fn render_children<M>(kids: &[Html<M>]) -> String {
    let mut s = String::new();
    for c in kids { s.push_str(&render_html(c)); }
    s
}
```

> The recursion descends only when element children align positionally by tag;
> otherwise it replaces inner HTML. This is the minimal correct subset for the
> counter (text + attr deltas) and never produces a wrong patch — worst case it
> over-replaces a subtree. P6 swaps in the full keyed algorithm.

- [ ] **Step 4: Wire the module + run tests**

Add to `live/mod.rs`: `pub mod diff; pub use diff::*;`
Run: `cd runtime-rust && cargo test --features live diff_`
Expected: PASS (all three).

- [ ] **Step 5: Commit**

```bash
git add runtime-rust/src/sky_runtime/live/diff.rs runtime-rust/src/sky_runtime/live/mod.rs
git commit -m "feat(rust): Sky.Live diff.rs — Patch (Go schema) + minimal text/attr diff"
```

---

## Task 7: `HandlerIndex` + dispatch resolution

**Files:**
- Create: `runtime-rust/src/sky_runtime/live/dispatch.rs`
- Modify: `runtime-rust/src/sky_runtime/live/mod.rs`

- [ ] **Step 1: Write the failing tests**

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use crate::sky_runtime::live::html::*;

    #[derive(Clone, Debug, PartialEq)]
    enum Msg { Inc, Typed(String) }

    fn tree() -> Html<Msg> {
        let mut t = Html::Element("div".into(), vec![], vec![
            Html::Element("button".into(), vec![Attribute::Event(Event::OnMsg("click".into(), Msg::Inc))], vec![]),
            Html::Element("input".into(), vec![Attribute::Event(Event::OnString("input".into(),
                std::sync::Arc::new(|s| Msg::Typed(s))))], vec![]),
        ]);
        assign_sky_ids(&mut t, "r");
        t
    }

    #[test]
    fn resolves_onmsg_and_onstring() {
        let idx = build_index(&tree());
        assert_eq!(idx.resolve("r_0_button", "click", &[]), Some(Msg::Inc));
        assert_eq!(idx.resolve("r_1_input", "input", &["hi".into()]), Some(Msg::Typed("hi".into())));
        assert_eq!(idx.resolve("r_0_button", "input", &[]), None); // wrong event
        assert_eq!(idx.resolve("nope", "click", &[]), None);       // unknown id
    }
}
```

- [ ] **Step 2: Run — verify it fails**

Run: `cd runtime-rust && cargo test --features live resolves_onmsg`
Expected: FAIL — `cannot find function build_index`.

- [ ] **Step 3: Implement the index**

Create `runtime-rust/src/sky_runtime/live/dispatch.rs`:

```rust
use crate::sky_runtime::live::html::*;
use std::collections::HashMap;

/// (sky-id, event-name) -> the cloneable handler closure (Event holds Arc).
pub struct HandlerIndex<M> { map: HashMap<(String, String), Event<M>> }

impl<M: Clone> HandlerIndex<M> {
    /// args[0] is the wire value for OnString (raw string) / OnBool ("true"/"false").
    /// OnForm uses the FormData path (Task 9), not this resolver.
    pub fn resolve(&self, sky_id: &str, event: &str, args: &[String]) -> Option<M> {
        match self.map.get(&(sky_id.to_string(), event.to_string()))? {
            Event::OnMsg(_, m) => Some(m.clone()),
            Event::OnString(_, f) => Some(f(args.first().cloned().unwrap_or_default())),
            Event::OnBool(_, f) => Some(f(args.first().map(|s| s == "true").unwrap_or(false))),
            Event::OnForm(_, _) => None, // dispatched via resolve_form
        }
    }
    pub fn resolve_form(&self, sky_id: &str, event: &str, fd: FormData) -> Option<M> {
        match self.map.get(&(sky_id.to_string(), event.to_string()))? {
            Event::OnForm(_, f) => Some(f(fd)),
            _ => None,
        }
    }
}

pub fn build_index<M: Clone>(root: &Html<M>) -> HandlerIndex<M> {
    let mut map = HashMap::new();
    walk(root, &mut map);
    HandlerIndex { map }
}

fn walk<M: Clone>(n: &Html<M>, map: &mut HashMap<(String,String), Event<M>>) {
    if let Html::Element(_, attrs, kids) = n {
        let id = attrs.iter().find_map(|a| match a {
            Attribute::Attr(k, v) if k == "sky-id" => Some(v.clone()), _ => None,
        }).unwrap_or_default();
        for a in attrs {
            if let Attribute::Event(e) = a {
                map.insert((id.clone(), e.name().to_string()), e.clone());
            }
        }
        for c in kids { walk(c, map); }
    }
}
```

- [ ] **Step 4: Wire module + run tests**

Add to `live/mod.rs`: `pub mod dispatch; pub use dispatch::*;`
Run: `cd runtime-rust && cargo test --features live resolves_onmsg`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add runtime-rust/src/sky_runtime/live/dispatch.rs runtime-rust/src/sky_runtime/live/mod.rs
git commit -m "feat(rust): Sky.Live dispatch.rs — handler index + resolve(sky-id,event,args)"
```

---

## Task 8: `LiveSession` + in-memory store + SSE channel type

**Files:**
- Create: `runtime-rust/src/sky_runtime/live/session.rs`, `runtime-rust/src/sky_runtime/live/sse.rs`
- Modify: `runtime-rust/src/sky_runtime/live/mod.rs`

- [ ] **Step 1: Write the failing test (store round-trip)**

In `session.rs`:

```rust
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn store_put_get_delete() {
        let store: MemStore<i32> = MemStore::new();
        store.put("s1".into(), 41);
        assert_eq!(store.with("s1", |v| *v), Some(41));
        store.update("s1", |v| *v += 1);
        assert_eq!(store.with("s1", |v| *v), Some(42));
        store.delete("s1");
        assert_eq!(store.with("s1", |v| *v), None);
    }
}
```

- [ ] **Step 2: Run — verify it fails**

Run: `cd runtime-rust && cargo test --features live store_put_get`
Expected: FAIL — `cannot find type MemStore`.

- [ ] **Step 3: Implement the SSE channel type**

`runtime-rust/src/sky_runtime/live/sse.rs`:

```rust
use tokio::sync::mpsc;

/// One framed SSE message body (already serialized patch-envelope JSON).
#[derive(Clone, Debug)]
pub struct SsePatch(pub String);

pub type SseTx = mpsc::Sender<SsePatch>;
pub type SseRx = mpsc::Receiver<SsePatch>;

/// Bounded buffer (Go default 16); drops oldest under backpressure are surfaced
/// by the caller. hello/heartbeat framing is done in mod.rs when wiring axum.
pub fn channel() -> (SseTx, SseRx) { mpsc::channel(16) }

/// SSE event framing: `event: <name>\ndata: <payload>\n\n`.
pub fn frame(event: &str, data: &str) -> String { format!("event: {event}\ndata: {data}\n\n") }
```

- [ ] **Step 4: Implement the session + in-memory store**

`runtime-rust/src/sky_runtime/live/session.rs`:

```rust
use super::sse::SseTx;
use crate::sky_runtime::live::dispatch::HandlerIndex;
use crate::sky_runtime::live::html::Html;
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use tokio::sync::mpsc::UnboundedSender;

/// Per-session live state. `last_view` + `index` are re-derived each commit.
pub struct LiveSession<Model, Msg> {
    pub model: Model,
    pub last_view: Html<Msg>,
    pub index: HandlerIndex<Msg>,
    pub seq: u64,
    pub sse_tx: Option<SseTx>,
    pub msg_tx: UnboundedSender<Msg>,   // Cmd/Sub results re-enter the loop here
}

/// In-memory store (P1). TTL gc + persisted backends land in P5. The whole
/// server is monomorphic over (Model, Msg), so one concrete store type suffices.
pub struct MemStore<T> { inner: Arc<Mutex<HashMap<String, T>>> }

impl<T> Clone for MemStore<T> { fn clone(&self) -> Self { MemStore { inner: self.inner.clone() } } }

impl<T> MemStore<T> {
    pub fn new() -> Self { MemStore { inner: Arc::new(Mutex::new(HashMap::new())) } }
    pub fn put(&self, id: String, v: T) { self.inner.lock().unwrap().insert(id, v); }
    pub fn delete(&self, id: &str) { self.inner.lock().unwrap().remove(id); }
    pub fn with<R>(&self, id: &str, f: impl FnOnce(&T) -> R) -> Option<R> {
        self.inner.lock().unwrap().get(id).map(f)
    }
    pub fn update<R>(&self, id: &str, f: impl FnOnce(&mut T) -> R) -> Option<R> {
        self.inner.lock().unwrap().get_mut(id).map(f)
    }
}
```

- [ ] **Step 5: Wire modules + run tests**

Add to `live/mod.rs`: `pub mod sse; pub use sse::*; pub mod session; pub use session::*;`
Run: `cd runtime-rust && cargo test --features live store_put_get`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add runtime-rust/src/sky_runtime/live/session.rs runtime-rust/src/sky_runtime/live/sse.rs runtime-rust/src/sky_runtime/live/mod.rs
git commit -m "feat(rust): Sky.Live session + in-memory store + SSE channel type"
```

---

## Task 9: Port the Go client JS verbatim

**Files:**
- Create: `runtime-rust/src/sky_runtime/live/client.js`
- Modify: `runtime-rust/src/sky_runtime/live/mod.rs`

- [ ] **Step 1: Extract the client JS from the Go runtime**

The browser client is the JS body returned by `liveJSWithCfgAndCsrfWithBase`
(`runtime-go/rt/live.go:5851`) — it composes `liveJS` (5749) + cfg/csrf/base
injection. Copy the JS source (the string literals those functions concatenate)
into `runtime-rust/src/sky_runtime/live/client.js` **verbatim**, replacing the Go
`%s` cfg-injection points with two literal JS globals at the top:

```js
// injected by render_page: window.__SKY_SID and window.__SKY_BASE
const SID = window.__SKY_SID, BASE = window.__SKY_BASE || "";
```

Keep every behavior: EventSource open on `BASE + "/_sky/sse?sid=" + SID`, POST to
`BASE + "/_sky/event"`, `hello`/heartbeat watchdogs, patch application
(`querySelector('[sky-id=…]')` then set `text`/`innerHTML`/attrs/remove),
uncontrolled-input preservation, `data-sky-on` listener binding, reconnect/queue.
Do **not** rewrite — transliterate the string only.

- [ ] **Step 2: Embed it + write `render_page`**

In `live/mod.rs`, replace the P0 `render_page` with the real wrap:

```rust
const CLIENT_JS: &str = include_str!("client.js");
const BASE_CSS: &str = "*,*::before,*::after{box-sizing:border-box}body{margin:0}"; // port from live.go liveBaseCSS (3847) if richer

/// Full page wrap. `sid` is the session id; `base` is the sub-app base path ("").
pub fn render_page_full(sid: &str, base: &str, body: &str) -> String {
    format!(
        "<!DOCTYPE html><html><head><meta charset=\"utf-8\">\
         <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\
         <meta name=\"sky-base\" content=\"{base}\">\
         <style>{BASE_CSS}</style></head>\
         <body><div id=\"sky-root\">{body}</div>\
         <script>window.__SKY_SID={sid:?};window.__SKY_BASE={base:?};\n{CLIENT_JS}</script>\
         </body></html>"
    )
}
```

- [ ] **Step 3: Build the runtime crate**

Run: `cd runtime-rust && cargo build --features live 2>&1 | grep -iE "^error|error\[|Finished"`
Expected: `Finished` (the JS is `include_str!`'d as text; no JS compilation). Fix any Rust-side `format!` brace-escaping if it errors.

- [ ] **Step 4: Commit**

```bash
git add runtime-rust/src/sky_runtime/live/client.js runtime-rust/src/sky_runtime/live/mod.rs
git commit -m "feat(rust): Sky.Live — port Go browser client verbatim + full page wrap"
```

---

## Task 10: `live_app` — the axum mount + TEA loop

**Files:**
- Modify: `runtime-rust/src/sky_runtime/live/mod.rs`

**Architecture:** `live_app` builds an axum router (reuse the `server` module's
axum setup) with three routes: `GET /{*path}` (initial render), `GET /_sky/sse`
(attach), `POST /_sky/event` (dispatch). Per session: spawn the TEA driver task
exactly like `cli_program` — an mpsc `msg_tx`/`msg_rx`; each Msg runs `update`,
re-renders, diffs, pushes an SSE patch, fires `cmd` via `cli_run_cmd` (reused),
and re-evaluates `subscriptions` via the `SubManager` (reused). The only delta
from `cli_program`: the output side serialises patches to SSE instead of printing.

- [ ] **Step 1: Implement `live_app` (initial render + session create)**

```rust
use crate::sky_runtime::tea::{SkyCmd, SkySub};
use crate::sky_runtime::core::{SkyTask, SkyResult};
// axum imports mirror server.rs

pub fn live_app<Model, Msg, FInit, FUpdate, FView, FSubs>(
    init: FInit, update: FUpdate, view: FView, subscriptions: FSubs, port: i64,
) -> SkyTask<crate::sky_runtime::SkyError, ()>
where
    Model: Clone + Send + 'static,
    Msg: Clone + Send + 'static,
    FInit: Fn(()) -> (Model, SkyCmd<Msg>) + Send + Sync + 'static,
    FUpdate: Fn(Msg, Model) -> (Model, SkyCmd<Msg>) + Send + Sync + 'static,
    FView: Fn(Model) -> html::Html<Msg> + Send + Sync + 'static,
    FSubs: Fn(Model) -> SkySub<Msg> + Send + Sync + 'static,
{
    Box::pin(async move {
        // Build axum router; shared MemStore<LiveSession<Model,Msg>> in app state;
        // Arc the four cfg fns so handlers + the per-session driver share them.
        // GET handler: new sid (uuid), (model,cmd0)=init(()), tree=view(model),
        //   assign_sky_ids(&mut tree,"r"), index=build_index(&tree); store session;
        //   spawn driver(sid); set cookie; return render_page_full(sid,"",&render_html(&tree)).
        // … (full body in steps 2-4) …
        let _ = (init, update, view, subscriptions, port);
        SkyResult::Ok(())
    })
}
```

> Implement the router body following `server.rs`'s `server_listen` →
> `to_axum_response` setup for the axum scaffolding (bind, `axum::serve`); reuse
> its cookie helpers for the session cookie.

- [ ] **Step 2: Implement the per-session driver (the TEA loop)**

```rust
// Spawned once per session on first GET. Owns msg_rx; mirrors cli_program's loop
// (tea.rs) but emits SSE instead of println.
async fn driver<Model, Msg>(/* sid, store, msg_rx, sse handle, Arc fns, SubManager */)
where Model: Clone + Send + 'static, Msg: Clone + Send + 'static {
    // let mut submgr = SubManager::new(tx_for_cmd_results);   // reuse tea.rs
    // submgr.update(subscriptions(model.clone()));
    // while let Some(msg) = msg_rx.recv().await {
    //   let (next, cmd) = update(msg, model);
    //   model = next;
    //   let mut tree = view(model.clone()); assign_sky_ids(&mut tree,"r");
    //   let patches = diff(&store.last_view, &tree);
    //   store.last_view = tree; store.index = build_index(&tree);
    //   if !patches.is_empty() {
    //       let body = serde_json::to_string(&PatchEnvelope{ kind:"patches", seq, patches })?;
    //       sse_tx.send(SsePatch(frame("patch", &body))).await.ok();
    //   }
    //   cli_run_cmd(cmd, &cmd_tx);                 // reuse tea.rs
    //   submgr.update(subscriptions(model.clone()));
    // }
}
```

Add the envelope type (matches Go's `patchesEventEnvelope`, `live.go:2558`):

```rust
#[derive(serde::Serialize)]
struct PatchEnvelope<'a> { #[serde(rename="type")] kind: &'a str, seq: u64, patches: &'a [diff::Patch] }
```

- [ ] **Step 3: Implement the SSE + event handlers**

```rust
// GET /_sky/sse?sid=…  → register sse_tx on the session; immediately send
//   frame("hello", "{}") + 2KB pad comment; spawn a 15s heartbeat (frame("ping","{}"));
//   stream rx via axum Body::from_stream (same pattern as server_stream.rs).
// POST /_sky/event  body {sky_id,event,args} → look up session.index;
//   msg = index.resolve(sky_id,event,args) (or resolve_form for "submit");
//   if Some(m): session.msg_tx.send(m)  (the driver does update+diff+SSE);
//   respond 200 (empty patch sets are JSON-acked by the driver's no-send path).
```

> Reuse `server_stream.rs`'s `Body::from_stream(unfold(rx, …))` for the SSE
> response stream; set `content-type: text/event-stream`, `x-accel-buffering: no`,
> `cache-control: no-cache`.

- [ ] **Step 4: Map `Live.app` in codegen + entry**

In `Builder.hs` `kernelToRust`: `("Live","app") -> "live_app"` and `("Std.Live","app") -> "live_app"`. Pin `("live_app", "::<_, _, _, _, _, _>")` only if inference needs it (Model/Msg flow from the cfg fns — likely no turbofish needed; add `::<…>` if the build reports E0283). Ensure `hasTokio`/entry treats a `live_app` main like a server (`mainIsTask`, `block_on`) — mirror `usesHttpServer` in the entry logic so `main : Task Error ()` runs.

- [ ] **Step 5: Build the compiler + runtime**

```bash
cabal build exe:sky 2>&1 | grep -iE "error:|Linking" | tail
cd runtime-rust && cargo build --features live 2>&1 | grep -iE "^error|Finished"
```
Expected: compiler links; runtime `Finished`. Fix type/lifetime errors iteratively (the `Arc`-wrapped cfg fns + `'static` bounds are the usual culprits — clone the `Arc`s into each handler/closure).

- [ ] **Step 6: Commit**

```bash
cabal install --overwrite-policy=always --installdir=./sky-out --install-method=copy exe:sky
git add runtime-rust/src/sky_runtime/live/mod.rs src/Sky/Generate/Rust/Builder.hs
git commit -m "feat(rust): Sky.Live live_app — axum mount + per-session TEA driver over SSE"
```

---

## Task 11: P1 gate — `examples/rust/28-live-counter` increments live

**Files:**
- Create: `examples/rust/28-live-counter/sky.toml`, `examples/rust/28-live-counter/src/Main.sky`

- [ ] **Step 1: Write the example**

`sky.toml`:

```toml
name = "28-live-counter"
version = "0.1.0"
entry = "src/Main.sky"
target = "rust"

[source]
root = "src"
```

`src/Main.sky`:

```elm
module Main exposing (main)

import Sky.Core.Prelude exposing (..)
import Sky.Core.Task as Task
import Std.Html as Html
import Std.Html.Attributes as Attr
import Std.Html.Events as Ev
import Std.Live as Live
import Std.Cmd as Cmd
import Std.Sub as Sub
import Sky.Core.Error exposing (Error)


type Msg = Increment | Decrement


type alias Model = { count : Int }


init : () -> ( Model, Cmd Msg )
init _ = ( { count = 0 }, Cmd.none )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        Increment -> ( { model | count = model.count + 1 }, Cmd.none )
        Decrement -> ( { model | count = model.count - 1 }, Cmd.none )


view : Model -> Html.Html Msg
view model =
    Html.div []
        [ Html.button [ Ev.onClick Decrement ] [ Html.text "-" ]
        , Html.span [] [ Html.text (String.fromInt model.count) ]
        , Html.button [ Ev.onClick Increment ] [ Html.text "+" ]
        ]


subscriptions : Model -> Sub Msg
subscriptions _ = Sub.none


main : Task Error ()
main =
    Live.app
        { init = init, update = update, view = view, subscriptions = subscriptions
        , routes = [ Live.route "/" () ]
        , notFound = ()
        }
```

> Confirm the `Ev.onClick` import path: `grep -n "onClick" sky-stdlib/Std/Html/Events.sky`. Adjust the import to the actual module. If `routes`/`notFound` cause a type issue in the cfg record on the minimal kernel, drop them for P1 (single implicit "/" route) and add routing in P3 — match `live_app`'s cfg arity to whatever fields the kernel actually consumes.

- [ ] **Step 2: Build + run the server**

```bash
cd examples/rust/28-live-counter && rm -rf sky-out .skycache
/home/arthur/Documentos/comp/sky/sky-out/sky build src/Main.sky 2>&1 | tail -3
./sky-out/rust/target/debug/sky-app > /tmp/live28.log 2>&1 &
APP=$!; until grep -qiE "listening|800" /tmp/live28.log; do sleep 0.3; done
```

Expected: `Build complete`; server logs a listening line.

- [ ] **Step 3: Verify initial render (P0 path through the loop)**

```bash
SID=$(curl -s -c /tmp/jar -i http://localhost:8000/ | tee /tmp/page.html | grep -i set-cookie | head -1)
grep -oE '<div id="sky-root">.*</div>' /tmp/page.html | head -c 400
```
Expected: the counter markup with `sky-id`s + `data-sky-on="click"` on the buttons + `<span sky-id="…">0</span>`.

- [ ] **Step 4: Verify the live round-trip over SSE**

```bash
# open SSE in the background capturing patches, post an Increment, assert a text patch to the span arrives
# (extract sid from the cookie jar; find the + button's sky-id from /tmp/page.html)
# minimal harness:
( curl -s -N -b /tmp/jar "http://localhost:8000/_sky/sse" & echo $! >/tmp/sse.pid ) > /tmp/sse.out &
sleep 0.5
BTN=$(grep -oE 'sky-id="[^"]*_button"' /tmp/page.html | tail -1 | sed 's/sky-id="//;s/"//')
curl -s -b /tmp/jar -X POST http://localhost:8000/_sky/event \
  -H 'content-type: application/json' -d "{\"sky_id\":\"$BTN\",\"event\":\"click\",\"args\":[]}"
sleep 0.5
grep -i '"text":"1"' /tmp/sse.out && echo "LIVE-OK"
kill -9 $APP $(cat /tmp/sse.pid) 2>/dev/null
```
Expected: `LIVE-OK` — the SSE stream carried a patch setting the span's text to `1`.

- [ ] **Step 5: Commit**

```bash
git add examples/rust/28-live-counter
git commit -m "feat(rust): P1 gate — 28-live-counter increments live over SSE"
```

---

## Task 12: Regression sweep + README + Go parity

**Files:**
- Modify: `runtime-rust/README.md`

- [ ] **Step 1: Full Rust example sweep**

Run the standard build+run sweep across `examples/rust/*` (build-only for servers incl. 27/28). Expected: all pass (28/28 → now 30/30 with 27 + 28).

- [ ] **Step 2: Go regression**

```bash
cd examples/01-hello-world && rm -rf sky-out .skycache .skydeps
/home/arthur/Documentos/comp/sky/sky-out/sky build src/Main.sky 2>&1 | tail -1
```
Expected: `Build complete: sky-out/app`.

- [ ] **Step 3: FFI byte-identity (the bridge change touched Builder.hs)**

```bash
cd /home/arthur/Documentos/comp/sky && timeout 300 cabal test --test-options='--match "FfiGenGoKernelJson"' 2>&1 | tail -3
```
Expected: `1 example, 0 failures`.

- [ ] **Step 4: Update the README**

In `runtime-rust/README.md`: move Sky.Live from "Deferred — large arcs" to a new "🚧 In progress" line noting P0+P1 landed (static render + live counter over SSE); add 27-live-static + 28-live-counter rows to the examples table; bump the example count.

- [ ] **Step 5: Commit**

```bash
git add runtime-rust/README.md
git commit -m "docs(rust): sync README — Sky.Live P0+P1 (static render + live counter)"
```

---

## Self-review notes (carried into execution)

- **Diff scope:** P1 ships text/attr/inner-html-replace only; **keyed reorder is explicitly P6**, not a gap. The counter gate needs only `text`. The diff never emits a *wrong* patch — worst case it over-replaces a subtree.
- **`OnForm`/serde:** not in P0+P1 (no forms in the counter). The `OnForm` variant exists in the enum (Task 1) but its codegen + `decode_form` are **P2**. `resolve_form` is stubbed-but-present so the dispatch surface is complete.
- **Page wrap:** Task 5 ships a minimal wrap; Task 9 replaces it with the real client-bearing wrap. 27-live-static uses the scaffold `renderStatic` (printed HTML), 28-live-counter uses `live_app` (served).
- **Client JS:** Task 9 is a verbatim transliteration of `live.go`'s client — the one task that must be done by copying the Go source string, not rewritten. Budget time to match its patch-application + reconnect behavior exactly (the protocol contract).
- **Type consistency:** `Html<M>`/`Attribute<M>`/`Event<M>` (Task 1), `assign_sky_ids` (Task 2), `render_html` (Task 3), `Patch`/`diff` (Task 6), `HandlerIndex`/`build_index`/`resolve` (Task 7), `MemStore`/`LiveSession`/`SsePatch`/`frame` (Task 8), `render_page_full` (Task 9), `live_app`/`PatchEnvelope`/`driver` (Task 10) — names used consistently across tasks.
- **Go untouched:** every runtime change is under `runtime-rust/`; every codegen change is in `src/Sky/Generate/Rust/*` (the Rust target path) — the Go codegen + `runtime-go/` are never edited.
