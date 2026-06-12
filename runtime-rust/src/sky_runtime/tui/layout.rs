//! Element → ANSI frame — the structured Sky.Tui renderer.
//!
//! Walks the shared `sky_runtime::ui::Element` tree (the SAME tree Sky.Live
//! renders to HTML) and lays it out to terminal cells by reading the TYPED
//! attributes directly — `AttrPadding`/`AttrSpacing`/`AttrFontColor`/
//! `AttrBgColor`/`AttrStyle "__row"` etc. — never CSS. This mirrors Go's
//! `runtime-go/rt/tui_ui.go` (`layoutElement`/`walkAttrs`/`colorOf`/
//! `resolveLengthCells`) and replaces the earlier CSS-reparsing approach.
//!
//! Logical-pixel canvas (Go parity): a design surface (default 1280×720) maps to
//! the live terminal cell grid, so `Ui.padding 8` / `Ui.spacing 16` scale to
//! cells via `pxPerCell` computed from the terminal size. Terminal cells are
//! ~2× taller than wide, so the vertical and horizontal rates differ naturally.
//!
//! Scope (this pass): the block/flex subset — column / row / el / text / button +
//! colour + spacing + padding + bold + Length(px/fill). Inputs / focus / scroll /
//! mouse are an explicit follow-on (task #62). No panic vectors: unicode-width
//! display widths, `.get`/iterators, saturating arithmetic, control-byte
//! sanitisation, `Raw`/unsupported attrs degrade gracefully.

use super::super::ui::{Attribute, Color, Element};
use super::cell::sanitize_rune;
use unicode_width::UnicodeWidthStr;

const CANVAS_W: usize = 1280;
const CANVAS_H: usize = 720;

/// Logical-pixel → cell conversion, derived from the live terminal size.
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
        let c = (px as f64 / self.px_per_cell_x).round() as i64;
        // Sub-half-cell but positive px still occupies ≥1 cell (Go parity).
        c.max(1) as usize
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
}

#[derive(Clone, Copy, PartialEq)]
enum Dir {
    Column,
    Row,
}

/// Typed attributes extracted from a node, mirroring Go's `walkedAttrs`.
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
    /// Right-pad every line to width `w` with `bg`-styled spaces (colour fill).
    fn pad_to_width(&mut self, w: usize, bg: Option<(u8, u8, u8)>) {
        for line in &mut self.lines {
            let lw: usize = line.iter().map(Run::width).sum();
            if lw < w {
                line.push(Run {
                    text: " ".repeat(w.saturating_sub(lw)),
                    style: Style { fg: None, bg, bold: false },
                });
            }
        }
    }
}

fn color_of(c: &Color) -> (u8, u8, u8) {
    let Color::Rgba(r, g, b, _) = c;
    (
        (*r & 0xff) as u8,
        (*g & 0xff) as u8,
        (*b & 0xff) as u8,
    )
}

/// Extract the typed layout/style attributes from a node's attribute list.
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

fn vstack(blocks: Vec<Block>, gap: usize) -> Block {
    let mut out = Block::default();
    for (i, b) in blocks.into_iter().enumerate() {
        if i > 0 {
            for _ in 0..gap {
                out.lines.push(Vec::new());
            }
        }
        out.lines.extend(b.lines);
    }
    out
}

fn hstack(blocks: Vec<Block>, gap: usize) -> Block {
    let height = blocks.iter().map(Block::height).max().unwrap_or(0);
    let mut out = Block { lines: vec![Vec::new(); height] };
    for (bi, b) in blocks.iter().enumerate() {
        let bw = b.width();
        for row in 0..height {
            if let Some(target) = out.lines.get_mut(row) {
                if bi > 0 && gap > 0 {
                    target.push(Run { text: " ".repeat(gap), style: Style::default() });
                }
                match b.lines.get(row) {
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
    out
}

fn apply_padding(inner: Block, w: &Walked, canvas: Canvas, self_style: Style) -> Block {
    let top = canvas.cells_y(w.pad_top);
    let bottom = canvas.cells_y(w.pad_bottom);
    let left = canvas.cells_x(w.pad_left);
    let right = canvas.cells_x(w.pad_right);
    let inner_w = inner.width();
    let total_w = inner_w + left + right;
    let pad_run = |n: usize| Run { text: " ".repeat(n), style: self_style };

    let mut out = Block::default();
    for _ in 0..top {
        out.lines.push(vec![pad_run(total_w)]);
    }
    for line in inner.lines {
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
        out.lines.push(row);
    }
    for _ in 0..bottom {
        out.lines.push(vec![pad_run(total_w)]);
    }
    out
}

/// Render one Element node into a styled `Block`, cascading text style downward.
fn render_node<M>(node: &Element<M>, inherited: Style, canvas: Canvas) -> Block {
    match node {
        Element::Empty => Block::default(),
        Element::Text(t) => {
            let clean: String = t.chars().map(sanitize_rune).collect();
            Block::single(clean, inherited)
        }
        Element::Raw(_) => Block::default(), // native HTML can't render to cells
        Element::Node(_desc, attrs, kids) | Element::TaggedNode(_, _desc, attrs, kids) => {
            let w = walk_attrs(attrs, inherited);
            let child_blocks: Vec<Block> = kids
                .iter()
                .map(|k| render_node(k, w.style, canvas))
                .filter(|b| b.height() > 0)
                .collect();

            let mut inner = if child_blocks.is_empty() {
                Block { lines: vec![Vec::new()] }
            } else {
                match w.dir {
                    Dir::Column => vstack(child_blocks, canvas.cells_y(w.spacing_px)),
                    Dir::Row => hstack(child_blocks, canvas.cells_x(w.spacing_px)),
                }
            };
            let inner_w = inner.width();
            inner.pad_to_width(inner_w, w.style.bg);
            apply_padding(inner, &w, canvas, w.style)
        }
    }
}

const SGR_RESET: &str = "\x1b[0m";

fn sgr(style: Style) -> String {
    let mut codes: Vec<String> = Vec::new();
    if style.bold {
        codes.push("1".to_string());
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

/// Render a `Std.Ui` `Element` view into an ANSI frame, clipped to the terminal.
pub fn element_to_cells<M>(view: &Element<M>, cols: usize, rows: usize) -> String {
    let canvas = Canvas::new(cols, rows);
    let block = render_node(view, Style::default(), canvas);
    let mut out = String::new();
    for line in &block.lines {
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

#[cfg(test)]
mod tests {
    use super::*;

    fn rgb(r: i64, g: i64, b: i64) -> Color {
        Color::Rgba(r, g, b, 1.0)
    }
    fn node<M>(attrs: Vec<Attribute<M>>, kids: Vec<Element<M>>) -> Element<M> {
        Element::Node(super::super::super::ui::Description::NoDescription, attrs, kids)
    }
    fn row_marker<M>() -> Attribute<M> {
        Attribute::AttrStyle("__row".into(), "true".into())
    }

    #[test]
    fn text_with_fg() {
        let t: Element<()> =
            node(vec![Attribute::AttrFontColor(rgb(255, 0, 0))], vec![Element::Text("hi".into())]);
        let frame = element_to_cells(&t, 80, 24);
        assert!(frame.contains("38;2;255;0;0"), "fg SGR: {frame:?}");
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
    fn row_places_side_by_side() {
        let t: Element<()> = node(
            vec![row_marker()],
            vec![
                node(vec![], vec![Element::Text("L".into())]),
                node(vec![], vec![Element::Text("R".into())]),
            ],
        );
        let first = element_to_cells(&t, 80, 24).split("\r\n").next().unwrap_or("").to_string();
        assert!(first.contains('L') && first.contains('R'), "same row: {first:?}");
    }

    #[test]
    fn padding_adds_blank_rows() {
        let t: Element<()> =
            node(vec![Attribute::AttrPadding(48, 0, 48, 0)], vec![Element::Text("x".into())]);
        let frame = element_to_cells(&t, 80, 24);
        // 48px vertical padding at ~30px/cell → ≥1 blank row above the text.
        let lines: Vec<&str> = frame.split("\r\n").collect();
        assert!(lines.len() >= 3, "padded: {lines:?}");
    }

    #[test]
    fn bg_color_emits_fill() {
        let t: Element<()> =
            node(vec![Attribute::AttrBgColor(rgb(10, 20, 30))], vec![Element::Text("x".into())]);
        let frame = element_to_cells(&t, 80, 24);
        assert!(frame.contains("48;2;10;20;30"), "bg SGR: {frame:?}");
    }

    #[test]
    fn clips_to_cols_and_sanitizes() {
        let t: Element<()> = node(vec![], vec![Element::Text("ab\u{7}cdefghij".into())]);
        let frame = element_to_cells(&t, 4, 24);
        let first = frame.split("\r\n").next().unwrap_or("");
        assert!(!first.contains('\u{7}'), "control stripped: {first:?}");
        let visible: String = first.chars().filter(|c| c.is_ascii_alphabetic()).collect();
        assert!(visible.len() <= 4, "clipped: {first:?}");
    }
}
