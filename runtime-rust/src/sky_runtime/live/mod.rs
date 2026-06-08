//! Sky.Live on the Rust backend — HTTP-first render + SSE patch loop.
//! Generic over the app's (Model, Msg); no `any`, static dispatch only.
pub mod html;
pub use html::*;
pub mod diff;
pub use diff::*;
pub mod dispatch;
pub use dispatch::*;

use super::*;

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

/// Minimal page wrap (P0). The full client-bearing wrap lands in Task 9/10.
pub fn render_page(body: &str) -> String {
    format!(
        "<!DOCTYPE html><html><head><meta charset=\"utf-8\"></head><body><div id=\"sky-root\">{body}</div></body></html>"
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
