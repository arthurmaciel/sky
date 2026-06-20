#!/usr/bin/env python3
"""Canonicalise a Sky.Live page's #sky-root subtree for Go≡Rust equivalence.

The Go and Rust backends are committed to BEHAVIOURAL parity, not byte-identical
output: several surface forms are legitimate implementation freedoms that this
normaliser collapses so a diff shows only behaviourally-meaningful divergences:

  * sky-id separators — Go `r.1#div.15`, Rust `r_1_div_15` encode the SAME
    structural path; collapse `#`/`.` → `_`. (machine-internal id; never user-seen)
  * attribute order — both sort for self-determinism (map/HashMap randomisation);
    the specific order is arbitrary. Sort alphabetically on both sides.
  * event wire-encoding — Go `sky-click="Dec"` (Msg) + `_click`-suffixed hid vs
    Rust `sky-click="click"` + `data-sky-on`. Same behaviour; canonicalise to the
    SET of event TYPES the element handles (`data-events="click,input"`).
  * pseudo-class / media-query / animation / transition STYLE DELIVERY — Go emits
    a scoped <style> child; Rust emits `data-sky-*-rules` attributes the client
    turns into CSS. Same visual; drop both delivery forms.
  * SVG chart coordinates — MASKED. They carry a KNOWN Go float→int truncation
    (Math.min/max + bar-height AsInt; upstream anzellai/sky PR #136). Compared
    structurally, not by value, until that fix syncs. TODO: un-mask the SVG_COORD
    values once the Go fix lands so coordinate regressions are caught too.

What SURVIVES normalisation (the meaningful surface a regression test must guard):
element structure + nesting, text content (e.g. a <textarea>'s value as content),
inline `style=` layout, user attrs (data-test-id, href, …), and which events each
element handles. The textarea-value and console-badge regressions both surface here.

Usage:  equiv_normalize_html.py <page.html>   # prints the canonical #sky-root form
"""
import sys
import re
from html.parser import HTMLParser

SKYID_KEYS = ('sky-id', 'data-sky-hid', 'data-sky-pc', 'data-sky-mq',
              'data-sky-anim', 'data-sky-tr', 'data-sky-key')
VOID = {'area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input',
        'link', 'meta', 'param', 'source', 'track', 'wbr'}
DELIVERY_ATTRS = ('data-sky-pc-rules', 'data-sky-mq-q', 'data-sky-mq-rules',
                  'data-sky-tr-rules', 'data-sky-tr-respect', 'data-sky-anim-name',
                  'data-sky-anim-rules', 'data-sky-anim-keyframes')
GO_STYLE_SCOPE = ('data-sky-pc', 'data-sky-mq', 'data-sky-anim', 'data-sky-tr')
SVG_COORD = {'d', 'x', 'y', 'x1', 'y1', 'x2', 'y2', 'cx', 'cy', 'r', 'rx', 'ry',
             'width', 'height', 'points', 'fill-opacity', 'stroke-width',
             'offset', 'viewBox', 'dx', 'dy'}
SVG_TAGS = ('svg', 'path', 'rect', 'circle', 'line', 'polyline', 'polygon', 'text', 'g')


def norm_skyid(v):
    return v.replace('#', '_').replace('.', '_')


def norm_style_text(t):
    return re.sub(r'sky-id="([^"]*)"', lambda m: 'sky-id="%s"' % norm_skyid(m.group(1)), t)


class Norm(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=False)
        self.out = []
        self.in_style = False
        self.style_buf = []
        self.svg_depth = 0
        self.suppress = 0

    def handle_starttag(self, tag, attrs):
        self._emit(tag, attrs, tag in VOID)

    def handle_startendtag(self, tag, attrs):
        self._emit(tag, attrs, True)

    def _emit(self, tag, attrs, selfclose):
        # Drop a Go pseudo/mq/anim/tr <style> delivery child entirely.
        if tag == 'style' and any(k in GO_STYLE_SCOPE for k, _ in attrs):
            self.suppress += 0 if selfclose else 1
            return
        if tag == 'svg':
            self.svg_depth += 1
        norm = []
        events = set()
        in_svg = self.svg_depth > 0 or tag in SVG_TAGS
        for k, v in attrs:
            if v is None:
                v = ''
            if k in ('data-sky-on', 'data-sky-hid') or k in DELIVERY_ATTRS:
                continue
            if k.startswith('sky-') and k != 'sky-id' and k != 'sky-key':
                events.add(k[4:])
                continue
            if k in SKYID_KEYS:
                v = norm_skyid(v)
            elif in_svg and k in SVG_COORD:
                v = '#'  # mask known-divergent chart coords (Go bug, PR #136)
            norm.append((k, v))
        if events:
            norm.append(('data-events', ','.join(sorted(events))))
        norm.sort(key=lambda kv: kv[0])
        s = '<' + tag
        for k, v in norm:
            s += ' %s="%s"' % (k, v)
        s += ' />' if selfclose else '>'
        self.out.append(s)
        if tag == 'style':
            self.in_style = True
            self.style_buf = []

    def handle_endtag(self, tag):
        if tag == 'svg' and self.svg_depth > 0:
            self.svg_depth -= 1
        if tag == 'style' and self.suppress > 0:
            self.suppress -= 1
            return
        if tag == 'style' and self.in_style:
            self.out.append(norm_style_text(''.join(self.style_buf)))
            self.in_style = False
        self.out.append('</%s>' % tag)

    def handle_data(self, d):
        if self.suppress > 0:
            return
        (self.style_buf if self.in_style else self.out).append(d)

    def handle_entityref(self, n):
        if self.suppress > 0:
            return
        (self.style_buf if self.in_style else self.out).append('&%s;' % n)

    def handle_charref(self, n):
        if self.suppress > 0:
            return
        (self.style_buf if self.in_style else self.out).append('&#%s;' % n)


def extract_sky_root(html):
    """Return the #sky-root element subtree (the rendered Std.Ui view), or '' —
    we compare the VIEW, not the page shell (Go inlines client JS, Rust externalises
    it; the shell legitimately differs)."""
    i = html.find('id="sky-root"')
    if i < 0:
        return ''
    s = html.rfind('<', 0, i)
    tagre = re.compile(r'<(/?)([a-zA-Z][\w-]*)([^>]*?)(/?)>')
    pos, depth, started, out = s, 0, False, []
    n = len(html)
    while pos < n:
        m = tagre.search(html, pos)
        if not m:
            break
        out.append(html[pos:m.end()])
        pos = m.end()
        closing = m.group(1) == '/'
        selfclose = m.group(4) == '/'
        tag = m.group(2)
        if not selfclose and tag not in VOID:
            depth += -1 if closing else 1
            started = True
            if started and depth == 0:
                break
    return ''.join(out)


def normalize(path):
    html = open(path, encoding='utf-8', errors='replace').read()
    root = extract_sky_root(html)
    p = Norm()
    p.feed(root)
    p.close()
    return re.sub(r'>(?=<)', '>\n', ''.join(p.out))


if __name__ == '__main__':
    sys.stdout.write(normalize(sys.argv[1]))
