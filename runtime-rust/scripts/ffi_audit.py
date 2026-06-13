#!/usr/bin/env python3
"""
ffi_audit.py — measure Sky -> Rust auto-FFI coverage across a sample of crates.

Runs the Sky Rust FFI inspector (sky-ffi-inspect-rs) on each crate, caches the
per-crate JSON, and summarizes WHAT BINDS: kept functions split into
free / constructor-like / accessor-only, plus a rough usability verdict.

Why "shape", not "% kept": the inspector emits only the KEPT (auto-bindable)
functions; it does not report why a function dropped. But the *shape* of what
survives already reveals usability — a crate that keeps only error-accessor
methods (axum keeps 56, all peripheral) is unusable for building anything,
even though "56 kept" sounds healthy. A precise drop-reason histogram would
need an inspector `--audit` mode (see SKILL.md, future work).

The run is RESUMABLE and supports PARTIAL SUMMARIES: each crate's result is
cached, already-done crates are skipped, and `summary` works at any time over
whatever has completed so far.

Usage:
  ffi_audit.py run     [--crates a,b,c] [--timeout 300] [--force] [--results-dir DIR]
  ffi_audit.py summary [--results-dir DIR] [--md]
  ffi_audit.py list
"""

from __future__ import annotations
import argparse
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

# ---------------------------------------------------------------------------
# The ~50-crate sample, grouped by class. The classes map to the strategic
# alternatives (see runtime-rust/README.md "FFI reach"):
#   leaf     -> expected fully auto-bindable (Alt 1 universe)
#   generic  -> stresses monomorphization-on-demand (Alt 1 extension)
#   serde    -> trait/derive-heavy data formats
#   client   -> client SDKs / IO / db (mixed: builders, async)
#   framework-> DSL / framework / async runtime (expected Alt 2/3 only)
# ---------------------------------------------------------------------------
CRATES: list[tuple[str, str]] = [
    # leaf / pure-data (20)
    ("sha2", "leaf"), ("blake3", "leaf"), ("md-5", "leaf"), ("hex", "leaf"),
    ("base64", "leaf"), ("base32", "leaf"), ("regex", "leaf"), ("url", "leaf"),
    ("semver", "leaf"), ("uuid", "leaf"), ("chrono", "leaf"), ("time", "leaf"),
    ("humantime", "leaf"), ("crc32fast", "leaf"), ("bytesize", "leaf"),
    ("byteorder", "leaf"), ("percent-encoding", "leaf"),
    ("unicode-segmentation", "leaf"), ("ryu", "leaf"), ("itoa", "leaf"),
    # generic data-structures / math (10)
    ("itertools", "generic"), ("indexmap", "generic"), ("smallvec", "generic"),
    ("arrayvec", "generic"), ("bitflags", "generic"), ("num", "generic"),
    ("num-bigint", "generic"), ("ordered-float", "generic"),
    ("ndarray", "generic"), ("nalgebra", "generic"),
    # serde / formats (6)
    ("serde_json", "serde"), ("toml", "serde"), ("serde_yaml", "serde"),
    ("csv", "serde"), ("quick-xml", "serde"), ("ron", "serde"),
    # client / io / db (6)
    ("reqwest", "client"), ("ureq", "client"), ("redis", "client"),
    ("rusqlite", "client"), ("tungstenite", "client"), ("sqlx", "client"),
    # framework / dsl / async (8)
    ("axum", "framework"), ("actix-web", "framework"), ("clap", "framework"),
    ("bevy_ecs", "framework"), ("diesel", "framework"), ("tokio", "framework"),
    ("tower", "framework"), ("tracing", "framework"),
]

CLASS_OF = {name: cls for name, cls in CRATES}

# Crates whose useful API is feature-gated; default features expose ~nothing.
# The inspector accepts `--features <comma,list> <crate>`. Applied automatically
# on `run` (cached crates are skipped, so this only affects fresh/--force runs).
# Override/extend per-run with --features "crate=a,b;crate2=c".
FEATURES: dict[str, str] = {
    "tokio": "full",
    "reqwest": "blocking,json",
    "sqlx": "sqlite,runtime-tokio",
    "diesel": "sqlite",
    "uuid": "v4,v7",
}

DEFAULT_RESULTS = Path.home() / ".cache" / "sky" / "ffi-audit" / "results"

# Constructor-like method/function name prefixes & exacts: a kept fn that
# *produces* a value of the type (so Sky can actually obtain one).
CTOR_EXACT = {"new", "default", "builder", "with_capacity", "init", "empty"}
CTOR_PREFIX = ("from", "with", "parse", "try_from", "try_new", "create",
               "open", "connect", "build", "make", "of", "load")


def find_inspector() -> str:
    env = os.environ.get("SKY_FFI_INSPECTOR_RS")
    if env and Path(env).is_file():
        return env
    candidates = [
        Path("/home/arthur/Documentos/comp/sky/tools/sky-ffi-inspect-rs/target/release/sky-ffi-inspect-rs"),
        Path.home() / ".cache/sky/tools/sky-ffi-inspect-rs/sky-ffi-inspect-rs",
    ]
    # Also walk up from CWD looking for the in-repo release binary.
    cur = Path.cwd()
    for _ in range(8):
        cand = cur / "tools/sky-ffi-inspect-rs/target/release/sky-ffi-inspect-rs"
        if cand.is_file():
            candidates.insert(0, cand)
            break
        if cur.parent == cur:
            break
        cur = cur.parent
    for c in candidates:
        if c.is_file():
            return str(c)
    sys.exit("error: sky-ffi-inspect-rs not found. Set $SKY_FFI_INSPECTOR_RS, "
             "build tools/sky-ffi-inspect-rs (cargo build --release), or run "
             "`sky add <anything> --target rust` once to materialise the embedded copy.")


def classify(fn: dict) -> str:
    """free | ctor | accessor — the role a kept function plays."""
    recv = (fn.get("recvType") or "").strip()
    name = (fn.get("name") or "").strip()
    if not recv:
        return "free"
    if name in CTOR_EXACT or name.startswith(CTOR_PREFIX):
        return "ctor"
    return "accessor"


def verdict(kept: int, free: int, ctor: int, status: str) -> str:
    """Rank by CONSTRUCTABLE SURFACE (free + ctor) — what lets Sky obtain or call
    something standalone. Accessor count is deliberately ignored: a crate with 50
    constructors and 200 accessors (chrono) is rich, not 'partial'."""
    if status != "ok":
        return f"FAILED({status})"
    if kept == 0:
        return "empty"
    reachable = free + ctor
    if reachable == 0:
        return "peripheral"   # only accessors on values you can't construct (axum)
    if reachable >= 10:
        return "rich"
    if reachable >= 3:
        return "usable"
    return "thin"             # 1-2 constructable entry points


def run_one(inspector: str, crate: str, results_dir: Path, timeout: int,
            force: bool, features: str = "") -> dict:
    out_json = results_dir / f"{crate}.json"
    out_status = results_dir / f"{crate}.status.json"
    if out_status.is_file() and not force:
        try:
            st = json.loads(out_status.read_text())
            if st.get("status") == "ok":
                return st
        except Exception:
            pass
    t0 = time.time()
    status = "ok"
    detail = ""
    data = None
    cmd = [inspector] + (["--features", features] if features else []) + [crate]
    try:
        proc = subprocess.run(cmd, capture_output=True,
                              text=True, timeout=timeout)
        if proc.returncode != 0:
            status = "inspector-error"
            detail = (proc.stderr or "").strip()[-400:]
        else:
            try:
                data = json.loads(proc.stdout)
                out_json.write_text(proc.stdout)
            except json.JSONDecodeError as e:
                status = "parse-error"
                detail = f"{e}; stderr: {(proc.stderr or '').strip()[-200:]}"
    except subprocess.TimeoutExpired:
        status = "timeout"
        detail = f">{timeout}s"
    elapsed = round(time.time() - t0, 1)

    st = {"crate": crate, "class": CLASS_OF.get(crate, "?"),
          "status": status, "elapsed_s": elapsed, "detail": detail,
          "features": features}
    if data is not None:
        fns = data.get("functions", [])
        roles = [classify(f) for f in fns]
        st.update({
            "version": data.get("version", ""),
            "kept": len(fns),
            "free": roles.count("free"),
            "ctor": roles.count("ctor"),
            "accessor": roles.count("accessor"),
            "recv_types": len({(f.get("recvType") or "") for f in fns if f.get("recvType")}),
            "inspector_errors": len(data.get("errors", [])),
        })
    else:
        st.update({"version": "", "kept": 0, "free": 0, "ctor": 0,
                   "accessor": 0, "recv_types": 0, "inspector_errors": 0})
    st["verdict"] = verdict(st["kept"], st["free"], st["ctor"], status)
    out_status.write_text(json.dumps(st, indent=2))
    return st


def load_all(results_dir: Path) -> list[dict]:
    rows = []
    if not results_dir.is_dir():
        return rows
    for p in sorted(results_dir.glob("*.status.json")):
        try:
            r = json.loads(p.read_text())
            # Recompute the verdict from stored counts so the CURRENT heuristic
            # always applies to cached results (no re-run needed after a tweak).
            r["verdict"] = verdict(r.get("kept", 0), r.get("free", 0),
                                   r.get("ctor", 0), r.get("status", "ok"))
            rows.append(r)
        except Exception:
            pass
    return rows


def print_summary(rows: list[dict], md: bool = False) -> None:
    if not rows:
        print("(no results yet — run `ffi_audit.py run` first)")
        return
    order = {"leaf": 0, "generic": 1, "serde": 2, "client": 3, "framework": 4, "?": 5}
    rows = sorted(rows, key=lambda r: (order.get(r.get("class", "?"), 9), r["crate"]))
    cols = ("crate", "class", "kept", "free", "ctor", "accs", "verdict", "version")
    if md:
        print("| " + " | ".join(cols) + " |")
        print("|" + "|".join(["---"] * len(cols)) + "|")
    else:
        print(f"{'crate':22} {'class':9} {'kept':>4} {'free':>4} {'ctor':>4} {'accs':>4}  {'verdict':14} version")
        print("-" * 84)
    for r in rows:
        vals = [r["crate"], r.get("class", "?"), str(r.get("kept", 0)),
                str(r.get("free", 0)), str(r.get("ctor", 0)),
                str(r.get("accessor", 0)), r.get("verdict", "?"),
                r.get("version", "") or (r.get("detail", "")[:24])]
        if md:
            print("| " + " | ".join(vals) + " |")
        else:
            print(f"{vals[0]:22} {vals[1]:9} {vals[2]:>4} {vals[3]:>4} "
                  f"{vals[4]:>4} {vals[5]:>4}  {vals[6]:14} {vals[7]}")

    # rollups
    print()
    by_class: dict[str, dict[str, int]] = {}
    by_verdict: dict[str, int] = {}
    for r in rows:
        c = r.get("class", "?")
        v = r.get("verdict", "?").split("(")[0]
        by_class.setdefault(c, {}).setdefault(v, 0)
        by_class[c][v] += 1
        by_verdict[v] = by_verdict.get(v, 0) + 1
    print(f"crates measured: {len(rows)} / {len(CRATES)}")
    print("verdict totals :", ", ".join(f"{k}={v}" for k, v in sorted(by_verdict.items())))
    print("by class       :")
    for c in sorted(by_class, key=lambda x: order.get(x, 9)):
        inner = ", ".join(f"{k}={v}" for k, v in sorted(by_class[c].items()))
        print(f"   {c:10} {inner}")
    print("\nverdict (by constructable surface = free+ctor): rich >=10 · "
          "usable 3-9 · thin 1-2 · peripheral 0 (accessors only, e.g. axum) · "
          "empty/FAILED = no/failed bindings")


def main() -> None:
    ap = argparse.ArgumentParser(description="Sky->Rust auto-FFI coverage audit")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p_run = sub.add_parser("run", help="run the inspector across the sample")
    p_run.add_argument("--crates", help="comma-separated crate names (default: built-in ~50 sample)")
    p_run.add_argument("--timeout", type=int, default=300, help="per-crate timeout seconds (default 300)")
    p_run.add_argument("--force", action="store_true", help="re-run crates even if cached")
    p_run.add_argument("--features", help='per-crate feature overrides, e.g. '
                       '"tokio=full;reqwest=blocking,json" (merged over built-in defaults)')
    p_run.add_argument("--results-dir", default=str(DEFAULT_RESULTS))

    p_sum = sub.add_parser("summary", help="summarize cached results (partial OK)")
    p_sum.add_argument("--results-dir", default=str(DEFAULT_RESULTS))
    p_sum.add_argument("--md", action="store_true", help="emit a Markdown table")

    sub.add_parser("list", help="print the built-in crate sample")

    args = ap.parse_args()

    if args.cmd == "list":
        for name, cls in CRATES:
            print(f"{cls:10} {name}")
        print(f"\n{len(CRATES)} crates")
        return

    if args.cmd == "summary":
        print_summary(load_all(Path(args.results_dir)), md=args.md)
        return

    # run
    results_dir = Path(args.results_dir)
    results_dir.mkdir(parents=True, exist_ok=True)
    inspector = find_inspector()
    if not shutil.which("cargo"):
        print("warning: cargo not on PATH; the inspector needs `cargo +nightly`.", file=sys.stderr)
    if subprocess.run(["pgrep", "-f", "mem-guard.sh"], capture_output=True).returncode != 0:
        print("WARNING: mem-guard.sh is not running. Heavy rustdoc builds (bevy/diesel/"
              "tokio/nalgebra) can pressure RAM — start it before a full sweep.", file=sys.stderr)

    overrides: dict[str, str] = {}
    if args.features:
        for part in args.features.split(";"):
            if "=" in part:
                k, v = part.split("=", 1)
                overrides[k.strip()] = v.strip()

    crates = ([(c.strip(), CLASS_OF.get(c.strip(), "?")) for c in args.crates.split(",")]
              if args.crates else CRATES)
    print(f"inspector: {inspector}")
    print(f"results  : {results_dir}")
    print(f"crates   : {len(crates)} (timeout {args.timeout}s each, resumable)\n")
    for i, (crate, _cls) in enumerate(crates, 1):
        feats = overrides.get(crate, FEATURES.get(crate, ""))
        label = f"{crate} [{feats}]" if feats else crate
        print(f"[{i}/{len(crates)}] {label} ... ", end="", flush=True)
        st = run_one(inspector, crate, results_dir, args.timeout, args.force, feats)
        print(f"{st['verdict']:11} kept={st['kept']:<4} "
              f"free={st['free']} ctor={st['ctor']} accs={st['accessor']} "
              f"({st['elapsed_s']}s)")
    print()
    print_summary(load_all(results_dir))


if __name__ == "__main__":
    main()
