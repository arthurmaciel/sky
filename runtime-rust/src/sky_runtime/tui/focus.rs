//! Sky.Tui input / focus state — the runtime-managed editor model.
//!
//! Port of Go's `tui_ui.go` inputRegistry / focusable / tuiEditInput. The Rust
//! version is cleaner than Go's reflection-based `eventPair` extraction: events
//! are the concrete `html::Event<M>` (`OnString("input", fn(String)->M)` /
//! `OnMsg("click", M)`), so dispatching a Msg is just applying the typed handler.
//!
//! Focus state (which element is focused, the per-input edit buffer + cursor) is
//! hidden from user code: the renderer discovers focusables in tab order during
//! the walk, the registry persists buffers across renders, and the loop
//! intercepts navigation/editing keys before the user's `onKey`.
//!
//! No panic vectors: rune-indexed edits via `.get`/iterators + saturating
//! arithmetic; nothing indexes or unwraps.

use super::super::html::{Attribute as HtmlAttribute, Event};
use std::collections::HashMap;

/// Per-input editor state, keyed by focus (tab-order) index in the registry.
#[derive(Default, Clone)]
pub struct InputState {
    pub buffer: String,
    /// Cursor position as a rune index into `buffer` (0..=rune_count).
    pub cursor: usize,
    /// The `value` attribute at last sync — lets the renderer detect a
    /// model-driven reset (e.g. `model.draft = ""`) and re-seed the buffer.
    pub last_value: String,
}

/// Edit buffers persisted across renders, keyed by tab-order focus index.
#[derive(Default)]
pub struct InputRegistry {
    inputs: HashMap<usize, InputState>,
}

impl InputRegistry {
    pub fn new() -> InputRegistry {
        InputRegistry::default()
    }
    pub fn get(&mut self, idx: usize) -> &mut InputState {
        self.inputs.entry(idx).or_default()
    }
    /// Sync the buffer from the rendered `value` attribute when the model changed
    /// it out-from-under the editor (Go parity: `box.valueAttr != st.lastValueAttr`).
    pub fn sync_value(&mut self, idx: usize, value: &str) {
        let st = self.inputs.entry(idx).or_default();
        if value != st.last_value {
            st.buffer = value.to_string();
            st.cursor = st.buffer.chars().count();
            st.last_value = value.to_string();
        }
    }
}

/// A focusable element discovered during the render walk, in tab order.
pub struct Focusable<M> {
    pub events: Vec<Event<M>>,
    pub is_input: bool,
    pub input_type: String,
    /// The element's `value` attribute (initial buffer / checkbox-radio state).
    pub value: String,
    pub placeholder: String,
    /// Top row of the element in the full (pre-scroll) frame — for scroll-into-view.
    pub line: usize,
    pub height: usize,
}

impl<M> Focusable<M> {
    pub fn is_checkbox_or_radio(&self) -> bool {
        self.is_input && (self.input_type == "checkbox" || self.input_type == "radio")
    }
}

/// Collect the `Event<M>`s carried by an attribute list (the `AttrEvent` →
/// `html::Attribute::EventAttr` payloads).
pub fn collect_events<M: Clone>(
    attrs: &[super::super::ui::Attribute<M>],
) -> Vec<Event<M>> {
    let mut out = Vec::new();
    for a in attrs {
        if let super::super::ui::Attribute::AttrEvent(HtmlAttribute::EventAttr(ev)) = a {
            out.push(ev.clone());
        }
    }
    out
}

/// Find a named event among a focusable's events.
fn event_named<M>(events: &[Event<M>], name: &str) -> Option<usize> {
    events.iter().position(|e| e.name() == name)
}

/// Apply an `input`/`change` (`String -> M`) handler to the current buffer.
pub fn extract_input_msg<M: Clone>(events: &[Event<M>], name: &str, buffer: &str) -> Option<M> {
    let i = event_named(events, name)?;
    match events.get(i)? {
        Event::OnString(_, f) => Some(f(buffer.to_string())),
        _ => None,
    }
}

/// Pull the Msg from a `click` (`OnMsg`) handler.
pub fn extract_click_msg<M: Clone>(events: &[Event<M>]) -> Option<M> {
    let i = event_named(events, "click")?;
    match events.get(i)? {
        Event::OnMsg(_, m) => Some(m.clone()),
        _ => None,
    }
}

/// Clamp a focus index into `[0, n)` (0 when there are no focusables).
pub fn clamp_focus(idx: usize, n: usize) -> usize {
    if n == 0 {
        0
    } else {
        idx.min(n - 1)
    }
}

/// Adjust the vertical scroll so the focused element stays on screen, preserving
/// the position when it's already visible (Go's `ensureFocusVisible`).
pub fn ensure_focus_visible<M>(
    focusables: &[Focusable<M>],
    idx: usize,
    scroll_y: usize,
    rows: usize,
    content_h: usize,
) -> usize {
    let max_scroll = content_h.saturating_sub(rows);
    let f = match focusables.get(idx) {
        Some(f) => f,
        None => return scroll_y.min(max_scroll),
    };
    let top = f.line;
    let bottom = f.line + f.height.saturating_sub(1);
    let mut s = scroll_y;
    if top < s {
        s = top;
    } else if bottom >= s + rows {
        s = (bottom + 1).saturating_sub(rows);
    }
    s.min(max_scroll)
}

/// Edit a single-line input buffer in response to a decoded key. Returns whether
/// the buffer/cursor changed (so the loop re-renders). `Enter` dispatch is handled
/// by the caller (it needs the focusable's `change`/`click` events). Multiline
/// cursor-up/down + word jumps are a follow-on; this covers char / space /
/// backspace / delete / left / right / home / end.
pub fn edit_input(st: &mut InputState, kind: &str, value: &str) -> bool {
    let runes: Vec<char> = st.buffer.chars().collect();
    let n = runes.len();
    st.cursor = st.cursor.min(n);
    match kind {
        "char" => {
            let ins: Vec<char> = value.chars().collect();
            let mut next: Vec<char> = Vec::with_capacity(n + ins.len());
            next.extend_from_slice(runes.get(..st.cursor).unwrap_or(&[]));
            next.extend_from_slice(&ins);
            next.extend_from_slice(runes.get(st.cursor..).unwrap_or(&[]));
            st.buffer = next.into_iter().collect();
            st.cursor += ins.len();
            true
        }
        "space" => {
            let mut next: Vec<char> = Vec::with_capacity(n + 1);
            next.extend_from_slice(runes.get(..st.cursor).unwrap_or(&[]));
            next.push(' ');
            next.extend_from_slice(runes.get(st.cursor..).unwrap_or(&[]));
            st.buffer = next.into_iter().collect();
            st.cursor += 1;
            true
        }
        "backspace" => {
            if st.cursor > 0 {
                let mut next: Vec<char> = Vec::with_capacity(n.saturating_sub(1));
                next.extend_from_slice(runes.get(..st.cursor - 1).unwrap_or(&[]));
                next.extend_from_slice(runes.get(st.cursor..).unwrap_or(&[]));
                st.buffer = next.into_iter().collect();
                st.cursor -= 1;
                true
            } else {
                false
            }
        }
        "delete" => {
            if st.cursor < n {
                let mut next: Vec<char> = Vec::with_capacity(n.saturating_sub(1));
                next.extend_from_slice(runes.get(..st.cursor).unwrap_or(&[]));
                next.extend_from_slice(runes.get(st.cursor + 1..).unwrap_or(&[]));
                st.buffer = next.into_iter().collect();
                true
            } else {
                false
            }
        }
        "left" => {
            if st.cursor > 0 {
                st.cursor -= 1;
                true
            } else {
                false
            }
        }
        "right" => {
            if st.cursor < n {
                st.cursor += 1;
                true
            } else {
                false
            }
        }
        "home" => {
            let moved = st.cursor != 0;
            st.cursor = 0;
            moved
        }
        "end" => {
            let moved = st.cursor != n;
            st.cursor = n;
            moved
        }
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn st(s: &str, cur: usize) -> InputState {
        InputState { buffer: s.into(), cursor: cur, last_value: s.into() }
    }

    #[test]
    fn typing_inserts_at_cursor() {
        let mut s = st("ac", 1);
        assert!(edit_input(&mut s, "char", "b"));
        assert_eq!(s.buffer, "abc");
        assert_eq!(s.cursor, 2);
    }

    #[test]
    fn backspace_at_start_noop() {
        let mut s = st("x", 0);
        assert!(!edit_input(&mut s, "backspace", ""));
        assert_eq!(s.buffer, "x");
    }

    #[test]
    fn backspace_deletes_left() {
        let mut s = st("ab", 2);
        assert!(edit_input(&mut s, "backspace", ""));
        assert_eq!(s.buffer, "a");
        assert_eq!(s.cursor, 1);
    }

    #[test]
    fn home_end_move_cursor() {
        let mut s = st("hello", 2);
        assert!(edit_input(&mut s, "end", ""));
        assert_eq!(s.cursor, 5);
        assert!(edit_input(&mut s, "home", ""));
        assert_eq!(s.cursor, 0);
    }

    #[test]
    fn sync_value_reseeds_on_model_reset() {
        let mut reg = InputRegistry::new();
        let s = reg.get(0);
        s.buffer = "typed".into();
        s.last_value = "typed".into();
        // model drove the value to "" — buffer must follow.
        reg.sync_value(0, "");
        assert_eq!(reg.get(0).buffer, "");
    }

    #[test]
    fn extract_input_applies_handler() {
        #[derive(Clone, PartialEq, Debug)]
        enum M {
            Got(String),
        }
        let events = vec![Event::OnString("input".into(), |s| M::Got(s))];
        assert_eq!(extract_input_msg(&events, "input", "hi"), Some(M::Got("hi".into())));
    }

    #[test]
    fn extract_click_returns_msg() {
        #[derive(Clone, PartialEq, Debug)]
        enum M {
            Clicked,
        }
        let events: Vec<Event<M>> = vec![Event::OnMsg("click".into(), M::Clicked)];
        assert_eq!(extract_click_msg(&events), Some(M::Clicked));
    }
}
