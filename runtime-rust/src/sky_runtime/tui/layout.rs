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

use super::super::ui::{Attribute, Color, Element, Length};
use super::cell::sanitize_rune;
use super::focus::{Focusable, InputRegistry};
use unicode_width::{UnicodeWidthChar, UnicodeWidthStr};

const CANVAS_W: usize = 1280;
const CANVAS_H: usize = 720;

#[derive(Clone, Copy)]
struct Canvas {
    px_per_cell_x: f64,
    px_per_cell_y: f64,
    cols: usize,
    rows: usize,
}
impl Canvas {
    fn new(cols: usize, rows: usize) -> Canvas {
        Canvas {
            px_per_cell_x: (CANVAS_W as f64 / cols.max(1) as f64).max(1.0),
            px_per_cell_y: (CANVAS_H as f64 / rows.max(1) as f64).max(1.0),
            cols,
            rows,
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
    /// The raw `Ui.width` `Length`, if any. `None` (or `Content`) → content-sized.
    /// Resolved to cells lazily (avail_w + canvas are only known at render time).
    width: Option<Length>,
    style: Style,
}

/// The `Ui.width` `Length` on a node, if present.
fn width_length<M>(attrs: &[Attribute<M>]) -> Option<Length> {
    attrs.iter().find_map(|a| match a {
        Attribute::AttrWidth(l) => Some(l.clone()),
        _ => None,
    })
}

/// `(portion, min_cells, max_cells)` for a fill child (see `fill_spec`).
type FillSpec = (i64, Option<usize>, Option<usize>);

/// Distribution spec for a fill child: `Some((portion, min_cells, max_cells))`
/// when the length is `Fill` (possibly wrapped in `Min`/`Max`). Such a child is
/// sized by the parent ROW's fill-distribution pass, not by its own content.
fn fill_spec(l: &Length, canvas: Canvas) -> Option<FillSpec> {
    match l {
        Length::Fill(p) => Some(((*p).max(1), None, None)),
        Length::Min(n, inner) => fill_spec(inner, canvas)
            .map(|(p, mn, mx)| (p, Some(mn.unwrap_or(0).max(canvas.cells_x(*n))), mx)),
        Length::Max(n, inner) => fill_spec(inner, canvas).map(|(p, mn, mx)| {
            let cap = canvas.cells_x(*n);
            (p, mn, Some(mx.map_or(cap, |x| x.min(cap))))
        }),
        _ => None,
    }
}

/// Resolve a NON-fill width `Length` to explicit cells given the available width.
/// `None` → content-sized (the caller measures children). Mirrors Go's
/// `resolveLengthCells` on the x-axis, EXCEPT `Min`/`Max` bounds are correctly
/// converted px→cells (the Go path returns the raw px as cells — a latent bug;
/// the Tui surface is not byte-gated against Go, so Rust does the right thing).
fn resolve_fixed_w(l: &Length, available: usize, canvas: Canvas) -> Option<usize> {
    match l {
        Length::Px(n) => Some(canvas.cells_x(*n)),
        Length::Content => None,
        Length::Fill(_) => Some(available), // a direct ask claims all; the ROW pass overrides
        Length::Vw(p) => Some(canvas.cols.saturating_mul((*p).max(0) as usize) / 100),
        Length::Vh(p) => Some(canvas.rows.saturating_mul((*p).max(0) as usize) / 100),
        Length::Min(n, inner) => {
            let mn = canvas.cells_x(*n);
            Some(resolve_fixed_w(inner, available, canvas).map_or(mn, |c| c.max(mn)))
        }
        Length::Max(n, inner) => {
            let mx = canvas.cells_x(*n);
            Some(resolve_fixed_w(inner, available, canvas).map_or(available.min(mx), |c| c.min(mx)))
        }
    }
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
    /// Constrain every line to EXACTLY `w` display cells — pad shorter lines with
    /// `bg`-styled spaces, clip longer ones. For explicit `Ui.width (Ui.px n)`.
    fn set_width(&mut self, w: usize, bg: Option<(u8, u8, u8)>) {
        for line in &mut self.lines {
            let lw: usize = line.iter().map(Run::width).sum();
            if lw > w {
                // Clip runs to `w` cells.
                let mut kept: Vec<Run> = Vec::new();
                let mut used = 0usize;
                for run in line.iter() {
                    if used >= w {
                        break;
                    }
                    let rw = run.width();
                    if used + rw <= w {
                        kept.push(run.clone());
                        used += rw;
                    } else {
                        let mut text = String::new();
                        let mut tw = 0usize;
                        for ch in run.text.chars() {
                            let cw = UnicodeWidthChar::width(ch).unwrap_or(0);
                            if used + tw + cw > w {
                                break;
                            }
                            text.push(ch);
                            tw += cw;
                        }
                        used += tw;
                        kept.push(Run { text, style: run.style });
                        break;
                    }
                }
                // A clip landing on a wide-char boundary can leave the kept
                // width one cell short of `w`; pad the remainder with
                // `bg`-styled spaces so the box always fills exactly `w`.
                if used < w {
                    kept.push(Run {
                        text: " ".repeat(w - used),
                        style: Style { bg, ..Style::default() },
                    });
                }
                *line = kept;
            } else if lw < w {
                line.push(Run {
                    text: " ".repeat(w - lw),
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
        width: width_length(attrs),
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
    avail_w: usize,
    is_multiline: bool,
) -> Rendered {
    // A `<textarea>` carries no `type` attr; mark it "textarea" so the cursor
    // renders multiline and the loop inserts `\n` on Enter (vs submit on input).
    let input_type = if is_multiline {
        "textarea".to_string()
    } else {
        attr_str(attrs, "type").unwrap_or("text").to_string()
    };
    let value = attr_str(attrs, "value").unwrap_or("").to_string();
    let placeholder = attr_str(attrs, "placeholder").unwrap_or("").to_string();
    let checked = attr_str(attrs, "checked").is_some() || value == "true";
    let events = super::focus::collect_events(attrs);

    let idx = ctx.focusables.len();
    let focused = idx == ctx.focus_idx;

    let mut block: Block = match input_type.as_str() {
        "checkbox" => {
            let g = if checked { "☑" } else { "☐" };
            Block::single(g.to_string(), Style { reverse: focused, ..style })
        }
        "radio" => {
            let g = if checked { "●" } else { "○" };
            Block::single(g.to_string(), Style { reverse: focused, ..style })
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
            Block::single(track, Style { reverse: focused, ..style })
        }
        _ => {
            // Text-like input (incl. textarea): sync the edit buffer to the
            // model's value, then render it (or placeholder) with the cursor at
            // its real (line, col) — multiline when the buffer has newlines.
            ctx.inputs.sync_value(idx, &value);
            let st = ctx.inputs.get(idx);
            let masked = input_type == "password";
            let run_style = Style { reverse: focused && !masked, ..style };
            if masked {
                // Masked: hide content (and any newlines) on one line; the cursor
                // sits at the end (per-char column tracking is meaningless hidden).
                let mut s = "•".repeat(st.buffer.chars().count());
                if focused {
                    s.push('▏');
                }
                if s.is_empty() {
                    s = "▁▁▁▁".to_string();
                }
                Block::single(s, run_style)
            } else if st.buffer.is_empty() && !focused {
                let s = if placeholder.is_empty() { "▁▁▁▁".to_string() } else { placeholder.clone() };
                Block::single(s, run_style)
            } else {
                // Real buffer: split into visual lines, insert the cursor glyph at
                // the focused (line, col).
                let runes: Vec<char> = st.buffer.chars().collect();
                let cursor = st.cursor.min(runes.len());
                let (cur_line, cur_col) = cursor_line_col(&runes, cursor);
                let mut out: Vec<Vec<Run>> = Vec::new();
                for (li, seg) in split_buffer_lines(&runes).into_iter().enumerate() {
                    let mut chars = seg;
                    if focused && li == cur_line {
                        chars.insert(cur_col.min(chars.len()), '▏');
                    }
                    out.push(vec![Run { text: chars.into_iter().collect(), style: run_style }]);
                }
                if out.is_empty() {
                    out.push(vec![Run {
                        text: if focused { "▏".to_string() } else { "▁▁▁▁".to_string() },
                        style: run_style,
                    }]);
                }
                Block { lines: out }
            }
        }
    };
    // Honour `Ui.width` on a text-like field so it renders at a fixed/fill width
    // (the field background fills it). `Fill` expands to the parent's allocation.
    if input_type != "range" {
        if let Some(l) = width_length(attrs) {
            // Fill → the parent's allocation (avail_w); otherwise resolve to cells.
            let cells = if fill_spec(&l, ctx.canvas).is_some() {
                Some(avail_w)
            } else {
                resolve_fixed_w(&l, avail_w, ctx.canvas)
            };
            if let Some(c) = cells {
                block.set_width(c.max(1), style.bg);
            }
        }
    }
    let width = block.width();
    let height = block.height().max(1);
    ctx.focusables.push(Focusable {
        events,
        is_input: true,
        input_type,
        value,
        placeholder,
        line: 0,
        col: 0,
        width,
        height,
    });
    Rendered { block, hits: vec![(idx, 0, 0, width, height)] }
}

/// Map a flat char-cursor into `(line, col)` over a `'\n'`-separated buffer.
fn cursor_line_col(runes: &[char], cursor: usize) -> (usize, usize) {
    let mut line = 0usize;
    let mut col = 0usize;
    for c in runes.iter().take(cursor) {
        if *c == '\n' {
            line += 1;
            col = 0;
        } else {
            col += 1;
        }
    }
    (line, col)
}

/// Split a char buffer into visual lines on `'\n'` (always ≥ 1 line).
fn split_buffer_lines(runes: &[char]) -> Vec<Vec<char>> {
    let mut lines: Vec<Vec<char>> = vec![Vec::new()];
    for c in runes {
        if *c == '\n' {
            lines.push(Vec::new());
        } else if let Some(last) = lines.last_mut() {
            last.push(*c);
        }
    }
    lines
}

/// Render one Element node, cascading text style + collecting focusables.
/// `avail_w` is the cell width the parent allocated to this node (for `Fill`).
fn render_node<M: Clone>(
    node: &Element<M>,
    inherited: Style,
    ctx: &mut Ctx<M>,
    avail_w: usize,
) -> Rendered {
    match node {
        Element::Empty => Rendered { block: Block::default(), hits: vec![] },
        Element::Text(t) => {
            let clean: String = t.chars().map(sanitize_rune).collect();
            Rendered { block: Block::single(clean, inherited), hits: vec![] }
        }
        Element::Raw(_) => Rendered { block: Block::default(), hits: vec![] },
        Element::TaggedNode(tag, _desc, attrs, _kids) if tag == "input" || tag == "textarea" => {
            render_input(attrs, inherited, ctx, avail_w, tag == "textarea")
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
            let content_avail = node_content_avail(avail_w, &w, ctx.canvas);
            let label_style = Style { reverse: focused, ..w.style };
            let child_blocks: Vec<Rendered> =
                kids.iter().map(|k| render_node(k, label_style, ctx, content_avail)).collect();
            let mut inner = match w.dir {
                Dir::Column => vstack(child_blocks, 0),
                Dir::Row => hstack(child_blocks, ctx.canvas.cells_x(w.spacing_px)),
            };
            apply_self_width(&mut inner.block, &w, content_avail, ctx.canvas);
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
            let content_avail = node_content_avail(avail_w, &w, ctx.canvas);
            // Render children IN ORDER (preserves focusable push order = Tab order),
            // pairing each with its fill spec, then drop empty blocks.
            let mut specs: Vec<Option<FillSpec>> = Vec::new();
            let mut children: Vec<Rendered> = Vec::new();
            for k in kids.iter() {
                let r = render_node(k, w.style, ctx, content_avail);
                if r.block.height() > 0 {
                    specs.push(child_width_length(k).and_then(|l| fill_spec(&l, ctx.canvas)));
                    children.push(r);
                }
            }
            // In a ROW, fill children share the leftover width (column children
            // already span the full width). Post-pass: rewrite fill child widths.
            if w.dir == Dir::Row {
                distribute_row_fill(
                    &mut children,
                    &specs,
                    content_avail,
                    ctx.canvas.cells_x(w.spacing_px),
                );
            }
            let mut inner = if children.is_empty() {
                Rendered { block: Block { lines: vec![Vec::new()] }, hits: vec![] }
            } else {
                match w.dir {
                    Dir::Column => vstack(children, ctx.canvas.cells_y(w.spacing_px)),
                    Dir::Row => hstack(children, ctx.canvas.cells_x(w.spacing_px)),
                }
            };
            apply_self_width(&mut inner.block, &w, content_avail, ctx.canvas);
            apply_padding(inner, &w, ctx.canvas, w.style)
        }
    }
}

/// Content width available to a node's children = the node's allocation minus its
/// horizontal padding.
fn node_content_avail(avail_w: usize, w: &Walked, canvas: Canvas) -> usize {
    let pad = canvas.cells_x(w.pad_left) + canvas.cells_x(w.pad_right);
    let base = match &w.width {
        None => avail_w,
        Some(l) => {
            if let Some((_, mn, mx)) = fill_spec(l, canvas) {
                // fill → the parent-allocated width, clamped to its own min/max
                // (a ROW parent re-distributes the final width over this).
                let mut t = avail_w;
                if let Some(m) = mn {
                    t = t.max(m);
                }
                if let Some(m) = mx {
                    t = t.min(m);
                }
                t
            } else {
                // Px / Vw / Min / Max → resolved cells; Content → avail.
                resolve_fixed_w(l, avail_w, canvas).unwrap_or(avail_w)
            }
        }
    };
    base.saturating_sub(pad)
}

/// Constrain a node's inner block to its `Ui.width` directive. `Auto` keeps the
/// natural content width (byte-identical to the pre-Fill behaviour); `Fill`
/// expands to the content allocation; `Px` sets the exact cell width.
fn apply_self_width(block: &mut Block, w: &Walked, content_avail: usize, _canvas: Canvas) {
    // `content_avail` is already the node's resolved inner width (node_content_avail
    // applied Px/Vw/Min/Max/Fill). So a sized node takes content_avail; an Auto /
    // Content node keeps its natural content width. A fill child in a row has its
    // final width re-set by the parent's distribution pass (which overrides this).
    let sized = !matches!(w.width, None | Some(Length::Content));
    if sized {
        block.set_width(content_avail, w.style.bg);
    }
}

/// The `Ui.width` `Length` declared on a child element, if any.
fn child_width_length<M>(el: &Element<M>) -> Option<Length> {
    match el {
        Element::Node(_, attrs, _) | Element::TaggedNode(_, _, attrs, _) => width_length(attrs),
        _ => None,
    }
}

/// Fill-distribution pass for a ROW. `children[i]` aligns with `specs[i]`; a
/// `Some((portion, min, max))` spec marks a fill child. Non-fill children keep
/// their already-rendered width; the leftover (`content_avail` − non-fill widths
/// − gaps) is split among fill children by portion and clamped to each child's
/// min/max. Children are already rendered (focusables pushed), so this only
/// resizes the fill blocks — last fill child absorbs the rounding remainder.
fn distribute_row_fill(
    children: &mut [Rendered],
    specs: &[Option<FillSpec>],
    content_avail: usize,
    gap: usize,
) {
    let total_portion: i64 = specs.iter().filter_map(|s| s.map(|(p, _, _)| p)).sum();
    if total_portion <= 0 {
        return;
    }
    let n = children.len();
    let gaps = if n > 1 { (n - 1) * gap } else { 0 };
    let non_fill: usize = children
        .iter()
        .zip(specs)
        .filter(|(_, s)| s.is_none())
        .map(|(r, _)| r.block.width())
        .sum();
    let remaining = content_avail.saturating_sub(non_fill + gaps);
    let fill_count = specs.iter().filter(|s| s.is_some()).count();
    let mut used = 0usize;
    let mut done = 0usize;
    for (r, s) in children.iter_mut().zip(specs) {
        if let Some((p, mn, mx)) = s {
            done += 1;
            let share = if done == fill_count {
                remaining.saturating_sub(used)
            } else {
                remaining.saturating_mul(*p as usize) / total_portion as usize
            };
            used = used.saturating_add(share);
            let mut target = share;
            if let Some(m) = mn {
                target = target.max(*m);
            }
            if let Some(m) = mx {
                target = target.min(*m);
            }
            // Preserve the fill child's own bg when padding out to `target`.
            let bg = r
                .block
                .lines
                .first()
                .and_then(|l| l.last())
                .and_then(|run| run.style.bg);
            r.block.set_width(target.max(1), bg);
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
                let cw = UnicodeWidthChar::width(ch).unwrap_or(0);
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
    let rendered = render_node(view, Style::default(), &mut ctx, cols);
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
    fn fill_width_expands_to_avail() {
        let t: Element<()> = node(
            vec![Attribute::AttrWidth(Length::Fill(1)), Attribute::AttrBgColor(rgb(5, 6, 7))],
            vec![Element::Text("x".into())],
        );
        let frame = element_to_cells(&t, 20, 24);
        let first = frame.split("\r\n").next().unwrap_or("");
        let spaces = first.matches(' ').count();
        assert!(spaces >= 15, "fill expanded toward 20 cols: {first:?} ({spaces} spaces)");
    }

    #[test]
    fn explicit_px_width_pads_box() {
        // canvas px_per_cell_x = 1280/80 = 16 → 160px ≈ 10 cells.
        let t: Element<()> = node(
            vec![Attribute::AttrWidth(Length::Px(160)), Attribute::AttrBgColor(rgb(1, 2, 3))],
            vec![Element::Text("hi".into())],
        );
        let frame = element_to_cells(&t, 80, 24);
        let first = frame.split("\r\n").next().unwrap_or("");
        // The bg fill extends the 2-char text toward ~10 cells.
        let visible_spaces = first.matches(' ').count();
        assert!(visible_spaces >= 5, "px width padded with bg: {first:?}");
    }

    #[test]
    fn vw_width_resolves_to_viewport_fraction() {
        // Vw(50) on 80 cols → ~40 cells of bg.
        let t: Element<()> = node(
            vec![Attribute::AttrWidth(Length::Vw(50)), Attribute::AttrBgColor(rgb(9, 9, 9))],
            vec![Element::Text("x".into())],
        );
        let frame = element_to_cells(&t, 80, 24);
        let first = frame.split("\r\n").next().unwrap_or("");
        let spaces = first.matches(' ').count();
        assert!((30..=45).contains(&spaces), "Vw(50)≈40 cols: {first:?} ({spaces} spaces)");
    }

    #[test]
    fn min_width_floors_content() {
        // Min(160, Content): content "hi" (2 cells) floored to 160px ≈ 10 cells.
        let t: Element<()> = node(
            vec![
                Attribute::AttrWidth(Length::Min(160, Box::new(Length::Content))),
                Attribute::AttrBgColor(rgb(4, 4, 4)),
            ],
            vec![Element::Text("hi".into())],
        );
        let frame = element_to_cells(&t, 80, 24);
        let first = frame.split("\r\n").next().unwrap_or("");
        assert!(first.matches(' ').count() >= 5, "min floored padding: {first:?}");
    }

    #[test]
    fn max_width_caps_fill() {
        // Max(160, Fill): fill would claim 80 cols, capped to 160px ≈ 10 cells.
        let t: Element<()> = node(
            vec![
                Attribute::AttrWidth(Length::Max(160, Box::new(Length::Fill(1)))),
                Attribute::AttrBgColor(rgb(2, 2, 2)),
            ],
            vec![Element::Text("x".into())],
        );
        let frame = element_to_cells(&t, 80, 24);
        let first = frame.split("\r\n").next().unwrap_or("");
        let spaces = first.matches(' ').count();
        assert!((3..=15).contains(&spaces), "Max caps fill at ~10 cols: {first:?} ({spaces})");
    }

    #[test]
    fn row_fill_splits_width() {
        // A row of two equal-portion fill children each take ~half of 20 cols.
        let child = |c: Color| -> Element<()> {
            node(vec![Attribute::AttrWidth(Length::Fill(1)), Attribute::AttrBgColor(c)],
                 vec![Element::Text("x".into())])
        };
        let row: Element<()> = node(
            vec![Attribute::AttrStyle("__row".into(), String::new())],
            vec![child(rgb(10, 0, 0)), child(rgb(0, 10, 0))],
        );
        let frame = element_to_cells(&row, 20, 24);
        let first = frame.split("\r\n").next().unwrap_or("");
        // Both fills present; neither claimed the whole row (would overflow pre-fix).
        assert!(first.contains("48;2;10;0;0"), "left fill bg present: {first:?}");
        assert!(first.contains("48;2;0;10;0"), "right fill bg present: {first:?}");
    }

    #[test]
    fn textarea_renders_multiline_with_cursor() {
        let t: Element<()> = Element::TaggedNode(
            "textarea".into(),
            Description::NoDescription,
            vec![Attribute::AttrAttribute("value".into(), "ab\ncd".into())],
            vec![],
        );
        let mut reg = InputRegistry::new();
        let (frame, _f, _h) = render_with_focus(&t, 80, 24, 0, &mut reg, 0);
        let a = frame.find("ab");
        let c = frame.find("cd");
        assert!(a.is_some() && c.is_some(), "both visual lines render: {frame:?}");
        assert!(a < c, "first line above second: {frame:?}");
        assert!(frame.contains('▏'), "cursor glyph present (focused): {frame:?}");
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
