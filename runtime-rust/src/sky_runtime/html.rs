use std::collections::HashMap;

/// Form data delivered to an `OnForm` handler (lower-cased keys; see dispatch).
pub type FormData = HashMap<String, String>;

#[derive(Clone, Debug, PartialEq)]
pub enum Html<M> {
    /// Normal element node — matches Sky's `HElement tag attrs children`.
    HElement(String, Vec<Attribute<M>>, Vec<Html<M>>),
    /// Text node (HTML-escaped on render) — matches Sky's `HText s`.
    HText(String),
    /// Raw, un-escaped HTML — trusted pre-rendered content only; caller sanitises.
    /// Matches Sky's `HRaw s`.
    HRaw(String),
}

/// Variant names mirror the Sky stdlib `Std.Html.Attributes.Attribute` ADT
/// (`Attr | BoolAttr | EventAttr (Event msg) | NoAttr`) so the Rust codegen's
/// bridge (`StdHtmlAttributesAttribute<msg> = sky_runtime::Attribute<msg>`)
/// constructs the right variants by name.
#[derive(Clone)]
pub enum Attribute<M> {
    Attr(String, String),
    BoolAttr(String, bool),
    EventAttr(Event<M>),
    /// Sentinel for a conditionally-absent attribute; skipped during render.
    NoAttr,
}

/// Variant names mirror the Sky stdlib `Std.Html.Attributes.Event` ADT
/// (`OnMsg | OnString | OnBool | OnRaw String any`). `OnString`/`OnBool` carry
/// fn pointers (the codegen renders the Sky `(String -> msg)` handler as
/// `fn(String) -> msg`). `OnRaw` is the heterogeneous-payload escape hatch
/// (`on` / `onSubmit`); its payload is type-erased — not dispatchable in P1,
/// but kept so the bridge compiles. The `submit` wire path resolves via
/// `OnForm` instead (constructed server-side, never from Sky stdlib).
#[derive(Clone)]
pub enum Event<M> {
    OnMsg(String, M),
    OnString(String, fn(String) -> M),
    OnBool(String, fn(bool) -> M),
    OnRaw(String, std::sync::Arc<dyn std::any::Any + Send + Sync>),
    /// Server-constructed form handler (not produced by the Sky stdlib bridge).
    /// Returns `Option<M>`: a malformed/incomplete form (decode failure) yields
    /// `None` so the live loop dispatches no Msg (see `decode_form`).
    OnForm(String, std::sync::Arc<dyn Fn(FormData) -> Option<M> + Send + Sync>),
}

impl<M: PartialEq> PartialEq for Attribute<M> {
    fn eq(&self, o: &Self) -> bool {
        use Attribute::*;
        match (self, o) {
            (Attr(a, b), Attr(c, d)) => a == c && b == d,
            (BoolAttr(a, b), BoolAttr(c, d)) => a == c && b == d,
            (EventAttr(a), EventAttr(b)) => a == b,
            (NoAttr, NoAttr) => true,
            _ => false,
        }
    }
}

impl<M> std::fmt::Debug for Attribute<M> {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        match self {
            Attribute::Attr(k, v) => write!(f, "Attr({k:?},{v:?})"),
            Attribute::BoolAttr(k, v) => write!(f, "BoolAttr({k:?},{v})"),
            Attribute::EventAttr(e) => write!(f, "{e:?}"),
            Attribute::NoAttr => write!(f, "NoAttr"),
        }
    }
}

// Structural equality only: (variant kind, event name). The message payload /
// closure is deliberately ignored. Sky.Live's diff is structure-only — it just
// decides whether a DOM node carries a listener of a given event name. The
// actual handler lives server-side in the per-session handler_index, which is
// REBUILT from the fresh view on every commit, so the diff never needs to
// compare handlers. Comparing payloads here would cause spurious re-renders
// (e.g. OnMsg("click", Inc) vs OnMsg("click", Dec) are equal for diff purposes).
impl<M> PartialEq for Event<M> {
    fn eq(&self, o: &Self) -> bool {
        self.kind_name() == o.kind_name()
    }
}

impl<M> Event<M> {
    pub fn name(&self) -> &str {
        match self {
            Event::OnMsg(n, _)
            | Event::OnString(n, _)
            | Event::OnBool(n, _)
            | Event::OnRaw(n, _)
            | Event::OnForm(n, _) => n,
        }
    }

    fn kind_name(&self) -> (u8, &str) {
        match self {
            Event::OnMsg(n, _) => (0, n),
            Event::OnString(n, _) => (1, n),
            Event::OnBool(n, _) => (2, n),
            Event::OnRaw(n, _) => (4, n),
            Event::OnForm(n, _) => (3, n),
        }
    }

    fn kind_tag(&self) -> &'static str {
        match self {
            Event::OnMsg(..) => "OnMsg",
            Event::OnString(..) => "OnString",
            Event::OnBool(..) => "OnBool",
            Event::OnRaw(..) => "OnRaw",
            Event::OnForm(..) => "OnForm",
        }
    }
}

impl<M> std::fmt::Debug for Event<M> {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        write!(f, "Event::{}({})", self.kind_tag(), self.name())
    }
}

const VOID: &[&str] = &[
    "area", "base", "br", "col", "embed", "hr", "img", "input",
    "link", "meta", "param", "source", "track", "wbr",
];

/// Render an `Html` tree to an HTML string. Text is HTML-escaped; Raw is
/// emitted verbatim; void elements self-close with no children; event
/// handlers emit a `data-sky-on="<space-separated event names>"` marker
/// attribute that the browser client reads to bind listeners. Mirrors Go
/// `renderVNode`.
pub fn render_html<M>(node: &Html<M>) -> String {
    let mut s = String::new();
    render_into(node, &mut s);
    s
}

fn render_into<M>(node: &Html<M>, s: &mut String) {
    match node {
        Html::HText(t) => s.push_str(&escape_text(t)),
        Html::HRaw(r) => s.push_str(r),
        Html::HElement(tag, attrs, kids) => {
            s.push('<');
            s.push_str(tag);
            let mut events: Vec<&str> = vec![];
            let mut sky_id: Option<&str> = None;
            for a in attrs {
                match a {
                    Attribute::Attr(k, v) => {
                        if k == "sky-id" {
                            sky_id = Some(v);
                        }
                        s.push(' ');
                        s.push_str(k);
                        s.push_str("=\"");
                        s.push_str(&escape_attr(v));
                        s.push('"');
                    }
                    Attribute::BoolAttr(k, true) => {
                        s.push(' ');
                        s.push_str(k);
                    }
                    Attribute::BoolAttr(_, false) | Attribute::NoAttr => {}
                    Attribute::EventAttr(e) => events.push(e.name()),
                }
            }
            // Browser-client wire markers (live/client.js): the delegated
            // binder scans for `[sky-<event>]`, reads `data-sky-hid` for the
            // sky-id, and posts the `sky-<event>` value as `msg`. We make that
            // value the EVENT NAME so the server can tell click from submit
            // (the client doesn't send the event type otherwise) — the handler
            // resolves by (sky-id, event). `data-sky-on` is kept for parity
            // with Go's render.
            if !events.is_empty() {
                s.push_str(" data-sky-on=\"");
                s.push_str(&events.join(" "));
                s.push('"');
                if let Some(id) = sky_id {
                    s.push_str(" data-sky-hid=\"");
                    s.push_str(&escape_attr(id));
                    s.push('"');
                }
                for ev in &events {
                    s.push_str(" sky-");
                    s.push_str(ev);
                    s.push_str("=\"");
                    s.push_str(ev);
                    s.push('"');
                }
            }
            if VOID.contains(&tag.as_str()) {
                s.push('>');
                return;
            }
            s.push('>');
            for c in kids {
                render_into(c, s);
            }
            s.push_str("</");
            s.push_str(tag);
            s.push('>');
        }
    }
}

fn escape_text(t: &str) -> String {
    t.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;")
}

fn escape_attr(t: &str) -> String {
    escape_text(t).replace('"', "&quot;")
}

/// Stamp every HElement (not HText/HRaw) with a stable `sky-id` attribute derived
/// from its path. Idempotent: an existing sky-id is overwritten with the same
/// value. HText/HRaw nodes are unaddressable (Go parity).
///
/// Each non-root segment is `{path}_{idx}_{tag}[:{key}]` — the embedded tag means
/// two structurally different subtrees never share an id at the same positional
/// depth, and the optional `:{key}` disambiguator (from an explicit `sky-key`
/// attribute, or implicit from `name` on form-bearing tags) lets keyed list items
/// and named form fields keep identity across reorder. Mirrors Go `assignSkyIDs`
/// / `skyIDKey` (`runtime-go/rt/live.go`).
pub fn assign_sky_ids<M>(node: &mut Html<M>, path: &str) {
    if let Html::HElement(_tag, attrs, kids) = node {
        set_attr(attrs, "sky-id", path);
        let mut idx = 0usize;
        for child in kids.iter_mut() {
            if let Html::HElement(ctag, cattrs, _) = child {
                let mut seg = format!("{path}_{idx}_{ctag}");
                if let Some(key) = sky_id_key(ctag, cattrs) {
                    seg.push(':');
                    seg.push_str(&key);
                }
                idx += 1;
                assign_sky_ids(child, &seg);
            }
        }
    }
}

/// Stable disambiguator for an element, or `None`. Priority: an explicit
/// `sky-key` attribute (set by `Html.keyed`), then `name` on form-bearing tags.
/// Any matched value is sanitised so it can't corrupt the sky-id grammar.
/// Mirrors Go `skyIDKey`.
fn sky_id_key<M>(tag: &str, attrs: &[Attribute<M>]) -> Option<String> {
    if let Some(k) = attr_value(attrs, "sky-key") {
        if !k.is_empty() {
            return Some(sanitise_sky_id_key(k));
        }
    }
    if matches!(
        tag,
        "input" | "textarea" | "select" | "form" | "button" | "fieldset"
    ) {
        if let Some(k) = attr_value(attrs, "name") {
            if !k.is_empty() {
                return Some(sanitise_sky_id_key(k));
            }
        }
    }
    None
}

fn attr_value<'a, M>(attrs: &'a [Attribute<M>], key: &str) -> Option<&'a str> {
    attrs.iter().find_map(|a| match a {
        Attribute::Attr(k, v) if k == key => Some(v.as_str()),
        _ => None,
    })
}

/// Replace anything outside `[A-Za-z0-9_-]` with `_`. Prevents the key from
/// breaking sky-id parsing, CSS selector escaping, or HTML attribute quoting.
/// Mirrors Go `sanitiseSkyIDKey`.
fn sanitise_sky_id_key(s: &str) -> String {
    s.chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '-' || c == '_' {
                c
            } else {
                '_'
            }
        })
        .collect()
}

fn set_attr<M>(attrs: &mut Vec<Attribute<M>>, key: &str, val: &str) {
    for a in attrs.iter_mut() {
        if let Attribute::Attr(k, v) = a {
            if k == key {
                *v = val.to_string();
                return;
            }
        }
    }
    attrs.push(Attribute::Attr(key.to_string(), val.to_string()));
}

// --- Std.Html kernel wrappers (`Ffi.callPure "htmlXxx"`) ---
// These match the kernel names used in sky-stdlib Std.Html.sky — the Sky-side
// helpers (render, escapeHtml, escapeAttr, attrToString) route here on the Rust
// backend. The codegen converts "htmlRender" → `html_render_()`, etc. Kept in
// this standalone module (not under live/) so a non-Live Std.Html / Std.Ui app
// renders via Html.toString without pulling the Sky.Live server machinery.

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

#[cfg(test)]
mod tests {
    use super::*;
    #[derive(Clone, Debug, PartialEq)]
    enum Msg {
        Inc,
    }

    #[test]
    fn render_escapes_and_emits_attrs_events_void() {
        let t: Html<()> = Html::HElement("div".into(),
            vec![Attribute::Attr("class".into(), "x".into())],
            vec![
                Html::HElement("input".into(),
                    vec![Attribute::Attr("value".into(), "a<b".into()), Attribute::BoolAttr("disabled".into(), true)],
                    vec![]),
                Html::HText("1 < 2".into()),
                Html::HRaw("<b>ok</b>".into()),
            ]);
        let mut t = t; assign_sky_ids(&mut t, "r");
        let s = render_html(&t);
        assert!(s.contains(r#"<div class="x" sky-id="r">"#), "{s}");
        assert!(s.contains(r#"<input value="a&lt;b" disabled sky-id="r_0_input">"#), "{s}");
        assert!(s.contains("1 &lt; 2"));
        assert!(s.contains("<b>ok</b>"));
        assert!(s.contains("</div>"));
    }

    #[test]
    fn render_emits_data_event_attr() {
        let t: Html<()> = Html::HElement("button".into(),
            vec![Attribute::EventAttr(Event::OnMsg("click".into(), ()))], vec![]);
        let mut t = t; assign_sky_ids(&mut t, "r");
        let s = render_html(&t);
        assert!(s.contains(r#"data-sky-on="click""#), "{s}");
    }

    #[test]
    fn sky_ids_are_stable_and_pathed() {
        let mut t: Html<()> = Html::HElement("div".into(), vec![], vec![
            Html::HElement("span".into(), vec![], vec![Html::HText("a".into())]),
            Html::HElement("span".into(), vec![], vec![]),
        ]);
        assign_sky_ids(&mut t, "r");
        let ids = collect_ids(&t);
        assert_eq!(ids, vec!["r", "r_0_span", "r_1_span"]);
        let mut t2 = t.clone();
        assign_sky_ids(&mut t2, "r");
        assert_eq!(collect_ids(&t2), ids);
    }

    fn collect_ids<M>(n: &Html<M>) -> Vec<String> {
        let mut out = vec![];
        fn go<M>(n: &Html<M>, out: &mut Vec<String>) {
            if let Html::HElement(_, attrs, kids) = n {
                for a in attrs { if let Attribute::Attr(k, v) = a { if k == "sky-id" { out.push(v.clone()); } } }
                for c in kids { go(c, out); }
            }
        }
        go(n, &mut out);
        out
    }

    #[test]
    fn keyed_items_keep_id_across_reorder() {
        // Two keyed <li> swapped: each keeps its `:{key}` id so the diff can
        // target the moved element instead of replacing the whole list.
        let li = |k: &str| -> Html<()> {
            Html::HElement(
                "li".into(),
                vec![Attribute::Attr("sky-key".into(), k.into())],
                vec![Html::HText(k.into())],
            )
        };
        let mut a: Html<()> =
            Html::HElement("ul".into(), vec![], vec![li("alpha"), li("beta")]);
        let mut b: Html<()> =
            Html::HElement("ul".into(), vec![], vec![li("beta"), li("alpha")]);
        assign_sky_ids(&mut a, "r");
        assign_sky_ids(&mut b, "r");
        let ids_a = collect_ids(&a);
        let ids_b = collect_ids(&b);
        // alpha keeps the same id in both renders even though its position moved.
        assert!(ids_a.contains(&"r_0_li:alpha".to_string()), "{ids_a:?}");
        assert!(ids_b.contains(&"r_1_li:alpha".to_string()), "{ids_b:?}");
        // The key disambiguator is present, sanitised.
        assert!(ids_a.iter().all(|s| s.contains(":alpha") || s.contains(":beta") || s == "r"));
    }

    #[test]
    fn name_on_form_tag_becomes_implicit_key() {
        let mut t: Html<()> = Html::HElement(
            "form".into(),
            vec![],
            vec![Html::HElement(
                "input".into(),
                vec![Attribute::Attr("name".into(), "email".into())],
                vec![],
            )],
        );
        assign_sky_ids(&mut t, "r");
        assert!(collect_ids(&t).contains(&"r_0_input:email".to_string()));
    }

    #[test]
    fn sky_key_value_is_sanitised() {
        assert_eq!(sanitise_sky_id_key("a/b c.d"), "a_b_c_d");
        assert_eq!(sanitise_sky_id_key("keep-_OK9"), "keep-_OK9");
    }

    #[test]
    fn html_tree_constructs() {
        let t: Html<Msg> = Html::HElement(
            "button".into(),
            vec![Attribute::EventAttr(Event::OnMsg("click".into(), Msg::Inc))],
            vec![Html::HText("+".into())],
        );
        match t {
            Html::HElement(tag, attrs, kids) => {
                assert_eq!(tag, "button");
                assert_eq!(attrs.len(), 1);
                assert_eq!(kids.len(), 1);
            }
            _ => panic!("expected element"),
        }

        // Clone + PartialEq round-trip on an attribute holding a closure.
        let attr: Attribute<Msg> = Attribute::EventAttr(Event::OnMsg("click".into(), Msg::Inc));
        assert_eq!(attr, attr.clone());
        // Debug prints the variant name + event name, not a numeric discriminant.
        let dbg = format!("{:?}", attr);
        assert!(dbg.contains("OnMsg") && dbg.contains("click"), "debug was: {dbg}");
    }
}
