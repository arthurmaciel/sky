use std::collections::HashMap;

/// Form data delivered to an `OnForm` handler (lower-cased keys; see dispatch).
pub type FormData = HashMap<String, String>;

#[derive(Clone, Debug, PartialEq)]
pub enum Html<M> {
    Element(String, Vec<Attribute<M>>, Vec<Html<M>>),
    Text(String),
    /// Raw, un-escaped HTML — trusted pre-rendered content only; caller sanitises.
    Raw(String),
}

#[derive(Clone)]
pub enum Attribute<M> {
    Attr(String, String),
    BoolAttr(String, bool),
    Event(Event<M>),
    /// Sentinel for a conditionally-absent attribute; skipped during render.
    NoAttr,
}

#[derive(Clone)]
pub enum Event<M> {
    OnMsg(String, M),
    OnString(String, std::sync::Arc<dyn Fn(String) -> M + Send + Sync>),
    OnBool(String, std::sync::Arc<dyn Fn(bool) -> M + Send + Sync>),
    OnForm(String, std::sync::Arc<dyn Fn(FormData) -> M + Send + Sync>),
}

impl<M: PartialEq> PartialEq for Attribute<M> {
    fn eq(&self, o: &Self) -> bool {
        use Attribute::*;
        match (self, o) {
            (Attr(a, b), Attr(c, d)) => a == c && b == d,
            (BoolAttr(a, b), BoolAttr(c, d)) => a == c && b == d,
            (Event(a), Event(b)) => a == b,
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
            Attribute::Event(e) => write!(f, "{e:?}"),
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
            | Event::OnForm(n, _) => n,
        }
    }

    fn kind_name(&self) -> (u8, &str) {
        match self {
            Event::OnMsg(n, _) => (0, n),
            Event::OnString(n, _) => (1, n),
            Event::OnBool(n, _) => (2, n),
            Event::OnForm(n, _) => (3, n),
        }
    }

    fn kind_tag(&self) -> &'static str {
        match self {
            Event::OnMsg(..) => "OnMsg",
            Event::OnString(..) => "OnString",
            Event::OnBool(..) => "OnBool",
            Event::OnForm(..) => "OnForm",
        }
    }
}

impl<M> std::fmt::Debug for Event<M> {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        write!(f, "Event::{}({})", self.kind_tag(), self.name())
    }
}

/// Stamp every Element (not Text/Raw) with a stable `sky-id` attribute derived
/// from its path. Idempotent: an existing sky-id is overwritten with the same
/// value. Text/Raw nodes are unaddressable (Go parity).
pub fn assign_sky_ids<M>(node: &mut Html<M>, path: &str) {
    if let Html::Element(_tag, attrs, kids) = node {
        set_attr(attrs, "sky-id", path);
        let mut idx = 0usize;
        for child in kids.iter_mut() {
            if let Html::Element(ctag, _, _) = child {
                let seg = format!("{path}_{idx}_{ctag}");
                idx += 1;
                assign_sky_ids(child, &seg);
            }
        }
    }
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

#[cfg(test)]
mod tests {
    use super::*;
    #[derive(Clone, Debug, PartialEq)]
    enum Msg {
        Inc,
    }

    #[test]
    fn sky_ids_are_stable_and_pathed() {
        let mut t: Html<()> = Html::Element("div".into(), vec![], vec![
            Html::Element("span".into(), vec![], vec![Html::Text("a".into())]),
            Html::Element("span".into(), vec![], vec![]),
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
            if let Html::Element(_, attrs, kids) = n {
                for a in attrs { if let Attribute::Attr(k, v) = a { if k == "sky-id" { out.push(v.clone()); } } }
                for c in kids { go(c, out); }
            }
        }
        go(n, &mut out);
        out
    }

    #[test]
    fn html_tree_constructs() {
        let t: Html<Msg> = Html::Element(
            "button".into(),
            vec![Attribute::Event(Event::OnMsg("click".into(), Msg::Inc))],
            vec![Html::Text("+".into())],
        );
        match t {
            Html::Element(tag, attrs, kids) => {
                assert_eq!(tag, "button");
                assert_eq!(attrs.len(), 1);
                assert_eq!(kids.len(), 1);
            }
            _ => panic!("expected element"),
        }

        // Clone + PartialEq round-trip on an attribute holding a closure.
        let attr: Attribute<Msg> = Attribute::Event(Event::OnMsg("click".into(), Msg::Inc));
        assert_eq!(attr, attr.clone());
        // Debug prints the variant name + event name, not a numeric discriminant.
        let dbg = format!("{:?}", attr);
        assert!(dbg.contains("OnMsg") && dbg.contains("click"), "debug was: {dbg}");
    }
}
