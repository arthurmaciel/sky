#!/usr/bin/env bash
# Sky Rust-backend BUILD + Go≡Rust EQUIVALENCE sweep — for each in-scope example
# (build_set from lib/examples.sh: every candidate dir minus Go-FFI), build the
# Rust backend AND assert it is EQUIVALENT to the Go backend, per the example's
# equiv MODE (equiv-classification.tsv — the equiv-mode SSOT).
#
# This is the cornerstone correctness gate: a green Rust build is necessary but
# NOT sufficient — the Rust output must MATCH Go. The per-shape "exercise a
# binary" logic is SHARED with run-sweep via lib/checks.sh, so "did the binary
# work?" has ONE definition both sweeps consume; here we run it against BOTH
# backends and compare.
#
# Per example (mode from the manifest):
#   stdout    cli   → build Go + Rust, run BOTH via exercise_cli, DIFF normalized
#                     stdout. match → equiv-stdout (byte-identical); else DIFFER.
#   scenario  live  → run the SAME web-verify scenario against BOTH binaries.
#                     both pass → equiv-scenario (APP-behaviour parity); else
#                     DIFFER/EQUIV-FAIL. NOT a raw-DOM diff — robust to the
#                     by-design console in-process(Go) vs cross-process(Rust).
#   serve     server→ exercise_server BOTH. both serve → equiv-serve; else DIFFER.
#   pty       tui   → exercise_tui BOTH. both no-crash → equiv-pty (NOT
#                     cell-identical rendering); else DIFFER.
#   none      misc  → Rust build only → builds (webview / Go-FFI / no-entry / a
#                     non-deterministic cli — genuinely incomparable).
#
# Scoreboard bins are HONEST about what was proven: equiv-stdout / equiv-scenario
# / equiv-serve / equiv-pty / builds / DIFFER / EQUIV-FAIL / sky-build-fails /
# cargo-fails / go-build-fails / sky-CRASH. Verdict FAILS on any DIFFER /
# EQUIV-FAIL / *-fails / CRASH / unclassified example.
#
# `go` is REQUIRED (the equivalence comparison side) UNLESS SKY_SWEEP_NO_EQUIV=1,
# the escape hatch for a fast go-free Rust-build-only run (every example bins
# `builds` / `*-fails` only — the pre-equiv behaviour).
#
# This script IS the procedure (the sky-rust-backend:build-sweep skill). If a run
# reveals a better way (a real divergence, a harness normalization gap, a new
# example to classify), IMPROVE THIS SCRIPT / checks.sh / the manifest.
#
# Exit: 0 = all build + equiv · 1 = a build/equiv failure or unclassified · 2 = setup error.
set -uo pipefail

# ── Env + manifest + shared checks (SINGLE SOURCE OF TRUTH under lib/) ───────
source "$(dirname "$0")/lib/env.sh"
source "$(dirname "$0")/lib/examples.sh"
source "$(dirname "$0")/lib/checks.sh"
if [ -z "$REPO" ] || [ ! -f "$REPO/runtime-rust/scripts/build-sweep.sh" ]; then
  echo "ERROR: can't locate the Sky repo. cd into it, or set SKY_REPO=/path/to/sky." >&2; exit 2
fi
cd "$REPO"
[ -x "$SKY_BIN" ] || { echo "ERROR: sky binary not at $SKY_BIN — build it (cabal build exe:sky)." >&2; exit 2; }
# Skip the per-example console pre-build (it's not what a build sweep checks).
export SKY_CONSOLE_PREBUILD=off

# ── Equivalence mode: on by default; SKY_SWEEP_NO_EQUIV=1 → Rust-build-only ──
NO_EQUIV="${SKY_SWEEP_NO_EQUIV:-0}"
if [ "$NO_EQUIV" = 1 ]; then
  echo "NOTE: SKY_SWEEP_NO_EQUIV=1 — Rust build-only (no Go≡Rust equivalence). go not required."
else
  command -v go >/dev/null 2>&1 || { echo "ERROR: go required for Go≡Rust equivalence (set SKY_SWEEP_NO_EQUIV=1 for a fast build-only run)." >&2; exit 2; }
fi
command -v curl >/dev/null 2>&1 || { echo "ERROR: curl required for serve/scenario equivalence." >&2; exit 2; }

MANIFEST="$REPO/runtime-rust/scripts/equiv-classification.tsv"
[ -f "$MANIFEST" ] || { echo "ERROR: equiv-mode manifest missing: $MANIFEST" >&2; exit 2; }
# mode_for <basename> → the example's equiv mode (none if unclassified).
mode_for() { awk -v k="$1" '!/^#/ && $1==k {print $2; exit}' "$MANIFEST"; }

HIST="$HOME/.cache/sky/build-sweep"; mkdir -p "$HIST"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOG="$HIST/sweep-$STAMP.log"     # the scoreboard (EXAMPLE / RESULT table)
say() { echo "$@" | tee -a "$HIST/run-$STAMP.log"; }
say "=== Sky Rust BUILD+EQUIV sweep @ $STAMP (repo: $REPO) ==="
[ "$NO_EQUIV" = 1 ] && say "  (SKY_SWEEP_NO_EQUIV=1 — Rust build only)"
[ "$NO_EQUIV" = 1 ] || [ "$WEB_OK" = 1 ] || say "  NOTE: browser stack incomplete — scenario examples fall back to a both-backends boot check."

# ── Hygiene: stray `sky lsp` / `sky doc --serve` can hold .skycache locks ───
ps -u "$USER" -o pid,args 2>/dev/null | awk '/\/sky (lsp|doc)/{print $1}' | xargs -r kill 2>/dev/null
reap; sync

# ── build_rust <dir> <example> → 0=ok; writes a result word to RUST_R ───────
# Builds the Rust backend (sky build --target rust + cargo build). RUST_R holds
# the failure word (sky-CRASH/sky-build-fails/cargo-fails) on failure, "" on ok.
RUST_R=""
build_rust() {
  local d="$1" n="$2" tmo=180
  case "$d" in examples/rust/*) tmo=1800;; esac
  if ! ( cd "$d" && timeout "$tmo" "$SKY_BIN" build src/Main.sky --target rust >"$HIST/$n.rust.sky.log" 2>&1 ); then
    if rg -qE "Non-exhaustive|CallStack \(from HasCallStack\)|Prelude\.[a-z]+: |internal error" "$HIST/$n.rust.sky.log" 2>/dev/null; then
      RUST_R="sky-CRASH"; else RUST_R="sky-build-fails"; fi
    return 1
  fi
  if ( cd "$d" && timeout 600 cargo build --manifest-path sky-out/Rust/Cargo.toml -q >"$HIST/$n.rust.cargo.log" 2>&1 ); then
    RUST_R=""; return 0
  fi
  RUST_R="cargo-fails"; return 1
}

# ── build_go <dir> <example> → 0=ok (binary at $d/sky-out/app), 1=fail ──────
build_go() {
  local d="$1" n="$2"
  ( cd "$d" && timeout 300 "$SKY_BIN" build src/Main.sky >"$HIST/$n.go.build.log" 2>&1 )
  [ -x "$d/sky-out/app" ]
}

# (The Rust binary is resolved via resolve_bin from lib/checks.sh — it handles
# the examples/rust/* package-named-after-dir case the shared sky-app name misses.)

# Normalize stdout for the stdout-mode diff: strip blank lines only (cosmetic) —
# NOT aggressive normalisation, which could mask a real divergence. A surviving
# diff is a genuine output mismatch (or a harness gap to fix in checks.sh).
norm() { grep -v '^[[:space:]]*$' "$1" 2>/dev/null | head -200; }

# ── Scoreboard: build_set, binned by build + equivalence outcome ────────────
say ""; say ">>> BUILD+EQUIV SWEEP  (build_set from lib/examples.sh; modes from equiv-classification.tsv)"
{
  printf "%-30s %s\n" "EXAMPLE" "RESULT"
  printf "%-30s %s\n" "-------" "------"
  # Read the example list on a DEDICATED fd (9), not stdin — so a child process
  # an exercise spawns (pty `script`, a server) can never DRAIN the loop pipe and
  # end it early. (checks.sh also seals each exercise's stdin; this is the second
  # belt.)
  while IFS= read -r d <&9; do
    n=$(basename "$d")
    [ -f "${d}/src/Main.sky" ] || continue
    mode="$(mode_for "$n")"; [ -n "$mode" ] || mode="UNCLASSIFIED"
    ( cd "$d" && rm -rf sky-out .skycache .skydeps )

    # 1) Rust build (always).
    if ! build_rust "$d" "$n"; then
      printf "%-30s %s\n" "$n" "$RUST_R"; ( cd "$d" && rm -rf sky-out .skycache .skydeps ); continue
    fi

    # SKY_SWEEP_NO_EQUIV / none mode / unclassified → Rust build only.
    if [ "$NO_EQUIV" = 1 ] || [ "$mode" = none ]; then
      printf "%-30s %s\n" "$n" "builds"; ( cd "$d" && rm -rf sky-out .skycache .skydeps ); continue
    fi
    if [ "$mode" = UNCLASSIFIED ]; then
      printf "%-30s %s\n" "$n" "UNCLASSIFIED"; ( cd "$d" && rm -rf sky-out .skycache .skydeps ); continue
    fi

    rbin="$(resolve_bin "$d")"
    rsl="$HIST/$n.rust.run.log"; gol="$HIST/$n.go.run.log"
    # A scenario example the browser driver can't locate (examples/rust/*) is
    # compared as a serve boot check on BOTH backends instead — honest floor.
    if [ "$mode" = scenario ] && ! browser_drivable "$d"; then mode=serve; fi

    case "$mode" in
      stdout)
        # Run Rust first (binary is current in the shared target), capture stdout.
        exercise_cli "$rbin" "$rsl" >/dev/null 2>&1 || true
        # Build + run Go.
        if ! build_go "$d" "$n"; then printf "%-30s %s\n" "$n" "go-build-fails"; ( cd "$d" && rm -rf sky-out .skycache .skydeps ); continue; fi
        exercise_cli "$d/sky-out/app" "$gol" >/dev/null 2>&1 || true
        if diff <(norm "$gol") <(norm "$rsl") >"$HIST/$n.diff.txt" 2>&1; then
          printf "%-30s %s\n" "$n" "equiv-stdout"
        else
          printf "%-30s %s\n" "$n" "DIFFER"
        fi
        ;;

      serve)
        # Both must boot + serve. Rust first (current binary), then Go.
        rok=1; exercise_server "$rbin" "$(free_port)" "$rsl" || rok=0; reap
        if ! build_go "$d" "$n"; then printf "%-30s %s\n" "$n" "go-build-fails"; ( cd "$d" && rm -rf sky-out .skycache .skydeps ); continue; fi
        gok=1; exercise_server "$d/sky-out/app" "$(free_port)" "$gol" || gok=0; reap
        if [ "$rok" = 1 ] && [ "$gok" = 1 ]; then printf "%-30s %s\n" "$n" "equiv-serve"
        else printf "%-30s %s\n" "$n" "DIFFER"; fi
        ;;

      pty)
        rok=1; exercise_tui "$rbin" "$rsl" || rok=0
        if ! build_go "$d" "$n"; then printf "%-30s %s\n" "$n" "go-build-fails"; ( cd "$d" && rm -rf sky-out .skycache .skydeps ); continue; fi
        gok=1; exercise_tui "$d/sky-out/app" "$gol" || gok=0
        if [ "$rok" = 1 ] && [ "$gok" = 1 ]; then printf "%-30s %s\n" "$n" "equiv-pty"
        else printf "%-30s %s\n" "$n" "DIFFER"; fi
        ;;

      scenario)
        scen="$(scenario_for "$n")"
        rok=1; exercise_live "$rbin" "$n" "$(free_port)" "$scen" "$rsl" || rok=0; reap
        if ! build_go "$d" "$n"; then printf "%-30s %s\n" "$n" "go-build-fails"; ( cd "$d" && rm -rf sky-out .skycache .skydeps ); continue; fi
        gok=1; exercise_live "$d/sky-out/app" "$n" "$(free_port)" "$scen" "$gol" || gok=0; reap
        if [ "$rok" = 1 ] && [ "$gok" = 1 ]; then printf "%-30s %s\n" "$n" "equiv-scenario"
        elif [ "$rok" = 0 ] && [ "$gok" = 0 ]; then printf "%-30s %s\n" "$n" "EQUIV-FAIL"   # both fail the scenario — not a Rust-vs-Go divergence, but neither works
        else printf "%-30s %s\n" "$n" "DIFFER"; fi   # one passes, the other doesn't → real divergence
        ;;
    esac
    reap
    # Reclaim disk immediately — many cargo target/ dirs otherwise fill the FS.
    ( cd "$d" && rm -rf sky-out .skycache .skydeps )
  done 9< <(build_set)
} > "$LOG" 2>&1

# ── Classification-coverage gate: every examples/ dir + build_set member classified ─
# "Go parity maintained" requires full coverage. An unclassified example means the
# parity claim is incomplete → FAIL.
classified_all="$(awk '!/^#/ && NF>=2 {print $1}' "$MANIFEST" | sort -u)"
on_disk_top="$(find examples -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -u)"
UNCLASSIFIED_TOP="$(comm -13 <(echo "$classified_all") <(echo "$on_disk_top") | tr '\n' ' ' | sed 's/ *$//')"
UNCLASSIFIED_SET=""
while IFS= read -r d; do
  n=$(basename "$d")
  echo "$classified_all" | grep -qx "$n" || UNCLASSIFIED_SET="$UNCLASSIFIED_SET $n"
done < <(build_set)
UNCLASSIFIED_SET="${UNCLASSIFIED_SET# }"

# ── Verdict ─────────────────────────────────────────────────────────────────
# count <regex>: matching scoreboard lines (always a clean single integer —
# `grep -c` exits 1 on zero matches AND prints 0, so route through wc -l).
count() { grep -cE "$1" "$LOG" 2>/dev/null | head -1; }
BUILT="$(count 'builds$|equiv-(stdout|scenario|serve|pty)$')"
EQUIV_OK="$(count 'equiv-(stdout|scenario|serve|pty)$')"
# Per-mode equiv counts (proof strength is visible in the verdict).
c_stdout="$(count 'equiv-stdout$')"
c_scen="$(count 'equiv-scenario$')"
c_serve="$(count 'equiv-serve$')"
c_pty="$(count 'equiv-pty$')"
c_builds="$(count 'builds$')"
FAILS="$(grep -vE '^EXAMPLE|^---' "$LOG" 2>/dev/null | grep -E 'fails$|CRASH$|DIFFER$|EQUIV-FAIL$|UNCLASSIFIED$' || true)"

say "  built: $BUILT   equiv-proven: $EQUIV_OK   (stdout=$c_stdout scenario=$c_scen serve=$c_serve pty=$c_pty · build-only=$c_builds)"
say "  full scoreboard: $LOG"

VERDICT_FAIL=0
if [ -n "$FAILS" ]; then
  VERDICT_FAIL=1
  say "  FAILURES (build / equivalence):"; printf '%s\n' "$FAILS" | sed 's/^/    /' | tee -a "$HIST/run-$STAMP.log"
fi
if [ -n "$UNCLASSIFIED_TOP" ] || [ -n "$UNCLASSIFIED_SET" ]; then
  VERDICT_FAIL=1
  say "  UNCLASSIFIED (classify in equiv-classification.tsv — parity claim incomplete):"
  [ -n "$UNCLASSIFIED_TOP" ] && say "    top-level: $UNCLASSIFIED_TOP"
  [ -n "$UNCLASSIFIED_SET" ] && say "    build_set: $UNCLASSIFIED_SET"
fi

if [ "$VERDICT_FAIL" = 1 ]; then
  say ""; say "=== VERDICT: FAIL (build / equivalence / classification failures above) ==="
  exit 1
fi
if [ "$NO_EQUIV" = 1 ]; then
  say "  all in-scope examples build ✓ (equivalence skipped — SKY_SWEEP_NO_EQUIV=1)"
else
  say "  all in-scope examples build AND match Go per their equiv mode ✓"
fi
say ""; say "=== VERDICT: PASS · scoreboard=$LOG ==="
exit 0
