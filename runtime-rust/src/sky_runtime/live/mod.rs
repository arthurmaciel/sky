//! Sky.Live on the Rust backend — HTTP-first render + SSE patch loop.
//! Generic over the app's (Model, Msg); no `any`, static dispatch only.
pub mod diff;
pub use diff::*;
pub mod dispatch;
pub use dispatch::*;
pub mod sse;
pub use sse::*;
pub mod form;
pub use form::*;
pub mod route;
pub use route::*;
pub mod req;
pub use req::*;
pub mod store;
pub use store::*;
pub mod pubsub;
// Explicit re-export of ONLY the codegen-referenced kernel functions. A glob
// (`pub use pubsub::*`) leaked the broker's `Event<T>` into this namespace,
// colliding with the HTML `Event` enum re-exported below (`pub use …html::*`)
// and surfacing as `error: `Event` is ambiguous` in generated code that names
// `sky_runtime::Event`. The broker internals (`Event`, `Broker`, `broker`,
// `subscribe`, `publish`) are `pub(crate)` in pubsub.rs — they never leave the
// crate, so they don't need re-exporting here.
pub use pubsub::{
    cmd_publish, cmd_publish_no_echo, pubsub_publish, pubsub_publish_no_echo,
    sub_subscribe_topic,
};

// Html ADTs + renderer now live in the standalone top-level `html` module;
// re-export them so live submodules (diff.rs, store.rs, …) that `use super::*`
// still see Html / Attribute / Event / render_html / html_render_.
pub use crate::sky_runtime::html::*;

use super::*;

// ─── Client assets ────────────────────────────────────────────────────────────

/// The browser-side Sky.Live client, extracted verbatim from Go's
/// `liveJSWithCfgAndCsrfWithBase` template (runtime-go/rt/live.go:5853-7490).
/// The 12 header `%`-verb lines are replaced with P1 static literals;
/// the two `%%` CSS escapes are un-escaped to `%`.
const CLIENT_JS: &str = include_str!("client.js");

/// Minimal CSS reset injected into every Sky.Live page.
/// Ported verbatim from Go's `liveBaseCSS` (runtime-go/rt/live.go:3847-3858).
const BASE_CSS: &str = concat!(
    "*,*::before,*::after{box-sizing:border-box}",
    "html,body{margin:0;padding:0;min-height:100%}",
    "body{min-height:100vh;display:flex;flex-direction:column;font-family:-apple-system,BlinkMacSystemFont,\"Segoe UI\",Roboto,\"Helvetica Neue\",Arial,sans-serif;line-height:1.4}",
    "#sky-root{display:flex;flex-direction:column;flex:1 0 auto;min-height:0}",
    "h1,h2,h3,h4,h5,h6,p,ul,ol,li,figure,blockquote,pre,dl,dd{margin:0;padding:0;font-weight:inherit;font-size:inherit}",
    "button,input,select,textarea{font:inherit;color:inherit}",
    "button{background:none;border:0;padding:0;cursor:pointer;text-align:inherit}",
    "a{color:inherit;text-decoration:none}",
    "img,video,canvas,svg{display:block;max-width:100%}",
);

// ─── Page renders ─────────────────────────────────────────────────────────────

/// P0 scaffold: render `view(model)` to a full HTML page and print it.
/// Replaced by `live_app` in P1 (Task 10); exists so the bridge + render
/// path is gate-testable now.
pub fn live_render_static<E, Model, Msg, FView>(
    view: FView,
    model: Model,
) -> SkyTask<E, ()>
where
    E: Send + 'static,
    Model: Send + 'static,
    Msg: Send + 'static,
    FView: Fn(Model) -> Html<Msg> + Send + 'static,
{
    Box::pin(async move {
        let mut tree = view(model);
        assign_sky_ids(&mut tree, "r");
        println!("{}", render_page(&render_html(&tree)));
        SkyResult::Ok(())
    })
}

/// Minimal page wrap (P0). Kept byte-identical so example 27-live-static
/// continues to pass. The full client-bearing wrap is `render_page_full`.
pub fn render_page(body: &str) -> String {
    format!(
        "<!DOCTYPE html><html><head><meta charset=\"utf-8\"></head><body><div id=\"sky-root\">{body}</div></body></html>"
    )
}

/// Full page wrap with the live client embedded.
/// Mirrors Go's live page render (runtime-go/rt/live.go:3788).
///
/// `sid`  — session id (injected into the JS via `window.__SKY_SID`).
/// `base` — sub-app base path, e.g. "" for root-mounted apps.
/// `body` — pre-rendered HTML body (from `render_html`).
///
/// The JS client reads `window.__SKY_SID` / `window.__SKY_BASE` from the
/// page rather than receiving them as Sprintf args — the 12 header vars in
/// `client.js` are static P1 literals that reference those window globals.
pub fn render_page_full(sid: &str, base: &str, body: &str) -> String {
    // sid_js / base_js: Rust Debug ("{:?}") of a &str yields a
    // double-quoted, properly-escaped JS string literal for plain ASCII
    // session ids and base paths.
    let sid_js = format!("{sid:?}");
    let base_js = format!("{base:?}");
    format!(
        "<!DOCTYPE html><html><head>\
         <meta charset=\"utf-8\">\
         <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\
         <meta name=\"sky-base\" content=\"{base}\">\
         <style>{BASE_CSS}</style>\
         </head>\
         <body><div id=\"sky-root\">{body}</div>\
         <script>window.__SKY_SID={sid_js};window.__SKY_BASE={base_js};\n{CLIENT_JS}</script>\
         </body></html>"
    )
}

// ─── live_app: axum mount + per-session TEA driver over SSE (Task 10) ───────

use crate::sky_runtime::tea::{SkyCmd, SkySub};
use std::sync::{Arc, Mutex};
use tokio::sync::mpsc::{UnboundedSender, UnboundedReceiver, unbounded_channel};

/// Per-session live state behind an `Arc<Mutex<…>>`. `index` / `last_view` are
/// re-derived on every commit; `sse_tx` is filled when the browser attaches the
/// SSE channel; `msg_tx` feeds the per-session driver loop.
pub struct SessionEntry<Model, Msg> {
    pub model: Model,
    pub last_view: Html<Msg>,
    pub index: HandlerIndex<Msg>,
    pub seq: u64,
    pub sse_tx: Option<SseTx>,
    pub msg_tx: UnboundedSender<Msg>,
}

/// SSE patches envelope. The browser client (`live/client.js`) consumes the
/// `event: patches` frame as `{globalSeq, patches}` and routes it through
/// `__skyHandleResponse(undefined, _, _, globalSeq)` → `__skyApplyPatches`.
/// We use `globalSeq` (the server-owned broadcast counter) rather than the
/// local `seq` so it never collides with the client's own POST-local seq gate.
#[derive(serde::Serialize)]
struct PatchEnvelope<'a> {
    #[serde(rename = "globalSeq")]
    global_seq: u64,
    patches: &'a [crate::sky_runtime::live::diff::Patch],
}

/// Wire shape POSTed by the browser client to `/_sky/event`
/// (`live/client.js` __skySend): `{sessionId, seq, msg, args, handlerId}`.
/// `handlerId` is the element's `data-sky-hid` (== its sky-id); `msg` is the
/// `sky-<event>` marker. We resolve handlers server-side by sky-id + event,
/// so `handlerId` is the authoritative locator; `event` is derived below.
#[derive(serde::Deserialize)]
struct EventBody {
    #[serde(default)]
    #[serde(rename = "sessionId")]
    session_id: String,
    #[serde(default)]
    #[serde(rename = "handlerId")]
    handler_id: String,
    /// Some senders use `id` instead of `handlerId`; accept both.
    #[serde(default)]
    id: String,
    /// Event name. The client posts the `sky-<event>` marker value as `msg`;
    /// `render_html` makes that value the event name (click / input / submit / …),
    /// so `msg` is the authoritative event. `event` is an explicit-override slot
    /// for future senders. Resolution: `event` ?: `msg` ?: "click".
    #[serde(default)]
    event: String,
    #[serde(default)]
    msg: String,
    /// Event args. For click/input/keydown `args[0]` is a string; for `submit`
    /// `args[0]` is the form-data object `{name: value, …}`. Parsed as JSON
    /// values so both shapes decode.
    #[serde(default)]
    args: Vec<serde_json::Value>,
}

/// Coerce a wire arg `Value` to the string the click/input/keydown path expects.
fn value_to_string(v: &serde_json::Value) -> String {
    match v {
        serde_json::Value::String(s) => s.clone(),
        other => other.to_string(),
    }
}


/// Boxed route resolver: a freshly-`init`'d model + GET path → the model whose
/// `page` field reflects the matched route.
type RouteResolver<Model> = Arc<dyn Fn(Model, &str) -> Model + Send + Sync>;
/// Boxed param resolver: a GET path → the matched route's `:name`→value params.
type ParamResolver = Arc<dyn Fn(&str) -> crate::sky_runtime::dict::SkyDict<String> + Send + Sync>;

/// Shared axum state: the session store + Arc'd TEA callbacks.
struct LiveState<Model, Msg, FInit, FUpdate, FView, FSubs> {
    store: Arc<dyn store::SessionStore<Model, Msg>>,
    init: Arc<FInit>,
    update: Arc<FUpdate>,
    view: Arc<FView>,
    subs: Arc<FSubs>,
    /// Maps the freshly-`init`'d model + GET path to the model whose `page`
    /// field reflects the matched route. `live_app` passes identity (no
    /// routing); `live_app_routed` captures the route table + page-setter.
    /// `Page`/`set_page` are erased into this boxed closure, so `LiveState`
    /// keeps its original 6 type params.
    route_resolver: RouteResolver<Model>,
    /// Maps a GET path to the matched route's `:name`→value params (for
    /// `req.params`). Model-independent so the page handler can build `req`
    /// BEFORE calling `init`. `live_app` returns empty; `live_app_routed`
    /// captures the route table.
    param_resolver: ParamResolver,
}

// Manual Clone — derive would demand Clone on the closures (they're behind Arc).
impl<Model, Msg, FInit, FUpdate, FView, FSubs> Clone
    for LiveState<Model, Msg, FInit, FUpdate, FView, FSubs>
{
    fn clone(&self) -> Self {
        LiveState {
            store: self.store.clone(),
            init: self.init.clone(),
            update: self.update.clone(),
            view: self.view.clone(),
            subs: self.subs.clone(),
            route_resolver: self.route_resolver.clone(),
            param_resolver: self.param_resolver.clone(),
        }
    }
}

/// Fire a `Cmd`: None/Batch recurse; Perform spawns the composed task→Msg thunk
/// and pushes the result back into the per-session loop.
fn run_cmd<Msg: Send + 'static>(cmd: SkyCmd<Msg>, tx: &UnboundedSender<Msg>, sid: &str) {
    match cmd {
        SkyCmd::None => {}
        SkyCmd::Batch(items) => {
            for c in items {
                run_cmd(c, tx, sid);
            }
        }
        SkyCmd::Perform(thunk) => {
            let tx = tx.clone();
            tokio::spawn(async move {
                let m = thunk().await;
                let _ = tx.send(m);
            });
        }
        SkyCmd::Publish(thunk) => {
            // Inject this session's sid as the broadcast origin (Go parity:
            // liveApp.Publish sets Origin = session.sid). Fire-and-forget.
            let _ = thunk(sid);
        }
    }
}

/// (Re-)spawn subscription tasks. Aborts the previous handles first (one model,
/// re-evaluated each commit — Go tea_subs.go parity). For P1 `subscriptions` is
/// `Sub.none`, so this is exercised mainly by the None arm.
fn spawn_subs<Msg: Clone + Send + 'static>(
    sub: SkySub<Msg>,
    tx: &UnboundedSender<Msg>,
    handles: &mut Vec<tokio::task::JoinHandle<()>>,
) {
    for h in handles.drain(..) {
        h.abort();
    }
    fn go<Msg: Clone + Send + 'static>(
        sub: SkySub<Msg>,
        tx: &UnboundedSender<Msg>,
        handles: &mut Vec<tokio::task::JoinHandle<()>>,
    ) {
        match sub {
            SkySub::None => {}
            SkySub::Batch(items) => {
                for s in items {
                    go(s, tx, handles);
                }
            }
            SkySub::Every { ms, msg } => {
                if ms <= 0 {
                    return;
                }
                let tx = tx.clone();
                let dur = std::time::Duration::from_millis(ms as u64);
                let h = tokio::spawn(async move {
                    loop {
                        tokio::time::sleep(dur).await;
                        if tx.send(msg.clone()).is_err() {
                            break;
                        }
                    }
                });
                handles.push(h);
            }
            SkySub::Source(spawn) => {
                let tx = tx.clone();
                let emit: Arc<dyn Fn(Msg) + Send + Sync> =
                    Arc::new(move |m| { let _ = tx.send(m); });
                handles.push(spawn(emit));
            }
        }
    }
    go(sub, tx, handles);
}

/// The per-session driver: folds each Msg through `update`, diffs the new view
/// against the last, pushes patches over SSE (if attached), runs the resulting
/// Cmd, and re-evaluates subscriptions.
// Eight distinct per-session runtime handles (entry, both channel ends, the three
// Arc'd TEA callbacks, the store, the sid) — bundling them into a struct purely to
// satisfy the 7-arg heuristic would add indirection without clarifying anything.
#[allow(clippy::too_many_arguments)]
async fn drive_session<Model, Msg, FUpdate, FView, FSubs>(
    entry: Arc<Mutex<SessionEntry<Model, Msg>>>,
    mut msg_rx: UnboundedReceiver<Msg>,
    msg_tx: UnboundedSender<Msg>,
    update: Arc<FUpdate>,
    view: Arc<FView>,
    subs: Arc<FSubs>,
    store: Arc<dyn store::SessionStore<Model, Msg>>,
    sid: String,
) where
    Model: Clone + Send + 'static,
    Msg: Clone + Send + 'static,
    FUpdate: Fn(Msg, Model) -> (Model, SkyCmd<Msg>) + Send + Sync + 'static,
    FView: Fn(Model) -> Html<Msg> + Send + Sync + 'static,
    FSubs: Fn(Model) -> SkySub<Msg> + Send + Sync + 'static,
{
    let mut sub_handles: Vec<tokio::task::JoinHandle<()>> = Vec::new();
    while let Some(msg) = msg_rx.recv().await {
        // Clone the model under a short lock, release before update.
        let model = { entry.lock().unwrap().model.clone() };
        let (next, cmd) = update(msg, model);

        let mut tree = view(next.clone());
        assign_sky_ids(&mut tree, "r");

        let (patches, seq, sse) = {
            let mut e = entry.lock().unwrap();
            let patches = diff(&e.last_view, &tree);
            e.last_view = tree.clone();
            e.index = build_index(&tree);
            e.model = next.clone();
            e.seq += 1;
            (patches, e.seq, e.sse_tx.clone())
        };

        if !patches.is_empty() {
            if let Some(sse) = sse {
                let env = PatchEnvelope { global_seq: seq, patches: &patches };
                if let Ok(json) = serde_json::to_string(&env) {
                    let _ = sse.send(SsePatch(sse::frame("patches", &json))).await;
                }
            }
        }

        // Write-through: checkpoint the committed model to the store (a touch
        // for memory; a re-serialize for persistent backends — Go store.Set on
        // every commit).
        store.set(&sid, entry.clone()).await;

        run_cmd(cmd, &msg_tx, &sid);
        pubsub::with_session_sid(sid.clone(), || {
            spawn_subs(subs(next.clone()), &msg_tx, &mut sub_handles)
        });
    }
    for h in sub_handles.drain(..) {
        h.abort();
    }
}

/// Generate a 128-bit random session id as 32 hex chars. Self-contained
/// (no uuid crate / uuid_kernel module dependency, since the generated
/// project's runtime mod.rs only declares those when Sky.Core.Uuid is used).
/// Entropy from a process-unique atomic counter mixed with the system clock
/// (sufficient for session-id uniqueness; not a security token).
fn new_sid() -> String {
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::time::{SystemTime, UNIX_EPOCH};
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos() as u64)
        .unwrap_or(0);
    let c = COUNTER.fetch_add(1, Ordering::Relaxed);
    // splitmix64 the two words for decent dispersion.
    let mix = |mut z: u64| {
        z = z.wrapping_add(0x9E3779B97F4A7C15);
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58476D1CE4E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D049BB133111EB);
        z ^ (z >> 31)
    };
    let hi = mix(nanos ^ (c.rotate_left(17)));
    let lo = mix(c ^ nanos.rotate_left(40));
    format!("{hi:016x}{lo:016x}")
}

/// Build the full-page HTTP response for a GET (initial render or reuse): the
/// client-bearing HTML wrap + the `sky_sid` cookie.
fn page_response(sid: &str, body: &str) -> axum::response::Response {
    use axum::response::IntoResponse;
    let html = render_page_full(sid, "", body);
    let cookie = format!("sky_sid={sid}; Path=/; HttpOnly; SameSite=Lax");
    (
        axum::http::StatusCode::OK,
        [
            (axum::http::header::CONTENT_TYPE, "text/html; charset=utf-8".to_string()),
            (axum::http::header::SET_COOKIE, cookie),
        ],
        html,
    )
        .into_response()
}

/// Session idle-TTL: `SKY_LIVE_TTL` seconds, default 1800 (30 min) — matches the
/// Go `[live] ttl` default.
fn live_ttl() -> std::time::Duration {
    let secs = std::env::var("SKY_LIVE_TTL")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(1800u64);
    std::time::Duration::from_secs(secs)
}

/// `Std.Live.app { init, update, view, subscriptions }` — serve via axum.
///
/// HTTP-first: a GET renders the full page with the embedded client, opens a
/// per-session TEA loop, and serves an SSE patch channel + a POST event
/// endpoint. The driver diffs view-over-view and pushes patches over SSE.
///
/// `init` ignores its `req` arg for P1; the generated `main_init` is monomorphic
/// over a unit-shaped arg, so we call `init(())`.
#[allow(clippy::too_many_arguments)]
pub fn live_app<E, Model, Msg, FInit, FUpdate, FView, FSubs>(
    init: FInit,
    update: FUpdate,
    view: FView,
    subscriptions: FSubs,
    store_kind: String,
    store_path: String,
) -> SkyTask<E, ()>
where
    E: From<String> + Send + 'static,
    Model: serde::Serialize + serde::de::DeserializeOwned + Clone + Send + Sync + 'static,
    Msg: Clone + Send + Sync + 'static,
    FInit: Fn(req::LiveReq) -> (Model, SkyCmd<Msg>) + Send + Sync + 'static,
    FUpdate: Fn(Msg, Model) -> (Model, SkyCmd<Msg>) + Send + Sync + 'static,
    FView: Fn(Model) -> Html<Msg> + Send + Sync + 'static,
    FSubs: Fn(Model) -> SkySub<Msg> + Send + Sync + 'static,
{
    Box::pin(async move {
        let store = store::choose_store::<Model, Msg>(&store_kind, &store_path, live_ttl()).await;
        let state = LiveState {
            store,
            init: Arc::new(init),
            update: Arc::new(update),
            view: Arc::new(view),
            subs: Arc::new(subscriptions),
            // No routing: GET serves the freshly-init'd model unchanged; no params.
            route_resolver: Arc::new(|m, _path| m),
            param_resolver: Arc::new(|_path| crate::sky_runtime::dict::dict_empty()),
        };
        serve_live(state).await
    })
}

/// `Std.Live.app { …, routes, notFound }` with URL routing — serve via axum.
///
/// Identical to `live_app` except a `route_resolver` is built from the route
/// table + page-setter: on each GET it matches the path to a `Page` value
/// (param strings applied via the route closures) and writes it into the
/// freshly-`init`'d model's `page` field via `set_page`. `Page`/`FSetPage`
/// are erased into the boxed resolver, so `serve_live`/`LiveState` keep the
/// original 6 type params.
#[allow(clippy::too_many_arguments)]
pub fn live_app_routed<E, Model, Msg, Page, FInit, FUpdate, FView, FSubs, FSetPage>(
    init: FInit,
    update: FUpdate,
    view: FView,
    subscriptions: FSubs,
    routes: Vec<route::Route<Page>>,
    not_found: Page,
    set_page: FSetPage,
    store_kind: String,
    store_path: String,
) -> SkyTask<E, ()>
where
    E: From<String> + Send + 'static,
    Model: serde::Serialize + serde::de::DeserializeOwned + Clone + Send + Sync + 'static,
    Msg: Clone + Send + Sync + 'static,
    Page: Clone + Send + Sync + 'static,
    FInit: Fn(req::LiveReq) -> (Model, SkyCmd<Msg>) + Send + Sync + 'static,
    FUpdate: Fn(Msg, Model) -> (Model, SkyCmd<Msg>) + Send + Sync + 'static,
    FView: Fn(Model) -> Html<Msg> + Send + Sync + 'static,
    FSubs: Fn(Model) -> SkySub<Msg> + Send + Sync + 'static,
    FSetPage: Fn(Page, Model) -> Model + Send + Sync + 'static,
{
    Box::pin(async move {
        let routes = Arc::new(routes);
        let not_found = Arc::new(not_found);
        let set_page = Arc::new(set_page);
        let routes_for_params = routes.clone();
        let resolver: RouteResolver<Model> =
            Arc::new(move |m, path| (set_page)(route::match_routes(&routes, &not_found, path), m));
        let param_resolver: ParamResolver =
            Arc::new(move |path| route::match_params(&routes_for_params, path));
        let store = store::choose_store::<Model, Msg>(&store_kind, &store_path, live_ttl()).await;
        let state = LiveState {
            store,
            init: Arc::new(init),
            update: Arc::new(update),
            view: Arc::new(view),
            subs: Arc::new(subscriptions),
            route_resolver: resolver,
            param_resolver,
        };
        serve_live(state).await
    })
}

/// Shared server setup for `live_app` / `live_app_routed`: nested HTTP
/// handlers (`page` / `sse_handler` / `event_handler`), router + bind/serve.
/// The only per-entry difference (the `route_resolver`) lives on `state`.
async fn serve_live<E, Model, Msg, FInit, FUpdate, FView, FSubs>(
    state: LiveState<Model, Msg, FInit, FUpdate, FView, FSubs>,
) -> SkyResult<E, ()>
where
    E: From<String> + Send + 'static,
    Model: Clone + Send + 'static,
    Msg: Clone + Send + 'static,
    FInit: Fn(req::LiveReq) -> (Model, SkyCmd<Msg>) + Send + Sync + 'static,
    FUpdate: Fn(Msg, Model) -> (Model, SkyCmd<Msg>) + Send + Sync + 'static,
    FView: Fn(Model) -> Html<Msg> + Send + Sync + 'static,
    FSubs: Fn(Model) -> SkySub<Msg> + Send + Sync + 'static,
{
    use axum::extract::State;
    use axum::http::StatusCode;
    use axum::response::{IntoResponse, Response};
    use axum::routing::{get, post};
    use axum::Router;

    {
        // ── GET page (root + any path) ────────────────────────────────────
        async fn page<Model, Msg, FInit, FUpdate, FView, FSubs>(
            State(st): State<LiveState<Model, Msg, FInit, FUpdate, FView, FSubs>>,
            method: axum::http::Method,
            uri: axum::http::Uri,
            headers: axum::http::HeaderMap,
        ) -> Response
        where
            Model: Clone + Send + 'static,
            Msg: Clone + Send + 'static,
            FInit: Fn(req::LiveReq) -> (Model, SkyCmd<Msg>) + Send + Sync + 'static,
            FUpdate: Fn(Msg, Model) -> (Model, SkyCmd<Msg>) + Send + Sync + 'static,
            FView: Fn(Model) -> Html<Msg> + Send + Sync + 'static,
            FSubs: Fn(Model) -> SkySub<Msg> + Send + Sync + 'static,
        {
            // Cookie-based session lifecycle (Go store.Get on every GET):
            //   * Live hit  → reuse the in-process session; re-apply routing for
            //                 this GET's path + re-render (no new driver).
            //   * Cold hit  → a persisted model (post-restart / different replica);
            //                 hydrate a fresh driver seeded with it (no init).
            //   * miss      → init a new session.
            let cookie_sid = sid_from_cookie(&headers);
            let hit = match cookie_sid.as_ref() {
                Some(s) => st.store.get(s).await,
                None => None,
            };

            let (sid, model, cmd0) = match hit {
                Some(store::StoreHit::Live(handle)) => {
                    let s = cookie_sid.expect("live hit implies a cookie sid");
                    let body = {
                        let mut e = handle.lock().unwrap();
                        e.model = (st.route_resolver)(e.model.clone(), uri.path());
                        let mut tree = (st.view)(e.model.clone());
                        assign_sky_ids(&mut tree, "r");
                        e.index = build_index(&tree);
                        e.last_view = tree.clone();
                        render_html(&tree)
                    };
                    st.store.set(&s, handle).await; // touch last-seen
                    return page_response(&s, &body);
                }
                Some(store::StoreHit::Cold(m)) => {
                    let s = cookie_sid.expect("cold hit implies a cookie sid");
                    (s, (st.route_resolver)(m, uri.path()), SkyCmd::None)
                }
                None => {
                    // Build the request context (params from routing — empty when
                    // unrouted) and init a fresh model. The param_resolver is
                    // model-independent, breaking the init↔routing cycle.
                    let params = (st.param_resolver)(uri.path());
                    let req = req::live_req(&method, &uri, &headers, params);
                    let (m, c) = (st.init)(req);
                    let s = cookie_sid.unwrap_or_else(new_sid);
                    (s, (st.route_resolver)(m, uri.path()), c)
                }
            };

            let mut tree = (st.view)(model.clone());
            assign_sky_ids(&mut tree, "r");
            let index = build_index(&tree);
            let body = render_html(&tree);

            let (msg_tx, msg_rx) = unbounded_channel::<Msg>();
            let entry = Arc::new(Mutex::new(SessionEntry {
                model,
                last_view: tree,
                index,
                seq: 0,
                sse_tx: None,
                msg_tx: msg_tx.clone(),
            }));
            st.store.set(&sid, entry.clone()).await;

            // Spawn the per-session driver (write-through to the store on commit).
            tokio::spawn(drive_session(
                entry,
                msg_rx,
                msg_tx.clone(),
                st.update.clone(),
                st.view.clone(),
                st.subs.clone(),
                st.store.clone(),
                sid.clone(),
            ));
            // Fire init's Cmd into the loop (None for a cold-restored session).
            run_cmd(cmd0, &msg_tx, &sid);

            page_response(&sid, &body)
        }

        // ── GET /_sky/sse ─────────────────────────────────────────────────
        async fn sse_handler<Model, Msg, FInit, FUpdate, FView, FSubs>(
            State(st): State<LiveState<Model, Msg, FInit, FUpdate, FView, FSubs>>,
            headers: axum::http::HeaderMap,
        ) -> Response
        where
            Model: Clone + Send + 'static,
            Msg: Clone + Send + 'static,
            FInit: Send + Sync + 'static,
            FUpdate: Send + Sync + 'static,
            FView: Send + Sync + 'static,
            FSubs: Send + Sync + 'static,
        {
            let sid = sid_from_cookie(&headers);
            let entry = match sid {
                Some(s) => match st.store.get(&s).await {
                    Some(store::StoreHit::Live(h)) => Some(h),
                    _ => None,
                },
                None => None,
            };
            let entry = match entry {
                Some(e) => e,
                None => return (StatusCode::NOT_FOUND, "no session").into_response(),
            };

            let (tx, rx) = sse::channel();
            { entry.lock().unwrap().sse_tx = Some(tx.clone()); }

            // Immediate hello + ~2KB proxy-buffer padding comment, then a 15s
            // heartbeat keepalive (Go parity: live.go SSE handshake).
            let _ = tx.send(SsePatch(format!(": {}\n\n", " ".repeat(2048)))).await;
            let _ = tx.send(SsePatch(sse::frame("hello", "{}"))).await;
            {
                let tx = tx.clone();
                tokio::spawn(async move {
                    loop {
                        tokio::time::sleep(std::time::Duration::from_secs(15)).await;
                        if tx.send(SsePatch(sse::frame("heartbeat", "{}"))).await.is_err() {
                            break;
                        }
                    }
                });
            }

            let body_stream = futures_util::stream::unfold(rx, |mut rx| async move {
                rx.recv()
                    .await
                    .map(|SsePatch(s)| (Ok::<_, std::io::Error>(axum::body::Bytes::from(s)), rx))
            });
            Response::builder()
                .status(StatusCode::OK)
                .header(axum::http::header::CONTENT_TYPE, "text/event-stream")
                .header(axum::http::header::CACHE_CONTROL, "no-cache")
                .header("x-accel-buffering", "no")
                .body(axum::body::Body::from_stream(body_stream))
                .unwrap()
                .into_response()
        }

        // ── POST /_sky/event ──────────────────────────────────────────────
        async fn event_handler<Model, Msg, FInit, FUpdate, FView, FSubs>(
            State(st): State<LiveState<Model, Msg, FInit, FUpdate, FView, FSubs>>,
            headers: axum::http::HeaderMap,
            body: axum::body::Bytes,
        ) -> Response
        where
            Model: Clone + Send + 'static,
            Msg: Clone + Send + 'static,
            FInit: Send + Sync + 'static,
            FUpdate: Send + Sync + 'static,
            FView: Send + Sync + 'static,
            FSubs: Send + Sync + 'static,
        {
            let parsed: EventBody = match serde_json::from_slice(&body) {
                Ok(b) => b,
                Err(_) => return (StatusCode::BAD_REQUEST, "bad body").into_response(),
            };
            // Prefer the cookie sid; fall back to the body's sessionId.
            let sid = sid_from_cookie(&headers).unwrap_or(parsed.session_id);
            let entry = match st.store.get(&sid).await {
                Some(store::StoreHit::Live(h)) => Some(h),
                _ => None,
            };
            let entry = match entry {
                Some(e) => e,
                None => return (StatusCode::NOT_FOUND, "no session").into_response(),
            };

            let hid = if !parsed.handler_id.is_empty() { parsed.handler_id } else { parsed.id };
            // Event name: explicit `event` override, else the `msg` marker
            // (render_html sets it to the event name), else default to click.
            let event = if !parsed.event.is_empty() {
                parsed.event
            } else if !parsed.msg.is_empty() {
                parsed.msg
            } else {
                "click".to_string()
            };

            let (msg, seq) = {
                let e = entry.lock().unwrap();
                if event == "submit" {
                    // args[0] is the form-data object {name: value, …}.
                    let fd: FormData = parsed
                        .args
                        .first()
                        .and_then(|v| v.as_object())
                        .map(|o| o.iter().map(|(k, v)| (k.clone(), value_to_string(v))).collect())
                        .unwrap_or_default();
                    (e.index.resolve_form(&hid, &event, fd), e.seq)
                } else {
                    let args: Vec<String> = parsed.args.iter().map(value_to_string).collect();
                    (e.index.resolve(&hid, &event, &args), e.seq)
                }
            };
            if let Some(m) = msg {
                let tx = { entry.lock().unwrap().msg_tx.clone() };
                let _ = tx.send(m);
            }
            // Real patches flow over SSE from the driver; ack with an empty list.
            (
                StatusCode::OK,
                [(axum::http::header::CONTENT_TYPE, "application/json")],
                format!("{{\"seq\":{seq},\"patches\":[]}}"),
            )
                .into_response()
        }

        // Background TTL eviction (Go memoryStore.cleanupLoop parity): sweep
        // idle-expired sessions every 60 s. Persistent backends also prune their
        // checkpoint table in `sweep`.
        {
            let store = state.store.clone();
            tokio::spawn(async move {
                let mut tick = tokio::time::interval(std::time::Duration::from_secs(60));
                loop {
                    tick.tick().await;
                    store.sweep().await;
                }
            });
        }

        let app: Router = Router::new()
            .route("/_sky/sse", get(sse_handler::<Model, Msg, FInit, FUpdate, FView, FSubs>))
            .route("/_sky/event", post(event_handler::<Model, Msg, FInit, FUpdate, FView, FSubs>))
            .route("/", get(page::<Model, Msg, FInit, FUpdate, FView, FSubs>))
            .route("/*path", get(page::<Model, Msg, FInit, FUpdate, FView, FSubs>))
            .with_state(state);

        pubsub::mark_live_running();

        let port: i64 = std::env::var("SKY_LIVE_PORT")
            .ok()
            .and_then(|s| s.parse().ok())
            .unwrap_or(8000);
        let addr = format!("0.0.0.0:{port}");
        let listener = match tokio::net::TcpListener::bind(&addr).await {
            Ok(l) => l,
            Err(e) => return SkyResult::Err(format!("Live.app: bind {addr}: {e}").into()),
        };
        eprintln!("[sky.live] listening on http://{addr}");
        match axum::serve(listener, app).await {
            Ok(()) => ok_res(()),
            Err(e) => SkyResult::Err(format!("Live.app: serve: {e}").into()),
        }
    }
}

/// Read the `sky_sid` cookie from request headers.
fn sid_from_cookie(headers: &axum::http::HeaderMap) -> Option<String> {
    let raw = headers.get(axum::http::header::COOKIE)?.to_str().ok()?;
    for c in raw.split(';') {
        let c = c.trim();
        if let Some((k, v)) = c.split_once('=') {
            if k.trim() == "sky_sid" {
                return Some(v.trim().to_string());
            }
        }
    }
    None
}

// The Std.Html `Ffi.callPure "htmlXxx"` kernel wrappers (html_render_,
// html_escape_text_, html_escape_attr_, html_attr_to_string_) now live in the
// standalone top-level `sky_runtime::html` module (re-exported here via
// `use super::*`), so a non-Live Std.Html / Std.Ui render doesn't pull this
// server module in.
