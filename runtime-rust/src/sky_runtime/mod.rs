// Sky Runtime — all modules (for standalone crate compilation).
// In generated projects, this file is overridden by the compiler.

pub mod config;
#[cfg(feature = "config")]
pub mod config_decode;
pub mod core;

#[cfg(feature = "tokio")]
pub mod task;
#[cfg(feature = "tokio")]
pub mod log;
#[cfg(feature = "tokio")]
pub mod trace;
#[cfg(feature = "tokio")]
pub mod system;
pub mod time;
pub mod random;
#[cfg(feature = "crypto")]
pub mod crypto;
pub mod file;
pub use file::*;

pub mod path;
pub use path::*;

#[cfg(feature = "json")]
pub mod json;
#[cfg(feature = "db")]
pub mod db;
#[cfg(feature = "db")]
pub use db::*;
// Telemetry spill — write-through SQLite persistence behind the
// db feature; the always-compiled telemetry sink calls its cfg-stubbed hook.
#[cfg(feature = "db")]
pub mod telemetry_spill;

pub use config::*;
#[cfg(feature = "config")]
pub use config_decode::*;
pub use core::*;
#[cfg(feature = "tokio")]
pub use task::*;
#[cfg(feature = "tokio")]
pub use log::*;
#[cfg(feature = "tokio")]
pub use trace::*;
#[cfg(feature = "tokio")]
pub use system::*;
pub use time::*;
pub use random::*;
#[cfg(feature = "json")]
pub use json::*;

pub mod encoding;
pub use encoding::*;

pub mod regex_kernel;
pub use regex_kernel::*;

#[cfg(feature = "json")]
pub mod jwt;
#[cfg(feature = "json")]
pub use jwt::*;

pub mod decimal;
pub use decimal::*;

#[cfg(feature = "compression")]
pub mod compression;
#[cfg(feature = "compression")]
pub use compression::*;

#[cfg(feature = "csv")]
pub mod csv;
#[cfg(feature = "csv")]
pub use csv::*;

#[cfg(feature = "cache_kernel")]
pub mod cache;
#[cfg(feature = "cache_kernel")]
pub use cache::*;

#[cfg(feature = "tui")]
pub mod tui;
// NB: no `pub use tui::*` — its `diff` module name collides with live's `diff`.
// Re-export only the kernels generated code calls unqualified: `tui_app`
// (String view, `Tui.program`) + `tui_app_ui` (Element view, `Tui.app`).
#[cfg(feature = "tui")]
pub use tui::{tui_app, tui_app_ui};

pub mod uuid_kernel;
pub use uuid_kernel::*;

#[cfg(feature = "server")]
pub mod server;
#[cfg(feature = "server")]
pub use server::*;
#[cfg(feature = "server")]
pub mod server_stream;
#[cfg(feature = "server")]
pub use server_stream::*;

#[cfg(feature = "http_client")]
pub mod http_client;
#[cfg(feature = "http_client")]
pub use http_client::*;
#[cfg(feature = "http_client")]
pub mod http_stream;
#[cfg(feature = "http_client")]
pub use http_stream::*;

#[cfg(feature = "email")]
pub mod email;
#[cfg(feature = "email")]
pub use email::*;

#[cfg(feature = "tokio")]
pub mod tea;
#[cfg(feature = "tokio")]
pub use tea::*;

#[cfg(feature = "websocket_client")]
pub mod ws_client;
#[cfg(feature = "websocket_client")]
pub use ws_client::*;

// Std.Html / Std.Ui render surface — the Html/Attribute/Event ADTs + renderer +
// htmlXxx kernel wrappers. Pure (std only), so always available; a non-Live
// Std.Ui app renders via Html.toString without the `live` server module. The
// live module re-exports from here.
pub mod html;
pub use html::*;

// In-process telemetry sink (log/error rings + request counters) — always
// compiled so `Std.Log.*` can feed it; the Sky.Live `console` module serves it.
pub mod telemetry;

// Std.Ui shared element tree — the general UI abstraction (Element/Attribute/
// Length/Color/...). Backends (Live/Tui/Webview) each render it to their target.
// Referenced by qualified path (`sky_runtime::ui::*`) from generated code; NOT
// glob-re-exported (its `Attribute` would collide with html's).
pub mod ui;

// Sky.Webview — native desktop window backend (a TEA app, so gated on the async
// runtime like `tea`). The cross-platform floor (a stub returning a graceful Err)
// keeps `import Std.Webview` linking everywhere; the real wry/tao window backend
// needs the system webview dev libs (staged behind the webview design doc).
// Mirrors Go's webview_stub.go.
#[cfg(feature = "tokio")]
pub mod webview;
#[cfg(feature = "tokio")]
pub use webview::{webview_app, WebviewAppCfg, WebviewWindowCfg};

#[cfg(feature = "live")]
pub mod live;
#[cfg(feature = "live")]
pub use live::*;

pub mod ffi_polyfills;
pub use ffi_polyfills::*;

pub mod money;
pub use money::*;

pub mod math;
pub use math::*;

pub mod dict;
pub use dict::*;
pub mod set;
pub use set::*;

pub mod string;
pub use string::*;

pub mod basics;
pub use basics::*;

pub mod stringify;
pub use stringify::*;

pub mod char_kernel;
pub use char_kernel::*;

pub mod list;
pub use list::*;

pub mod io;
pub use io::*;

// auth.rs's external deps are `bcrypt` (crypto), `jsonwebtoken`/`serde_json`
// (json), AND `sqlx`/`Db` (db — register/login/setRole write the user table).
// Gate on ALL THREE: the old `all(db, json)` gate omitted `crypto`, so a
// `--features db` build (crypto off) compiled auth and failed on unresolved
// `bcrypt`. With `crypto` required, that build excludes auth instead.
#[cfg(all(feature = "crypto", feature = "db", feature = "json"))]
pub mod auth;
#[cfg(all(feature = "crypto", feature = "db", feature = "json"))]
pub use auth::*;
