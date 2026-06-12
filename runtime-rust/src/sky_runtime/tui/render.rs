//! Element → ANSI frame.
//!
//! Sky.Tui's `Tui.app` view returns a `Std.Ui` `Element`, which the Rust
//! backend lowers to the SAME `Html<M>` tree Sky.Live renders to HTML — layout
//! is encoded as inline CSS `style` attributes (`display:flex`,
//! `flex-direction`, `gap`, `padding`, `background-color`, `color`,
//! `font-weight`). This module walks that tree, runs a minimal flex layout, and
//! paints a styled-cell frame as an ANSI string. It is the Rust mirror of Go's
//! `tui_ui.go` layout engine, built for the common block/flex subset first
//! (column / row / el / text / button + colour + spacing + padding); inputs,
//! scroll and mouse hit-testing (`23`/`24`-class apps) layer on later.
//!
//! No panic vectors: display width via `unicode-width`, every span access is a
//! `.get` / iterator, all arithmetic is saturating, control bytes are stripped.
//! `<style>` / `<script>` children are ignored (Go parity — the terminal can't
//! honour injected CSS).

use super::super::html::{Attribute, Html};
use super::cell::sanitize_rune;
use unicode_width::UnicodeWidthStr;

/// 24-bit colour parsed from an `rgb(r, g, b)` CSS value.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
struct Rgb(u8, u8, u8);

/// Inherited text style (cascades down the tree) plus the per-element box
/// directives (flex direction / gap / padding) which do NOT inherit.
#[derive(Clone, Copy, Default)]
struct Style {
    fg: Option<Rgb>,
    bg: Option<Rgb>,
    bold: bool,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Dir {
    Column,
    Row,
}

/// A box's layout directives, read from its inline `style` string.
struct BoxStyle {
    dir: Dir,
    gap: u16,
    pad_top: u16,
    pad_right: u16,
    pad_bottom: u16,
    pad_left: u16,
    fg: Option<Rgb>,
    bg: Option<Rgb>,
    bold: bool,
}

/// One painted span of text carrying a resolved style.
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

/// A rectangular block of styled text: each line is a sequence of runs. Width is
/// the max line width; height is the line count.
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

    /// Right-pad every line with `bg`-styled spaces so all lines reach `w`.
    fn pad_to_width(&mut self, w: usize, bg: Option<Rgb>) {
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

/// Px→cell conversion. Terminal cells are ~2× taller than wide, so vertical
/// directives convert at a coarser rate than horizontal. Coarse but legible;
/// Go's engine uses a logical-pixel canvas + terminal-derived `pxPerCell`.
fn px_to_rows(px: u16) -> usize {
    (px / 16) as usize
}
fn px_to_cols(px: u16) -> usize {
    (px / 8) as usize
}

fn parse_rgb(v: &str) -> Option<Rgb> {
    let inner = v.trim().strip_prefix("rgb(")?.strip_suffix(')')?;
    let mut it = inner.split(',').map(|p| p.trim().parse::<u8>().ok());
    let r = it.next()??;
    let g = it.next()??;
    let b = it.next()??;
    Some(Rgb(r, g, b))
}

/// First `px` integer in a CSS length value (e.g. `"16px"` → 16, `"8px 16px"` →
/// 8). Saturates on overflow; non-numeric → 0.
fn parse_px(v: &str) -> u16 {
    let digits: String = v.trim().chars().take_while(|c| c.is_ascii_digit()).collect();
    digits.parse::<u16>().unwrap_or(0)
}

/// Parse a `"k: v; k2: v2"` inline-style string into a `BoxStyle`, inheriting
/// text style from the parent where the element doesn't override.
fn parse_box_style(style: &str, inherited: Style) -> BoxStyle {
    let mut bs = BoxStyle {
        dir: Dir::Column,
        gap: 0,
        pad_top: 0,
        pad_right: 0,
        pad_bottom: 0,
        pad_left: 0,
        fg: inherited.fg,
        bg: inherited.bg,
        bold: inherited.bold,
    };
    for decl in style.split(';') {
        let mut kv = decl.splitn(2, ':');
        let key = kv.next().unwrap_or("").trim();
        let val = kv.next().unwrap_or("").trim();
        match key {
            "flex-direction" => {
                if val == "row" {
                    bs.dir = Dir::Row;
                }
            }
            "gap" => bs.gap = parse_px(val),
            "padding" => {
                let p = parse_px(val);
                bs.pad_top = p;
                bs.pad_right = p;
                bs.pad_bottom = p;
                bs.pad_left = p;
            }
            "padding-top" => bs.pad_top = parse_px(val),
            "padding-right" => bs.pad_right = parse_px(val),
            "padding-bottom" => bs.pad_bottom = parse_px(val),
            "padding-left" => bs.pad_left = parse_px(val),
            "color" => bs.fg = parse_rgb(val).or(bs.fg),
            "background-color" | "background" => bs.bg = parse_rgb(val).or(bs.bg),
            "font-weight" => {
                if val == "bold" || val.parse::<u16>().map(|n| n >= 600).unwrap_or(false) {
                    bs.bold = true;
                }
            }
            _ => {}
        }
    }
    bs
}

fn style_attr<M>(attrs: &[Attribute<M>]) -> Option<&str> {
    attrs.iter().find_map(|a| match a {
        Attribute::Attr(k, v) if k == "style" => Some(v.as_str()),
        _ => None,
    })
}

/// Stack `blocks` vertically with `gap` blank rows between them.
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

/// Place `blocks` side by side with `gap` spaces between them. Shorter blocks
/// are bottom-padded with blank lines so rows align.
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

/// Wrap `inner` with padding rows/cols, filling the padded area with `bg`.
fn apply_padding(inner: Block, bs: &BoxStyle, self_style: Style) -> Block {
    let top = px_to_rows(bs.pad_top);
    let bottom = px_to_rows(bs.pad_bottom);
    let left = px_to_cols(bs.pad_left);
    let right = px_to_cols(bs.pad_right);
    let inner_w = inner.width();
    let total_w = inner_w + left + right;
    let pad_run = |w: usize| Run { text: " ".repeat(w), style: self_style };

    let mut out = Block::default();
    for _ in 0..top {
        out.lines.push(vec![pad_run(total_w)]);
    }
    for line in inner.lines {
        let mut row = Vec::new();
        if left > 0 {
            row.push(pad_run(left));
        }
        let mut lw = 0;
        for run in &line {
            lw += run.width();
        }
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

/// Render one `Html` node into a `Block`, cascading text style downward.
fn render_node<M>(node: &Html<M>, inherited: Style) -> Block {
    match node {
        Html::HText(t) => {
            let clean: String = t.chars().map(sanitize_rune).collect();
            Block::single(clean, inherited)
        }
        Html::HRaw(_) => Block::default(),
        Html::HElement(tag, attrs, kids) => {
            if tag == "style" || tag == "script" {
                return Block::default();
            }
            let bs = match style_attr(attrs) {
                Some(s) => parse_box_style(s, inherited),
                None => parse_box_style("", inherited),
            };
            let self_style = Style { fg: bs.fg, bg: bs.bg, bold: bs.bold };
            let child_blocks: Vec<Block> = kids
                .iter()
                .map(|k| render_node(k, self_style))
                .filter(|b| b.height() > 0)
                .collect();

            let mut inner = if child_blocks.is_empty() {
                // A box with no element children (e.g. an empty button) still
                // occupies its own style — render an empty single line so its
                // background paints.
                Block { lines: vec![Vec::new()] }
            } else {
                match bs.dir {
                    Dir::Column => vstack(child_blocks, px_to_rows(bs.gap).max(if bs.gap >= 8 { 1 } else { 0 })),
                    Dir::Row => hstack(child_blocks, px_to_cols(bs.gap)),
                }
            };

            // Paint this box's background across the full inner width so colour
            // fills are contiguous, then wrap with padding.
            let inner_w = inner.width();
            inner.pad_to_width(inner_w, bs.bg);
            apply_padding(inner, &bs, self_style)
        }
    }
}

const SGR_RESET: &str = "\x1b[0m";

fn sgr(style: Style) -> String {
    let mut codes: Vec<String> = Vec::new();
    if style.bold {
        codes.push("1".to_string());
    }
    if let Some(Rgb(r, g, b)) = style.fg {
        codes.push(format!("38;2;{r};{g};{b}"));
    }
    if let Some(Rgb(r, g, b)) = style.bg {
        codes.push(format!("48;2;{r};{g};{b}"));
    }
    if codes.is_empty() {
        String::new()
    } else {
        format!("\x1b[{}m", codes.join(";"))
    }
}

/// Render a `Std.Ui` Element (`Html<M>`) view into an ANSI frame string, clipped
/// to `cols` columns. Each painted run is bracketed with its SGR escape and a
/// reset, so styles never bleed across lines.
pub fn render_element<M>(view: &Html<M>, cols: usize) -> String {
    let block = render_node(view, Style::default());
    let mut out = String::new();
    for line in &block.lines {
        let mut col = 0usize;
        for run in line {
            if col >= cols {
                break;
            }
            // Clip the run so the line never exceeds `cols` display columns.
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

    fn div<M>(style: &str, kids: Vec<Html<M>>) -> Html<M> {
        Html::HElement("div".into(), vec![Attribute::Attr("style".into(), style.into())], kids)
    }

    #[test]
    fn text_renders_with_fg() {
        let t: Html<()> = div("color: rgb(255, 0, 0)", vec![Html::HText("hi".into())]);
        let frame = render_element(&t, 80);
        assert!(frame.contains("38;2;255;0;0"), "fg SGR present: {frame:?}");
        assert!(frame.contains("hi"));
    }

    #[test]
    fn column_stacks_vertically() {
        let t: Html<()> = div(
            "display: flex; flex-direction: column; gap: 16px",
            vec![
                div("", vec![Html::HText("a".into())]),
                div("", vec![Html::HText("b".into())]),
            ],
        );
        let frame = render_element(&t, 80);
        let lines: Vec<&str> = frame.split("\r\n").collect();
        // a, blank (gap), b → at least 3 lines.
        assert!(lines.len() >= 3, "stacked: {lines:?}");
        assert!(frame.find('a').unwrap_or(0) < frame.find('b').unwrap_or(0));
    }

    #[test]
    fn row_places_side_by_side() {
        let t: Html<()> = div(
            "display: flex; flex-direction: row; gap: 8px",
            vec![
                div("", vec![Html::HText("L".into())]),
                div("", vec![Html::HText("R".into())]),
            ],
        );
        let frame = render_element(&t, 80);
        let first = frame.split("\r\n").next().unwrap_or("");
        assert!(first.contains('L') && first.contains('R'), "same row: {first:?}");
    }

    #[test]
    fn clips_to_cols() {
        let t: Html<()> = div("", vec![Html::HText("abcdefghij".into())]);
        let frame = render_element(&t, 4);
        let first = frame.split("\r\n").next().unwrap_or("");
        // Only 4 display columns of content (escapes aside).
        let visible: String = first.chars().filter(|c| c.is_ascii_alphabetic()).collect();
        assert_eq!(visible, "abcd", "clipped: {first:?}");
    }

    #[test]
    fn ignores_style_child() {
        let t: Html<()> = div(
            "",
            vec![
                Html::HElement("style".into(), vec![], vec![Html::HText("x{}".into())]),
                div("", vec![Html::HText("real".into())]),
            ],
        );
        let frame = render_element(&t, 80);
        assert!(frame.contains("real"));
        assert!(!frame.contains("x{}"), "style child ignored: {frame:?}");
    }

    #[test]
    fn sanitizes_control_bytes() {
        let t: Html<()> = div("", vec![Html::HText("a\u{7}b".into())]);
        let frame = render_element(&t, 80);
        assert!(!frame.contains('\u{7}'), "control stripped: {frame:?}");
    }
}
