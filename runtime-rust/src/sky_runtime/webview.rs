//! Sky.Webview — native desktop window backend.
//!
//! `Webview.app { init, update, view, subscriptions, window }` opens a native
//! system webview (`wry` ≥0.55 + `tao` ≥0.35: WKWebView on macOS, WebView2 on
//! Windows, WebKitGTK on Linux — webkit2gtk-4.1 + libsoup-3.0) and runs the same
//! TEA loop as Sky.Live, reusing Sky.Live's `Html` renderer + event dispatch
//! (`HandlerIndex`) — the view paints identically across web / terminal /
//! desktop. The bridge is in-process: `with_html` for the initial paint, an IPC
//! handler for DOM events, `evaluate_script` for re-renders. No HTTP server, SSE,
//! or session store.
//!
//! Modern wry/tao use objc2 (macOS) + current windows-rs (Windows) and so build
//! on macOS-15/Xcode-16 + Windows-2025 toolchains — unlike the legacy wry 0.24 /
//! tao 0.16 stack this replaced. The event loop is per-OS: Linux runs it on the
//! TEA task thread (off the OS main thread) via `EventLoopBuilderExtUnix::
//! with_any_thread(true)` (GTK tolerates it for a single-window single-thread
//! app); macOS/Windows REQUIRE the main thread, so there it is a plain
//! `EventLoopBuilder::build()`. The webview is built per-OS too: `build(&window)`
//! (raw-window-handle) off Linux, `build_gtk(window.gtk_window())` on Linux.
//!
//! Two builds: the real backend is behind the opt-in `webview` Cargo feature
//! (needs the system webview dev libraries); otherwise a stub returning a graceful
//! `Err` is compiled (mirrors Go's `webview_stub.go` on non-darwin), so a program
//! that `import Std.Webview`s always links + never panics. No panic vectors: the
//! stub returns `Err`; the real path routes every fallible call through `Err`.

use super::core::SkyTask;
use super::html::Html;
use super::tea::{SkyCmd, SkySub};

/// Window configuration — mirrors Sky's closed `WindowCfg { title, size }`.
#[allow(non_snake_case)]
#[derive(Clone, Debug)]
pub struct WebviewWindowCfg {
    pub title: String,
    pub size: (i64, i64),
}

/// Phantom marker for Sky's `AppCfg model msg` record alias (destructured at the
/// call site, never built in Rust). See the codegen `markerCfgAliases`.
pub struct WebviewAppCfg;

#[cfg(not(feature = "webview"))]
mod imp {
    use super::*;
    use crate::sky_runtime::core::SkyResult;

    /// Stub `webview_app` — compiled when the `webview` feature is off (no system
    /// webview libraries). Returns a graceful `Err` with a remediation message.
    #[allow(clippy::type_complexity)]
    pub fn webview_app<Model, Msg, E, FInit, FUpdate, FView, FSubs>(
        _init: FInit,
        _update: FUpdate,
        _view: FView,
        _subscriptions: FSubs,
        _window: WebviewWindowCfg,
    ) -> SkyTask<E, ()>
    where
        E: Send + From<String> + 'static,
        Model: Clone + Send + 'static,
        Msg: Clone + Send + 'static,
        FInit: Fn(()) -> (Model, SkyCmd<Msg>) + Send + 'static,
        FUpdate: Fn(Msg, Model) -> (Model, SkyCmd<Msg>) + Send + 'static,
        FView: Fn(Model) -> Html<Msg> + Send + 'static,
        FSubs: Fn(Model) -> SkySub<Msg> + Send + 'static,
    {
        Box::pin(async move {
            SkyResult::Err(
                "Webview.app: this Sky build has no native webview backend. Rebuild \
                 with `--features webview` on a machine with the webview dev \
                 libraries (Linux: webkit2gtk + libsoup; macOS: WKWebView; Windows: \
                 the Edge WebView2 runtime)."
                    .to_string()
                    .into(),
            )
        })
    }
}

#[cfg(feature = "webview")]
mod imp {
    use super::*;
    use crate::sky_runtime::core::{ok_res, SkyResult};
    use crate::sky_runtime::html::{assign_sky_ids, render_html};
    use crate::sky_runtime::live::dispatch::build_index;

    // Bridge JS: delegated event listeners on the document forward DOM events on
    // `[sky-id]` elements to the IPC channel as `{skyId, event, args}`. Re-bound
    // implicitly via event delegation, so a full innerHTML swap needs no re-bind.
    const BRIDGE_JS: &str = r#"
(function(){
  function send(skyId, ev, args){ try{ window.ipc.postMessage(JSON.stringify({skyId:skyId, event:ev, args:args})); }catch(e){} }
  function idOf(el){ return el && el.getAttribute ? el.getAttribute('sky-id') : null; }
  document.addEventListener('click', function(e){ var id=idOf(e.target.closest('[sky-id]')); if(id) send(id,'click',[]); });
  document.addEventListener('input', function(e){ var id=idOf(e.target.closest('[sky-id]')); if(id) send(id,'input',[e.target.value||'']); }, true);
  document.addEventListener('change', function(e){ var id=idOf(e.target.closest('[sky-id]')); if(id) send(id,'change',[e.target.value||'']); }, true);
  window.__skyApply = function(html){ document.body.innerHTML = html; };
})();
"#;

    fn json_str(s: &str) -> String {
        let mut out = String::from("\"");
        for c in s.chars() {
            match c {
                '"' => out.push_str("\\\""),
                '\\' => out.push_str("\\\\"),
                '\n' => out.push_str("\\n"),
                '\r' => out.push_str("\\r"),
                c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
                c => out.push(c),
            }
        }
        out.push('"');
        out
    }

    /// Parse `{skyId, event, args}` (from the bridge) without serde.
    fn parse_ipc(body: &str) -> Option<(String, String, Vec<String>)> {
        let v: serde_json::Value = serde_json::from_str(body).ok()?;
        let sky_id = v.get("skyId")?.as_str()?.to_string();
        let event = v.get("event")?.as_str()?.to_string();
        let args = v
            .get("args")
            .and_then(|a| a.as_array())
            .map(|a| a.iter().filter_map(|x| x.as_str().map(String::from)).collect())
            .unwrap_or_default();
        Some((sky_id, event, args))
    }

    /// Render the view to an `(html_body, HandlerIndex)` pair, stamping sky-ids.
    fn render<Model, Msg, FView>(
        view: &FView,
        model: &Model,
    ) -> (String, crate::sky_runtime::live::dispatch::HandlerIndex<Msg>)
    where
        Model: Clone,
        Msg: Clone,
        FView: Fn(Model) -> Html<Msg>,
    {
        let mut tree = view(model.clone());
        assign_sky_ids(&mut tree, "r");
        let index = build_index(&tree);
        (render_html(&tree), index)
    }

    /// Real `Webview.app` — opens a native window and runs the TEA loop on the
    /// event-loop thread. DOM events arrive over IPC, resolve to Msgs via the
    /// reused `HandlerIndex`, drive `update`, and re-render via `evaluate_script`.
    ///
    /// The future has no `.await` after the (`!Send`) window/webview are created
    /// — `event_loop.run` is synchronous + diverging — so the future stays `Send`
    /// (`SkyTask`'s bound) while the webview itself never crosses an await.
    /// Async `Cmd.perform` / `Sub.every` are a follow-on (the synchronous event
    /// loop doesn't pump tokio); `Cmd.none` works.
    #[allow(clippy::type_complexity)]
    pub fn webview_app<Model, Msg, E, FInit, FUpdate, FView, FSubs>(
        init: FInit,
        update: FUpdate,
        view: FView,
        _subscriptions: FSubs,
        window: WebviewWindowCfg,
    ) -> SkyTask<E, ()>
    where
        E: Send + From<String> + 'static,
        Model: Clone + Send + 'static,
        Msg: Clone + Send + 'static,
        FInit: Fn(()) -> (Model, SkyCmd<Msg>) + Send + 'static,
        FUpdate: Fn(Msg, Model) -> (Model, SkyCmd<Msg>) + Send + 'static,
        FView: Fn(Model) -> Html<Msg> + Send + 'static,
        FSubs: Fn(Model) -> SkySub<Msg> + Send + 'static,
    {
        Box::pin(async move {
            use tao::dpi::LogicalSize;
            use tao::event::{Event, WindowEvent};
            use tao::event_loop::{ControlFlow, EventLoopBuilder};
            use tao::window::WindowBuilder;
            use wry::WebViewBuilder;
            #[cfg(target_os = "linux")]
            use tao::platform::unix::{EventLoopBuilderExtUnix, WindowExtUnix};
            #[cfg(target_os = "linux")]
            use wry::WebViewBuilderExtUnix;

            #[derive(Debug)]
            enum UserEvent {
                Ipc(String),
            }

            // Per-OS event loop. On Linux the TEA task is polled off the OS main
            // thread (tokio block_on), so build with `with_any_thread(true)` —
            // tao otherwise panics. Sky webview programs are single-window
            // single-thread, so the GTK single-thread caveat is satisfied. On
            // macOS/Windows the event loop MUST live on the main thread, so build
            // it plainly (the TEA task runs on the main thread there).
            let event_loop = {
                #[allow(unused_mut)]
                let mut builder = EventLoopBuilder::<UserEvent>::with_user_event();
                #[cfg(target_os = "linux")]
                builder.with_any_thread(true);
                builder.build()
            };
            let (w, h) = window.size;
            let win = match WindowBuilder::new()
                .with_title(&window.title)
                .with_inner_size(LogicalSize::new(w.max(1) as f64, h.max(1) as f64))
                .build(&event_loop)
            {
                Ok(win) => win,
                Err(e) => return SkyResult::Err(format!("Webview.app: window: {e}").into()),
            };

            let (mut model, _cmd0) = init(());
            let (body0, mut index) = render::<Model, Msg, _>(&view, &model);
            let html = format!(
                "<!doctype html><html><head><meta charset=\"utf-8\"></head><body>{body0}</body><script>{BRIDGE_JS}</script></html>"
            );

            let proxy = event_loop.create_proxy();
            // Modern wry: `WebViewBuilder::new()` is no-arg; the window is supplied
            // at build time. The IPC handler closure receives the message as a
            // `wry::http::Request<String>`; we forward its body to the TEA loop.
            let builder = WebViewBuilder::new()
                .with_html(html)
                .with_ipc_handler(move |req: wry::http::Request<String>| {
                    let _ = proxy.send_event(UserEvent::Ipc(req.into_body()));
                });
            // Build per-OS: raw-window-handle path off Linux, gtk widget on Linux
            // (so Wayland + X11 both work). Both return `wry::Result<WebView>`.
            #[cfg(not(target_os = "linux"))]
            let built: wry::Result<wry::WebView> = builder.build(&win);
            #[cfg(target_os = "linux")]
            // Pack into the window's default vertical `gtk::Box` when present —
            // a tao `gtk::ApplicationWindow` is a single-child `GtkBin` that
            // already holds that box, so adding the WebKitWebView to the window
            // directly is a GTK contract violation (the "can only contain one
            // widget" warning). The box is the correct container; fall back to
            // the window only if the default vbox was disabled.
            let built: wry::Result<wry::WebView> = match win.default_vbox() {
                Some(vbox) => builder.build_gtk(vbox),
                None => builder.build_gtk(win.gtk_window()),
            };
            let webview = match built {
                Ok(wv) => wv,
                Err(e) => return SkyResult::Err(format!("Webview.app: webview: {e}").into()),
            };

            event_loop.run(move |event, _target, control_flow| {
                *control_flow = ControlFlow::Wait;
                match event {
                    Event::WindowEvent { event: WindowEvent::CloseRequested, .. } => {
                        *control_flow = ControlFlow::Exit;
                    }
                    Event::UserEvent(UserEvent::Ipc(body)) => {
                        if let Some((sky_id, ev, args)) = parse_ipc(&body) {
                            if let Some(msg) = index.resolve(&sky_id, &ev, &args) {
                                let (next, _cmd) = update(msg, model.clone());
                                model = next;
                                let (nbody, nindex) = render::<Model, Msg, _>(&view, &model);
                                index = nindex;
                                let js = format!("window.__skyApply({})", json_str(&nbody));
                                let _ = webview.evaluate_script(&js);
                            }
                        }
                    }
                    _ => {}
                }
            });

            // event_loop.run diverges; this is unreachable but satisfies the type.
            #[allow(unreachable_code)]
            ok_res(())
        })
    }
}

pub use imp::webview_app;
