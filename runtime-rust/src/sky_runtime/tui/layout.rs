//! Element → ANSI frame — the structured Sky.Tui renderer + focus/input model.
//!
//! Walks the shared `sky_runtime::ui::Element` tree (the SAME tree Sky.Live
//! renders to HTML) and lays it out to terminal cells by reading the TYPED
//! attributes directly — never CSS. Mirrors Go's `tui_ui.go`. Recognises the
//! `Std.Ui.Input.*` widgets (`TaggedNode "input"/"textarea"/"button"` carrying
//! `AttrAttribute "type"/"value"/"placeholder"` + `AttrEvent`), collects them as
//! focusables in tab order, renders the focused one with a buffer + cursor, and
//! reports their positions for scroll-into-view.
//!
//! Logical-pixel canvas (Go parity): a design surface (default 1280×720) maps to
//! the live terminal cell grid via `pxPerCell`.
//!
//! Scope: column / row / el / text / button + colour + spacing + padding + bold;
//! text/password/checkbox/radio/slider inputs; Tab focus; scroll-into-view.
//! Follow-on: mouse hit-testing, multiline cursor up/down, word-jumps, precise
//! slider value, Length(Fill/Min/Max). No panic vectors.

use super::super::ui::{Attribute, Color, Element};
use super::cell::sanitize_rune;
use super::focus::{Focusable, InputRegistry};
use unicode_width::UnicodeWidthStr;

const CANVAS_W: usize = 1280;
const CANVAS_H: usize = 720;

#[derive(Clone, Copy)]
struct Canvas {
    px_per_cell_x: f64,
    px_per_cell_y: f64,
}
impl Canvas {
    fn new(cols: usize, rows: usize) -> Canvas {
        Canvas {
            px_per_cell_x: (CANVAS_W as f64 / cols.max(1) as f64).max(1.0),
            px_per_cell_y: (CANVAS_H as f64 / rows.max(1) as f64).max(1.0),
        }
    }
    fn cells_x(self, px: i64) -> usize {
        if px <= 0 {
            return 0;
        }
        ((px as f64 / self.px_per_cell_x).round() as i64).max(1) as usize
    }
    fn cells_y(self, px: i64) -> usize {
        if px <= 0 {
            return 0;
        }
        ((px as f64 / self.px_per_cell_y).round() as i64).max(1) as usize
    }
}

#[derive(Clone, Copy, Default)]
struct Style {
    fg: Option<(u8, u8, u8)>,
    bg: Option<(u8, u8, u8)>,
    bold: bool,
    reverse: bool,
}

#[derive(Clone, Copy, PartialEq)]
enum Dir {
    Column,
    Row,
}

struct Walked {
    dir: Dir,
    spacing_px: i64,
    pad_top: i64,
    pad_right: i64,
    pad_bottom: i64,
    pad_left: i64,
    style: Style,
}

#[derive(Clone)]
struct Run {
    text: String,
    style: Style,
}
impl Run {
    fn width(&self) -> usize {
        UnicodeWidthStr::width(self.text.as_str())
    }
}

#[derive(Clone, Default)]
struct Block {
    lines: Vec<Vec<Run>>,
}
impl Block {
    fn width(&self) -> usize {
        self.lines
            .iter()
            .map(|l| l.iter().map(Run::width).sum::<usize>())
            .max()
            .unwrap_or(0)
    }
    fn height(&self) -> usize {
        self.lines.len()
    }
    fn single(text: String, style: Style) -> Block {
        Block { lines: vec![vec![Run { text, style }]] }
    }
    fn pad_to_width(&mut self, w: usize, bg: Option<(u8, u8, u8)>) {
        for line in &mut self.lines {
            let lw: usize = line.iter().map(Run::width).sum();
            if lw < w {
                line.push(Run {
                    text: " ".repeat(w.saturating_sub(lw)),
                    style: Style { bg, ..Style::default() },
                });
            }
        }
    }
}

/// A rendered subtree plus the focusables it produced, each as
/// `(focusable index, line, col, width, height)` relative to this block's
/// top-left — composition shifts line/col to absolute frame coordinates.
struct Rendered {
    block: Block,
    hits: Vec<(usize, usize, usize, usize, usize)>,
}

/// Render-time context threaded through the walk.
struct Ctx<'a, M> {
    canvas: Canvas,
    focus_idx: usize,
    focusables: Vec<Focusable<M>>,
    inputs: &'a mut InputRegistry,
}

fn color_of(c: &Color) -> (u8, u8, u8) {
    let Color::Rgba(r, g, b, _) = c;
    ((*r & 0xff) as u8, (*g & 0xff) as u8, (*b & 0xff) as u8)
}

fn attr_str<'a, M>(attrs: &'a [Attribute<M>], key: &str) -> Option<&'a str> {
    attrs.iter().find_map(|a| match a {
        Attribute::AttrAttribute(k, v) if k == key => Some(v.as_str()),
        _ => None,
    })
}

fn walk_attrs<M>(attrs: &[Attribute<M>], inherited: Style) -> Walked {
    let mut w = Walked {
        dir: Dir::Column,
        spacing_px: 0,
        pad_top: 0,
        pad_right: 0,
        pad_bottom: 0,
        pad_left: 0,
        style: inherited,
    };
    for a in attrs {
        match a {
            Attribute::AttrStyle(k, _) if k == "__row" => w.dir = Dir::Row,
            Attribute::AttrStyle(k, _) if k == "__col" => w.dir = Dir::Column,
            Attribute::AttrSpacing(n) => w.spacing_px = *n,
            Attribute::AttrPadding(t, r, b, l) => {
                w.pad_top = *t;
                w.pad_right = *r;
                w.pad_bottom = *b;
                w.pad_left = *l;
            }
            Attribute::AttrFontColor(c) => w.style.fg = Some(color_of(c)),
            Attribute::AttrBgColor(c) => w.style.bg = Some(color_of(c)),
            Attribute::AttrFontWeight(n) if *n >= 600 => w.style.bold = true,
            _ => {}
        }
    }
    w
}

fn vstack(children: Vec<Rendered>, gap: usize) -> Rendered {
    let mut block = Block::default();
    let mut hits = Vec::new();
    let mut line0 = 0usize;
    for (i, r) in children.into_iter().enumerate() {
        if i > 0 {
            for _ in 0..gap {
                block.lines.push(Vec::new());
            }
            line0 += gap;
        }
        for (idx, l, c, w, h) in r.hits {
            hits.push((idx, line0 + l, c, w, h)); // stacked vertically — col unchanged
        }
        let h = r.block.lines.len();
        block.lines.extend(r.block.lines);
        line0 += h;
    }
    Rendered { block, hits }
}

fn hstack(children: Vec<Rendered>, gap: usize) -> Rendered {
    let height = children.iter().map(|r| r.block.height()).max().unwrap_or(0);
    let mut block = Block { lines: vec![Vec::new(); height] };
    let mut hits = Vec::new();
    let mut col0 = 0usize;
    for (bi, r) in children.iter().enumerate() {
        let bw = r.block.width();
        if bi > 0 {
            col0 += gap;
        }
        for (idx, l, c, w, h) in &r.hits {
            hits.push((*idx, *l, col0 + *c, *w, *h)); // side by side — shift col
        }
        col0 += bw;
        for row in 0..height {
            if let Some(target) = block.lines.get_mut(row) {
                if bi > 0 && gap > 0 {
                    target.push(Run { text: " ".repeat(gap), style: Style::default() });
                }
                match r.block.lines.get(row) {
                    Some(line) => {
                        let mut lw = 0;
                        for run in line {
                            lw += run.width();
                            target.push(run.clone());
                        }
                        if lw < bw {
                            target.push(Run {
                                text: " ".repeat(bw.saturating_sub(lw)),
                                style: Style::default(),
                            });
                        }
                    }
                    None => target.push(Run { text: " ".repeat(bw), style: Style::default() }),
                }
            }
        }
    }
    Rendered { block, hits }
}

fn apply_padding(inner: Rendered, w: &Walked, canvas: Canvas, self_style: Style) -> Rendered {
    let top = canvas.cells_y(w.pad_top);
    let bottom = canvas.cells_y(w.pad_bottom);
    let left = canvas.cells_x(w.pad_left);
    let right = canvas.cells_x(w.pad_right);
    let inner_w = inner.block.width();
    let total_w = inner_w + left + right;
    let pad_run = |n: usize| Run { text: " ".repeat(n), style: self_style };

    let mut block = Block::default();
    for _ in 0..top {
        block.lines.push(vec![pad_run(total_w)]);
    }
    for line in inner.block.lines {
        let mut row = Vec::new();
        if left > 0 {
            row.push(pad_run(left));
        }
        let lw: usize = line.iter().map(Run::width).sum();
        row.extend(line);
        let tail = right + inner_w.saturating_sub(lw);
        if tail > 0 {
            row.push(pad_run(tail));
        }
        block.lines.push(row);
    }
    for _ in 0..bottom {
        block.lines.push(vec![pad_run(total_w)]);
    }
    let hits = inner.hits.into_iter().map(|(idx, l, c, w, h)| (idx, l + top, c + left, w, h)).collect();
    Rendered { block, hits }
}

/// Render an input widget (text/password/checkbox/radio/range) into a styled
/// single-line block, registering it as a focusable.
fn render_input<M: Clone>(
    attrs: &[Attribute<M>],
    style: Style,
    ctx: &mut Ctx<M>,
) -> Rendered {
    let input_type = attr_str(attrs, "type").unwrap_or("text").to_string();
    let value = attr_str(attrs, "value").unwrap_or("").to_string();
    let placeholder = attr_str(attrs, "placeholder").unwrap_or("").to_string();
    let checked = attr_str(attrs, "checked").is_some() || value == "true";
    let events = super::focus::collect_events(attrs);

    let idx = ctx.focusables.len();
    let focused = idx == ctx.focus_idx;

    let cell = match input_type.as_str() {
        "checkbox" => {
            let g = if checked { "☑" } else { "☐" };
            Run { text: g.to_string(), style: Style { reverse: focused, ..style } }
        }
        "radio" => {
            let g = if checked { "●" } else { "○" };
            Run { text: g.to_string(), style: Style { reverse: focused, ..style } }
        }
        "range" => {
            // Track with the thumb positioned at value within [min, max].
            let min: f64 = attr_str(attrs, "min").and_then(|s| s.trim().parse().ok()).unwrap_or(0.0);
            let max: f64 = attr_str(attrs, "max").and_then(|s| s.trim().parse().ok()).unwrap_or(100.0);
            let val: f64 = value.trim().parse().unwrap_or(min);
            let width = 12usize;
            let frac = if max > min { ((val - min) / (max - min)).clamp(0.0, 1.0) } else { 0.0 };
            let thumb = ((frac * (width - 1) as f64).round() as usize).min(width - 1);
            let track: String = (0..width)
                .map(|i| {
                    if i == 0 {
                        '├'
                    } else if i == width - 1 {
                        '┤'
                    } else if i == thumb {
                        '●'
                    } else {
                        '─'
                    }
                })
                .collect();
            Run { text: track, style: Style { reverse: focused, ..style } }
        }
        _ => {
            // Text-like input: keep the edit buffer in sync with the model's
            // value, then render buffer (or placeholder) + a cursor when focused.
            ctx.inputs.sync_value(idx, &value);
            let st = ctx.inputs.get(idx);
            let masked = input_type == "password";
            let shown: String = if st.buffer.is_empty() && !focused {
                placeholder.clone()
            } else if masked {
                "•".repeat(st.buffer.chars().count())
            } else {
                st.buffer.clone()
            };
            let mut text = if shown.is_empty() { "▁▁▁▁".to_string() } else { shown };
            if focused {
                text.push('▏'); // cursor marker at end (column tracking is a follow-on)
            }
            Run { text, style: Style { reverse: focused && input_type != "password", ..style } }
        }
    };

    let block = Block { lines: vec![vec![cell]] };
    let width = block.width();
    ctx.focusables.push(Focusable {
        events,
        is_input: true,
        input_type,
        value,
        placeholder,
        line: 0,
        col: 0,
        width,
        height: 1,
    });
    Rendered { block, hits: vec![(idx, 0, 0, width, 1)] }
}

/// Render one Element node, cascading text style + collecting focusables.
fn render_node<M: Clone>(node: &Element<M>, inherited: Style, ctx: &mut Ctx<M>) -> Rendered {
    match node {
        Element::Empty => Rendered { block: Block::default(), hits: vec![] },
        Element::Text(t) => {
            let clean: String = t.chars().map(sanitize_rune).collect();
            Rendered { block: Block::single(clean, inherited), hits: vec![] }
        }
        Element::Raw(_) => Rendered { block: Block::default(), hits: vec![] },
        Element::TaggedNode(tag, _desc, attrs, kids) if tag == "input" => {
            render_input(attrs, inherited, ctx)
        }
        Element::TaggedNode(tag, _desc, attrs, kids) if tag == "button" => {
            // A button is focusable; render its label (kids), highlighted when
            // focused. Click is dispatched from its events in the loop.
            let events = super::focus::collect_events(attrs);
            let idx = ctx.focusables.len();
            let focused = idx == ctx.focus_idx;
            ctx.focusables.push(Focusable {
                events,
                is_input: false,
                input_type: String::new(),
                value: String::new(),
                placeholder: String::new(),
                line: 0,
                col: 0,
                width: 0,
                height: 1,
            });
            let w = walk_attrs(attrs, inherited);
            let label_style = Style { reverse: focused, ..w.style };
            let child_blocks: Vec<Rendered> =
                kids.iter().map(|k| render_node(k, label_style, ctx)).collect();
            let inner = match w.dir {
                Dir::Column => vstack(child_blocks, 0),
                Dir::Row => hstack(child_blocks, ctx.canvas.cells_x(w.spacing_px)),
            };
            let mut padded = apply_padding(inner, &w, ctx.canvas, label_style);
            // Force the focus reverse over the whole label row(s).
            if focused {
                for line in &mut padded.block.lines {
                    for run in line {
                        run.style.reverse = true;
                    }
                }
            }
            let h = padded.block.height().max(1);
            let bw = padded.block.width();
            // Record this button's hit (line/col resolved by the caller's compose).
            padded.hits.insert(0, (idx, 0, 0, bw, h));
            padded
        }
        Element::Node(_d, attrs, kids) | Element::TaggedNode(_, _d, attrs, kids) => {
            let w = walk_attrs(attrs, inherited);
            let children: Vec<Rendered> = kids
                .iter()
                .map(|k| render_node(k, w.style, ctx))
                .filter(|r| r.block.height() > 0)
                .collect();
            let mut inner = if children.is_empty() {
                Rendered { block: Block { lines: vec![Vec::new()] }, hits: vec![] }
            } else {
                match w.dir {
                    Dir::Column => vstack(children, ctx.canvas.cells_y(w.spacing_px)),
                    Dir::Row => hstack(children, ctx.canvas.cells_x(w.spacing_px)),
                }
            };
            let inner_w = inner.block.width();
            inner.block.pad_to_width(inner_w, w.style.bg);
            apply_padding(inner, &w, ctx.canvas, w.style)
        }
    }
}

const SGR_RESET: &str = "\x1b[0m";

fn sgr(style: Style) -> String {
    let mut codes: Vec<String> = Vec::new();
    if style.bold {
        codes.push("1".to_string());
    }
    if style.reverse {
        codes.push("7".to_string());
    }
    if let Some((r, g, b)) = style.fg {
        codes.push(format!("38;2;{r};{g};{b}"));
    }
    if let Some((r, g, b)) = style.bg {
        codes.push(format!("48;2;{r};{g};{b}"));
    }
    if codes.is_empty() {
        String::new()
    } else {
        format!("\x1b[{}m", codes.join(";"))
    }
}

fn emit_block(block: &Block, cols: usize, scroll_y: usize, rows: usize) -> String {
    let mut out = String::new();
    for line in block.lines.iter().skip(scroll_y).take(rows) {
        let mut col = 0usize;
        for run in line {
            if col >= cols {
                break;
            }
            let mut text = String::new();
            let mut w = 0usize;
            for ch in run.text.chars() {
                let cw = UnicodeWidthStr::width(ch.to_string().as_str());
                if col + w + cw > cols {
                    break;
                }
                text.push(ch);
                w += cw;
            }
            let esc = sgr(run.style);
            if esc.is_empty() {
                out.push_str(&text);
            } else {
                out.push_str(&esc);
                out.push_str(&text);
                out.push_str(SGR_RESET);
            }
            col += w;
        }
        out.push_str("\r\n");
    }
    out
}

/// Render the view, returning the ANSI frame (scrolled to `scroll_y`), the
/// discovered focusables (with absolute line positions), and the full content
/// height. The loop uses the focusables to dispatch input/click Msgs and to keep
/// the focused element on screen.
pub fn render_with_focus<M: Clone>(
    view: &Element<M>,
    cols: usize,
    rows: usize,
    focus_idx: usize,
    inputs: &mut InputRegistry,
    scroll_y: usize,
) -> (String, Vec<Focusable<M>>, usize) {
    let canvas = Canvas::new(cols, rows);
    let mut ctx = Ctx { canvas, focus_idx, focusables: Vec::new(), inputs };
    let rendered = render_node(view, Style::default(), &mut ctx);
    let content_h = rendered.block.height();
    // Write back absolute positions onto the focusables (for scroll + hit-test).
    for (idx, line, col, width, h) in rendered.hits {
        if let Some(f) = ctx.focusables.get_mut(idx) {
            f.line = line;
            f.col = col;
            f.width = width;
            f.height = h;
        }
    }
    let frame = emit_block(&rendered.block, cols, scroll_y, rows);
    (frame, ctx.focusables, content_h)
}

/// `Std.Ui` Element → ANSI frame, no focus (used by the layout tests + any
/// caller that doesn't need the input model).
pub fn element_to_cells<M: Clone>(view: &Element<M>, cols: usize, rows: usize) -> String {
    let mut inputs = InputRegistry::new();
    render_with_focus(view, cols, rows, usize::MAX, &mut inputs, 0).0
}

#[cfg(test)]
mod tests {
    use super::super::super::ui::Description;
    use super::*;

    fn rgb(r: i64, g: i64, b: i64) -> Color {
        Color::Rgba(r, g, b, 1.0)
    }
    fn node<M>(attrs: Vec<Attribute<M>>, kids: Vec<Element<M>>) -> Element<M> {
        Element::Node(Description::NoDescription, attrs, kids)
    }
    fn input<M>(ty: &str, value: &str) -> Element<M> {
        Element::TaggedNode(
            "input".into(),
            Description::NoDescription,
            vec![
                Attribute::AttrAttribute("type".into(), ty.into()),
                Attribute::AttrAttribute("value".into(), value.into()),
            ],
            vec![],
        )
    }

    #[test]
    fn text_with_fg() {
        let t: Element<()> =
            node(vec![Attribute::AttrFontColor(rgb(255, 0, 0))], vec![Element::Text("hi".into())]);
        let frame = element_to_cells(&t, 80, 24);
        assert!(frame.contains("38;2;255;0;0"));
        assert!(frame.contains("hi"));
    }

    #[test]
    fn column_stacks_vertically() {
        let t: Element<()> = node(
            vec![Attribute::AttrSpacing(16)],
            vec![
                node(vec![], vec![Element::Text("a".into())]),
                node(vec![], vec![Element::Text("b".into())]),
            ],
        );
        let frame = element_to_cells(&t, 80, 24);
        assert!(frame.find('a').unwrap_or(99) < frame.find('b').unwrap_or(0));
    }

    #[test]
    fn checkbox_glyphs_track_checked() {
        let unchecked: Element<()> = input("checkbox", "false");
        assert!(element_to_cells(&unchecked, 80, 24).contains('☐'));
        let checked: Element<()> = input("checkbox", "true");
        assert!(element_to_cells(&checked, 80, 24).contains('☑'));
    }

    #[test]
    fn focusables_collected_in_order() {
        let t: Element<()> = node(
            vec![],
            vec![input("text", "a"), input("checkbox", "false"), input("radio", "x")],
        );
        let mut reg = InputRegistry::new();
        let (_f, focusables, _h) = render_with_focus(&t, 80, 24, usize::MAX, &mut reg, 0);
        assert_eq!(focusables.len(), 3);
        assert_eq!(focusables[0].input_type, "text");
        assert_eq!(focusables[1].input_type, "checkbox");
    }

    #[test]
    fn focused_input_reverses() {
        let t: Element<()> = node(vec![], vec![input("text", "hi")]);
        let mut reg = InputRegistry::new();
        let (frame, _f, _h) = render_with_focus(&t, 80, 24, 0, &mut reg, 0);
        assert!(frame.contains("\x1b[7"), "focused input reverse-video: {frame:?}");
    }

    #[test]
    fn scroll_offsets_content() {
        let kids: Vec<Element<()>> =
            (0..40).map(|i| node(vec![], vec![Element::Text(format!("row{i}"))])).collect();
        let t: Element<()> = node(vec![], kids);
        let mut reg = InputRegistry::new();
        let (frame, _f, h) = render_with_focus(&t, 80, 10, usize::MAX, &mut reg, 20);
        assert!(h >= 40);
        assert!(frame.contains("row20"), "scrolled to row20: {frame:?}");
        assert!(!frame.contains("row0\r\n"), "row0 scrolled off");
    }
}
