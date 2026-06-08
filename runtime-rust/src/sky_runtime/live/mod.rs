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
        Attribute::Event(e) => format!("data-sky-on=\"{}\"", e.name()),
    }
}
