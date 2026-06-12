//! Sky.Webview — native desktop window backend (cross-platform floor).
//!
//! `Webview.app { init, update, view, subscriptions, window }` is meant to drive
//! a native system webview (WebKitGTK on Linux, WKWebView on macOS, WebView2 on
//! Windows) via `wry` + `tao`, reusing the SAME `Html` renderer as Sky.Live /
//! Sky.Tui — the view paints identically across all three backends. The bridge is
//! in-process (`with_html` for the initial paint + an IPC handler for events);
//! there is no HTTP server, SSE, or session store.
//!
//! This module is the **cross-platform floor**: a stub `webview_app` that returns
//! a graceful `Err` with a remediation message, exactly mirroring Go's
//! `webview_stub.go` on non-darwin builds. It keeps the `webview_app` symbol
//! present so any Sky program that `import Std.Webview`s builds + links on every
//! platform and never panics. The real `wry`/`tao` window backend needs the
//! system webview dev libraries (Linux: `webkit2gtk-4.1` + `libsoup-3.0`) — which
//! are absent in the CI/build environment — so it is staged as a design rather
//! than shipped as unverifiable code; see
//! `runtime-rust/docs/superpowers/specs/2026-06-12-s5-sky-webview-design.md`.
//!
//! No panic vectors: the stub returns `Err`; no `unwrap`/`expect`/`panic`.

use super::core::{SkyResult, SkyTask};
use super::html::Html;
use super::tea::{SkyCmd, SkySub};

/// Window configuration — mirrors Sky's closed `WindowCfg { title, size }`.
#[allow(non_snake_case)]
#[derive(Clone, Debug)]
pub struct WebviewWindowCfg {
    pub title: String,
    pub size: (i64, i64),
}

/// Phantom marker for Sky's `AppCfg model msg` record alias. The cfg is
/// destructured field-by-field at the `Webview.app` call site (see the Rust
/// codegen), never constructed in Rust, so the Sky alias maps to this zero-field
/// marker via `runtimeOpaqueTypes` — which suppresses generating a struct whose
/// `Fn`-typed fields + `view : model -> any` can't derive Debug/PartialEq or
/// resolve `any`.
pub struct WebviewAppCfg;

/// `Webview.app` — cross-platform floor. Returns an `Err` directing the user to a
/// webview-capable build; the real native-window backend is staged behind the
/// design doc above. Keeps the symbol present so `import Std.Webview` links.
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
            "Webview.app: this Sky build has no native webview backend. The Rust \
             target's Webview window needs the system webview dev libraries \
             (Linux: webkit2gtk-4.1 + libsoup-3.0; macOS: WKWebView ships with the \
             OS; Windows: install the Edge WebView2 runtime). Build on a supported \
             machine to open a window."
                .to_string()
                .into(),
        )
    })
}
