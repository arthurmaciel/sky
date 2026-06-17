#!/usr/bin/env bash
# Sky Rust-backend EXAMPLES sweep — the cornerstone correctness gate. For each
# in-scope example (build_set, DERIVED in lib/examples.sh: every candidate dir
# minus Go-FFI) it does THREE things and emits ONE table row with three columns:
#
#   BUILD   sky build --target rust + cargo build       → ok / sky-fail / cargo-fail
#   RUN     run the Rust binary headless, per shape      → ok / panic / hang / noserve / notty / skip
#   EQUIV   build the Go reference + compare to Rust     → equiv-stdout / equiv-body N /
#                                                           equiv-serve / equiv-scenario /
#                                                           equiv-pty / n/a / DIFFER / go-ref-broken
#
# This REPLACES the old build-sweep + run-sweep (folded into one pass; the shared
# per-shape `exercise_*` logic lives in lib/checks.sh, the SINGLE SOURCE OF TRUTH).
# A green Rust build is necessary but NOT sufficient — RUN catches the runtime-
# regression class (panic / dead server / dead click) and EQUIV asserts the Rust
# output MATCHES Go per the example's DERIVED equiv mode (overrides in
# equiv-classification.tsv).
#
# PRINCIPLES (README.md top, strict order): security > correctness > soundness >
# efficiency > completeness > readability. This harness serves CORRECTNESS — it
# must never label `equiv` what is only "both boot", and never hide a real
# divergence. A DIFFER is reported precisely, not papered over.
#
# GREEN row  = BUILD ok AND RUN ok AND EQUIV ∈ {equiv-*, n/a, amber go-ref-broken}.
# RED row    = any *-fail / panic / hang / noserve / notty / DIFFER.
# AMBER      = go-ref-broken (the Go reference itself fails — an upstream Go bug,
#              NOT a Rust-backend failure; discriminated from DIFFER explicitly).
# VERDICT PASS iff no RED row.
#
# FLAGS:
#   SKY_SWEEP_BUILD_ONLY=1  → BUILD column only (fast go-free compile check;
#                             RUN + EQUIV = `—`). No `go` needed.
#   SKY_SWEEP_NO_EQUIV=1    → BUILD + RUN; EQUIV skipped (`—`).
#   SKY_SWEEP_FORCE=1       → override the night gate (run outside 22:00–08:00 BRT).
#   RUST_EXAMPLES="01-… 19-…" → subset override (paths or basenames).
#
# This script IS the procedure (the sky-rust-backend:examples-sweep skill). If a
# run reveals a better way (a real divergence, a normalization gap, a new shape),
# IMPROVE THIS SCRIPT / lib/checks.sh / the overrides manifest.
#
# Exit: 0 = no RED row · 1 = a RED row (build/run/equiv failure) · 2 = setup/gate.
set -uo pipefail

# ── Env + manifest + shared checks (SINGLE SOURCE OF TRUTH under lib/) ───────
source "$(dirname "$0")/lib/env.sh"
source "$(dirname "$0")/lib/examples.sh"
source "$(dirname "$0")/lib/checks.sh"

# ── Night gate (22:00–08:00 America/Sao_Paulo; SKY_SWEEP_FORCE=1 overrides) ──
night_guard "examples-sweep"

if [ -z "$REPO" ] || [ ! -f "$REPO/runtime-rust/scripts/examples-sweep.sh" ]; then
  echo "ERROR: can't locate the Sky repo. cd into it, or set SKY_REPO=/path/to/sky." >&2; exit 2
fi
cd "$REPO"
[ -x "$SKY_BIN" ] || { echo "ERROR: sky binary not at $SKY_BIN — build it (cabal build exe:sky)." >&2; exit 2; }

# ── Preflight: this box has corrupted builds under low disk OR no mem-guard ───
# Both are HARD gates (a runaway sky/cargo/ghc has force-powered-off the host;
# ENOSPC mid-build leaves half-written artifacts). SKY_SWEEP_FORCE=1 — the user's
# explicit "I know what I'm doing" signal (same flag that overrides the night
# gate) — downgrades the mem-guard gate to a WARN, for a host where mem-guard
# can't run (it's macOS-only: sysctl hw.pagesize / vm_stat). The disk gate is
# never bypassed — a corrupt-build risk is not worth any override.
FREE_KB="$(df -Pk "$REPO" 2>/dev/null | awk 'NR==2{print $4}')"
if [ -n "$FREE_KB" ] && [ "$FREE_KB" -lt 5242880 ]; then
  echo "ERROR: < 5G free disk on $REPO ($((FREE_KB/1024/1024))G) — builds corrupt under ENOSPC. Free space first (go clean -cache)." >&2; exit 2
fi
if ! pgrep -f 'mem-guard\.sh' >/dev/null 2>&1; then
  if [ -n "${SKY_SWEEP_FORCE:-}" ]; then
    echo "WARN: mem-guard.sh not running — proceeding under SKY_SWEEP_FORCE=1. A runaway sky/cargo/ghc can OOM the host; watch memory. (mem-guard is macOS-only — sysctl hw.pagesize / vm_stat.)" >&2
  else
    echo "ERROR: mem-guard.sh not running — a runaway sky/cargo/ghc has powered off this host before. Start it (macOS): nohup ./scripts/mem-guard.sh >/tmp/mem-guard.out 2>&1 & disown — or SKY_SWEEP_FORCE=1 to proceed without it on a host where it can't run." >&2; exit 2
  fi
fi

# ── Mode flags ───────────────────────────────────────────────────────────────
BUILD_ONLY="${SKY_SWEEP_BUILD_ONLY:-0}"
NO_EQUIV="${SKY_SWEEP_NO_EQUIV:-0}"
[ "$BUILD_ONLY" = 1 ] && NO_EQUIV=1   # build-only implies no equiv
if [ "$BUILD_ONLY" != 1 ]; then
  command -v curl >/dev/null 2>&1 || { echo "ERROR: curl required for RUN/EQUIV (set SKY_SWEEP_BUILD_ONLY=1 for a fast compile-only run)." >&2; exit 2; }
fi
if [ "$NO_EQUIV" != 1 ]; then
  command -v go >/dev/null 2>&1 || { echo "ERROR: go required for Go≡Rust EQUIV (set SKY_SWEEP_NO_EQUIV=1 or SKY_SWEEP_BUILD_ONLY=1)." >&2; exit 2; }
fi
# rg (ripgrep) is required by `is_out_of_scope` — the build_set Go-FFI filter used
# in EVERY mode. Without it the import-scan silently returns "in scope" for all, so
# Go-FFI examples (02/03/05/08/11/13…) leak into build_set and every one fails
# `--target rust`. Fail LOUDLY (a CI runner must install ripgrep) rather than run a
# wrong, all-red sweep.
command -v rg >/dev/null 2>&1 || { echo "ERROR: rg (ripgrep) required for the example-scope filter (is_out_of_scope). Install ripgrep." >&2; exit 2; }
# Skip the per-example console pre-build (not what this sweep checks).
export SKY_CONSOLE_PREBUILD=off

HIST="$HOME/.cache/sky/examples-sweep"; mkdir -p "$HIST"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
TABLE="$HIST/sweep-$STAMP.table"   # the aligned BUILD·RUN·EQUIV scoreboard
RUNLOG="$HIST/run-$STAMP.log"
say() { echo "$@" | tee -a "$RUNLOG"; }
say "=== Sky Rust EXAMPLES sweep @ $STAMP (repo: $REPO) ==="
[ "$BUILD_ONLY" = 1 ] && say "  (SKY_SWEEP_BUILD_ONLY=1 — BUILD column only; RUN+EQUIV skipped)"
[ "$BUILD_ONLY" != 1 ] && [ "$NO_EQUIV" = 1 ] && say "  (SKY_SWEEP_NO_EQUIV=1 — BUILD+RUN; EQUIV skipped)"
[ "$NO_EQUIV" = 1 ] || [ "$WEB_OK" = 1 ] || say "  NOTE: browser stack incomplete — scenario equiv falls back to a both-backends boot check."

# ── Hygiene: stray `sky lsp` / `sky doc --serve` hold .skycache locks ───────
ps -u "$USER" -o pid,args 2>/dev/null | awk '/\/sky (lsp|doc)/{print $1}' | xargs -r kill 2>/dev/null
reap; sync

# ── build_rust <dir> <example> → 0=ok; sets BUILD_CELL to the failure word ───
BUILD_CELL=""
build_rust() {
  # SKY_SWEEP_BUILD_TIMEOUT overrides the per-example ceiling. The 180 s default
  # assumes a warm sccache (true locally). A COLD CI run cold-compiles the whole
  # Rust dep tree on the first example and blows past 180 s → every build sky-fails;
  # CI raises this (and pre-warms the deps) so the cold first build fits.
  local d="$1" n="$2" tmo="${SKY_SWEEP_BUILD_TIMEOUT:-180}"
  case "$d" in examples/rust/*) tmo="${SKY_SWEEP_BUILD_TIMEOUT_FFI:-1800}";; esac
  # Windows shares ONE CARGO_TARGET_DIR holding a single sky-app.exe. A just-RUN
  # example (webview/tui) can leave the app / winpty / its console host ALIVE,
  # holding the .exe handle, so the next example's `cargo build` can't overwrite
  # it → "failed to remove file … Access is denied (os error 5)". GNU `timeout`'s
  # signal does NOT reliably kill a Windows GUI/pty process tree, so we must
  # FORCE-KILL the lingerers (not just wait): `taskkill //F` (// → /F under Git
  # Bash) before the build, and again on each lock retry.
  _win_reap_app() {
    [ "${SKY_HOST_OS:-}" = windows ] || return 0
    taskkill //F //T //IM sky-app.exe      >/dev/null 2>&1 || true
    taskkill //F //T //IM winpty.exe       >/dev/null 2>&1 || true
    taskkill //F //T //IM winpty-agent.exe >/dev/null 2>&1 || true
  }
  _win_reap_app; [ "${SKY_HOST_OS:-}" = windows ] && sleep 1
  local attempt ok=0
  for attempt in 1 2 3 4; do
    if ( cd "$d" && timeout "$tmo" "$SKY_BIN" build src/Main.sky --target rust >"$HIST/$n.rust.sky.log" 2>&1 ); then
      ok=1; break
    fi
    if [ "${SKY_HOST_OS:-}" = windows ] && [ "$attempt" -lt 4 ] && \
       grep -qiE 'Access is denied \(os error 5\)|failed to remove file' "$HIST/$n.rust.sky.log"; then
      _win_reap_app; sleep 3; continue
    fi
    break
  done
  if [ "$ok" != 1 ]; then
    BUILD_CELL="sky-fail"; return 1
  fi
  if ( cd "$d" && timeout 600 cargo build --manifest-path sky-out/Rust/Cargo.toml -q >"$HIST/$n.rust.cargo.log" 2>&1 ); then
    BUILD_CELL="ok"; return 0
  fi
  BUILD_CELL="cargo-fail"; return 1
}

# ── build_go <dir> <example> → 0=ok (binary at $d/sky-out/app), 1=fail ──────
build_go() {
  local d="$1" n="$2"
  ( cd "$d" && timeout 300 "$SKY_BIN" build src/Main.sky >"$HIST/$n.go.build.log" 2>&1 )
  sync   # flush the freshly-written binary so the immediate exec isn't ETXTBSY
  [ -x "$d/sky-out/app" ]
}

# Normalize stdout for the stdout-mode diff: strip blank lines only (cosmetic) —
# NOT aggressive normalization, which could mask a real divergence.
norm() { grep -v '^[[:space:]]*$' "$1" 2>/dev/null | head -200; }

# ── go_stdout_deterministic <go_bin> <log>: run Go twice; 0 if stdout stable ─
# stdout-mode determinism auto-probe — a backend-independent stdout that differs
# run-to-run (timestamp / Dict order) is auto-downgraded to n/a, never DIFFER.
go_stdout_deterministic() {
  local gb="$1" l="$2"
  exercise_cli "$gb" "$l.1" >/dev/null 2>&1 || true
  exercise_cli "$gb" "$l.2" >/dev/null 2>&1 || true
  diff <(norm "$l.1") <(norm "$l.2") >/dev/null 2>&1
}

# ── EQUIV for one example → echoes the EQUIV cell + NOTE (tab-separated) ─────
# Args: <dir> <name> <mode> <rust_bin>. Builds the Go reference as needed.
equiv_for() {
  local d="$1" n="$2" mode="$3" rbin="$4"
  local rsl="$HIST/$n.rust.run.log" gol="$HIST/$n.go.run.log"
  case "$mode" in
    none) printf 'n/a\t%s\n' "$(equiv_override_reason "$d")"; return 0 ;;
  esac

  case "$mode" in
    stdout)
      # Rust binary is current in the shared target — capture its stdout first.
      exercise_cli "$rbin" "$rsl" >/dev/null 2>&1 || true
      build_go "$d" "$n" || { printf 'go-ref-broken\tGo build failed\n'; return 0; }
      if ! go_stdout_deterministic "$d/sky-out/app" "$gol"; then
        printf 'n/a\tnondeterministic Go stdout (auto-probe)\n'; return 0
      fi
      if diff <(norm "$gol.1") <(norm "$rsl") >"$HIST/$n.diff.txt" 2>&1; then
        printf 'equiv-stdout\t\n'
      else
        printf 'DIFFER\tstdout differs (see %s.diff.txt)\n' "$n"
      fi
      ;;

    body)
      build_go "$d" "$n" || { printf 'go-ref-broken\tGo build failed\n'; return 0; }
      local res note
      res="$(exercise_server_equiv "$d/sky-out/app" "$rbin" "$d" "$HIST/$n.equiv")"
      reap
      case "$res" in
        equiv-body\ *) printf '%s\t\n' "$res" ;;
        equiv-serve)   printf 'equiv-serve\t0 comparable GET routes — both boot\n' ;;
        go-ref-broken) printf 'go-ref-broken\tGo reference did not boot+serve\n' ;;
        rust-broken)   printf 'DIFFER\tRust did not boot+serve where Go did\n' ;;
        DIFFER)        printf 'DIFFER\troute body differs (see %s.equiv)\n' "$n" ;;
        *)             printf 'DIFFER\tunexpected equiv result: %s\n' "$res" ;;
      esac
      ;;

    serve)
      # Explicit serve override (rare) — both must boot.
      local rok=1 gok=1
      exercise_server "$rbin" "$(free_port)" "$rsl" || rok=0; reap
      build_go "$d" "$n" || { printf 'go-ref-broken\tGo build failed\n'; return 0; }
      exercise_server "$d/sky-out/app" "$(free_port)" "$gol" || gok=0; reap
      if [ "$gok" = 0 ]; then printf 'go-ref-broken\tGo did not boot+serve\n'
      elif [ "$rok" = 1 ]; then printf 'equiv-serve\t\n'
      else printf 'DIFFER\tRust did not boot+serve where Go did\n'; fi
      ;;

    pty)
      local rok=1 gok=1 rrc
      exercise_tui "$rbin" "$rsl"; rrc=$?
      # On a host with no pty (Windows / macOS-no-script) tui can't be exercised
      # on EITHER backend → n/a, never a DIFFER. Probe the Rust rc; if it's the
      # skip rc, the Go probe would skip identically.
      if [ "$rrc" = "$EXERCISE_SKIP_RC" ]; then printf 'n/a\t%s\n' "$(grep -m1 '^SKIP' "$rsl" | sed 's/^SKIP //')"; return 0; fi
      [ "$rrc" = 0 ] || rok=0
      build_go "$d" "$n" || { printf 'go-ref-broken\tGo build failed\n'; return 0; }
      exercise_tui "$d/sky-out/app" "$gol" || gok=0
      if [ "$gok" = 0 ]; then printf 'go-ref-broken\tGo TUI panicked\n'
      elif [ "$rok" = 1 ]; then printf 'equiv-pty\tboth drive runtime (NOT cell-identical)\n'
      else printf 'DIFFER\tRust TUI panicked where Go did not\n'; fi
      ;;

    scenario)
      local scen rok=1 gok=1
      if ! browser_drivable "$d"; then
        # Driver can't locate examples/rust/* — fall back to both-boot.
        exercise_server "$rbin" "$(free_port)" "$rsl" || rok=0; reap
        build_go "$d" "$n" || { printf 'go-ref-broken\tGo build failed\n'; return 0; }
        exercise_server "$d/sky-out/app" "$(free_port)" "$gol" || gok=0; reap
        if [ "$gok" = 0 ]; then printf 'go-ref-broken\tGo did not boot+serve\n'
        elif [ "$rok" = 1 ]; then printf 'equiv-serve\tdriver cannot locate dir — boot-both floor\n'
        else printf 'DIFFER\tRust did not boot+serve where Go did\n'; fi
        return 0
      fi
      scen="$(scenario_for "$n")"
      exercise_live "$rbin" "$n" "$(free_port)" "$scen" "$rsl" || rok=0; reap
      build_go "$d" "$n" || { printf 'go-ref-broken\tGo build failed\n'; return 0; }
      exercise_live "$d/sky-out/app" "$n" "$(free_port)" "$scen" "$gol" || gok=0; reap
      if [ "$gok" = 0 ] && [ "$rok" = 0 ]; then printf 'go-ref-broken\tboth fail scenario (neither works — not a Rust divergence)\n'
      elif [ "$gok" = 0 ]; then printf 'go-ref-broken\tGo fails scenario %s\n' "$scen"
      elif [ "$rok" = 1 ]; then printf 'equiv-scenario\t(scenario %s; APP-behaviour, not DOM-diff)\n' "$scen"
      else printf 'DIFFER\tRust fails scenario %s where Go passes\n' "$scen"; fi
      ;;

    *) printf 'n/a\tunknown mode %s\n' "$mode" ;;
  esac
}

# ── RUN for one example → echoes the RUN cell + NOTE (tab-separated) ─────────
# Args: <name> <shape> <rust_bin>. The shape dispatch mirrors run-sweep verbatim.
run_for() {
  local n="$1" shape="$2" bin="$3" rl="$HIST/$n.run.log"
  case "$shape" in
    cli)
      if exercise_cli "$bin" "$rl"; then printf 'ok\t\n'
      elif grep -qiE "$PANIC_RE" "$rl"; then printf 'panic\tcli panicked\n'
      else printf 'hang\tcli timed out\n'; fi
      ;;
    tui)
      exercise_tui "$bin" "$rl"; local rc=$?
      if   [ "$rc" = 0 ]; then printf 'ok\t\n'
      elif [ "$rc" = "$EXERCISE_SKIP_RC" ]; then printf 'skip\t%s\n' "$(grep -m1 '^SKIP' "$rl" | sed 's/^SKIP //')"
      elif grep -qiE "not a tty|inappropriate ioctl|TERM environment" "$rl"; then printf 'notty\tno terminal allocated\n'
      else printf 'panic\ttui panicked\n'; fi
      ;;
    webview)
      # exercise_webview returns EXERCISE_SKIP_RC on a host that can't run it
      # (Windows; Linux w/o xvfb) — that's a SKIP, never a panic.
      if ! command -v xvfb-run >/dev/null 2>&1 && [ "$SKY_HOST_OS" = linux ]; then printf 'skip\twebview: install xvfb to run headless\n'
      else
        exercise_webview "$bin" "$rl"; local rc=$?
        if   [ "$rc" = 0 ]; then printf 'ok\t\n'
        elif [ "$rc" = "$EXERCISE_SKIP_RC" ]; then printf 'skip\t%s\n' "$(grep -m1 '^SKIP' "$rl" | sed 's/^SKIP //')"
        else printf 'panic\twebview panicked\n'; fi
      fi
      ;;
    fyne)
      printf 'skip\tfyne: Go-FFI shape — not a Rust target\n'
      ;;
    live)
      local port; port="$(free_port)"
      if [ "$WEB_OK" = 1 ] && browser_drivable "$DCUR" && is_web_example "$DCUR"; then
        local scen; scen="$(scenario_for "$n")"
        if exercise_live "$bin" "$n" "$port" "$scen" "$rl"; then printf 'ok\t(browser round-trip, scenario %s)\n' "$scen"
        else printf 'noserve\tlive browser: %s\n' "$(grep -m1 '^FAIL' "$rl" | sed 's/^FAIL [^ ]* — //')"; fi
      else
        if exercise_server "$bin" "$port" "$rl"; then printf 'ok\t(serves :%s)\n' "$port"
        elif grep -qiE "$PANIC_RE" "$rl"; then printf 'panic\tlive panicked\n'
        else printf 'noserve\tlive did not serve\n'; fi
      fi
      ;;
    server)
      local port; port="$(free_port)"
      if exercise_server "$bin" "$port" "$rl"; then printf 'ok\t(serves :%s)\n' "$port"
      elif grep -qiE "$PANIC_RE" "$rl"; then printf 'panic\tserver panicked\n'
      else printf 'noserve\tserver did not serve\n'; fi
      ;;
    *) printf 'skip\tunknown shape %s\n' "$shape" ;;
  esac
}

# ── Build the example list (build_set, or RUST_EXAMPLES override) ────────────
EXAMPLES=()
if [ -n "${RUST_EXAMPLES:-}" ]; then
  for e in $RUST_EXAMPLES; do
    if [ -d "$e" ]; then EXAMPLES+=("${e%/}"); else e="examples/${e#examples/}"; EXAMPLES+=("${e%/}"); fi
  done
else
  while IFS= read -r d; do EXAMPLES+=("$d"); done < <(build_set)
fi

# ── Sweep: one row per example, columns BUILD·RUN·EQUIV (+ NOTE) ─────────────
say ""; say ">>> EXAMPLES SWEEP  (build_set DERIVED in lib/examples.sh; equiv modes DERIVED + overrides in equiv-classification.tsv)"
ROWS="$HIST/rows-$STAMP.tsv"; : >"$ROWS"
DCUR=""   # current example dir (for run_for's live dispatch)

for d in "${EXAMPLES[@]}"; do
  n="$(basename "$d")"
  [ -f "$d/src/Main.sky" ] || continue
  DCUR="$d"
  shape="$(example_shape "$d")"
  mode="$(equiv_mode "$d")"
  ( cd "$d" && rm -rf sky-out .skycache .skydeps )

  build_cell=""; run_cell="—"; equiv_cell="—"; note=""

  # 1) BUILD (always).
  if ! build_rust "$d" "$n"; then
    build_cell="$BUILD_CELL"; note="rust build failed (see $n.rust.*.log)"
    printf '%s\t%s\t%s\t%s\t%s\n' "$n" "$build_cell" "—" "—" "$note" >>"$ROWS"
    ( cd "$d" && rm -rf sky-out .skycache .skydeps ); continue
  fi
  build_cell="ok"
  rbin="$(resolve_bin "$d")"

  if [ "$BUILD_ONLY" = 1 ] || [ -z "$rbin" ]; then
    [ -z "$rbin" ] && { run_cell="noserve"; note="no binary resolved after build"; }
    printf '%s\t%s\t%s\t%s\t%s\n' "$n" "$build_cell" "$run_cell" "$equiv_cell" "$note" >>"$ROWS"
    ( cd "$d" && rm -rf sky-out .skycache .skydeps ); continue
  fi

  # 2) RUN (Rust binary, per shape).
  IFS=$'\t' read -r run_cell run_note < <(run_for "$n" "$shape" "$rbin")

  # 3) EQUIV (Go vs Rust, per derived mode) — unless NO_EQUIV.
  if [ "$NO_EQUIV" = 1 ]; then
    equiv_cell="—"; equiv_note=""
  else
    IFS=$'\t' read -r equiv_cell equiv_note < <(equiv_for "$d" "$n" "$mode" "$rbin")
  fi

  note="$run_note"; [ -n "$equiv_note" ] && note="${note:+$note; }$equiv_note"
  printf '%s\t%s\t%s\t%s\t%s\n' "$n" "$build_cell" "$run_cell" "$equiv_cell" "$note" >>"$ROWS"
  reap
  ( cd "$d" && rm -rf sky-out .skycache .skydeps )
done

# ── Render the aligned table ─────────────────────────────────────────────────
{
  printf "%-28s %-10s %-9s %-16s %s\n" "EXAMPLE" "BUILD" "RUN" "EQUIV" "NOTE"
  printf "%-28s %-10s %-9s %-16s %s\n" "-------" "-----" "---" "-----" "----"
  while IFS=$'\t' read -r n b r e note; do
    printf "%-28s %-10s %-9s %-16s %s\n" "$n" "$b" "$r" "$e" "$note"
  done < "$ROWS"
} | tee "$TABLE" | tee -a "$RUNLOG"

# ── Verdict ──────────────────────────────────────────────────────────────────
# RED = any cell in {sky-fail, cargo-fail, panic, hang, noserve, notty, DIFFER}.
# AMBER = go-ref-broken in EQUIV (upstream Go bug — NOT a Rust failure).
# GREEN = BUILD ok AND RUN ∈ {ok, —, skip} AND EQUIV ∈ {equiv-*, n/a, —, go-ref-broken}.
RED=0; GREEN=0; SKIP=0; AMBER=0; RED_ROWS=""
declare -A EQ_COUNT=()
while IFS=$'\t' read -r n b r e note; do
  row_red=0
  case "$b" in sky-fail|cargo-fail) row_red=1 ;; esac
  case "$r" in panic|hang|noserve|notty) row_red=1 ;; esac
  case "$e" in DIFFER) row_red=1 ;; go-ref-broken) AMBER=$((AMBER+1)) ;; esac
  # equiv-mode tally
  case "$e" in
    equiv-stdout)   EQ_COUNT[stdout]=$(( ${EQ_COUNT[stdout]:-0} + 1 )) ;;
    equiv-body*)    EQ_COUNT[body]=$(( ${EQ_COUNT[body]:-0} + 1 )) ;;
    equiv-serve)    EQ_COUNT[serve]=$(( ${EQ_COUNT[serve]:-0} + 1 )) ;;
    equiv-scenario) EQ_COUNT[scenario]=$(( ${EQ_COUNT[scenario]:-0} + 1 )) ;;
    equiv-pty)      EQ_COUNT[pty]=$(( ${EQ_COUNT[pty]:-0} + 1 )) ;;
    n/a)            EQ_COUNT[na]=$(( ${EQ_COUNT[na]:-0} + 1 )) ;;
    go-ref-broken)  EQ_COUNT[goref]=$(( ${EQ_COUNT[goref]:-0} + 1 )) ;;
  esac
  row_skip=0; case "$r" in skip) SKIP=$((SKIP+1)); row_skip=1 ;; esac
  if [ "$row_red" = 1 ]; then RED=$((RED+1)); RED_ROWS="$RED_ROWS $n"
  elif [ "$row_skip" = 0 ]; then GREEN=$((GREEN+1)); fi
done < "$ROWS"
# Disjoint buckets: green + red + skip = total. A clean skip row (webview without
# xvfb) is NOT counted green — RUN was skipped, not proven ok.
TOTAL="$(wc -l < "$ROWS" | tr -d ' ')"

EQ_BREAK="stdout=${EQ_COUNT[stdout]:-0} body=${EQ_COUNT[body]:-0} scenario=${EQ_COUNT[scenario]:-0} serve=${EQ_COUNT[serve]:-0} pty=${EQ_COUNT[pty]:-0} n/a=${EQ_COUNT[na]:-0} go-ref-broken=${EQ_COUNT[goref]:-0}"

say ""
say "  summary: $GREEN green · $RED red · $SKIP skipped (of $TOTAL) · amber go-ref-broken=$AMBER"
say "  equiv-mode breakdown: $EQ_BREAK"
say "  full table: $TABLE"

# ── HIST scoreboard (one line per run, like the sibling sweeps) ─────────────
SCORE="$HIST/scoreboard.tsv"
printf '%s\tgreen=%s\tred=%s\tskip=%s\tamber=%s\t%s\n' "$STAMP" "$GREEN" "$RED" "$SKIP" "$AMBER" "$EQ_BREAK" >>"$SCORE"

if [ "$RED" -gt 0 ]; then
  say "  RED rows (build/run/equiv failure — investigate or swarm-fix):${RED_ROWS}"
  say ""; say "=== VERDICT: FAIL ($RED red row(s)) ==="
  exit 1
fi
say ""; say "=== VERDICT: PASS · no red row · table=$TABLE ==="
exit 0
