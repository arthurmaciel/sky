# S5 — Sky.Webview on the Rust backend

**Status:** Cross-platform floor shipped (stub + codegen). Real `wry`/`tao`
window backend staged (this doc) — it needs the system webview dev libraries,
which are absent in the build/CI environment, so it is designed here rather than
shipped as unverifiable code.

## What shipped (the floor)

`Webview.app { init, update, view, subscriptions, window }` lowers to the runtime
`webview_app` (see `runtime-rust/src/sky_runtime/webview.rs`). On a build without
the system webview libraries the stub returns a graceful `Err` with a remediation
message — exactly mirroring Go's `webview_stub.go` on non-darwin builds. A Sky
program that `import Std.Webview`s therefore builds, links, and runs (no panic) on
every platform.

Codegen plumbing (all in `src/Sky/Generate/Rust/`):

- **Walker** — a `Std.Webview` import sets `usesWebview` (+ `usesTea`, `usesHtml`,
  the view paints to the same `Html` tree as Sky.Live / Sky.Tui).
- **ExprEmitter** — `Webview.app` arrives as `VarTopLevel "Std.Webview" "app"`
  (it is a `.sky` `Ffi.kernel` alias, unlike the pure-kernel `Tui.app` /
  `Live.app`). The call-site special-case destructures the cfg record and emits
  `webview_app(init, update, view, subscriptions, WebviewWindowCfg { title, size })`.
  As with `Tui.app`, the view wraps in `Ui.layout` so it yields `Html`.
- **Types / opaque registry** — `Std.Webview.WindowCfg → sky_runtime::WebviewWindowCfg`
  (real struct, field names match); `Std.Webview.AppCfg → sky_runtime::WebviewAppCfg`
  (a zero-field marker — the cfg is destructured at the call site, never built in
  Rust, and its `view : model -> any` + `Fn` fields can't lower to a struct).
- **ModuleEmitter** — the synthesized record constructor for a marker-mapped cfg
  (`markerCfgAliases`) is skipped (a fieldless marker has nothing to construct);
  plain-data opaque cfgs (CacheCfg, WsServerCfg) keep theirs.
- **Project** — emits the `webview` module + re-exports when `usesWebview`.

Proof: `examples/rust/39-webview` (a Std.Ui counter) builds on `--target rust`
and runs without panic (stub `Err`).

## The real backend (staged)

Gate behind a `webview` Cargo feature with optional `wry` + `tao` deps (NOT in
`full`, so default + CI builds compile the stub and never link webkit). Build on
a machine with `webkit2gtk-4.1` + `libsoup-3.0` (Linux) / WKWebView (macOS) /
WebView2 (Windows).

Shape (mirrors Go's `webview.go`, reusing the shared `Html` renderer):

1. **Window** — `tao::event_loop::EventLoop` + `WindowBuilder` (title + logical
   size from `WebviewWindowCfg`). UI calls must stay on the event-loop thread.
2. **Initial paint** — `render_html(&view(model))` → `WebViewBuilder::with_html`
   (`<body>{html}</body>` + a bridge `<script>`).
3. **Bridge** — `with_ipc_handler` receives DOM events as JSON
   (`{ handlerId, args }`), forwarded to the TEA loop as Msgs through the shared
   `handler_index` (reuse Sky.Live's handler-id → Msg table, built from each
   fresh view). `evaluate_script("window.__skyApply(<html>)")` pushes re-renders.
4. **TEA loop** — the model lives on the event-loop thread; each Msg runs
   `update`, repaints via `evaluate_script`, and `Cmd` / `Sub` drive through the
   same `cli_run_cmd` / `SubManager` the Cli/Tui backends use (a `tao` user-event
   proxy delivers async Msgs back onto the UI thread). Diffing (reuse Sky.Live's
   `diff_trees`) replaces the full-body `__skyApply` once the bridge is proven.

### Open design points

- **Event-loop ↔ Task boundary** — `tao`'s `run` is diverging (`-> !`). The
  `webview_app` `SkyTask` must bridge a non-returning, `!Send` event loop. Likely
  shape: run the event loop on the calling thread and model completion
  (window-close) as the Task's resolution; `Cmd.perform` work hops onto the UI
  thread via the event-loop proxy. Needs verification on real hardware.
- **No panic vectors** — every `wry`/`tao` fallible call routes through
  `SkyResult::Err` (window build, webview build, `evaluate_script`), never
  `unwrap`/`expect`.

## Out of scope (v0.1 parity)

Tray icons, global hotkeys, native file dialogs, multi-window — Go's Sky.Webview
v0.1 is macOS-only and defers these to v0.2; the Rust floor matches that scope.
