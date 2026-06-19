#!/usr/bin/env python3
"""Regenerate the machine-owned tables in runtime-rust/README.md from CI sweep data.

This is the SINGLE writer of the fenced AUTOGEN regions in README.md. Everything
else in README from `## Getting started` down is hand-written by the
`sky-rust-backend:update-docs` skill; this script owns ONLY the content between
`<!-- AUTOGEN:<id> BEGIN -->` / `<!-- AUTOGEN:<id> END -->` fences. update-docs
delegates those regions to this script instead of hand-writing them, so the table
DATA has one source of truth (the CI result files) and the surrounding PROSE has
another (update-docs). No history/dates/SHAs ever enter a fenced region.

Currently owned regions:
  - AUTOGEN:static-table  — the CI cross-OS static-build table, rendered from the
                            three `static-perf-<OS>-*.tsv` artifacts.

Companion drift check (NO write — keeps editorial prose consistency in human hands):
  - `headline-check` reads the latest examples-sweep scoreboard + perf TSV and
    reports (to a GitHub job summary) whether the committed README sweep headline
    and perf numbers have drifted, so `update-docs` is run to reconcile the table
    AND its prose together. We do NOT auto-write the examples/perf table: its perf
    numbers are noisy run-to-run and live next to hand-written perf headlines that
    only update-docs can keep in sync — a blind auto-write would desync them.

Usage:
  readme-tables.py static        [--results DIR] [--readme PATH] [--write | --check]
  readme-tables.py headline-check [--results DIR] [--readme PATH]   # always exit 0; prints markdown

`--results DIR` defaults to ~/.cache/sky (the local sweep cache). On CI, point it
at the directory holding the downloaded `static-perf-*` / `examples-*` artifacts;
the script globs recursively, so per-artifact subdirectories are fine.

Exit codes:
  0  success / in-sync (or write made/no-op)
  3  --check found drift (the fenced region is stale)
  4  usage / IO error
"""

from __future__ import annotations

import argparse
import glob
import math
import os
import platform
import re
import sys
import tempfile

# Canonical render order. Rows present in the TSVs are emitted in this order;
# anything unexpected is appended afterwards (alphabetically) so new data never
# silently vanishes.
OS_ORDER = ["Linux", "Windows", "macOS"]
EXAMPLE_ORDER = [
    "01-hello-world",
    "15-http-server",
    "18-job-queue",
    "21-tui-stopwatch",
    "33-websocket-echo",
]

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
DEFAULT_README = os.path.join(REPO_ROOT, "runtime-rust", "README.md")
DEFAULT_RESULTS = os.path.expanduser("~/.cache/sky")
DEFAULT_SIDECAR = os.path.join(os.path.dirname(__file__), "readme-examples.tsv")

# Parity verdict: default ±10% band on the geometric mean of per-example Rust/Go
# ratios. Aggregating with the GEOMETRIC mean (not arithmetic) is the standard way
# to summarise normalised/ratio benchmark numbers (Fleming & Wallace, CACM 1986;
# SPEC CPU). ±10% is conservative enough to absorb shared-CI throughput noise
# without calling a real difference "parity". Override with --band.
DEFAULT_BAND = 0.10

# The four perf columns ↔ the perf-TSV metric names, with the "good" direction.
# "up" = higher Rust/Go is better (throughput); "down" = lower is better.
PERF_METRICS = {
    "throughput": {"col": "thru", "dir": "up", "dp": 2},
    "rss": {"col": "rss", "dir": "down", "dp": 2},
    "coldstart": {"col": "cold", "dir": "down", "dp": 2},
    "binsize": {"col": "bin", "dir": "down", "dp": 3},
}


# ── small helpers ────────────────────────────────────────────────────────────
def _write_atomic(path: str, text: str) -> None:
    """Write to a temp file in the same dir, then os.replace — so an interrupted
    write can't truncate README.md (this script is its SINGLE writer for the
    AUTOGEN region, so a half-write corrupts the committed doc)."""
    d = os.path.dirname(os.path.abspath(path)) or "."
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".readme-tables.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(text)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def _num(s: str):
    """Parse a possibly-empty TSV cell as float; return None if blank/non-numeric."""
    s = (s or "").strip()
    if not s:
        return None
    try:
        return float(s)
    except ValueError:
        return None


def _kib(bytes_str: str) -> str:
    n = _num(bytes_str)
    return f"{round(n / 1024)}K" if n is not None else "—"


def _arrow(dyn: str, static: str, as_int: bool = True) -> str:
    """Render a `dyn→static` cell, or `—` when either side is missing."""
    d, s = _num(dyn), _num(static)
    if d is None or s is None:
        return "—"
    if as_int:
        return f"{round(d)}→{round(s)}"
    return f"{d:g}→{s:g}"


def newest(results_root: str, *patterns: str):
    """Newest file matching any of the (recursive) globs under results_root, or None."""
    hits = []
    for pat in patterns:
        hits += glob.glob(os.path.join(results_root, pat), recursive=True)
    hits = [h for h in hits if os.path.isfile(h)]
    if not hits:
        return None
    return max(hits, key=os.path.getmtime)


def read_provenance(results_root: str, *patterns: str):
    """Newest matching *.provenance → dict (stamp/os/arch/runner), or {} if none."""
    f = newest(results_root, *patterns)
    if not f:
        return {}
    prov = {}
    with open(f, encoding="utf-8") as fh:
        for ln in fh:
            if "=" in ln:
                k, v = ln.rstrip("\n").split("=", 1)
                prov[k] = v
    return prov


def provenance_banner(results_root: str, sweep: str, tsv_for_fallback: str | None) -> str:
    """A one-line italic banner: WHERE + WHEN the numbers were machine-measured."""
    if sweep == "static-perf":
        prov = read_provenance(results_root, "**/static-perf-*-*.provenance", "static-perf-*-*.provenance")
    else:
        prov = read_provenance(results_root, "**/perf-*.provenance", "**/examples-perf-sweep/perf-*.provenance")
    stamp = prov.get("stamp")
    if not stamp and tsv_for_fallback:  # derive from the TSV filename: perf-<stamp>.tsv
        m = re.search(r"(\d{8}T\d{6}Z)", os.path.basename(tsv_for_fallback))
        stamp = m.group(1) if m else "unknown"
    # No provenance file ⇒ a local --write seed measured on THIS host (downloaded
    # CI artifacts always carry provenance). Fill from the local platform so the
    # banner honestly names where it ran, per spec §4. CI provenance overrides.
    runner = prov.get("runner") or platform.node() or "local"
    osname = prov.get("os") or platform.system() or "?"
    arch = prov.get("arch") or platform.machine() or "?"
    return (
        f"> _Machine-measured · {stamp or 'unknown'} · {runner} {osname} ({arch}) · "
        f"{sweep} — regenerated by `readme-tables.py`, not hand-edited._"
    )


def read_tsv(path: str):
    """Read a header+rows TSV into a list of dicts keyed by the header row."""
    with open(path, encoding="utf-8") as fh:
        lines = [ln.rstrip("\n") for ln in fh if ln.strip()]
    if not lines:
        return []
    header = lines[0].split("\t")
    rows = []
    for ln in lines[1:]:
        cells = ln.split("\t")
        cells += [""] * (len(header) - len(cells))
        rows.append(dict(zip(header, cells)))
    return rows


# ── fence splicing ───────────────────────────────────────────────────────────
def fence_re(region_id: str) -> re.Pattern:
    return re.compile(
        r"(<!-- AUTOGEN:" + re.escape(region_id) + r" BEGIN -->\n)"
        r".*?"
        r"(\n<!-- AUTOGEN:" + re.escape(region_id) + r" END -->)",
        re.DOTALL,
    )


def splice(text: str, region_id: str, body: str) -> str:
    pat = fence_re(region_id)
    if not pat.search(text):
        raise SystemExit(
            f"error: AUTOGEN:{region_id} fence not found in README — "
            f"add the BEGIN/END comment markers around the table first."
        )
    # body is the inner content (no surrounding newlines); fences supply them.
    return pat.sub(lambda m: m.group(1) + body + m.group(2), text)


def current_region(text: str, region_id: str) -> str | None:
    m = fence_re(region_id).search(text)
    if not m:
        return None
    # Inner content is everything between the two captured fence lines.
    whole = m.group(0)
    inner = whole[len(m.group(1)) : len(whole) - len(m.group(2))]
    return inner


# ── static cross-OS table ────────────────────────────────────────────────────
def render_static_table(results_root: str) -> str | None:
    """Build the static-build table body from the three static-perf-<OS>-*.tsv.

    Returns the markdown table (header + rows) as a string, or None if no
    static-perf TSV is available (so callers can no-op instead of blanking).
    """
    by_os: dict[str, str] = {}
    for label in OS_ORDER:
        f = newest(results_root, f"**/static-perf-{label}-*.tsv", f"static-perf-{label}-*.tsv")
        if f:
            by_os[label] = f
    if not by_os:
        return None

    note = (
        "<!-- Machine-generated by runtime-rust/scripts/readme-tables.py from the CI\n"
        "     static-perf artifacts. Do NOT hand-edit between these fences — edits are\n"
        "     overwritten on the next `static-perf` workflow run. -->"
    )
    header = (
        "| OS | Example | Shape | Build | Bin (static) | Static/Dyn | "
        "Thru s/d | RSS s/d (MB) | Cold d→s (ms) |\n"
        "|---|---|---|:-:|--:|--:|--:|--:|--:|"
    )
    banner = provenance_banner(results_root, "static-perf", by_os.get("Linux"))
    lines = [note, banner, "", header]

    for label in OS_ORDER:
        path = by_os.get(label)
        if not path:
            continue
        rows = {r["example"]: r for r in read_tsv(path)}
        ordered = [e for e in EXAMPLE_ORDER if e in rows]
        ordered += sorted(e for e in rows if e not in EXAMPLE_ORDER)
        for ex in ordered:
            r = rows[ex]
            built = (r.get("build_static") or "").strip() == "ok"
            build_cell = "✅" if built else "❌"
            ratio = "—"
            d, s = _num(r.get("dyn_bytes")), _num(r.get("static_bytes"))
            if d and s:
                star = "*" if label == "macOS" else ""
                ratio = f"{s / d:.2f}{star}"
            lines.append(
                "| {os} | {ex} | {shape} | {build} | {bin} | {ratio} | "
                "{thru} | {rss} | {cold} |".format(
                    os=label,
                    ex=ex,
                    shape=r.get("shape", "").strip() or "—",
                    build=build_cell,
                    bin=_kib(r.get("static_bytes")),
                    ratio=ratio,
                    thru=_arrow(r.get("thru_dyn"), r.get("thru_static")),
                    rss=_arrow(r.get("rss_dyn_mb"), r.get("rss_static_mb")),
                    cold=_arrow(r.get("cold_dyn_ms"), r.get("cold_static_ms")),
                )
            )
    return "\n".join(lines)


def cmd_static(args) -> int:
    with open(args.readme, encoding="utf-8") as fh:
        text = fh.read()

    body = render_static_table(args.results)
    if body is None:
        print(
            f"static: no static-perf TSV under {args.results} — leaving the table unchanged.",
            file=sys.stderr,
        )
        return 0

    new_text = splice(text, "static-table", body)

    if args.check:
        if new_text != text:
            cur = (current_region(text, "static-table") or "").strip()
            fresh = body.strip()
            print("DRIFT: AUTOGEN:static-table is stale.\n")
            print("--- committed ---\n" + cur + "\n\n--- from latest TSVs ---\n" + fresh)
            return 3
        print("static-table: in sync.")
        return 0

    if new_text == text:
        print("static-table: already up to date (no write).")
        return 0
    _write_atomic(args.readme, new_text)
    print(f"static-table: wrote refreshed table to {args.readme}")
    return 0


# ── examples/perf table (fully auto-written) + parity verdict ────────────────
def read_perf(results_root: str):
    """Return {example: {metric: ratio_str}} from the newest perf-*.tsv, or None.

    ratio_str is the raw column-5 cell: a numeric Rust/Go ratio, or the literal
    "n/a" when the metric was measured but the probe couldn't compare. A metric
    absent for an example means it was never measured for that shape.
    """
    f = newest(results_root, "**/perf-*.tsv", "**/examples-perf-sweep/perf-*.tsv")
    if not f:
        return None
    table: dict[str, dict[str, str]] = {}
    with open(f, encoding="utf-8") as fh:
        for ln in fh:
            cells = ln.rstrip("\n").split("\t")
            if len(cells) < 5:
                continue
            ex, metric, ratio = cells[0], cells[1], cells[4].strip()
            table.setdefault(ex, {})[metric] = ratio
    return table


def read_sidecar(path: str):
    """Ordered [(example, shape, roundtrip, equiv_cell)] from the editorial sidecar."""
    rows = []
    with open(path, encoding="utf-8") as fh:
        for ln in fh:
            ln = ln.rstrip("\n")
            if not ln or ln.lstrip().startswith("#"):
                continue
            cells = ln.split("\t")
            cells += [""] * (4 - len(cells))
            rows.append(tuple(cells[:4]))
    return rows


def _perf_cell(perf_row: dict, metric: str, dp: int, arrow: bool = False) -> str:
    """Format one perf column. — = unmeasured · n/a = measured-but-incomparable."""
    if not perf_row or metric not in perf_row:
        return "—"
    raw = perf_row[metric]
    val = _num(raw)
    if val is None:
        return "n/a" if raw.strip() == "n/a" else "—"
    cell = f"{val:.{dp}f}"
    if arrow:  # throughput: append × and bold a clear win (≥2×)
        cell = f"{cell}×"
        if val >= 2.0:
            cell = f"**{cell}**"
    return cell


def render_examples_table(results_root: str, sidecar_path: str) -> str | None:
    """Build the BUILD·RUN·EQUIV+perf table from the sidecar ⋈ the perf TSV.

    Build/Run hardcode ✅ — the CI update-readme job writes this ONLY on a green
    sweep (`needs: examples-sweep`), so every listed example is passing at write
    time. Returns None if no perf TSV is available (so callers no-op rather than
    blanking the perf columns)."""
    perf = read_perf(results_root)
    if perf is None:
        return None
    sidecar = read_sidecar(sidecar_path)

    note = (
        "<!-- Machine-generated by runtime-rust/scripts/readme-tables.py: the "
        "editorial\n     columns come from runtime-rust/scripts/readme-examples.tsv, "
        "the perf\n     ratios from the latest CI perf TSV. Do NOT hand-edit between "
        "these fences. -->"
    )
    header = (
        "| Build | Run | Example | Shape | Round-trip | Equiv | "
        "Thru ↑ | RSS ↓ | Cold ↓ | Bin ↓ |\n"
        "|:-:|:-:|---|---|---|---|:-:|:-:|:-:|:-:|"
    )
    banner = provenance_banner(results_root, "examples-perf-sweep",
                               newest(results_root, "**/perf-*.tsv", "**/examples-perf-sweep/perf-*.tsv"))
    lines = [note, banner, "", header]
    listed = {ex for ex, *_ in sidecar}
    for ex, shape, rt, equiv in sidecar:
        pr = perf.get(ex, {})
        lines.append(
            "| ✅ | ✅ | {ex} | {shape} | {rt} | {equiv} | {thru} | {rss} | {cold} | {bin} |".format(
                ex=ex, shape=shape, rt=rt, equiv=equiv,
                thru=_perf_cell(pr, "throughput", 2, arrow=True),
                rss=_perf_cell(pr, "rss", 2),
                cold=_perf_cell(pr, "coldstart", 2),
                bin=_perf_cell(pr, "binsize", 3),
            )
        )
    # Loud about any measured example missing from the sidecar — never drop it silently.
    missing = sorted(set(perf) - listed)
    if missing:
        print(
            f"warning: perf TSV has examples absent from {os.path.basename(sidecar_path)} "
            f"(add them there to surface in the table): {', '.join(missing)}",
            file=sys.stderr,
        )
    return "\n".join(lines)


def _geomean(vals):
    return math.exp(sum(math.log(v) for v in vals) / len(vals)) if vals else None


def render_perf_verdict(results_root: str, band: float) -> str | None:
    """Per-metric 3-state parity verdict from the geomean of Rust/Go ratios."""
    perf = read_perf(results_root)
    if perf is None:
        return None

    pct = f"±{round(band * 100)}%"
    note = (
        "<!-- Machine-generated by runtime-rust/scripts/readme-tables.py from the CI "
        "perf TSV.\n     Do NOT hand-edit between these fences. -->"
    )
    banner = provenance_banner(results_root, "examples-perf-sweep",
                               newest(results_root, "**/perf-*.tsv", "**/examples-perf-sweep/perf-*.tsv"))
    lines = [
        note,
        banner,
        "",
        f"**Performance verdict** — Rust vs Go, geometric mean of the per-example "
        f"Rust/Go ratios (parity band {pct}):",
        "",
    ]
    labels = {
        "throughput": "Throughput",
        "rss": "Memory / RSS",
        "coldstart": "Cold-start",
        "binsize": "Binary size",
    }
    for metric, meta in PERF_METRICS.items():
        ratios = []
        for ex_metrics in perf.values():
            v = _num(ex_metrics.get(metric))
            if v is not None and v > 0:
                ratios.append(v)
        g = _geomean(ratios)
        if g is None:
            continue
        better = (g >= 1 + band) if meta["dir"] == "up" else (g <= 1 - band)
        worse = (g <= 1 - band) if meta["dir"] == "up" else (g >= 1 + band)
        verdict = (
            "**Rust outperforms Go**" if better
            else "**Rust underperforms Go**" if worse
            else "**Rust at parity with Go**"
        )
        arrow = "↑ better" if meta["dir"] == "up" else "↓ better"
        lines.append(
            f"- **{labels[metric]}** ({arrow}): {verdict} — geomean "
            f"{g:.{meta['dp']}f}× across {len(ratios)} examples."
        )
    return "\n".join(lines)


def cmd_examples(args) -> int:
    with open(args.readme, encoding="utf-8") as fh:
        text = fh.read()

    tbl = render_examples_table(args.results, args.sidecar)
    verdict = render_perf_verdict(args.results, args.band)
    if tbl is None or verdict is None:
        print(
            f"examples: no perf-*.tsv under {args.results} — leaving the table + "
            f"verdict unchanged.",
            file=sys.stderr,
        )
        return 0

    new_text = splice(splice(text, "examples-table", tbl), "perf-verdict", verdict)

    if args.check:
        if new_text != text:
            print("DRIFT: AUTOGEN:examples-table / perf-verdict is stale vs the latest perf TSV.")
            return 3
        print("examples-table + perf-verdict: in sync.")
        return 0

    if new_text == text:
        print("examples-table + perf-verdict: already up to date (no write).")
        return 0
    _write_atomic(args.readme, new_text)
    print(f"examples-table + perf-verdict: wrote refreshed content to {args.readme}")
    return 0


# ── examples/perf headline drift check (no write) ────────────────────────────
def cmd_headline_check(args) -> int:
    """Report (markdown, exit 0) whether the README sweep headline + perf numbers
    have drifted from the latest examples-sweep data — a signal to run update-docs.
    NEVER writes: the examples/perf table sits next to hand-written prose that only
    update-docs can keep consistent."""
    out = ["### README sync check"]

    with open(args.readme, encoding="utf-8") as fh:
        text = fh.read()

    # Sweep headline: latest scoreboard green/red vs the README's stated counts.
    score = newest(args.results, "**/scoreboard.tsv", "**/examples-sweep/scoreboard.tsv")
    if score:
        with open(score, encoding="utf-8") as fh:
            last = [ln for ln in fh if ln.strip()]
        green = red = None
        if last:
            fields = last[-1].split("\t")
            for f in fields:
                if f.startswith("green="):
                    green = f.split("=", 1)[1]
                elif f.startswith("red="):
                    red = f.split("=", 1)[1]
        m = re.search(r"examples-sweep\s*=\s*(\d+)\s*green\s*·\s*(\d+)\s*red", text)
        readme_green = m.group(1) if m else "?"
        readme_red = m.group(2) if m else "?"
        if green is not None and (green != readme_green or red != readme_red):
            out.append(
                f"- ⚠️ **Sweep headline stale** — README says `{readme_green} green · "
                f"{readme_red} red`; latest sweep is `{green} green · {red} red`. "
                f"Run `sky-rust-backend:update-docs`."
            )
        elif green is not None:
            out.append(f"- ✅ Sweep headline in sync (`{green} green · {red} red`).")
    else:
        out.append("- _No scoreboard.tsv in results — sweep headline not checked._")

    # Perf freshness: note the latest perf TSV stamp + where the auto-write happens.
    perf = newest(args.results, "**/perf-*.tsv", "**/examples-perf-sweep/perf-*.tsv")
    if perf:
        out.append(
            f"- ℹ️ Latest perf TSV: `{os.path.basename(perf)}`. The examples/perf table + "
            f"verdict are auto-written by the `update-readme` job on workflow_dispatch / "
            f"schedule (not on push — push runs no perf sweep)."
        )

    print("\n".join(out))
    return 0


# ── CLI ──────────────────────────────────────────────────────────────────────
def main(argv) -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    def common(sp):
        sp.add_argument("--results", default=DEFAULT_RESULTS, help="dir holding the CI result files (recursive)")
        sp.add_argument("--readme", default=DEFAULT_README, help="path to README.md")

    sp_static = sub.add_parser("static", help="regenerate the cross-OS static-build table")
    common(sp_static)
    mode = sp_static.add_mutually_exclusive_group()
    mode.add_argument("--write", action="store_true", help="write the refreshed table in place (default)")
    mode.add_argument("--check", action="store_true", help="exit 3 if the committed table is stale")

    sp_ex = sub.add_parser("examples", help="regenerate the examples/perf table + parity verdict")
    common(sp_ex)
    sp_ex.add_argument("--sidecar", default=DEFAULT_SIDECAR, help="editorial sidecar TSV")
    sp_ex.add_argument("--band", type=float, default=DEFAULT_BAND, help="parity band (fraction, e.g. 0.10)")
    exmode = sp_ex.add_mutually_exclusive_group()
    exmode.add_argument("--write", action="store_true", help="write the refreshed table + verdict (default)")
    exmode.add_argument("--check", action="store_true", help="exit 3 if the committed content is stale")

    sp_head = sub.add_parser("headline-check", help="report sweep-headline / perf drift (no write, exit 0)")
    common(sp_head)

    args = p.parse_args(argv)
    try:
        if args.cmd == "static":
            return cmd_static(args)
        if args.cmd == "examples":
            return cmd_examples(args)
        if args.cmd == "headline-check":
            return cmd_headline_check(args)
    except FileNotFoundError as e:
        print(f"error: {e}", file=sys.stderr)
        return 4
    return 4


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
