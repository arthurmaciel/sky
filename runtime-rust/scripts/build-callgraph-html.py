#!/usr/bin/env python3
"""Embed the rendered call-graph SVG into a self-contained, infinitely-zoomable
HTML (no CDN / no JS deps — viewBox-based wheel-zoom + drag-pan).

Usage: build-callgraph-html.py <in.svg> <out.html>
"""
import re
import sys

svg = open(sys.argv[1]).read()
# Drop the XML/doctype preamble; keep from <svg ...>.
i = svg.find("<svg")
svg = svg[i:] if i >= 0 else svg
# Make the SVG fill its container + keep its viewBox (dot emits one).
svg = re.sub(r'<svg\b[^>]*?\bwidth="[^"]*"', "<svg", svg, count=1)
svg = re.sub(r'<svg\b([^>]*?)\bheight="[^"]*"', r"<svg\1", svg, count=1)
svg = svg.replace("<svg", '<svg id="cg" preserveAspectRatio="xMidYMid meet" '
                          'style="width:100%;height:100%;display:block"', 1)

HTML = """<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<title>Sky compiler — call graph by compilation phase</title>
<style>
  html,body{{margin:0;height:100%;background:#0c0e14;color:#dfe3ee;
    font:13px/1.4 ui-monospace,SFMono-Regular,Menlo,monospace}}
  #bar{{position:fixed;top:0;left:0;right:0;z-index:10;display:flex;gap:14px;
    align-items:center;padding:8px 14px;background:#12141cdd;border-bottom:1px solid #2a2f40;
    backdrop-filter:blur(4px)}}
  #bar b{{color:#8ec8a8}} #bar .s{{color:#7a86a8}}
  #bar button{{background:#1a1f2c;color:#cfd6e6;border:1px solid #2a2f40;border-radius:4px;
    padding:3px 9px;cursor:pointer;font:inherit}} #bar button:hover{{border-color:#6496dc}}
  #wrap{{position:fixed;inset:42px 0 0 0;overflow:hidden;cursor:grab}}
  #wrap.drag{{cursor:grabbing}}
  #hint{{position:fixed;bottom:8px;right:12px;color:#56607a;font-size:11px}}
</style></head>
<body>
<div id="bar">
  <b>Sky compiler · call graph by phase</b>
  <span class="s">{stats}</span>
  <button onclick="zoom(1.25)">+</button>
  <button onclick="zoom(0.8)">&minus;</button>
  <button onclick="reset()">reset</button>
  <span class="s">{note}</span>
</div>
<div id="wrap">{svg}</div>
<div id="hint">scroll = zoom · drag = pan</div>
<script>
const svg = document.getElementById('cg'), wrap = document.getElementById('wrap');
let vb = svg.getAttribute('viewBox').split(/[ ,]+/).map(Number); // [x,y,w,h]
const home = vb.slice();
function apply(){{ svg.setAttribute('viewBox', vb.join(' ')); }}
function reset(){{ vb = home.slice(); apply(); }}
function zoom(f, cx, cy){{
  const r = wrap.getBoundingClientRect();
  // zoom toward (cx,cy) screen point, default = center
  const px = (cx==null? r.width/2 : cx - r.left) / r.width;
  const py = (cy==null? r.height/2: cy - r.top ) / r.height;
  const nx = vb[0] + vb[2]*px, ny = vb[1] + vb[3]*py;
  vb[2] /= f; vb[3] /= f;
  vb[0] = nx - vb[2]*px; vb[1] = ny - vb[3]*py;
  apply();
}}
wrap.addEventListener('wheel', e => {{ e.preventDefault();
  zoom(e.deltaY < 0 ? 1.15 : 1/1.15, e.clientX, e.clientY); }}, {{passive:false}});
let pan=null;
wrap.addEventListener('mousedown', e => {{ pan=[e.clientX,e.clientY]; wrap.classList.add('drag'); }});
addEventListener('mouseup', () => {{ pan=null; wrap.classList.remove('drag'); }});
addEventListener('mousemove', e => {{ if(!pan) return;
  const r = wrap.getBoundingClientRect();
  vb[0] -= (e.clientX-pan[0]) * vb[2]/r.width;
  vb[1] -= (e.clientY-pan[1]) * vb[3]/r.height;
  pan=[e.clientX,e.clientY]; apply(); }});
</script>
</body></html>
"""

stats = sys.argv[3] if len(sys.argv) > 3 else ""
note = sys.argv[4] if len(sys.argv) > 4 else ""
open(sys.argv[2], "w").write(HTML.format(svg=svg, stats=stats, note=note))
print("wrote", sys.argv[2])
