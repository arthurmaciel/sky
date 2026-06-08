//! Sky.Live on the Rust backend — HTTP-first render + SSE patch loop.
//! Generic over the app's (Model, Msg); no `any`, static dispatch only.
pub mod html;
pub use html::*;
pub mod diff;
pub use diff::*;
pub mod dispatch;
pub use dispatch::*;
pub mod sse;
pub use sse::*;
pub mod session;
pub use session::*;
pub mod form;
pub use form::*;

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
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use tokio::sync::mpsc::{UnboundedSender, UnboundedReceiver, unbounded_channel};

/// Per-session live state behind an `Arc<Mutex<…>>`. `index` / `last_view` are
/// re-derived on every commit; `sse_tx` is filled when the browser attaches the
/// SSE channel; `msg_tx` feeds the per-session driver loop.
struct SessionEntry<Model, Msg> {
    model: Model,
    last_view: Html<Msg>,
    index: HandlerIndex<Msg>,
    seq: u64,
    sse_tx: Option<SseTx>,
    msg_tx: UnboundedSender<Msg>,
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

type SessionMap<Model, Msg> = Arc<Mutex<HashMap<String, Arc<Mutex<SessionEntry<Model, Msg>>>>>>;

/// Shared axum state: the session map + Arc'd TEA callbacks.
struct LiveState<Model, Msg, FInit, FUpdate, FView, FSubs> {
    sessions: SessionMap<Model, Msg>,
    init: Arc<FInit>,
    update: Arc<FUpdate>,
    view: Arc<FView>,
    subs: Arc<FSubs>,
}

// Manual Clone — derive would demand Clone on the closures (they're behind Arc).
impl<Model, Msg, FInit, FUpdate, FView, FSubs> Clone
    for LiveState<Model, Msg, FInit, FUpdate, FView, FSubs>
{
    fn clone(&self) -> Self {
        LiveState {
            sessions: self.sessions.clone(),
            init: self.init.clone(),
            update: self.update.clone(),
            view: self.view.clone(),
            subs: self.subs.clone(),
        }
    }
}

/// Fire a `Cmd`: None/Batch recurse; Perform spawns the composed task→Msg thunk
/// and pushes the result back into the per-session loop.
fn run_cmd<Msg: Send + 'static>(cmd: SkyCmd<Msg>, tx: &UnboundedSender<Msg>) {
    match cmd {
        SkyCmd::None => {}
        SkyCmd::Batch(items) => {
            for c in items {
                run_cmd(c, tx);
            }
        }
        SkyCmd::Perform(thunk) => {
            let tx = tx.clone();
            tokio::spawn(async move {
                let m = thunk().await;
                let _ = tx.send(m);
            });
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
async fn drive_session<Model, Msg, FUpdate, FView, FSubs>(
    entry: Arc<Mutex<SessionEntry<Model, Msg>>>,
    mut msg_rx: UnboundedReceiver<Msg>,
    msg_tx: UnboundedSender<Msg>,
    update: Arc<FUpdate>,
    view: Arc<FView>,
    subs: Arc<FSubs>,
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

        run_cmd(cmd, &msg_tx);
        spawn_subs(subs(next.clone()), &msg_tx, &mut sub_handles);
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

/// `Std.Live.app { init, update, view, subscriptions }` — serve via axum.
///
/// HTTP-first: a GET renders the full page with the embedded client, opens a
/// per-session TEA loop, and serves an SSE patch channel + a POST event
/// endpoint. The driver diffs view-over-view and pushes patches over SSE.
///
/// `init` ignores its `req` arg for P1; the generated `main_init` is monomorphic
/// over a unit-shaped arg, so we call `init(())`.
pub fn live_app<E, Model, Msg, FInit, FUpdate, FView, FSubs>(
    init: FInit,
    update: FUpdate,
    view: FView,
    subscriptions: FSubs,
) -> SkyTask<E, ()>
where
    E: From<String> + Send + 'static,
    Model: Clone + Send + 'static,
    Msg: Clone + Send + 'static,
    FInit: Fn(()) -> (Model, SkyCmd<Msg>) + Send + Sync + 'static,
    FUpdate: Fn(Msg, Model) -> (Model, SkyCmd<Msg>) + Send + Sync + 'static,
    FView: Fn(Model) -> Html<Msg> + Send + Sync + 'static,
    FSubs: Fn(Model) -> SkySub<Msg> + Send + Sync + 'static,
{
    use axum::extract::State;
    use axum::http::StatusCode;
    use axum::response::{IntoResponse, Response};
    use axum::routing::{get, post};
    use axum::Router;

    Box::pin(async move {
        let state = LiveState {
            sessions: Arc::new(Mutex::new(HashMap::new())),
            init: Arc::new(init),
            update: Arc::new(update),
            view: Arc::new(view),
            subs: Arc::new(subscriptions),
        };

        // ── GET page (root + any path) ────────────────────────────────────
        async fn page<Model, Msg, FInit, FUpdate, FView, FSubs>(
            State(st): State<LiveState<Model, Msg, FInit, FUpdate, FView, FSubs>>,
        ) -> Response
        where
            Model: Clone + Send + 'static,
            Msg: Clone + Send + 'static,
            FInit: Fn(()) -> (Model, SkyCmd<Msg>) + Send + Sync + 'static,
            FUpdate: Fn(Msg, Model) -> (Model, SkyCmd<Msg>) + Send + Sync + 'static,
            FView: Fn(Model) -> Html<Msg> + Send + Sync + 'static,
            FSubs: Fn(Model) -> SkySub<Msg> + Send + Sync + 'static,
        {
            let sid = new_sid();
            let (model, cmd0) = (st.init)(());
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
            st.sessions.lock().unwrap().insert(sid.clone(), entry.clone());

            // Spawn the per-session driver.
            tokio::spawn(drive_session(
                entry,
                msg_rx,
                msg_tx.clone(),
                st.update.clone(),
                st.view.clone(),
                st.subs.clone(),
            ));
            // Fire init's Cmd into the loop.
            run_cmd(cmd0, &msg_tx);

            let html = render_page_full(&sid, "", &body);
            let cookie = format!("sky_sid={sid}; Path=/; HttpOnly; SameSite=Lax");
            (
                StatusCode::OK,
                [
                    (axum::http::header::CONTENT_TYPE, "text/html; charset=utf-8".to_string()),
                    (axum::http::header::SET_COOKIE, cookie),
                ],
                html,
            )
                .into_response()
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
            let entry = sid.and_then(|s| st.sessions.lock().unwrap().get(&s).cloned());
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
            let entry = st.sessions.lock().unwrap().get(&sid).cloned();
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

        let app: Router = Router::new()
            .route("/_sky/sse", get(sse_handler::<Model, Msg, FInit, FUpdate, FView, FSubs>))
            .route("/_sky/event", post(event_handler::<Model, Msg, FInit, FUpdate, FView, FSubs>))
            .route("/", get(page::<Model, Msg, FInit, FUpdate, FView, FSubs>))
            .route("/*path", get(page::<Model, Msg, FInit, FUpdate, FView, FSubs>))
            .with_state(state);

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
    })
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

// ─── Go-parity kernel stubs ────────────────────────────────────────────────
// These match the `Ffi.callPure "htmlXxx"` kernel names used in sky-stdlib
// Std.Html.sky — the Sky-side helpers (render, escapeHtml, escapeAttr,
// attrToString) route here on the Rust backend.  The codegen converts
// "htmlRender" → `html_render_()`, "htmlEscapeText" → `html_escape_text_()`,
// etc., so we export the matching snake-case names with trailing `_`.

/// `Ffi.callPure "htmlRender"` — render an Html tree to an HTML string.
pub fn html_render_<M>(node: Html<M>) -> String {
    render_html(&node)
}

/// `Ffi.callPure "htmlEscapeText"` — HTML-escape a string for text content.
pub fn html_escape_text_(s: String) -> String {
    s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;")
}

/// `Ffi.callPure "htmlEscapeAttr"` — escape a string for use in a double-quoted attribute.
pub fn html_escape_attr_(s: String) -> String {
    html_escape_text_(s).replace('"', "&quot;")
}

/// `Ffi.callPure "htmlAttrToString"` — serialise a single Attribute to its key="value" form.
pub fn html_attr_to_string_<M>(attr: Attribute<M>) -> String {
    match attr {
        Attribute::Attr(k, v) => format!("{}=\"{}\"", k, html_escape_attr_(v)),
        Attribute::BoolAttr(k, true) => k,
        Attribute::BoolAttr(_, false) | Attribute::NoAttr => String::new(),
        Attribute::EventAttr(e) => format!("data-sky-on=\"{}\"", e.name()),
    }
}
