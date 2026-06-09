# Rust Sky.Live P4 — Typed Request to `init` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** `init req` on the Rust backend receives a typed request record so apps
can read `req.path`, `req.query`, `req.method`, `req.params`, `req.headers`,
`req.cookies` (e.g. `Dict.get "sky_sid" req.cookies` to bootstrap a session on
first render). Matches the modern v0.16.7+ Go convention (record access), not the
old heterogeneous-Dict form (`Dict.get "path" req`) which clashes with Rust's
no-`any` rule.

**Architecture:** A runtime `LiveReq` struct with the six typed fields, built from
the axum request in the page handler. `init`'s arg becomes `LiveReq` (was `()`).
The shared kernel type keeps `init : req -> …` FREE (no Go-affecting change —
pinning it would break Go example 13 / skyshop's Dict-access). Instead a **Rust
codegen pre-pass** collects the fn(s) used as a `Live.app` cfg's `init` field and
types their first param as `sky_runtime::LiveReq`; field accesses (`req.path`,
`req.cookies`) lower to `.field` against `LiveReq`. Route `:params` (already
delivered to apps via the Page ctor in P3) are ALSO surfaced in `req.params`.

**Tech stack:** Rust runtime (`runtime-rust/src/sky_runtime/live/*`), Haskell
codegen (`src/Sky/Generate/Rust/Builder.hs`). `SkyDict<T> = HashMap<String,T>`;
`dict_from_list` builds dicts; `parse_cookies` (server.rs) parses the Cookie
header.

**Scope (P4):** the six request fields to `init`, top-level-ref init fns. OUT:
inline-lambda `init = \req -> …` (top-level `init = init` only), query-string
*parsing* into a Dict (`req.query` is the raw string; apps use
`Sky.Core.Http.parseQuery`), `update`/handlers receiving req.

---

## Task 1: `LiveReq` runtime type + builder

**Files:**
- Modify: `runtime-rust/src/sky_runtime/live/mod.rs` (or new `live/req.rs` + wire into mod.rs)

- [ ] **Step 1: Define `LiveReq`**
```rust
use crate::sky_runtime::dict::SkyDict;

/// The request context passed to a Sky.Live `init`. Mirrors the modern Go
/// `req` record (v0.16.7+): `req.path`, `req.query`, `req.method` are strings;
/// `req.params`, `req.headers`, `req.cookies` are `Dict String String`.
#[derive(Clone, Debug)]
pub struct LiveReq {
    pub path: String,
    pub query: String,
    pub method: String,
    pub params: SkyDict<String>,
    pub headers: SkyDict<String>,
    pub cookies: SkyDict<String>,
}
```

- [ ] **Step 2: Builder from the axum request**
```rust
/// Build a `LiveReq` from the incoming request parts + the matched route params.
pub fn live_req(
    method: &axum::http::Method,
    uri: &axum::http::Uri,
    headers: &axum::http::HeaderMap,
    params: SkyDict<String>,
) -> LiveReq {
    let mut hdrs: SkyDict<String> = SkyDict::new();
    for (k, v) in headers.iter() {
        if let Ok(val) = v.to_str() {
            // canonical-case header name (axum lowercases; Title-Case for parity)
            hdrs.insert(canonical_header(k.as_str()), val.to_string());
        }
    }
    let mut cookies: SkyDict<String> = SkyDict::new();
    if let Some(c) = headers.get(axum::http::header::COOKIE).and_then(|v| v.to_str().ok()) {
        for pair in c.split(';') {
            let pair = pair.trim();
            if let Some((k, v)) = pair.split_once('=') {
                cookies.insert(k.trim().to_string(), v.trim().to_string());
            }
        }
    }
    LiveReq {
        path: uri.path().to_string(),
        query: uri.query().unwrap_or("").to_string(),
        method: method.as_str().to_string(),
        params,
        headers: hdrs,
        cookies,
    }
}

fn canonical_header(k: &str) -> String {
    // Title-Case each `-`-separated token: "content-type" -> "Content-Type".
    k.split('-').map(|w| {
        let mut c = w.chars();
        match c.next() {
            Some(f) => f.to_ascii_uppercase().to_string() + &c.as_str().to_ascii_lowercase(),
            None => String::new(),
        }
    }).collect::<Vec<_>>().join("-")
}
```
> If a `parse_cookies` helper already exists in `live/mod.rs` or is reachable,
> reuse it instead of the inline cookie split. Check `sid_from_cookie` (live/mod.rs)
> for the existing parse pattern.

- [ ] **Step 3: unit test**
```rust
#[test]
fn live_req_parses_headers_and_cookies() {
    let mut h = axum::http::HeaderMap::new();
    h.insert(axum::http::header::COOKIE, "sky_sid=abc; theme=dark".parse().unwrap());
    h.insert("x-custom", "v".parse().unwrap());
    let uri: axum::http::Uri = "/apps/sky?q=1".parse().unwrap();
    let req = live_req(&axum::http::Method::GET, &uri, &h, crate::sky_runtime::dict::dict_empty());
    assert_eq!(req.path, "/apps/sky");
    assert_eq!(req.query, "q=1");
    assert_eq!(req.method, "GET");
    assert_eq!(req.cookies.get("sky_sid").map(String::as_str), Some("abc"));
    assert_eq!(req.cookies.get("theme").map(String::as_str), Some("dark"));
    assert_eq!(req.headers.get("X-Custom").map(String::as_str), Some("v"));
}
```
Run: `cd runtime-rust && cargo test --features live live_req_parses` → PASS.

- [ ] **Step 4: Commit** (NO co-author trailer)
```bash
git add runtime-rust/src/sky_runtime/live/
git commit -m "feat(rust): Sky.Live LiveReq — typed request record + axum builder"
```

---

## Task 2: pass `LiveReq` to `init` (live_app + live_app_routed)

**Files:**
- Modify: `runtime-rust/src/sky_runtime/live/mod.rs`

- [ ] **Step 1: `route_resolver` returns params too**

Change `route_resolver` from `Fn(Model, &str) -> Model` to
`Fn(Model, &str) -> (Model, SkyDict<String>)` (the second element is the matched
route's `:name`→value params for `req.params`). `live_app`'s resolver:
`Arc::new(|m, _path| (m, dict_empty()))`. `live_app_routed`'s resolver:
`Arc::new(move |m, path| (set_page(match_routes(&routes, &not_found, path), m), route::match_params(&routes, path)))`.

Add `match_params` to `route.rs`:
```rust
/// Name→value params for the first route matching `path` (Dict for req.params).
pub fn match_params<Page>(routes: &[Route<Page>], path: &str) -> crate::sky_runtime::dict::SkyDict<String> {
    use crate::sky_runtime::dict::SkyDict;
    for rt in routes {
        if let Some(values) = match_route(&rt.pattern, path) {
            let names: Vec<String> = split_path_pub(&rt.pattern).into_iter()
                .filter(|s| s.starts_with(':')).map(|s| s[1..].to_string()).collect();
            let mut d: SkyDict<String> = SkyDict::new();
            for (n, v) in names.into_iter().zip(values) { d.insert(n, v); }
            return d;
        }
    }
    SkyDict::new()
}
```
(Expose `split_path` as `split_path_pub` or inline the same trim/split logic; keep `split_path` private if preferred and duplicate the 2 lines.)

- [ ] **Step 2: `FInit` bound + page handler build req**

Change the `FInit` bound in `live_app`, `live_app_routed`, `serve_live`, the
`page` handler, and `LiveState` from `Fn(()) -> (Model, SkyCmd<Msg>)` to
`Fn(LiveReq) -> (Model, SkyCmd<Msg>)`. In the `page` handler add the
`method`/`headers` extractors (it already has `uri`): signature
`(State(st), method: axum::http::Method, uri: axum::http::Uri, headers: axum::http::HeaderMap)`.
Replace `let (model, cmd0) = (st.init)(());` + the resolver call with:
```rust
let (model0, cmd0) = {
    // resolver gives the routed model + the matched params (empty when unrouted).
    // Build req AFTER init so init sees a complete request; but the model needs
    // the page from the resolver. Order: init(req) first, then apply routing.
    let (m0, _c) = ((), ());  // placeholder — see real order below
    (m0, _c)
};
```
REAL order (important): `init` must receive the `req` (with params), and the
routed page must be injected. Do:
```rust
let (model_after_route, params) = (st.route_resolver)(/* model from init */, uri.path());
```
but `route_resolver` takes the model, which comes from `init`, which needs `req`,
which needs `params`, which comes from `route_resolver`. Break the cycle: compute
`params` directly first via a SECOND resolver, OR split routing into "params" +
"set_page". Simplest: change `route_resolver` to `Fn(Model,&str)->(Model,SkyDict)`
and compute params independently of the model by calling it with a *throwaway*
isn't possible (needs model). Instead, compute params via a separate
`Fn(&str)->SkyDict` captured closure `param_resolver` (no model dependency):
- Add `param_resolver: Arc<dyn Fn(&str) -> SkyDict<String> + Send + Sync>` to
  `LiveState`. `live_app`: `Arc::new(|_| dict_empty())`. `live_app_routed`:
  `Arc::new(move |path| route::match_params(&routes2, path))` (clone the routes Arc).
- Keep `route_resolver: Fn(Model,&str)->Model` (set_page only) as in P3.
Page handler:
```rust
let params = (st.param_resolver)(uri.path());
let req = live_req(&method, &uri, &headers, params);
let (model0, cmd0) = (st.init)(req);
let model = (st.route_resolver)(model0, uri.path());
```
This builds req (with params) → init(req) → set_page. Clean, no cycle.

- [ ] **Step 3: build** — `cargo build --features live` clean.

- [ ] **Step 4: Commit** (NO co-author trailer)
```bash
git add runtime-rust/src/sky_runtime/live/mod.rs runtime-rust/src/sky_runtime/live/route.rs
git commit -m "feat(rust): Sky.Live init receives LiveReq (path/query/method/params/headers/cookies)"
```

---

## Task 3: codegen — type `Live.app` init param as `LiveReq`

**Files:**
- Modify: `src/Sky/Generate/Rust/Builder.hs`

The shared kernel type leaves `init`'s arg FREE (Go-safe). The Rust codegen must
type the init fn's first param as `sky_runtime::LiveReq` so `req.path` /
`req.cookies` resolve. Mechanism: a pre-pass (mirror the form-target pre-pass)
collecting init-fn names used as a `Live.app` cfg `init` field, then override
param 0's Rust type when emitting those fns.

- [ ] **Step 1: pre-pass `collectLiveInitFns`**

Walk all modules for the `Live.app` cfg (the record-splice peephole's input): the
`init` field expr. When it's a top-level ref `Can.VarTopLevel mod name` (e.g.
`Main.init`), record the fn's Rust codegen name (e.g. `main_init` via the same
mangling `exprToRustString`/`toSnakeCase(modPrefix ++ "_" ++ name)` produces). If
the init field is a lambda (not a top-level ref), SKIP (P4 scope: top-level init
only) — those keep the `()` shape; note it. Store the set in `BuilderState`
(mirror `builderFormTargets`).

- [ ] **Step 2: override param 0 type when emitting an init fn**

Find where a top-level fn's signature/params are emitted (the param type comes
from its solved type via `typeToRustString`). When the fn's Rust name is in the
live-init set, emit its FIRST param's type as `sky_runtime::LiveReq` (regardless
of what HM inferred — free `()` or an open record). The body's `req.path` /
`req.cookies` accesses lower to `.field` (Rust field access; `LiveReq` has
`path`/`query`/`method`/`params`/`headers`/`cookies`, lowercase). `Dict.get "k"
req.cookies` lowers to a dict_get over `req.cookies : SkyDict<String>` — works
because `LiveReq.cookies` is `SkyDict<String>`.

> If HM generated a dead anon-record struct for the inferred req, it becomes
> unused (a `dead_code` warning at worst) — acceptable; suppress only if it
> errors. Verify the field-access lowering doesn't depend on the inferred record's
> field-index ordering in a way that breaks against `LiveReq` (Sky `req.path` →
> Rust `req.path` by name, so it shouldn't).

- [ ] **Step 3: build the compiler** (`timeout 1800 cabal install …`).

- [ ] **Step 4: Commit** (NO co-author trailer)
```bash
git add src/Sky/Generate/Rust/Builder.hs
git commit -m "feat(rust): codegen — type Live.app init param as sky_runtime::LiveReq"
```

---

## Task 4: P4 gate — `examples/rust/31-live-req`

**Files:**
- Create: `examples/rust/31-live-req/sky.toml`, `examples/rust/31-live-req/src/Main.sky`

- [ ] **Step 1: Write an app reading `req` in init**
```elm
module Main exposing (main)

import Sky.Core.Prelude exposing (..)
import Sky.Core.Task as Task
import Std.Html as Html
import Std.Html.Attributes as Attr
import Std.Live as Live
import Std.Cmd as Cmd
import Std.Sub as Sub
import Sky.Core.Dict as Dict
import Sky.Core.Error exposing (Error)


type alias Model = { lastPath : String, sid : String, method : String }


type Msg = NoOp


init : LiveReqShim -> ( Model, Cmd Msg )
init req =
    ( { lastPath = req.path
      , sid = Maybe.withDefault "none" (Dict.get "sky_sid" req.cookies)
      , method = req.method
      }
    , Cmd.none
    )


update : Msg -> Model -> ( Model, Cmd Msg )
update _ model = ( model, Cmd.none )


view : Model -> Html.Html Msg
view model =
    Html.div []
        [ Html.p [] [ Html.text ("path: " ++ model.lastPath) ]
        , Html.p [] [ Html.text ("sid: " ++ model.sid) ]
        , Html.p [] [ Html.text ("method: " ++ model.method) ]
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
> `LiveReqShim`: the kernel leaves `req` free, so `init`'s annotation can't name a
> concrete type. EASIEST: drop the `init` type annotation entirely (`init req = …`)
> so HM infers the open record from `req.path`/`req.cookies`/`req.method` and the
> codegen overrides it to `LiveReq`. Use that — DELETE the `init : … ->` line and
> the `LiveReqShim` reference. Confirm the un-annotated `init` type-checks (it
> should — req is an open record inferred from field access).

- [ ] **Step 2: Build + codegen check**
```bash
cd examples/rust/31-live-req && rm -rf sky-out .skycache
/home/arthur/Documentos/comp/sky/sky-out/sky build src/Main.sky 2>&1 | tail -4
grep -nE "fn main_init\(.*LiveReq|req\.path|req\.cookies" sky-out/Rust/src/main.rs | head
```
Expected: `Build complete`; `fn main_init(req: sky_runtime::LiveReq)` (or `LiveReq`); `req.path` / `req.cookies` accesses.

- [ ] **Step 3: HTTP gate**
```bash
cd examples/rust/31-live-req
timeout 45 ./sky-out/Rust/target/debug/sky-app &   # or run_in_background
sleep 1.5
echo "--- GET /hello with a cookie ---"
curl -s -H 'Cookie: sky_sid=abc123; x=y' http://localhost:8000/hello | grep -oE '<p[^>]*>[^<]*</p>'
pkill -9 -f "31-live-req/sky-out"
```
Expected three `<p>`s: `path: /hello`, `sid: abc123`, `method: GET`. (Proves
`req.path` + `req.cookies` via `Dict.get` + `req.method` all flow.)

- [ ] **Step 4: Commit** (NO co-author trailer)
```bash
git add examples/rust/31-live-req
git commit -m "feat(rust): P4 gate — 31-live-req reads req.path/cookies/method in init"
```

---

## Task 5: Regression + README

**Files:** Modify `runtime-rust/README.md`

- [ ] **Step 1: Regression** — `cargo test --features live` all pass; rebuild
27/28/29/30 with the new compiler (their `init _ = …` ignores req — confirm they
still build + 28 click + 30 routing round-trip; the init param is now `LiveReq`
but ignored). Go hello-world builds; `cabal test --test-options='--match
"FfiGenGoKernelJson"'` 0 failures.
- [ ] **Step 2: README** — bump example count to 31; add a 31-live-req row;
update the Sky.Live section: P4 (typed `LiveReq` to init — path/query/method/
params/headers/cookies) landed; move it out of the Ahead list. Note the
divergence from Go's heterogeneous-Dict req (Rust uses the typed-record form).
- [ ] **Step 3: Commit** (NO co-author trailer)
```bash
git add runtime-rust/README.md
git commit -m "docs(rust): sync README — Sky.Live P4 (typed LiveReq to init)"
```

---

## Self-review notes

- **No shared-type change** — the kernel keeps `init : req -> …` free (Go-safe;
  skyshop's Dict-access keeps compiling on Go). The Rust codegen alone pins the
  init param to `LiveReq`. Rust apps use the modern record form (`req.path`).
- **The cycle** (init needs req.params, params need routing, routing needs the
  model from init) is broken by a `param_resolver: Fn(&str)->SkyDict` that's
  independent of the model — compute params from the path, build req, init(req),
  then set_page.
- **Scope:** top-level-ref `init` only (lambda-init skipped); `req.query` is the
  raw string (parse via `Sky.Core.Http.parseQuery`); req reaches `init` only (not
  update/handlers). All-`String`-valued dicts (params/headers/cookies).
- **Backward-compatible:** `init _ = …` apps ignore the `LiveReq` param; 27–30
  rebuild unchanged in behavior.
