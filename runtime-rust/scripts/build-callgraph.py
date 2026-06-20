#!/usr/bin/env python3
"""Build the Sky compiler/runtime call graph artifacts from the swarm's markdown.

Input : a markdown call-graph dump (## phase / ### file / `- fn → callee, …`).
Output (into runtime-rust/docs/):
  compiler-call-graph.json  — processable {phases, nodes, edges} for further viz
  compiler-call-graph.dot   — graphviz source, clustered by compilation phase
(then `dot -Tsvg` → .svg, embedded into the zoomable .html — see the runner.)

Usage: build-callgraph.py <input.md> <out-dir>
"""
import json
import re
import sys

# Canonical compilation-phase order (the swarm's `ord` prefixes were unreliable).
PHASE_ORDER = [
    ("Parse", 1), ("Canonicalise", 2),
    ("Type — Constrain", 3), ("Type — Solve", 4),
    ("Type — Infer", 5),
    ("Build — Compile", 6), ("Build — FFI", 7),
    ("Generate — Go", 8), ("Generate — Rust (Kernel", 9),
    ("Generate — Rust (Types", 10),
    ("Tooling — LSP", 11), ("Tooling — Format", 12),
    ("Entry", 13),
    ("Runtime (Rust) — core", 14), ("Runtime (Rust) — Sky.Live", 15),
    ("Runtime (Rust) — Sky.Tui", 16),
    ("Runtime (Rust) — IO", 17), ("Runtime (Rust) — crypto", 18),
    ("Runtime (Rust) — UI", 19), ("Runtime (Go)", 20),
]


def phase_ord(name):
    # Longest canonical key that the phase name contains wins (so "Generate — Rust
    # (Kernel" beats "Generate — Rust (Types" correctly by exact-prefix length).
    best = (999, -1)
    for key, ordv in PHASE_ORDER:
        if key in name and len(key) > best[1]:
            best = (ordv, len(key))
    return best[0]


IDENT = re.compile(r"[A-Za-z_][A-Za-z0-9_.]*")
# prose tokens that are never real callees
NOISE = {"leaf", "self", "recursive", "re", "export", "no", "in", "slice", "calls",
         "only", "and", "the", "a", "via", "of", "plus", "lib", "otherwise", "etc",
         "stub", "empty", "pattern", "constraints", "live", "inline"}


def first_ident(seg):
    seg = seg.strip().strip("`")
    m = IDENT.match(seg)
    if not m:
        return None
    tok = m.group(0)
    if tok.lower() in NOISE or len(tok) < 2:
        return None
    return tok


def parse(md):
    phases = {}        # name -> {order, files:{path:[fn,...]}}
    nodes = {}         # id -> {phase, file}
    edges = set()      # (from, to)
    cur_phase = None
    cur_file = None
    for line in md.splitlines():
        m = re.match(r"^##\s+(?:\d+\.\s*)?(.+)$", line)
        if m and not line.startswith("###"):
            cur_phase = m.group(1).strip()
            phases.setdefault(cur_phase, {"order": phase_ord(cur_phase), "files": {}})
            cur_file = None
            continue
        m = re.match(r"^###\s+(.+)$", line)
        if m:
            cur_file = m.group(1).strip()
            if cur_phase:
                phases[cur_phase]["files"].setdefault(cur_file, [])
            continue
        m = re.match(r"^-\s+`?([A-Za-z_][A-Za-z0-9_.]*)`?\s*(?:→|->)\s*(.*)$", line)
        if m and cur_phase:
            src = m.group(1)
            rhs = m.group(2)
            nodes.setdefault(src, {"phase": cur_phase, "file": cur_file or ""})
            if cur_file and src not in phases[cur_phase]["files"].get(cur_file, []):
                phases[cur_phase]["files"].setdefault(cur_file, []).append(src)
            for seg in re.split(r"[,;]", rhs):
                tgt = first_ident(seg)
                if tgt and tgt != src:
                    edges.add((src, tgt))
                    nodes.setdefault(tgt, {"phase": "", "file": ""})
    return phases, nodes, edges


def to_json(phases, nodes, edges):
    return json.dumps({
        "phases": [
            {"name": n, "order": d["order"],
             "files": [{"path": p, "functions": fns} for p, fns in d["files"].items()]}
            for n, d in sorted(phases.items(), key=lambda kv: kv[1]["order"])
        ],
        "nodes": [{"id": k, **v} for k, v in sorted(nodes.items())],
        "edges": [{"from": a, "to": b} for a, b in sorted(edges)],
        "stats": {"phases": len(phases), "nodes": len(nodes), "edges": len(edges)},
    }, indent=2)


def san(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def to_dot(phases, nodes, edges):
    out = [
        "digraph sky_compiler {",
        '  graph [rankdir=LR, fontname="monospace", bgcolor="#0c0e14", '
        'fontcolor="#dfe3ee", compound=true, ranksep=1.2, nodesep=0.25];',
        '  node  [shape=box, style="rounded,filled", fontname="monospace", '
        'fontsize=9, color="#2a2f40", fillcolor="#161a24", fontcolor="#cfd6e6", '
        'margin="0.06,0.03"];',
        '  edge  [color="#33415588", arrowsize=0.5, penwidth=0.6];',
    ]
    pal = ["#8ec8a8", "#6496dc", "#dcb464", "#dc6464", "#b48edc", "#64c8c8"]
    declared = set()
    for pname, d in sorted(phases.items(), key=lambda kv: kv[1]["order"]):
        col = pal[d["order"] % len(pal)]
        out.append(f"  subgraph cluster_{d['order']} {{")
        out.append(f'    label={san(pname)}; fontcolor="{col}"; color="{col}55"; style="rounded";')
        for _p, fns in d["files"].items():
            for fn in fns:
                if fn not in declared:
                    out.append(f'    {san(fn)} [color="{col}66"];')
                    declared.add(fn)
        out.append("  }")
    for a, b in sorted(edges):
        out.append(f"  {san(a)} -> {san(b)};")
    out.append("}")
    return "\n".join(out)


def main():
    md = open(sys.argv[1]).read()
    outdir = sys.argv[2].rstrip("/")
    phases, nodes, edges = parse(md)
    open(f"{outdir}/compiler-call-graph.json", "w").write(to_json(phases, nodes, edges))
    open(f"{outdir}/compiler-call-graph.dot", "w").write(to_dot(phases, nodes, edges))
    print(f"phases={len(phases)} nodes={len(nodes)} edges={len(edges)}")


if __name__ == "__main__":
    main()
