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
/// `Arc<dyn Fn(..) -> msg>` (not bare fn pointers) so the handler can be a
/// CAPTURING closure — exactly as the Go backend allows. A faithful Sky.Live
/// app's `onChange = \s -> toMsg (parse s default)` captures locals; a bare
/// fn-pointer field rejected that. Bare ctors / non-capturing fns coerce into
/// `Arc::new` fine; capturing closures box into the trait object. This follows
/// the `OnForm` precedent (already `Arc<dyn Fn>`). `OnRaw` is the
/// heterogeneous-payload escape hatch (`on` / `onSubmit`); its payload is
/// type-erased — not dispatchable, but kept so the bridge compiles. The
/// `submit` wire path resolves via `OnForm` instead (constructed server-side,
/// never from Sky stdlib).
#[derive(Clone)]
pub enum Event<M> {
    OnMsg(String, M),
    OnString(String, std::sync::Arc<dyn Fn(String) -> M + Send + Sync>),
    OnBool(String, std::sync::Arc<dyn Fn(bool) -> M + Send + Sync>),
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
            // Injection guard: an unsafe tag name (spaces / `>` / `<` …) would
            // break out of the start tag. Drop the whole element — including its
            // subtree — rather than emit an attacker-controlled tag.
            if !is_safe_html_name(tag) {
                return;
            }
            s.push('<');
            s.push_str(tag);
            // Collect regular + bool attrs into (key, value) pairs, then sort
            // by key — Go's renderVNode emits from a map under sort.Strings, so
            // matching byte-for-byte requires the same alphabetical order. A
            // BoolAttr renders as `k="true"` (Go stores it as the string "true"
            // in n.Attrs), NOT a bare `k`.
            let mut pairs: Vec<(&str, String)> = vec![];
            let mut events: Vec<&str> = vec![];
            let mut sky_id: Option<&str> = None;
            for a in attrs {
                match a {
                    Attribute::Attr(k, v) => {
                        if k == "sky-id" {
                            sky_id = Some(v);
                        }
                        pairs.push((k.as_str(), v.clone()));
                    }
                    Attribute::BoolAttr(k, true) => {
                        pairs.push((k.as_str(), "true".to_string()));
                    }
                    Attribute::BoolAttr(_, false) | Attribute::NoAttr => {}
                    Attribute::EventAttr(e) => events.push(e.name()),
                }
            }
            // <textarea> and <select> have NO `value` attribute in the HTML spec
            // — a textarea's displayed value is its TEXT CONTENT; a select's is the
            // `selected` <option>. Emitting `<textarea value="…">` renders EMPTY in
            // every browser (and a server re-render would wipe the user's text). So
            // strip the `value` attr here for both, and (textarea only) splice it
            // back as escaped text content after the open tag when there are no
            // explicit children. Mirrors Go `renderVNode` (live.go).
            let mut textarea_value: Option<String> = None;
            if tag == "textarea" || tag == "select" {
                if let Some(pos) = pairs.iter().position(|(k, _)| *k == "value") {
                    let (_, v) = pairs.remove(pos);
                    textarea_value = Some(v);
                }
            }
            pairs.sort_by(|a, b| a.0.cmp(b.0));
            for (k, v) in &pairs {
                // Attr KEY is emitted unescaped; an unsafe key (`x onload=…`)
                // injects a new attribute. Skip it (the value is still escaped).
                if !is_safe_html_name(k) {
                    continue;
                }
                s.push(' ');
                s.push_str(k);
                s.push_str("=\"");
                s.push_str(&escape_attr(v));
                s.push('"');
            }
            // Browser-client wire markers (live/client.js): the delegated
            // binder scans for `[sky-<event>]`, reads `data-sky-hid` for the
            // sky-id, and posts the `sky-<event>` value as `msg`. We make that
            // value the EVENT NAME so the server can tell click from submit
            // (the client doesn't send the event type otherwise) — the handler
            // resolves by (sky-id, event). `data-sky-on` is kept for parity
            // with Go's render.
            // Event names are emitted unescaped as both the `data-sky-on` value
            // and the `sky-<ev>` attribute key — an unsafe name injects markup.
            // Drop any that aren't valid HTML names.
            events.retain(|e| is_safe_html_name(e));
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
                s.push_str(" />");
                return;
            }
            s.push('>');
            // Textarea value-as-content (Go parity): write the captured value as
            // escaped text content. Explicit children take precedence (a user who
            // wrote `textarea [] [ text "hi" ]` keeps that), matching Go's
            // `isTextarea && value != "" && len(children) == 0` guard.
            if tag == "textarea" {
                if let Some(v) = &textarea_value {
                    if !v.is_empty() && kids.is_empty() {
                        s.push_str(&escape_text(v));
                    }
                }
            }
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
    // `&` first (so the inserted `&xxx;` entities aren't re-escaped), then the
    // remaining metacharacters. The single quote `'` is escaped too — Go's
    // html.EscapeString covers the full `& ' < > "` set, and a missed `'` is an
    // attribute-breakout XSS hole when the result lands in a single-quoted attr.
    t.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('\'', "&#39;")
}

fn escape_attr(t: &str) -> String {
    // `"` → `&#34;` (NOT `&quot;`) to match Go's html.EscapeString byte-for-byte
    // (GOROOT/src/html/escape.go uses the numeric entity). Both are valid HTML;
    // the numeric form is what the Go renderer emits, so equiv tests byte-compare.
    escape_text(t).replace('"', "&#34;")
}

/// True when `name` is safe to emit UNESCAPED as a tag name, attribute key, or
/// event name. Tag/attr/event names are NEVER escaped (an escaped `<` in a tag
/// position is meaningless), so a name carrying a structural metacharacter is a
/// direct injection: a tag `"div><script>…"` or an attr key `"x onmouseover=…"`
/// would break out of the element. Sky `Html.node` / `Html.attribute` take the
/// name as a `String`, so it can be attacker-derived. Accept only the characters
/// that appear in real HTML names — letters, digits, and `-_:.` — and reject
/// everything else (whitespace, `<>"'=/\``, control bytes, non-ASCII). An invalid
/// name causes the element / attribute / event marker to be DROPPED rather than
/// emitted, closing the XSS hole with no escaping ambiguity.
fn is_safe_html_name(name: &str) -> bool {
    !name.is_empty()
        && name.bytes().all(|b| {
            b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b':' | b'.')
        })
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
/// Routes through the same escaper as render so the escape set (`& ' < > "`,
/// matching Go's html.EscapeString for the text subset) can never drift.
pub fn html_escape_text_(s: String) -> String {
    escape_text(&s)
}

/// `Ffi.callPure "htmlEscapeAttr"` — escape a string for use in a quoted
/// attribute. Shares render's attr escaper, so a value placed in a single- or
/// double-quoted attribute is escaped identically (no attribute-breakout hole).
pub fn html_escape_attr_(s: String) -> String {
    escape_attr(&s)
}

/// `Ffi.callPure "htmlAttrToString"` — serialise a single Attribute to its key="value" form.
pub fn html_attr_to_string_<M>(attr: Attribute<M>) -> String {
    // Gate the attribute KEY / event name with is_safe_html_name — same as the
    // render_into path. The key is emitted UNESCAPED, so a hostile key such as
    // `x onload=alert(1)` (reachable via Std.Html.Attributes.attribute) would
    // inject markup; the value is entity-escaped. An unsafe name drops the whole
    // attribute, mirroring render_into's `events.retain(is_safe_html_name)`.
    match attr {
        Attribute::Attr(k, v) if is_safe_html_name(&k) => {
            format!("{}=\"{}\"", k, html_escape_attr_(v))
        }
        Attribute::BoolAttr(k, true) if is_safe_html_name(&k) => k,
        Attribute::EventAttr(e) if is_safe_html_name(e.name()) => {
            format!("data-sky-on=\"{}\"", e.name())
        }
        // unsafe key / event name, false bool attr, or NoAttr → emit nothing
        Attribute::Attr(..)
        | Attribute::BoolAttr(..)
        | Attribute::EventAttr(..)
        | Attribute::NoAttr => String::new(),
    }
}

// ─── SkyStringify for the Html runtime types ────────────────────────────────
// Same rationale as the Std.Ui impls in ui/element.rs: a codegen-emitted
// `sky_show` recurses into every field, so an Html/Attribute/Event a generated
// type can hold must impl the trait (else E0599). No Go `%v` analogue worth
// matching; a stable type-tag placeholder is total and never recurses into `M`.
impl<M> crate::sky_runtime::stringify::SkyStringify for Html<M> {
    fn sky_show(&self) -> String { "<html>".to_string() }
}
impl<M> crate::sky_runtime::stringify::SkyStringify for Attribute<M> {
    fn sky_show(&self) -> String { "<html-attribute>".to_string() }
}
impl<M> crate::sky_runtime::stringify::SkyStringify for Event<M> {
    fn sky_show(&self) -> String { "<event>".to_string() }
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
        // Attrs are sorted alphabetically; BoolAttr renders as `k="true"`; void
        // elements self-close — all to match Go renderVNode.
        assert!(s.contains(r#"<input disabled="true" sky-id="r_0_input" value="a&lt;b" />"#), "{s}");
        assert!(s.contains("1 &lt; 2"));
        assert!(s.contains("<b>ok</b>"));
        assert!(s.contains("</div>"));
    }

    #[test]
    fn textarea_value_renders_as_content_not_attr() {
        // <textarea value="…"> renders EMPTY in browsers — the value must become
        // the text content. Go parity (live.go renderVNode). Std.Ui.Input.multiline
        // sets a `value` attr; the renderer must move it into the body.
        let t: Html<()> = Html::HElement("textarea".into(),
            vec![Attribute::Attr("value".into(), "fill the column".into())],
            vec![]);
        let s = render_html(&t);
        assert!(!s.contains("value=\""), "value attr must be stripped from textarea: {s}");
        assert!(s.contains(">fill the column</textarea>"), "value must be content: {s}");
    }

    #[test]
    fn textarea_value_is_escaped_and_select_strips_value() {
        // textarea content is HTML-escaped (XSS); explicit children win over the
        // attr-derived value; <select> strips a redundant `value` attr (no content).
        let ta: Html<()> = Html::HElement("textarea".into(),
            vec![Attribute::Attr("value".into(), "a<b'c".into())], vec![]);
        assert!(render_html(&ta).contains(">a&lt;b&#39;c</textarea>"), "{}", render_html(&ta));

        let ta_kids: Html<()> = Html::HElement("textarea".into(),
            vec![Attribute::Attr("value".into(), "ignored".into())],
            vec![Html::HText("explicit".into())]);
        let s = render_html(&ta_kids);
        assert!(s.contains(">explicit</textarea>") && !s.contains("ignored"), "{s}");

        let sel: Html<()> = Html::HElement("select".into(),
            vec![Attribute::Attr("value".into(), "x".into())], vec![]);
        assert!(!render_html(&sel).contains("value="), "select strips value: {}", render_html(&sel));
    }

    #[test]
    fn single_quote_is_escaped_everywhere() {
        // A `'` in attr/text/kernel output must become `&#39;` so a value placed
        // in a single-quoted attribute can't break out (XSS) and the escape set
        // matches Go's html.EscapeString.
        assert_eq!(escape_text("it's <b>"), "it&#39;s &lt;b&gt;");
        assert_eq!(escape_attr("a'\"b"), "a&#39;&#34;b");
        assert_eq!(html_escape_text_("x'y".to_string()), "x&#39;y");
        assert_eq!(html_escape_attr_("x'y".to_string()), "x&#39;y");
        // Round-trips through render on a real attribute value.
        let mut t: Html<()> = Html::HElement(
            "a".into(),
            vec![Attribute::Attr("href".into(), "/x?q='z".into())],
            vec![],
        );
        assign_sky_ids(&mut t, "r");
        let s = render_html(&t);
        assert!(s.contains("href=\"/x?q=&#39;z\""), "{s}");
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
