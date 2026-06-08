# Rust Sky.Live P3 — URL Routing (full Go parity) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** `Live.app { …, routes = [ Live.route "/" Home, Live.route "/apps/:slug" AppDetail ], notFound = NotFound }`
works on the Rust backend with **Go parity**: the runtime matches the request URL
against `routes` in declaration order, captures `:param` segments, builds the
`Page` value (applying captured strings to the page constructor), and **injects it
into `model.page`** so `view` renders the right page — exactly as Go's
`applyRoute` + `RecordUpdate(model, {"Page": page})` does, but reflection-free.

**Architecture:** Go injects the page via reflection (`RecordUpdate`). Rust can't,
so: (1) each `Live.route pattern ctor` lowers (call-site peephole) to a
`Route<Page> { pattern, build: Arc<Fn(Vec<String>) -> Page> }` capturing the page
ctor at the site where its arity is known (same trick as `onSubmit`); (2) the
codegen detects the Model's `page` field and generates a **page-setter**
`Arc<Fn(Page, Model) -> Model> = |p, m| Model { page: p, ..m }` (the
reflection-equivalent); (3) a new runtime `live_app_routed` matches the URL →
`Page` → `set_page(page, model)` after `init` and on every `sky-nav` navigation,
then renders/patches. Apps WITHOUT a `page` field keep using the P1 `live_app`
(single route) unchanged. Route params reach the app through the Page ctor
(`AppDetail slug`), so no request-record bridging is needed for P3.

**Tech stack:** Rust runtime (`runtime-rust/src/sky_runtime/live/*`), Haskell
codegen (`src/Sky/Generate/Rust/Builder.hs`). Reuses the ported Go client JS
(`sky-nav` interception + `popstate` + `data-sky-path` already handled).

**Design source:** `runtime-rust/superpowers/specs/2026-06-07-rust-sky-live-design.md`
§2(a),(e); Go reference `runtime-go/rt/live.go` `matchRoute` / `applyRouteWithParams`.

**Scope (P3):** static + single-`:param` + multi-`:param` routes, declaration-order
match, `notFound` fallback, `sky-nav` + `popstate` full-page re-render. OUT (later):
a rich `req` record (path/query/params/method/headers/cookies) to `init`,
per-GET session reuse on navigation, query-string parsing.

---

## Go matching semantics (replicate exactly — `live.go`)

- `matchRoute(pattern, path)`: split both on `/`; segment counts must be equal;
  a `:name` pattern segment matches any non-empty path segment and captures it;
  a literal segment must equal the path segment. Returns the captured params in
  pattern order.
- `matchAnyRoute`: first route (declaration order) whose `matchRoute` succeeds.
  Empty `routes` + path `"/"` is the implicit root.
- `applyRouteWithParams`: first matching route → build its page; else `notFound`.
- Trailing-slash / exact-match handling: mirror `matchRoute` (study lines around
  `func matchRoute` in live.go — confirm the empty-segment + trailing-slash rules
  and replicate them in the Rust `match_route`).

---

## Task 1: `Route<Page>` + route matching (runtime)

**Files:**
- Create: `runtime-rust/src/sky_runtime/live/route.rs`
- Modify: `runtime-rust/src/sky_runtime/live/mod.rs` (`pub mod route; pub use route::*;`)

- [ ] **Step 1: Write failing tests**

In `route.rs`:
```rust
#[cfg(test)]
mod tests {
    use super::*;
    #[derive(Clone, Debug, PartialEq)]
    enum Page { Home, App(String), NF }

    fn routes() -> Vec<Route<Page>> {
        vec![
            Route::new("/", |_| Page::Home),
            Route::new("/apps/:slug", |p| Page::App(p[0].clone())),
        ]
    }

    #[test]
    fn matches_static_and_param_in_order() {
        let rs = routes();
        assert_eq!(match_routes(&rs, &Page::NF, "/"), Page::Home);
        assert_eq!(match_routes(&rs, &Page::NF, "/apps/foo"), Page::App("foo".into()));
        assert_eq!(match_routes(&rs, &Page::NF, "/nope"), Page::NF);          // notFound
        assert_eq!(match_routes(&rs, &Page::NF, "/apps"), Page::NF);          // arity mismatch
        assert_eq!(match_routes(&rs, &Page::NF, "/apps/"), Page::NF);         // empty param seg
    }
}
```

- [ ] **Step 2: Run — verify fail** (`cd runtime-rust && cargo test --features live matches_static_and_param`)

- [ ] **Step 3: Implement**

```rust
use std::sync::Arc;

/// A declared route: a URL pattern + a builder that applies the captured
/// `:param` strings (pattern order) to the page constructor. `Page: Clone`
/// because `notFound` is cloned on a miss.
#[derive(Clone)]
pub struct Route<Page> {
    pub pattern: String,
    pub build: Arc<dyn Fn(Vec<String>) -> Page + Send + Sync>,
}

impl<Page> Route<Page> {
    pub fn new(pattern: &str, build: impl Fn(Vec<String>) -> Page + Send + Sync + 'static) -> Self {
        Route { pattern: pattern.to_string(), build: Arc::new(build) }
    }
}

/// Match `path` against `pattern` (Go `matchRoute` parity): equal segment counts;
/// `:name` captures a non-empty segment; literals must match. Returns captured
/// params in pattern order, or None.
pub fn match_route(pattern: &str, path: &str) -> Option<Vec<String>> {
    let p_segs: Vec<&str> = pattern.trim_matches('/').split('/').collect();
    let u_segs: Vec<&str> = path.trim_matches('/').split('/').collect();
    // "/" trims to [""]; normalise both so root matches root.
    let norm = |v: Vec<&str>| if v == [""] { vec![] } else { v };
    let (p_segs, u_segs) = (norm(p_segs), norm(u_segs));
    if p_segs.len() != u_segs.len() { return None; }
    let mut params = Vec::new();
    for (ps, us) in p_segs.iter().zip(u_segs.iter()) {
        if let Some(name) = ps.strip_prefix(':') {
            let _ = name;
            if us.is_empty() { return None; }   // empty param segment
            params.push((*us).to_string());
        } else if ps != us {
            return None;
        }
    }
    Some(params)
}

/// First route (declaration order) whose pattern matches `path` → its built
/// page; else `not_found` (cloned). Go `applyRouteWithParams` parity.
pub fn match_routes<Page: Clone>(routes: &[Route<Page>], not_found: &Page, path: &str) -> Page {
    for rt in routes {
        if let Some(params) = match_route(&rt.pattern, path) {
            return (rt.build)(params);
        }
    }
    not_found.clone()
}
```
> Verify `match_route`'s root + trailing-slash behavior against Go's `matchRoute`
> (read it). Adjust `norm`/empty-segment handling to match exactly; add test cases
> for any Go edge case you find (e.g. `/apps/foo/` trailing slash).

- [ ] **Step 4: Wire + test** — add module to `live/mod.rs`; `cargo test --features live matches_static_and_param` → PASS.

- [ ] **Step 5: Commit** (NO co-author trailer)
```bash
git add runtime-rust/src/sky_runtime/live/route.rs runtime-rust/src/sky_runtime/live/mod.rs
git commit -m "feat(rust): Sky.Live Route<Page> + match_routes (Go matchRoute parity)"
```

---

## Task 2: `live_app_routed` runtime entry

**Files:**
- Modify: `runtime-rust/src/sky_runtime/live/mod.rs`

Add a routing-aware sibling to `live_app`. It is identical EXCEPT the GET page
handler, after `init`, computes the matched page and applies `set_page` before the
first `view`; and it serves the same SSE + event endpoints. Refactor the shared
driver/SSE/event internals so both entries reuse them (don't copy-paste the loop).

- [ ] **Step 1: Signature**
```rust
pub fn live_app_routed<E, Model, Msg, Page, FInit, FUpdate, FView, FSubs, FSetPage>(
    init: FInit, update: FUpdate, view: FView, subscriptions: FSubs,
    routes: Vec<route::Route<Page>>, not_found: Page, set_page: FSetPage,
) -> SkyTask<E, ()>
where
    E: From<String> + Send + 'static,
    Model: Clone + Send + 'static,
    Msg: Clone + Send + 'static,
    Page: Clone + Send + Sync + 'static,
    FInit: Fn(()) -> (Model, SkyCmd<Msg>) + Send + Sync + 'static,
    FUpdate: Fn(Msg, Model) -> (Model, SkyCmd<Msg>) + Send + Sync + 'static,
    FView: Fn(Model) -> Html<Msg> + Send + Sync + 'static,
    FSubs: Fn(Model) -> SkySub<Msg> + Send + Sync + 'static,
    FSetPage: Fn(Page, Model) -> Model + Send + Sync + 'static,
```

- [ ] **Step 2: GET handler applies the route**

In the page handler: `let (model0, cmd0) = init(()); let page = match_routes(&routes, &not_found, req_path); let model = set_page(page, model0);` then assign_sky_ids / build_index / store session / render as today. `req_path` is the axum request path (extract via the matched route path — add an axum `Path`/`OriginalUri` extractor; for `/*path` capture, read `uri.path()`). Store `routes`/`not_found`/`set_page` (Arc'd) in `LiveState` so the handler closure can use them.

- [ ] **Step 3: sky-nav navigation**

A `sky-nav` link / `popstate` makes the client re-`GET` the URL with header
`X-Sky-Nav: 1`, expecting a full-body patch. For P3, the page handler returning a
full HTML document on that GET is acceptable (the client's `__skyPatch`
full-body-replaces). Confirm the ported client sends `X-Sky-Nav` and consumes the
response as a full-body swap; if it expects a patch envelope instead, return the
full HTML (the client handles both — verify in `client.js`). Re-rendering applies
the new route → new page → new `model` (new session is OK for P3; per-GET session
reuse is tracked separately).

- [ ] **Step 4: Build** — `cargo build --features live` clean (no example yet).

- [ ] **Step 5: Commit** (NO co-author trailer)
```bash
git add runtime-rust/src/sky_runtime/live/mod.rs
git commit -m "feat(rust): Sky.Live live_app_routed — URL match -> set_page on GET + nav"
```

---

## Task 3: Codegen — `Live.route` call-site peephole

**Files:**
- Modify: `src/Sky/Generate/Rust/Builder.hs`

`Live.route pattern pageCtor` must lower to
`route::Route::new(<pattern>, { let __c = <pageCtor>; move |__p: Vec<String>| <apply __c to __p> })`.
The closure's body applies the captured param strings to the page ctor by arity:
nullary page value → ignore params (`move |_p| <pageCtor>.clone()` — but a bare
ctor value isn't Clone-captured; emit `move |_p| <pageCtor>`); N-ary ctor →
`<pageCtor>(__p[0].clone(), …, __p[N-1].clone())`.

- [ ] **Step 1: Find the head form + arity source**

Mirror the `onSubmit` peephole (added in P2) and the `Live.app` peephole. The call
is `Can.Call (Ann.At _ (Can.VarKernel "Live" "route")) [patternArg, ctorArg]`
(confirm `VarKernel "Live" "route"` — `Live.route` is a static kernel). Get the
ctor's arity from its type: `Map.lookup region (ecRegionTypes ctx)` on `ctorArg`'s
region → `extractParamTypes` length = N. (A nullary Page value has 0 params.)

- [ ] **Step 2: Emit**

```
route::Route::new(<patternStr>, {
    let __c = <ctorStr>;
    move |__p: Vec<String>| __c(__p[0].clone(), __p[1].clone(), … N args …)
})
```
For N == 0: `move |_p: Vec<String>| __c` (the page value; if it's a value not a
fn, just `__c`). Confirm the page ctor lowers as a callable when N>0 (a Sky ADT
ctor `AppDetail : String -> Page` lowers to a Rust fn/tuple-variant constructor —
verify it's callable as `__c(arg)`; if it's an enum variant it is). `<patternStr>`
is the string literal; `<ctorStr> = exprToRustString ctx ctorArg`.

- [ ] **Step 3: Build the compiler** (`timeout 1800 cabal install …`). No gate yet.

- [ ] **Step 4: Commit** (NO co-author trailer)
```bash
git add src/Sky/Generate/Rust/Builder.hs
git commit -m "feat(rust): codegen — Live.route lowers to Route::new with param-applying closure"
```

---

## Task 4: Codegen — `Live.app` routing mode + generated page-setter

**Files:**
- Modify: `src/Sky/Generate/Rust/Builder.hs`

Extend the existing `Live.app` record-splice peephole. Detect whether the app's
`Model` has a `page` field; if so, emit `live_app_routed` with routes + notFound +
a generated `set_page`; else keep emitting `live_app` (P1, single route).

- [ ] **Step 1: Get the Model type + detect a `page` field**

In the `Live.app` peephole, the cfg record's `init` field has type
`() -> (Model, Cmd Msg)` (or `view : Model -> Html Msg`). Recover `Model` from the
solved type of the `view`/`init` field expr (region type → for `view`, the param
type is `Model`). Look up `Model`'s record fields (the record alias map the codegen
already builds — `ecRecordMap`/the alias env). `hasPageField = "page" \`elem\` fieldNames`.
Also get `Page`'s Rust type (the type of the `page` field) for the setter + routes.

- [ ] **Step 2: Routing-mode emission**

When `hasPageField`:
```
live_app_routed(
    <init>, <update>, <view>, <subscriptions>,
    vec![<route0>, <route1>, …],          // from the `routes` field list (each via Task-3 peephole)
    <notFound>,                            // from the `notFound` field
    { move |__page: <PageRustTy>, __model: <ModelRustTy>| <ModelRustTy> { page: __page, ..__model } },
)
```
The `routes` field is a `Can.List` of `Live.route …` calls — emit each element
(they hit the Task-3 peephole) into the `vec![…]`. `notFound` is the field expr.
The `set_page` closure uses Rust struct-update syntax; the Rust field name for Sky
`page` is `page` (lowercase — confirm via how records lower, e.g. `MainCreds { email }`).
`<ModelRustTy>` is the Model record's Rust struct name (e.g. `MainModel`).

When NOT `hasPageField`: emit `live_app(<init>, <update>, <view>, <subscriptions>)`
exactly as today (counter/form keep working — their `routes=[route "/" ()]` /
`notFound=()` are dropped, single-page).

- [ ] **Step 3: Build the compiler.**

- [ ] **Step 4: Commit** (NO co-author trailer)
```bash
git add src/Sky/Generate/Rust/Builder.hs
git commit -m "feat(rust): codegen — Live.app routing mode (page-field detect + generated set_page)"
```

---

## Task 5: P3 gate — `examples/rust/30-live-routing`

**Files:**
- Create: `examples/rust/30-live-routing/sky.toml`, `examples/rust/30-live-routing/src/Main.sky`

- [ ] **Step 1: Write a 3-page app with a `:param` route**
```elm
module Main exposing (main)

import Sky.Core.Prelude exposing (..)
import Sky.Core.Task as Task
import Std.Html as Html
import Std.Html.Attributes as Attr
import Std.Live as Live
import Std.Cmd as Cmd
import Std.Sub as Sub
import Sky.Core.Error exposing (Error)


type Page = Home | AppDetail String | NotFound


type alias Model = { page : Page }


type Msg = NoOp


init : () -> ( Model, Cmd Msg )
init _ = ( { page = Home }, Cmd.none )


update : Msg -> Model -> ( Model, Cmd Msg )
update _ model = ( model, Cmd.none )


view : Model -> Html.Html Msg
view model =
    case model.page of
        Home -> Html.div [] [ Html.h1 [] [ Html.text "Home" ]
                            , Html.a [ Attr.href "/apps/sky", Attr.attribute "sky-nav" "" ] [ Html.text "Sky app" ] ]
        AppDetail slug -> Html.div [] [ Html.h1 [] [ Html.text ("App: " ++ slug) ] ]
        NotFound -> Html.div [] [ Html.h1 [] [ Html.text "404" ] ]


subscriptions : Model -> Sub Msg
subscriptions _ = Sub.none


main : Task Error ()
main =
    Live.app
        { init = init, update = update, view = view, subscriptions = subscriptions
        , routes = [ Live.route "/" Home, Live.route "/apps/:slug" AppDetail ]
        , notFound = NotFound
        }
```
(Confirm `Attr.href` / `Attr.attribute` exist: `grep -nE "href|^attribute " sky-stdlib/Std/Html/Attributes.sky`.)

- [ ] **Step 2: Build + codegen check**
```bash
cd examples/rust/30-live-routing && rm -rf sky-out .skycache
/home/arthur/Documentos/comp/sky/sky-out/sky build src/Main.sky 2>&1 | tail -4
grep -nE "live_app_routed|Route::new|set_page|\.\.__model|page: __page" sky-out/Rust/src/main.rs | head
```
Expected: `Build complete`; `live_app_routed(...)` with a `vec![Route::new("/", …), Route::new("/apps/:slug", …)]`, `NotFound`, and a `MainModel { page: __page, ..__model }` setter.

- [ ] **Step 3: Routing gate (HTTP)**
```bash
cd examples/rust/30-live-routing
timeout 45 ./sky-out/Rust/target/debug/sky-app &   # or run_in_background
sleep 1.5
echo "--- GET / (expect Home) ---"
curl -s http://localhost:8000/ | grep -oE '<h1[^>]*>[^<]*</h1>' | head -1
echo "--- GET /apps/sky (expect App: sky) ---"
curl -s http://localhost:8000/apps/sky | grep -oE '<h1[^>]*>[^<]*</h1>' | head -1
echo "--- GET /nope (expect 404) ---"
curl -s http://localhost:8000/nope | grep -oE '<h1[^>]*>[^<]*</h1>' | head -1
pkill -9 -f "30-live-routing/sky-out"
```
Expected: `Home`; `App: sky`; `404`. (Proves declaration-order match, `:slug`
capture → `AppDetail "sky"` page injected into `model.page`, and `notFound`.)

- [ ] **Step 4: Commit** (NO co-author trailer)
```bash
git add examples/rust/30-live-routing
git commit -m "feat(rust): P3 gate — 30-live-routing matches URL -> page (static + :param + notFound)"
```

---

## Task 6: Regression + README

**Files:** Modify `runtime-rust/README.md`

- [ ] **Step 1: Regression** — `cargo test --features live` all pass; 27/28/29 rebuild green with the new compiler (the `Live.app` peephole now branches on the page field — confirm counter/form, which have NO page field, still emit `live_app` and round-trip); Go hello-world builds; `cabal test --test-options='--match "FfiGenGoKernelJson"'` 0 failures.
- [ ] **Step 2: README** — bump example count to 30; add a 30-live-routing row; update the Sky.Live section: P3 (URL routing, full Go parity — page-injection) landed; move routing out of the Ahead list.
- [ ] **Step 3: Commit** (NO co-author trailer)
```bash
git add runtime-rust/README.md
git commit -m "docs(rust): sync README — Sky.Live P3 (URL routing, Go-parity page injection)"
```

---

## Self-review notes

- **The reflection-equivalent** is the generated `set_page` closure (Task 4) + the
  route-ctor closures (Task 3). Together they replace Go's `RecordUpdate(model,
  {"Page": page})` with static Rust. Params reach the app via the Page ctor, not a
  req record — so no request-record bridging in P3.
- **Backward-compatible:** apps without a `page` field (counter/form) keep emitting
  `live_app`. The page-field detection is the switch. Verify those still work.
- **Scope:** static + `:param` routes, declaration-order, `notFound`, sky-nav
  full-page re-render. A rich `req` (path/query/params/method/headers/cookies) to
  `init`, query parsing, and per-GET session reuse on navigation are later.
- **No Go changes; no shared `.sky` changes** (Live.route/app types already exist).
  All codegen is `--target rust`.
