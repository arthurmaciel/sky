use crate::sky_runtime::live::html::*;
use serde::Serialize;
use std::collections::HashMap;

/// A single DOM patch emitted by `diff`. Field names mirror the Go `Patch` struct
/// (JSON: `id`, `text`, `html`, `attrs`, `remove`) — see `runtime-go/rt/live.go`.
#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct Patch {
    pub id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub html: Option<String>,
    /// Attribute delta: present key with non-empty value → set; empty value → remove.
    /// Go convention: `""` means remove.
    #[serde(skip_serializing_if = "HashMap::is_empty", default)]
    pub attrs: HashMap<String, String>,
    #[serde(skip_serializing_if = "std::ops::Not::not", default)]
    pub remove: bool,
}

impl Patch {
    fn for_id(id: &str) -> Self {
        Patch {
            id: id.into(),
            text: None,
            html: None,
            attrs: HashMap::new(),
            remove: false,
        }
    }

    fn is_noop(&self) -> bool {
        self.text.is_none() && self.html.is_none() && self.attrs.is_empty() && !self.remove
    }
}

/// Structural diff between two `Html` trees that have already had `assign_sky_ids`
/// applied. Returns the minimal list of `Patch` operations needed to update the
/// DOM from `old` to `new`.
///
/// Strategy (P1 — sufficient for the counter gate):
/// - Matched-tag element pair: diff attributes + children recursively.
/// - Structural mismatch (different tag or different node kind): emit a whole-subtree
///   `html` replace.
/// - Single text child change: `SetText` via `p.text`.
/// - Keyed reorder is deferred to P6.
pub fn diff<M>(old: &Html<M>, new: &Html<M>) -> Vec<Patch> {
    let mut out = vec![];
    diff_node(old, new, &mut out);
    out
}

// ─── internal helpers ─────────────────────────────────────────────────────────

fn sky_id<M>(n: &Html<M>) -> Option<&str> {
    if let Html::HElement(_, attrs, _) = n {
        for a in attrs {
            if let Attribute::Attr(k, v) = a {
                if k == "sky-id" {
                    return Some(v);
                }
            }
        }
    }
    None
}

fn diff_node<M>(old: &Html<M>, new: &Html<M>, out: &mut Vec<Patch>) {
    match (old, new) {
        (Html::HElement(ot, oa, ok), Html::HElement(nt, na, nk)) if ot == nt => {
            let id = sky_id(new).unwrap_or("").to_string();
            let mut p = Patch::for_id(&id);
            diff_attrs(oa, na, &mut p);

            if same_child_shape(ok, nk) {
                // Recurse into matched children.
                if !p.is_noop() {
                    out.push(p);
                }
                // Handle a sole text-child change via SetText (cheaper than html replace).
                diff_text_children(&id, ok, nk, out);
                // Recurse into element children.
                for (c_old, c_new) in ok.iter().zip(nk.iter()) {
                    if matches!(c_old, Html::HElement(..)) {
                        diff_node(c_old, c_new, out);
                    }
                }
            } else {
                // Structural mismatch — replace the whole inner HTML.
                p.html = Some(render_children(nk));
                out.push(p);
            }
        }
        // Text ↔ text handled by the parent's diff_text_children; nothing to do here.
        // Any other mismatch is handled at the parent level via html replace.
        _ => {}
    }
}

/// Emit a `SetText` patch when the sole child is a text node that changed.
fn diff_text_children<M>(id: &str, ok: &[Html<M>], nk: &[Html<M>], out: &mut Vec<Patch>) {
    if let ([Html::HText(o)], [Html::HText(n)]) = (ok, nk) {
        if o != n {
            let mut p = Patch::for_id(id);
            p.text = Some(n.clone());
            out.push(p);
        }
    }
}

/// True when both child lists have the same length and the same per-position
/// node kinds (element vs text vs raw) with matching tag names on elements.
fn same_child_shape<M>(a: &[Html<M>], b: &[Html<M>]) -> bool {
    a.len() == b.len()
        && a.iter().zip(b).all(|(x, y)| match (x, y) {
            (Html::HElement(t1, _, _), Html::HElement(t2, _, _)) => t1 == t2,
            (Html::HText(_), Html::HText(_)) => true,
            (Html::HRaw(_), Html::HRaw(_)) => true,
            _ => false,
        })
}

/// Compute the attribute delta between `old` and `new` attribute lists.
/// Keys changed or added → new value. Keys removed → empty string (Go convention).
/// `sky-id` is excluded (never patched as an attribute).
fn diff_attrs<M>(old: &[Attribute<M>], new: &[Attribute<M>], p: &mut Patch) {
    let collect = |xs: &[Attribute<M>]| -> HashMap<String, String> {
        let mut m = HashMap::new();
        for a in xs {
            match a {
                Attribute::Attr(k, v) if k != "sky-id" => {
                    m.insert(k.clone(), v.clone());
                }
                Attribute::BoolAttr(k, true) => {
                    m.insert(k.clone(), String::new());
                }
                _ => {}
            }
        }
        m
    };
    let (om, nm) = (collect(old), collect(new));
    for (k, v) in &nm {
        if om.get(k) != Some(v) {
            p.attrs.insert(k.clone(), v.clone());
        }
    }
    for k in om.keys() {
        if !nm.contains_key(k) {
            // Signal removal with empty string (Go convention).
            p.attrs.insert(k.clone(), String::new());
        }
    }
}

fn render_children<M>(kids: &[Html<M>]) -> String {
    let mut s = String::new();
    for c in kids {
        s.push_str(&render_html(c));
    }
    s
}

// ─── tests ────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::sky_runtime::live::html::*;

    fn ids(h: &mut Html<()>) {
        assign_sky_ids(h, "r");
    }

    #[test]
    fn diff_text_change() {
        let mut a: Html<()> =
            Html::HElement("p".into(), vec![], vec![Html::HText("1".into())]);
        let mut b: Html<()> =
            Html::HElement("p".into(), vec![], vec![Html::HText("2".into())]);
        ids(&mut a);
        ids(&mut b);
        let p = diff(&a, &b);
        assert_eq!(p.len(), 1);
        assert_eq!(p[0].id, "r");
        assert_eq!(p[0].text.as_deref(), Some("2"));
    }

    #[test]
    fn diff_attr_set_and_remove() {
        let mut a: Html<()> = Html::HElement(
            "div".into(),
            vec![Attribute::Attr("class".into(), "x".into())],
            vec![],
        );
        let mut b: Html<()> = Html::HElement(
            "div".into(),
            vec![
                Attribute::Attr("class".into(), "y".into()),
                Attribute::Attr("title".into(), "t".into()),
            ],
            vec![],
        );
        ids(&mut a);
        ids(&mut b);
        let p = diff(&a, &b);
        assert_eq!(p.len(), 1);
        let attrs = &p[0].attrs;
        assert_eq!(attrs.get("class").map(String::as_str), Some("y"));
        assert_eq!(attrs.get("title").map(String::as_str), Some("t"));
    }

    #[test]
    fn diff_identical_is_empty() {
        let mut a: Html<()> =
            Html::HElement("p".into(), vec![], vec![Html::HText("1".into())]);
        let mut b = a.clone();
        ids(&mut a);
        ids(&mut b);
        assert!(diff(&a, &b).is_empty());
    }
}
