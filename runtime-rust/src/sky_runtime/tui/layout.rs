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

#[derive(Clone, Copy, Default, PartialEq)]
struct Style {
    fg: Option<(u8, u8, u8)>,
    bg: Option<(u8, u8, u8)>,
    bold: bool,
    italic: bool,
    underline: bool,
    strike: bool,
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
    /// `__grid` marker present (`Ui.grid`). Children flow row-major into auto-flow
    /// columns sized off `grid_min_px` (Go's `box.gridLayout`).
    is_grid: bool,
    /// `__paragraph` / `__textcolumn` marker (`Ui.paragraph` / `Ui.textColumn`).
    /// Text children are joined + word-wrapped to the available width.
    is_paragraph: bool,
    is_text_column: bool,
    /// `__gridMin` value — the minimum column WIDTH in logical px (set by
    /// `Ui.gridColumns N`). The actual column COUNT is `availW / cells_x(min)`.
    grid_min_px: i64,
    /// Border frame, present when `Border.width > 0`. See [`BorderSpec`].
    border: Option<BorderSpec>,
}

/// A border frame's `(colour, style)`. The colour is `None` when only width (no
/// `Border.color`) was given — glyphs then keep the inherited fg, matching Go's
/// `drawBorder` (which sets the glyph fg only when the border colour is set). The
/// style string is one of `solid` / `dashed` / `dotted` (anything else → solid).
type BorderSpec = (Option<(u8, u8, u8)>, String);

/// The root element's `Background.color`, if it sets one — the page background Go
/// paints across the whole frame rect (`fillRect` on the root box). `None` when the
/// root carries no bg (then nothing is backfilled and blank cells stay terminal-
/// default, matching Go's empty `newCellGrid`). Only the OUTERMOST node's bg is the
/// page fill; a child's bg belongs to that child's own box.
fn root_bg<M>(view: &Element<M>) -> Option<(u8, u8, u8)> {
    let attrs = match view {
        Element::Node(_, attrs, _) | Element::TaggedNode(_, _, attrs, _) => attrs,
        _ => return None,
    };
    attrs.iter().rev().find_map(|a| match a {
        Attribute::AttrBgColor(c) => Some(color_of(c)),
        _ => None,
    })
}

/// The root element's `Ui.width` `Length`, if it sets one — drives whether the
/// page background fills to the frame's right edge (a full-width / unsized root) or
/// stops at the root box's own width (a narrower px / vw / capped root).
fn root_width<M>(view: &Element<M>) -> Option<Length> {
    match view {
        Element::Node(_, attrs, _) | Element::TaggedNode(_, _, attrs, _) => width_length(attrs),
        _ => None,
    }
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
/// The fixed pixel height of `attrs` (`Ui.height (Ui.px n)`) in CELLS, when set.
/// Only `Px` yields a fixed row count (the multiline-textarea case); Fill/Content
/// auto-size and return `None`.
fn height_cells<M>(attrs: &[Attribute<M>], canvas: Canvas) -> Option<usize> {
    for a in attrs {
        if let Attribute::AttrHeight(Length::Px(n)) = a {
            return Some(canvas.cells_y(*n).max(1));
        }
    }
    None
}

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
    /// Constrain every line to EXACTLY `w` cells, filling the slack with the input
    /// TRACK (`░` in `track_fg` over `bg`) instead of plain spaces — mirrors Go's
    /// `paintInputBufferAdvanced`, which paints a shaded track across the whole
    /// field so its bounds stay visible even when empty. Real content (clipped to
    /// `w`) stays painted over the track. The cursor run keeps its own style.
    fn fill_input_track(&mut self, w: usize, bg: Option<(u8, u8, u8)>, track_fg: (u8, u8, u8)) {
        let track_run = |n: usize| Run {
            text: "░".repeat(n),
            style: Style { fg: Some(track_fg), bg, ..Style::default() },
        };
        for line in &mut self.lines {
            let lw: usize = line.iter().map(Run::width).sum();
            if lw > w {
                // Clip to `w` cells (reuse the same per-rune walk as set_width).
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
                if used < w {
                    kept.push(track_run(w - used));
                }
                *line = kept;
            } else if lw < w {
                line.push(track_run(w - lw));
            }
        }
    }
    /// Backfill the root element's background across the WHOLE frame rect, the way
    /// Go's `paintBox` fills the root box's rect with `box.bg` via `fillRect`
    /// BEFORE any child paints (`tui_ui.go` ~2418). The run model has no
    /// "paint underneath" step, so a gap / padding / trailing cell that no child
    /// covered is left with the default (terminal) background instead of the root
    /// bg — the 6-trailing-column + inter-gap divergence the styled-cell-grid
    /// equivalence test caught.
    ///
    /// Faithful equivalent: every cell whose bg is still unset (`None`) sits on the
    /// root box's fill in Go, so it takes `root_bg`. A cell that ALREADY carries a
    /// bg was painted by its owning box (a header / card / input with its own
    /// `Background.color`) and is left untouched.
    ///
    /// `fill_to_edge` extends each line to the full `cols` width with `root_bg` —
    /// Go's root box width is `innerMaxW == cols` ONLY when the root carries no
    /// explicit width, so the page background reaches the right edge. A root with an
    /// explicit narrower width (`Ui.width (px/vw …)`) fills only to its own width
    /// and the trailing columns stay terminal-default (Go's `fillRect` covers just
    /// `box.width`). Total — no index/panic.
    fn backfill_root_bg(&mut self, cols: usize, root_bg: (u8, u8, u8), fill_to_edge: bool) {
        let fill_style = Style { bg: Some(root_bg), ..Style::default() };
        for line in &mut self.lines {
            // Set the root bg on every run that has no bg of its own (a real glyph
            // on the root surface, or a blank gap/pad cell), preserving fg/flags.
            let mut width = 0usize;
            for run in line.iter_mut() {
                if run.style.bg.is_none() {
                    run.style.bg = Some(root_bg);
                }
                width += run.width();
            }
            // Extend the line to the full frame width with root-bg spaces (the page
            // background reaching the right edge). A line wider than `cols` is left
            // as-is — `emit_block` clips it to `cols` at paint time.
            if fill_to_edge && width < cols {
                line.push(Run { text: " ".repeat(cols - width), style: fill_style });
            }
        }
    }

    /// Reverse-video the single display cell at `(line, col)` — the text-input
    /// cursor (Go renders the cursor as `grid[cur].reverse`, never an inserted
    /// glyph). Rebuilds the line one char at a time, flagging the char at display
    /// column `col` (or appending a reverse space if the cursor sits past the
    /// content). Adjacent same-style chars re-coalesce into runs. Total — uses
    /// iterators + `.get`, never indexes or unwraps.
    fn reverse_cell_at(&mut self, line: usize, col: usize) {
        let Some(target_line) = self.lines.get_mut(line) else { return };
        // Flatten to (char, style) cells, marking the cursor char's style reverse.
        let mut cells: Vec<(char, Style)> = Vec::new();
        let mut acc = 0usize;
        for run in target_line.iter() {
            for ch in run.text.chars() {
                let cw = UnicodeWidthChar::width(ch).unwrap_or(0);
                let style = if acc == col {
                    Style { reverse: true, ..run.style }
                } else {
                    run.style
                };
                cells.push((ch, style));
                acc += cw;
            }
        }
        // Cursor past the end of the line content → append a reverse space.
        if acc <= col {
            // Pad any gap with normal spaces, then the reverse cursor space.
            for _ in acc..col {
                cells.push((' ', Style::default()));
            }
            cells.push((' ', Style { reverse: true, ..Style::default() }));
        }
        // Re-coalesce adjacent cells sharing a style into runs.
        let mut out: Vec<Run> = Vec::new();
        for (ch, style) in cells {
            match out.last_mut() {
                Some(last) if last.style == style => last.text.push(ch),
                _ => out.push(Run { text: ch.to_string(), style }),
            }
        }
        *target_line = out;
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

/// Clamp-add `delta` to a channel (Go's `lighten`). Saturating — no overflow.
fn lighten(c: u8, delta: i64) -> u8 {
    (c as i64 + delta).clamp(0, 255) as u8
}

/// The input track foreground: dim grey when the input has no bg, else the bg
/// lightened by 38 (Go's `paintInputBufferAdvanced` trackFg rule). The `░` shade
/// glyph rendered in this fg gives the field a visible groove.
fn input_track_fg(bg: Option<(u8, u8, u8)>) -> (u8, u8, u8) {
    match bg {
        Some((r, g, b)) => (lighten(r, 38), lighten(g, 38), lighten(b, 38)),
        None => (110, 110, 110),
    }
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
        is_grid: false,
        is_paragraph: false,
        is_text_column: false,
        grid_min_px: 0,
        border: None,
    };
    // Border accumulates across two attrs (width gate + colour); style defaults
    // to "solid". A frame is drawn only when width > 0 (Go: borderWidth sum > 0).
    let mut border_width = 0i64;
    let mut border_color: Option<Color> = None;
    let mut border_style = String::from("solid");
    for a in attrs {
        match a {
            Attribute::AttrStyle(k, _) if k == "__row" => w.dir = Dir::Row,
            Attribute::AttrStyle(k, _) if k == "__col" => w.dir = Dir::Column,
            Attribute::AttrStyle(k, _) if k == "__grid" => w.is_grid = true,
            Attribute::AttrStyle(k, _) if k == "__paragraph" => w.is_paragraph = true,
            Attribute::AttrStyle(k, _) if k == "__textcolumn" => w.is_text_column = true,
            Attribute::AttrStyle(k, v) if k == "__gridMin" => {
                w.grid_min_px = v.trim().parse().unwrap_or(0);
            }
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
            // Typography SGR (Go parity — tui_ui.go cellStyleSGR emits 3/4/9).
            Attribute::AttrFontItalic => w.style.italic = true,
            Attribute::AttrFontUnderline => w.style.underline = true,
            Attribute::AttrFontDecoration(s) if s == "underline" => w.style.underline = true,
            Attribute::AttrFontDecoration(s) if s == "line-through" || s == "strike" => {
                w.style.strike = true
            }
            // Border frame (Go: drawBorder — solid/dashed/dotted box). Width is
            // taken as present/absent (the frame is always 1 cell each side in the
            // terminal regardless of CSS px); colour + style drive the glyphs.
            Attribute::AttrBorderWidth(n) if *n > 0 => border_width = *n,
            Attribute::AttrBorderWidthEach(t, r, b, l) if t + r + b + l > 0 => {
                border_width = (t + r + b + l).max(1)
            }
            Attribute::AttrBorderColor(c) => border_color = Some(c.clone()),
            Attribute::AttrBorderStyle(s) => border_style = s.clone(),
            // Raw CSS escape hatch `Ui.style "border-style" "dashed"|"dotted"` —
            // the list-driven way the kitchen-sink picks a style. Without this the
            // value was dropped and dashed/dotted rendered as solid (border_glyphs
            // already supports ┄┆ / ┈┊).
            Attribute::AttrStyle(k, v) if k == "border-style" => border_style = v.clone(),
            _ => {}
        }
    }
    if border_width > 0 {
        w.border = Some((border_color.as_ref().map(color_of), border_style));
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
    inherited: Style,
    ctx: &mut Ctx<M>,
    avail_w: usize,
    is_multiline: bool,
) -> Rendered {
    // Fold the input's OWN visual attrs (Background.color / Font.color) on top of
    // the inherited style. An input is a leaf `TaggedNode` dispatched straight to
    // this fn, so its attrs were never walked by a parent — without this, the
    // input's `Background.color` track / text colour is silently dropped (Go reads
    // box.bg from the input's own attrs in `boxOwnStyle`).
    let mut style = inherited;
    for a in attrs {
        match a {
            Attribute::AttrBgColor(c) => style.bg = Some(color_of(c)),
            Attribute::AttrFontColor(c) => style.fg = Some(color_of(c)),
            _ => {}
        }
    }
    // A `<textarea>` carries no `type` attr; mark it "textarea" so the cursor
    // renders multiline and the loop inserts `\n` on Enter (vs submit on input).
    let input_type = if is_multiline {
        "textarea".to_string()
    } else {
        attr_str(attrs, "type").unwrap_or("text").to_string()
    };
    let value = attr_str(attrs, "value").unwrap_or("").to_string();
    let placeholder = attr_str(attrs, "placeholder").unwrap_or("").to_string();
    // Checked detection. A checkbox uses `checked`/`value="true"`. A radio in the
    // common hand-rolled idiom (`value = if selected then val else ""`) signals
    // selection by a NON-EMPTY value — so a radio is checked when an explicit
    // `checked` attr is present OR its value is non-empty and not "false". Without
    // the radio clause the selected radio kept drawing ○ (the "radio doesn't work"
    // report — onClick fires, but there was no visual feedback).
    let checked = attr_str(attrs, "checked").is_some()
        || value == "true"
        || (input_type == "radio" && !value.is_empty() && value != "false");
    let events = super::focus::collect_events(attrs);

    let idx = ctx.focusables.len();
    let focused = idx == ctx.focus_idx;

    // The text-input cursor, as `(line, col)` to reverse-video AFTER the track
    // fill (so a cursor past the content lands on a track cell, like Go). `None`
    // for non-text / unfocused inputs.
    let mut cursor_marker: Option<(usize, usize)> = None;
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
            // Track with the thumb positioned at value within [min, max]. Track
            // width follows `Ui.width` (was a fixed 12 — the slider rendered
            // narrower than its declared width); fall back to 12 when unsized.
            let min: f64 = attr_str(attrs, "min").and_then(|s| s.trim().parse().ok()).unwrap_or(0.0);
            let max: f64 = attr_str(attrs, "max").and_then(|s| s.trim().parse().ok()).unwrap_or(100.0);
            let val: f64 = value.trim().parse().unwrap_or(min);
            let width = width_length(attrs)
                .and_then(|l| resolve_fixed_w(&l, avail_w, ctx.canvas))
                .unwrap_or(12)
                .max(3);
            let frac = if max > min { ((val - min) / (max - min)).clamp(0.0, 1.0) } else { 0.0 };
            // Inset the thumb to the INNER span [1, width-2] so it is never
            // overwritten by the `├`/`┤` end-glyphs (the "ball disappears at the
            // extremes" report — at val≈0/100 the thumb landed on position
            // 0 / width-1 and the bracket won the cell).
            let span = width - 3; // count of steps between the two inner ends
            let thumb = 1 + (frac * span as f64).round() as usize;
            let thumb = thumb.clamp(1, width - 2);
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
            // Text-like input (incl. textarea): sync the edit buffer to the model's
            // value, then render it (or placeholder). The cursor is a REVERSE-VIDEO
            // cell over the underlying char/track (Go's paintInputBufferAdvanced
            // sets grid[cur].reverse), NOT a glyph insert — so it doesn't shift the
            // track and the field is byte-identical to Go in a text dump.
            ctx.inputs.sync_value(idx, &value);
            let st = ctx.inputs.get(idx);
            let masked = input_type == "password";
            let run_style = style; // field is NOT whole-reversed (Go: only the cell)
            let cursor_cell: Option<(usize, usize)> = if masked {
                // Masked single line: content hidden as bullets; cursor tracks the
                // EDIT position (st.cursor), not always the end — Left/Home/Ctrl-Left
                // move the caret and it must render where the caret actually is.
                let n = st.buffer.chars().count();
                if focused { Some((0, st.cursor.min(n))) } else { None }
            } else if st.buffer.is_empty() && !focused {
                None
            } else {
                let runes: Vec<char> = st.buffer.chars().collect();
                let cursor = st.cursor.min(runes.len());
                let (cl, cc) = cursor_line_col(&runes, cursor);
                if focused { Some((cl, cc)) } else { None }
            };
            let block = if masked {
                Block::single("•".repeat(st.buffer.chars().count()), run_style)
            } else if st.buffer.is_empty() && !focused {
                // Empty + unfocused: italic placeholder when present, else empty
                // line — the track fill paints the field bounds.
                if placeholder.is_empty() {
                    Block::single(String::new(), run_style)
                } else {
                    Block::single(placeholder.clone(), Style { italic: true, ..run_style })
                }
            } else {
                let runes: Vec<char> = st.buffer.chars().collect();
                let mut out: Vec<Vec<Run>> = Vec::new();
                for seg in split_buffer_lines(&runes) {
                    out.push(vec![Run { text: seg.into_iter().collect(), style: run_style }]);
                }
                if out.is_empty() {
                    out.push(vec![Run { text: String::new(), style: run_style }]);
                }
                Block { lines: out }
            };
            // Stash the cursor cell so it's applied AFTER the track fill (the track
            // pads the line out, so reversing a cell past current content lands on a
            // track ░ — exactly Go's reverse-over-track cursor).
            cursor_marker = cursor_cell;
            block
        }
    };
    // Honour `Ui.width` on a text-like field so it renders at a fixed/fill width.
    // checkbox / radio are glyph-only (no track); range owns its slider track.
    // Text-like inputs (text / password / email / search / textarea) paint a SHADED
    // TRACK across their full width (Go's paintInputBufferAdvanced) so the field
    // bounds stay visible even when empty — dim grey when no bg, else the bg
    // lightened by 38; real content + cursor paint over the track.
    let is_text_like = !matches!(input_type.as_str(), "checkbox" | "radio" | "range");
    // Border frame spec — a bordered input draws a REAL 1-cell box (correct
    // Std.Ui: Border.width > 0 ⇒ a frame). Previously the frame was suppressed
    // (a Go-mirror) and the border only widened the track, so no border showed.
    let mut bw = 0i64;
    let mut bcolor: Option<Color> = None;
    let mut bsty = String::from("solid");
    for a in attrs {
        match a {
            Attribute::AttrBorderWidth(n) if *n > 0 => bw = *n,
            Attribute::AttrBorderWidthEach(t, r, b, l) if t + r + b + l > 0 => bw = (t + r + b + l).max(1),
            Attribute::AttrBorderColor(c) => bcolor = Some(c.clone()),
            Attribute::AttrBorderStyle(s) => bsty = s.clone(),
            _ => {}
        }
    }
    let border_spec: Option<BorderSpec> = if bw > 0 {
        Some((bcolor.as_ref().map(color_of), bsty))
    } else {
        None
    };
    // The frame consumes a 1-cell ring each side; reserve it so the OUTER box
    // still fits the requested `Ui.width` (border-box sizing, Elm-ui style).
    let frame_ring = if border_spec.is_some() { 2 } else { 0 };
    if input_type != "range" {
        // Resolve the field width: explicit `Ui.width` → its cells; else the
        // text-like field stretches to the parent's allocation so an unsized input
        // still shows a full-width groove.
        let cells = match width_length(attrs) {
            Some(l) if fill_spec(&l, ctx.canvas).is_some() => Some(avail_w),
            Some(l) => resolve_fixed_w(&l, avail_w, ctx.canvas),
            None if is_text_like => Some(avail_w),
            None => None,
        };
        if let Some(c) = cells {
            let target = c.saturating_sub(frame_ring).max(1);
            if is_text_like {
                block.fill_input_track(target, style.bg, input_track_fg(style.bg));
            } else {
                block.set_width(target, style.bg);
            }
        }
    }
    // Reverse-video the cursor cell (reverse-over-track cursor) — applied after the
    // track fill so a cursor at/after the content lands on a track ░.
    if let Some((cl, cc)) = cursor_marker {
        block.reverse_cell_at(cl, cc);
    }
    // Multiline: honour a fixed `Ui.height (px)` — normalise to EXACTLY that many
    // rows, scrolling the window to keep the cursor row visible (correct Std.Ui: a
    // fixed-height textarea scrolls internally; it neither grows with content nor
    // shrinks below its height).
    if is_multiline {
        if let Some(rows) = height_cells(attrs, ctx.canvas) {
            let inner_rows = rows.saturating_sub(frame_ring).max(1);
            let total = block.lines.len();
            if total > inner_rows {
                let cur_line = cursor_marker.map(|(l, _)| l).unwrap_or(0);
                let start = cur_line.saturating_sub(inner_rows - 1).min(total - inner_rows);
                block.lines = block.lines[start..start + inner_rows].to_vec();
            } else {
                // Pad with blank track rows so the box keeps its fixed height.
                let track_w = block.width();
                let tfg = input_track_fg(style.bg);
                while block.lines.len() < inner_rows {
                    block.lines.push(vec![Run {
                        text: "░".repeat(track_w),
                        style: Style { fg: Some(tfg), bg: style.bg, ..Style::default() },
                    }]);
                }
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
    let rendered = Rendered { block, hits: vec![(idx, 0, 0, width, height)] };
    match &border_spec {
        Some(spec) => frame_rendered(rendered, spec, style),
        None => rendered,
    }
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
            // Paragraph / textColumn: join the element's text content and
            // word-wrap to the available width (Go's isParagraph/isTextColumn
            // branch in layoutElement, ~1474-1518). Each wrapped line is one
            // Text run; textColumn inserts a blank line between child paragraphs.
            let inner = if w.is_paragraph || w.is_text_column {
                let wrap_w = content_avail.max(1);
                let mut lines: Vec<Vec<Run>> = Vec::new();
                if w.is_text_column {
                    for (i, k) in kids.iter().enumerate() {
                        if i > 0 {
                            lines.push(Vec::new());
                        }
                        for l in wrap_text(&extract_text(k), wrap_w) {
                            lines.push(vec![Run { text: l, style: w.style }]);
                        }
                    }
                } else {
                    let joined = kids
                        .iter()
                        .map(extract_text)
                        .collect::<Vec<_>>()
                        .join(" ");
                    for l in wrap_text(&joined, wrap_w) {
                        lines.push(vec![Run { text: l, style: w.style }]);
                    }
                }
                if lines.is_empty() {
                    lines.push(Vec::new());
                }
                let mut block = Block { lines };
                // Go's paragraph/textColumn box width is `wrapW` (= the full
                // available content width when unsized), and its bg fills that whole
                // rect via `fillRect`. So a bg-carrying paragraph paints every
                // wrapped line out to `wrap_w`, not just to the text — matching Go's
                // wide page-card fill (the styled-cell-grid `232837×41` divergence).
                if w.style.bg.is_some() {
                    block.set_width(wrap_w, w.style.bg);
                }
                Rendered { block, hits: vec![] }
            } else if w.is_grid {
                render_grid(kids, &w, ctx, content_avail)
            } else {
                // Render children IN ORDER (preserves focusable push order = Tab
                // order), pairing each with its fill spec, then drop empty blocks.
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
                inner
            };
            let padded = apply_padding(inner, &w, ctx.canvas, w.style);
            // Border frame (Go's drawBorder): wrap the padded block in a 1-cell
            // box. The frame consumes 1 cell on each side of the OUTER block, so
            // the border sits outside the padding ring (Go insets children by
            // padding + borderWidth; here padding is already applied, the frame
            // adds the border ring outside it).
            apply_border(padded, &w, w.style)
        }
    }
}

/// Extract the concatenated text content of an element subtree (Go's
/// `extractTextContent` — flattens every `Text` leaf, space-joining nested ones).
fn extract_text<M>(el: &Element<M>) -> String {
    match el {
        Element::Text(t) => t.clone(),
        Element::Node(_, _, kids) | Element::TaggedNode(_, _, _, kids) => {
            kids.iter().map(extract_text).collect::<Vec<_>>().join(" ")
        }
        _ => String::new(),
    }
}

/// Word-wrap `text` to `width` cells. Mirrors Go's `wrapText`/`wrapParagraph`
/// (tui_wrap.go): soft-break on whitespace runs, hard-break (char chunks) only
/// for words longer than the line; embedded `'\n'` forces a break. Always ≥ 1
/// line. Total + bounds-checked — no panics.
fn wrap_text(text: &str, width: usize) -> Vec<String> {
    if width == 0 {
        return vec![String::new()];
    }
    let mut out: Vec<String> = Vec::new();
    for paragraph in text.split('\n') {
        wrap_paragraph_into(paragraph, width, &mut out);
    }
    if out.is_empty() {
        out.push(String::new());
    }
    out
}

fn wrap_paragraph_into(text: &str, width: usize, out: &mut Vec<String>) {
    let words: Vec<&str> = text.split_whitespace().collect();
    if words.is_empty() {
        out.push(String::new());
        return;
    }
    let mut cur = String::new();
    let mut cur_w = 0usize;
    for word in words {
        let ww = UnicodeWidthStr::width(word);
        // Word wider than the line — flush, then hard-break into chunks.
        if ww > width {
            if !cur.is_empty() {
                out.push(std::mem::take(&mut cur));
                cur_w = 0;
            }
            hard_break_chunks(word, width, out);
            continue;
        }
        let needed = if cur.is_empty() { ww } else { ww + 1 };
        if cur_w + needed > width {
            out.push(std::mem::take(&mut cur));
            cur.push_str(word);
            cur_w = ww;
        } else {
            if !cur.is_empty() {
                cur.push(' ');
                cur_w += 1;
            }
            cur.push_str(word);
            cur_w += ww;
        }
    }
    if !cur.is_empty() {
        out.push(cur);
    }
}

/// Split a long word into chunks of at most `width` display cells (Go's
/// `hardBreakChunks`). Char-counted, total.
fn hard_break_chunks(word: &str, width: usize, out: &mut Vec<String>) {
    if width == 0 || word.is_empty() {
        out.push(word.to_string());
        return;
    }
    let mut cur = String::new();
    let mut cur_w = 0usize;
    for ch in word.chars() {
        let cw = UnicodeWidthChar::width(ch).unwrap_or(0);
        if cur_w + cw > width && !cur.is_empty() {
            out.push(std::mem::take(&mut cur));
            cur_w = 0;
        }
        cur.push(ch);
        cur_w += cw;
    }
    if !cur.is_empty() {
        out.push(cur);
    }
}

/// Grid layout (Go's `gridLayout` branch, ~2518-2549). `grid_min_px` (from
/// `Ui.gridColumns N`) → min column cells; `ncols = avail / min` (≥1); cells flow
/// row-major into `ncols` per row, each column padded to `col_width`; rows stack
/// vertically with the spacing gap. Focusable hits are shifted to absolute coords.
fn render_grid<M: Clone>(
    kids: &[Element<M>],
    w: &Walked,
    ctx: &mut Ctx<M>,
    content_avail: usize,
) -> Rendered {
    let min_col = {
        let c = ctx.canvas.cells_x(w.grid_min_px);
        if c == 0 { 10 } else { c }
    };
    let avail = content_avail.max(1);
    let ncols = (avail / min_col).max(1);
    let col_width = (avail / ncols).max(1);
    let gap_y = ctx.canvas.cells_y(w.spacing_px);

    // Render every child at col_width (its own content fits within); collect into
    // a flat list (skipping empty blocks would break row-major alignment, so keep
    // ALL cells in order).
    let cells: Vec<Rendered> =
        kids.iter().map(|k| render_node(k, w.style, ctx, col_width)).collect();

    // Chunk row-major into rows of `ncols`, hstack each row (no inter-cell gap —
    // each cell is padded to col_width, matching Go's `x = innerCol + col*colWidth`),
    // vstack the rows with the spacing gap.
    let mut rows: Vec<Rendered> = Vec::new();
    for chunk in cells.chunks(ncols.max(1)) {
        let mut sized: Vec<Rendered> = Vec::new();
        for r in chunk {
            let mut r2 = Rendered { block: r.block.clone(), hits: r.hits.clone() };
            // Pad the cell to col_width with the CELL's OWN bg, not the grid's — Go
            // gives each grid cell box `width = colWidth` and fills it with that
            // cell's `box.bg` (`60 50 80` here), so the padding to col_width carries
            // the cell colour, not the grid background (the `3c3250×30` contiguous
            // fill the styled-cell-grid test expects). Fall back to the grid's bg
            // for a cell that declares none.
            let cell_bg = cell_block_bg(&r2.block).or(w.style.bg);
            r2.block.set_width(col_width, cell_bg);
            sized.push(r2);
        }
        rows.push(hstack(sized, 0));
    }
    vstack(rows, gap_y)
}

/// The cell's own background, read from its rendered runs — the bg a grid cell
/// painted on itself (via its `Background.color` cascading into `apply_padding` /
/// `set_width`). Returns the first run-level bg found scanning the block. `None`
/// when no run carries a bg (a cell with no `Background.color`), letting the caller
/// fall back to the grid's bg. Total — no index/unwrap.
fn cell_block_bg(block: &Block) -> Option<(u8, u8, u8)> {
    block.lines.iter().flatten().find_map(|run| run.style.bg)
}

/// Wrap a rendered block in a 1-cell border frame (Go's `drawBorder`). The frame
/// is only drawn when `w.border` is set AND the block is ≥ 2×2 (Go's `w<2||h<2`
/// guard). Corners ┌┐└┘, edges ─│ per style; the border colour (when set)
/// overrides the glyph fg. Hits + content shift down/right by 1.
fn apply_border(inner: Rendered, w: &Walked, self_style: Style) -> Rendered {
    match &w.border {
        Some(spec) => frame_rendered(inner, spec, self_style),
        None => inner,
    }
}

/// Wrap a `Rendered` in a 1-cell box-drawing frame from a `BorderSpec`. Shared by
/// box borders (`apply_border`) and bordered inputs (`render_input`). Shifts the
/// inner content + focusable hits +1 line / +1 col (the frame's top-left).
fn frame_rendered(inner: Rendered, spec: &BorderSpec, self_style: Style) -> Rendered {
    let (border_fg, style) = (spec.0, spec.1.as_str());
    let inner_w = inner.block.width();
    let inner_h = inner.block.height();
    let outer_w = inner_w + 2;
    let outer_h = inner_h + 2;
    if outer_w < 2 || outer_h < 2 {
        return inner;
    }
    let (hor, vert, tl, tr, bl, br) = border_glyphs(style);
    // Border runs inherit the frame fg (when set) but keep the node's bg so the
    // box reads as one filled rect.
    let bstyle = Style { fg: border_fg.or(self_style.fg), ..self_style };
    let edge = |ch: &str, n: usize| Run { text: ch.repeat(n), style: bstyle };
    let corner = |ch: &str| Run { text: ch.to_string(), style: bstyle };

    let mut block = Block::default();
    // Top edge: ┌──…──┐
    {
        let mut row = vec![corner(tl)];
        if inner_w > 0 {
            row.push(edge(hor, inner_w));
        }
        row.push(corner(tr));
        block.lines.push(row);
    }
    // Middle rows: │ <content padded to inner_w> │
    for line in &inner.block.lines {
        let mut row = vec![corner(vert)];
        let lw: usize = line.iter().map(Run::width).sum();
        row.extend(line.iter().cloned());
        if lw < inner_w {
            row.push(Run { text: " ".repeat(inner_w - lw), style: self_style });
        }
        row.push(corner(vert));
        block.lines.push(row);
    }
    // Bottom edge: └──…──┘
    {
        let mut row = vec![corner(bl)];
        if inner_w > 0 {
            row.push(edge(hor, inner_w));
        }
        row.push(corner(br));
        block.lines.push(row);
    }
    // Content + focusables shift +1 line / +1 col (the frame's top-left).
    let hits = inner.hits.into_iter().map(|(idx, l, c, ww, hh)| (idx, l + 1, c + 1, ww, hh)).collect();
    Rendered { block, hits }
}

/// Box-drawing glyphs `(hor, vert, tl, tr, bl, br)` for a border style. Mirrors
/// Go's `borderGlyphs`: dashed ┄┆, dotted ┈┊, everything else solid ─│.
fn border_glyphs(style: &str) -> (&'static str, &'static str, &'static str, &'static str, &'static str, &'static str) {
    match style {
        "dashed" => ("┄", "┆", "┌", "┐", "└", "┘"),
        "dotted" => ("┈", "┊", "┌", "┐", "└", "┘"),
        _ => ("─", "│", "┌", "┐", "└", "┘"),
    }
}

/// Content width available to a node's children = the node's allocation minus its
/// horizontal padding (and the 1-cell-each-side border ring, when present).
fn node_content_avail(avail_w: usize, w: &Walked, canvas: Canvas) -> usize {
    let pad = canvas.cells_x(w.pad_left)
        + canvas.cells_x(w.pad_right)
        + if w.border.is_some() { 2 } else { 0 };
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

/// Honour the `NO_COLOR` convention (https://no-color.org): when the env var is
/// present and non-empty, suppress all COLOUR output (fg/bg) — text attributes
/// (bold/italic/underline/…) are kept, only colour is dropped. Cached once.
fn no_color() -> bool {
    static NC: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    *NC.get_or_init(|| std::env::var_os("NO_COLOR").map(|v| !v.is_empty()).unwrap_or(false))
}

fn sgr(style: Style) -> String {
    let mut codes: Vec<String> = Vec::new();
    if style.bold {
        codes.push("1".to_string());
    }
    if style.italic {
        codes.push("3".to_string());
    }
    if style.underline {
        codes.push("4".to_string());
    }
    if style.strike {
        codes.push("9".to_string());
    }
    if style.reverse {
        codes.push("7".to_string());
    }
    if !no_color() {
        if let Some((r, g, b)) = style.fg {
            codes.push(format!("38;2;{r};{g};{b}"));
        }
        if let Some((r, g, b)) = style.bg {
            codes.push(format!("48;2;{r};{g};{b}"));
        }
    }
    if codes.is_empty() {
        String::new()
    } else {
        format!("\x1b[{}m", codes.join(";"))
    }
}

fn emit_block(block: &Block, cols: usize, scroll_y: usize, rows: usize) -> String {
    let mut out = String::new();
    // Lines are CRLF-separated, but the SEPARATOR goes BEFORE each line after the
    // first — NOT a trailing CRLF after the last visible row. A trailing CRLF on a
    // full-height frame (visible lines == terminal rows) advances the cursor past
    // the bottom row and scrolls the whole screen up by one, dropping the top row
    // (the root padding) and diverging from Go on the very first paint (Go
    // positions each row absolutely and never trails a newline). `paint()` issues
    // ESC[2J + home first, so a leading-separator model lands every row correctly.
    for (i, line) in block.lines.iter().skip(scroll_y).take(rows).enumerate() {
        if i > 0 {
            out.push_str("\r\n");
        }
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
    let mut rendered = render_node(view, Style::default(), &mut ctx, cols);
    // Backfill the root element's page background across the full frame rect — the
    // gap / padding / trailing cells no child covered take the root bg (Go paints
    // the root box's rect first via `fillRect`, then children on top). Without this
    // the page background stops at the content's right edge + inter-element gaps
    // read as terminal-default (the styled-cell-grid equivalence divergence).
    if let Some(bg) = root_bg(view) {
        // The page bg reaches the right edge only when the root box spans the full
        // width — i.e. it has no explicit width, or a width that resolves to the
        // whole frame (Go: root `width == innerMaxW == cols`). An explicitly
        // NARROWER root (px / vw / a capped max / capped fill) fills only its own
        // resolved width; the trailing columns stay terminal-default.
        let fill_to_edge = match root_width(view) {
            None | Some(Length::Content) => true,
            Some(Length::Fill(_)) => true,
            Some(l) => resolve_fixed_w(&l, cols, canvas).is_none_or(|cells| cells >= cols),
        };
        rendered.block.backfill_root_bg(cols, bg, fill_to_edge);
    }
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
        // Cursor is a reverse-video cell (Go parity), not an inserted glyph.
        assert!(frame.contains("\x1b[7"), "reverse-video cursor present (focused): {frame:?}");
        assert!(!frame.contains('▏'), "no inserted cursor glyph: {frame:?}");
    }

    #[test]
    fn wrap_text_breaks_on_whitespace() {
        let lines = wrap_text("the quick brown fox", 9);
        assert_eq!(lines, vec!["the quick", "brown fox"]);
    }

    #[test]
    fn wrap_text_hard_breaks_long_word() {
        // A 12-char word exceeds width 5 → char-chunks of ≤5.
        let lines = wrap_text("abcdefghijkl", 5);
        assert_eq!(lines, vec!["abcde", "fghij", "kl"]);
    }

    #[test]
    fn wrap_text_honours_newlines_and_zero_width() {
        assert_eq!(wrap_text("a\nb", 10), vec!["a", "b"]);
        assert_eq!(wrap_text("anything", 0), vec![""]);
        assert_eq!(wrap_text("", 10), vec![""]);
    }

    #[test]
    fn paragraph_word_wraps() {
        // A paragraph node carrying long text wraps to the canvas width.
        let t: Element<()> = node(
            vec![Attribute::AttrStyle("__paragraph".into(), "true".into())],
            vec![Element::Text(
                "alpha beta gamma delta epsilon zeta eta theta iota".into(),
            )],
        );
        // 20 cols → multiple wrapped lines.
        let frame = element_to_cells(&t, 20, 24);
        let body_lines: Vec<&str> = frame.split("\r\n").filter(|l| l.contains("alpha") || l.contains("zeta")).collect();
        assert!(frame.contains("alpha"), "first word present: {frame:?}");
        // The text spans more than one line (not a single truncated line).
        assert!(frame.matches("\r\n").count() >= 2, "wrapped onto ≥2 lines: {frame:?}");
        let _ = body_lines;
    }

    #[test]
    fn grid_flows_row_major() {
        // gridColumns 80 px ≈ 5 cells min → on 60 cols, ncols = 60/5 = 12 → all
        // six single-char cells land on one row.
        let cell = |s: &str| -> Element<()> {
            node(vec![], vec![Element::Text(s.into())])
        };
        let g: Element<()> = node(
            vec![
                Attribute::AttrStyle("__grid".into(), "true".into()),
                Attribute::AttrStyle("__gridMin".into(), "80".into()),
            ],
            vec![cell("G1"), cell("G2"), cell("G3"), cell("G4"), cell("G5"), cell("G6")],
        );
        let frame = element_to_cells(&g, 60, 24);
        let first = frame.split("\r\n").next().unwrap_or("");
        assert!(first.contains("G1"), "G1 on row 0: {first:?}");
        assert!(first.contains("G6"), "G6 on the SAME row 0 (row-major flow): {first:?}");
    }

    #[test]
    fn reverse_cell_marks_one_cell() {
        let mut b = Block::single("hello".into(), Style::default());
        b.reverse_cell_at(0, 2); // reverse the 'l' at col 2
        let line = b.lines.first().expect("one line");
        // Rebuilds as before("he") + reverse("l") + after("lo").
        let rev: Vec<&Run> = line.iter().filter(|r| r.style.reverse).collect();
        assert_eq!(rev.len(), 1, "exactly one reverse run");
        assert_eq!(rev.first().map(|r| r.text.as_str()), Some("l"));
        let full: String = line.iter().map(|r| r.text.as_str()).collect();
        assert_eq!(full, "hello", "content unchanged, only style split");
    }

    #[test]
    fn reverse_cell_past_content_appends_space() {
        let mut b = Block::single("hi".into(), Style::default());
        b.reverse_cell_at(0, 5); // cursor past "hi"
        let line = b.lines.first().expect("one line");
        let full: String = line.iter().map(|r| r.text.as_str()).collect();
        assert_eq!(full, "hi    ", "padded to col 5 + reverse space");
        assert!(line.iter().any(|r| r.style.reverse), "reverse cursor appended");
    }

    #[test]
    fn focused_empty_input_has_no_glyph_just_reverse_track() {
        // A focused empty text input shows a reverse-video track cell (Go), not a
        // ▏ glyph.
        let inp: Element<()> = Element::TaggedNode(
            "input".into(),
            Description::NoDescription,
            vec![
                Attribute::AttrWidth(Length::Px(160)),
                Attribute::AttrAttribute("type".into(), "text".into()),
            ],
            vec![],
        );
        let mut reg = InputRegistry::new();
        let (frame, _f, _h) = render_with_focus(&inp, 80, 24, 0, &mut reg, 0);
        assert!(!frame.contains('▏'), "no inserted cursor glyph: {frame:?}");
        assert!(frame.contains("\x1b[7"), "reverse-video cursor cell: {frame:?}");
        assert!(frame.contains('░'), "track still present: {frame:?}");
    }

    #[test]
    fn input_paints_shaded_track() {
        // A bg-coloured text input with explicit width fills its full width with
        // the ░ track (lightened bg fg), not plain spaces.
        let inp: Element<()> = Element::TaggedNode(
            "input".into(),
            Description::NoDescription,
            vec![
                Attribute::AttrWidth(Length::Px(160)),
                Attribute::AttrBgColor(rgb(30, 36, 60)),
                Attribute::AttrAttribute("type".into(), "text".into()),
            ],
            vec![],
        );
        let frame = element_to_cells(&inp, 80, 24);
        assert!(frame.contains('░'), "shaded track present: {frame:?}");
        // track fg = lighten(bg, 38) = (68, 74, 98).
        assert!(frame.contains("38;2;68;74;98"), "track fg = lightened bg: {frame:?}");
        // bg of the field present too.
        assert!(frame.contains("48;2;30;36;60"), "field bg present: {frame:?}");
    }

    #[test]
    fn input_track_no_bg_is_dim_grey() {
        let inp: Element<()> = Element::TaggedNode(
            "input".into(),
            Description::NoDescription,
            vec![
                Attribute::AttrWidth(Length::Px(160)),
                Attribute::AttrAttribute("type".into(), "text".into()),
            ],
            vec![],
        );
        let frame = element_to_cells(&inp, 80, 24);
        assert!(frame.contains('░'), "track present without bg: {frame:?}");
        assert!(frame.contains("38;2;110;110;110"), "dim-grey track: {frame:?}");
    }

    #[test]
    fn border_frames_a_box() {
        let t: Element<()> = node(
            vec![
                Attribute::AttrBorderWidth(1),
                Attribute::AttrBorderColor(rgb(100, 130, 180)),
            ],
            vec![Element::Text("hi".into())],
        );
        let frame = element_to_cells(&t, 80, 24);
        assert!(frame.contains('┌') && frame.contains('┐'), "top corners: {frame:?}");
        assert!(frame.contains('└') && frame.contains('┘'), "bottom corners: {frame:?}");
        assert!(frame.contains('│') && frame.contains('─'), "edges: {frame:?}");
        assert!(frame.contains("hi"), "content inside frame: {frame:?}");
    }

    #[test]
    fn border_style_picks_dashed_dotted_glyphs() {
        let mk = |style: &str| -> Element<()> {
            node(
                vec![
                    Attribute::AttrBorderWidth(1),
                    Attribute::AttrBorderStyle(style.into()),
                ],
                vec![Element::Text("x".into())],
            )
        };
        assert!(element_to_cells(&mk("dashed"), 80, 24).contains('┄'));
        assert!(element_to_cells(&mk("dotted"), 80, 24).contains('┈'));
    }

    #[test]
    fn frame_has_no_trailing_newline() {
        // A full-height frame must NOT end with CRLF — a trailing newline on the
        // bottom row scrolls the screen up one (drops the top row, diverges from
        // Go on first paint). Build a frame with as many lines as terminal rows.
        let kids: Vec<Element<()>> =
            (0..10).map(|i| node(vec![], vec![Element::Text(format!("r{i}"))])).collect();
        let t: Element<()> = node(vec![], kids);
        let frame = element_to_cells(&t, 80, 10);
        assert!(!frame.ends_with("\r\n"), "no trailing CRLF: {frame:?}");
        // Still CRLF-separated between rows.
        assert_eq!(frame.matches("\r\n").count(), 9, "9 separators for 10 rows: {frame:?}");
    }

    #[test]
    fn root_bg_fills_full_width_and_gaps() {
        // Go paints the root box's bg across the WHOLE frame rect, so trailing
        // columns + inter-element gaps the content didn't cover read as the page
        // bg, not terminal-default. A root column (bg set, no explicit width) with
        // a child narrower than the frame must still paint bg to the right edge.
        let t: Element<()> = node(
            vec![Attribute::AttrBgColor(rgb(18, 22, 38))],
            vec![node(vec![], vec![Element::Text("x".into())])],
        );
        let frame = element_to_cells(&t, 20, 3);
        let first = frame.split("\r\n").next().unwrap_or("");
        // The page bg SGR reaches the row; the glyph 'x' sits on it and the
        // remaining cells to col 20 carry the same bg (one fill run to the edge).
        assert!(first.contains("48;2;18;22;38"), "page bg present: {first:?}");
        // Count visible spaces after 'x' — the bg-filled tail to col 20.
        let spaces = first.matches(' ').count();
        assert!(spaces >= 15, "bg fills toward the right edge: {first:?} ({spaces})");
    }

    #[test]
    fn root_bg_none_leaves_cells_default() {
        // No root bg → nothing is backfilled (matches Go's empty cell grid); the
        // frame carries no 48;2 background SGR at all.
        let t: Element<()> = node(vec![], vec![node(vec![], vec![Element::Text("x".into())])]);
        let frame = element_to_cells(&t, 20, 3);
        assert!(!frame.contains("48;2;"), "no bg backfilled without a root bg: {frame:?}");
    }

    #[test]
    fn grid_cell_bg_fills_column_not_grid_bg() {
        // Go fills each grid cell to col_width with that CELL's own bg. A grid with
        // a page bg whose cells carry a different bg must show the CELL bg across
        // each column (contiguous), not the grid bg between content + col edge.
        let cell = |s: &str| -> Element<()> {
            node(
                vec![Attribute::AttrBgColor(rgb(60, 50, 80))],
                vec![Element::Text(s.into())],
            )
        };
        let g: Element<()> = node(
            vec![
                Attribute::AttrBgColor(rgb(18, 22, 38)),
                Attribute::AttrStyle("__grid".into(), "true".into()),
                Attribute::AttrStyle("__gridMin".into(), "80".into()),
            ],
            vec![cell("G1"), cell("G2")],
        );
        let frame = element_to_cells(&g, 60, 4);
        let first = frame.split("\r\n").next().unwrap_or("");
        // The cell bg (60,50,80 = 3c3250) is present and fills past the 2-char
        // label toward its column width.
        assert!(first.contains("48;2;60;50;80"), "grid cell bg present: {first:?}");
    }

    #[test]
    fn paragraph_bg_fills_wrap_width() {
        // A bg-carrying paragraph paints every wrapped line out to the wrap width
        // (Go's paragraph box width = wrapW), not just to the text.
        let t: Element<()> = node(
            vec![
                Attribute::AttrStyle("__paragraph".into(), "true".into()),
                Attribute::AttrBgColor(rgb(35, 40, 55)),
            ],
            vec![Element::Text("alpha beta gamma delta epsilon".into())],
        );
        let frame = element_to_cells(&t, 20, 6);
        // Every text row carries the paragraph bg filling to ~20 cells.
        let body: Vec<&str> = frame.split("\r\n").filter(|l| l.contains("48;2;35;40;55")).collect();
        assert!(!body.is_empty(), "paragraph bg present on wrapped lines: {frame:?}");
        let first = body.first().copied().unwrap_or("");
        // The bg run pads the wrapped line out (≥ several trailing bg spaces).
        assert!(first.matches(' ').count() >= 3, "paragraph bg pads to wrap width: {first:?}");
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
