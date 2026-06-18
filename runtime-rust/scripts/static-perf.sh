#!/usr/bin/env bash
# static-perf.sh — STATIC-BUILD cross-OS measurement for the Sky Rust backend.
#
# workflow_dispatch-only. Feeds a README static-build table (the orchestrator
# writes the README — this script ONLY produces the per-OS TSV + md artifact).
#
# For a focused 5-example set (one per shape; webview EXCLUDED — it links system
# GUI libs and can't link static) it ATTEMPTS, per OS, a RELEASE build three ways
# and records binary SIZE + the static build ✅/❌:
#   dynamic  — `cargo build --release` (the default; glibc-dynamic / native)
#   static   — per-OS mechanism (see below)
#   go       — `sky build` (Go backend, fully static) for a size baseline (best-effort)
#
# Per-OS STATIC mechanism + runnability:
#   Linux   — `--target x86_64-unknown-linux-musl --features static_alloc`
#             (true static-pie + mimalloc). RUNNABLE on the host (native ELF).
#   Windows — env `RUSTFLAGS=-C target-feature=+crt-static`, native target
#             (static MSVC CRT). RUNNABLE on the host.
#   macOS   — CROSS-compile `--target x86_64-unknown-linux-musl --features
#             static_alloc` → a LINUX ELF. NOT runnable on the macOS host
#             (RUNNABLE=0); we record build status + sizes only.
#
# PERF (Linux + RUNNABLE only — never on Windows/macOS, where perf cols stay n/a):
#   cli/tui    → cold-start ms (best of 5, wall-clock, `timeout 10 bin`).
#   server/live→ throughput (`ab -n -c` after boot) + peak RSS (/proc VmRSS),
#                measured for BOTH the dynamic and static binary → static/dyn ratio.
#
# Output: a TSV + a ready-to-paste markdown table under
# $HOME/.cache/sky/static-perf/. Exit 0 ALWAYS (informational; no night gate —
# it's dispatch-only). Every build/run is timeout-bounded; servers are reaped
# (TERM→KILL) and orphans swept on exit.
set -uo pipefail

# ── Build env. Source lib/env.sh for PATH/SKY_BIN/sccache, then OVERRIDE
# CARGO_TARGET_DIR to an ISOLATED dir so this sweep never clobbers the shared
# sky-rust-target (and vice-versa). ─────────────────────────────────────────
_SP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=lib/env.sh
source "$_SP_DIR/lib/env.sh"
export CARGO_TARGET_DIR="${SKY_STATIC_PERF_TARGET:-$HOME/.cache/sky-static-perf-target}"
mkdir -p "$CARGO_TARGET_DIR"

# ── OS detection ────────────────────────────────────────────────────────────
RAW_OS="${RUNNER_OS:-$(uname -s)}"
case "$RAW_OS" in
  Linux)            OS_LABEL="Linux";   RUNNABLE=1 ;;
  Windows*|MINGW*|MSYS*|CYGWIN*) OS_LABEL="Windows"; RUNNABLE=1 ;;
  macOS|Darwin)     OS_LABEL="macOS";   RUNNABLE=0 ;;
  *)                OS_LABEL="$RAW_OS"; RUNNABLE=0 ;;
esac

MUSL_TRIPLE="x86_64-unknown-linux-musl"
# Point cargo at the musl C cross-linker for C deps (zstd/sqlite/ring), if present.
if command -v x86_64-linux-musl-gcc >/dev/null 2>&1; then
  export CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_LINKER="x86_64-linux-musl-gcc"
fi

# ── Example set (one per shape; webview excluded — can't link static). Override
# with SKY_STATIC_PERF_EXAMPLES="01-hello-world:cli 15-http-server:server" for a
# focused dry-run. Each entry is "<dir>:<shape>". ───────────────────────────
DEFAULT_EXAMPLES=(
  "01-hello-world:cli"
  "15-http-server:server"
  "18-job-queue:live"
  "21-tui-stopwatch:tui"
  "33-websocket-echo:server"
)
if [ -n "${SKY_STATIC_PERF_EXAMPLES:-}" ]; then
  read -r -a EXAMPLES <<<"$SKY_STATIC_PERF_EXAMPLES"
else
  EXAMPLES=("${DEFAULT_EXAMPLES[@]}")
fi

# ── Output sinks ────────────────────────────────────────────────────────────
HIST="$HOME/.cache/sky/static-perf"; mkdir -p "$HIST"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
TSV="$HIST/static-perf-$OS_LABEL-$STAMP.tsv"
MD="$HIST/static-perf-$OS_LABEL-$STAMP.md"
LOG="$HIST/static-perf-$OS_LABEL-$STAMP.log"
say()  { echo "$@" | tee -a "$LOG" >&2; }     # STDERR → never pollutes captured values

command -v "$SKY_BIN" >/dev/null 2>&1 || SKY_BIN="$REPO/sky-out/sky"
[ -x "$SKY_BIN" ] || { echo "ERROR: sky binary not at $SKY_BIN" >&2; exit 0; }
cd "$REPO" || exit 0

# ── Tunables (overridable) ──────────────────────────────────────────────────
COLD_RUNS="${COLD_RUNS:-5}"
AB_N="${AB_N:-5000}"; AB_C="${AB_C:-50}"
AB_TIMEOUT_S="${AB_TIMEOUT_S:-60}"
SERVER_READY_S="${SERVER_READY_S:-15}"
EMIT_TIMEOUT="${EMIT_TIMEOUT:-600}"
CARGO_TIMEOUT="${CARGO_TIMEOUT:-1200}"
GO_TIMEOUT="${GO_TIMEOUT:-600}"

# ── Orphan reaping ──────────────────────────────────────────────────────────
SERVER_PIDS=()
cleanup() {
  for pid in "${SERVER_PIDS[@]:-}"; do [ -n "${pid:-}" ] && kill -TERM "$pid" 2>/dev/null; done
  sleep 1
  for pid in "${SERVER_PIDS[@]:-}"; do [ -n "${pid:-}" ] && kill -KILL "$pid" 2>/dev/null; done
  pkill -f "$CARGO_TARGET_DIR/.*sky-app" 2>/dev/null
}
trap cleanup EXIT INT TERM

HAVE_AB=0; command -v ab >/dev/null 2>&1 && HAVE_AB=1

# size in bytes of an existing file, or empty. `stat -c%s` works under Git Bash.
fsize() { [ -f "$1" ] && stat -c%s "$1" 2>/dev/null || echo ""; }
now_ns() { { gdate +%s%N 2>/dev/null || date +%s%N; }; }

# cold-start ms (best of COLD_RUNS) of a cli/tui binary; "" for non-runnable.
coldstart_ms() {
  local bin="$1" best="" i t0 t1 ms
  [ -x "$bin" ] || { echo ""; return; }
  for i in $(seq 1 "$COLD_RUNS"); do
    t0="$(now_ns)"
    timeout 10 "$bin" >/dev/null 2>&1 </dev/null || true
    t1="$(now_ns)"
    ms=$(( (t1 - t0) / 1000000 ))
    { [ -z "$best" ] || [ "$ms" -lt "$best" ]; } && best="$ms"
  done
  echo "$best"
}

# Determine the port an example's server binds. Sniff the source for
# Server.listen <N>; fall back to 8000.
server_port_for() {
  local d="$1" p
  # `-U` (multiline) — Server.listen and the port often sit on separate lines;
  # `-I` drops the filename prefix so head -1 yields a bare number.
  p="$(rg -NoUI 'Server\.listen\s+([0-9]+)' -r '$1' "$d/src" 2>/dev/null | head -1)"
  [ -z "$p" ] && p="$(rg -NoI '\b(80[0-9][0-9])\b' -r '$1' "$d/src" 2>/dev/null | head -1)"
  echo "${p:-8000}"
}

# Boot a server binary, wait until "/" answers (bounded), echo "pid port" or "".
boot_server() {
  local bin="$1" port="$2" log deadline
  log="$(mktemp)"
  SKY_LIVE_PORT="$port" PORT="$port" "$bin" >"$log" 2>&1 &
  local pid=$!; SERVER_PIDS+=("$pid")
  deadline=$(( $(date +%s) + SERVER_READY_S ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    kill -0 "$pid" 2>/dev/null || { rm -f "$log"; echo ""; return; }
    # Prefer the app's self-reported "listening on …:PORT" line if present.
    local lp; lp="$(rg -io 'listening on[^0-9]*:([0-9]+)' -r '$1' "$log" 2>/dev/null | tail -1)"
    [ -n "$lp" ] || lp="$port"
    if curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$lp/" 2>/dev/null; then
      rm -f "$log"; echo "$pid $lp"; return
    fi
    sleep 0.2
  done
  rm -f "$log"; kill -9 "$pid" 2>/dev/null; echo ""
}

reap_server() { # $1=pid
  local pid="$1"
  kill -TERM "$pid" 2>/dev/null; sleep 0.3; kill -KILL "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null || true
}

# Throughput (req/s) of an already-running server. "" if ab absent / no result.
ab_throughput() { # $1=port
  [ "$HAVE_AB" -eq 1 ] || { echo ""; return; }
  local rps
  rps="$(timeout "$AB_TIMEOUT_S" ab -r -n "$AB_N" -c "$AB_C" "http://127.0.0.1:$1/" 2>/dev/null \
        | awk '/Requests per second/{print $4}')"
  echo "${rps:-}"
}

# Peak RSS (MB, 1 decimal) of a pid from /proc VmRSS. "" if unreadable.
rss_mb() { # $1=pid
  local kb; kb="$(awk '/^VmRSS:/{print $2}' "/proc/$1/status" 2>/dev/null)"
  [ -n "$kb" ] && awk -v k="$kb" 'BEGIN{printf "%.1f", k/1024}' || echo ""
}

# Measure a server binary (boot → throughput + peak RSS → reap). Echoes
# "thru|rss" — a `|`-delimited pair so an empty throughput field can't shift the
# rss into the wrong slot (space-split read would misassign when thru is empty).
measure_server() { # $1=binary $2=port
  local bin="$1" port="$2" pp pid actual thru="" rss=""
  pp="$(boot_server "$bin" "$port")"
  if [ -n "$pp" ]; then
    pid="${pp% *}"; actual="${pp#* }"
    thru="$(ab_throughput "$actual")"
    rss="$(rss_mb "$pid")"
    reap_server "$pid"
  fi
  echo "${thru:-}|${rss:-}"
}

# ── Static link assertion (Linux): the musl binary must be statically linked ─
assert_static_linux() { # $1=binary -> "yes"/"no"/""
  [ -x "$1" ] || { echo ""; return; }
  if ldd "$1" 2>&1 | grep -qi 'not a dynamic executable\|statically linked'; then
    echo "yes"
  else
    echo "no"
  fi
}

say "=== static-perf @ $OS_LABEL · $STAMP · ${#EXAMPLES[@]} examples (RUNNABLE=$RUNNABLE, ab=$HAVE_AB) ==="
printf 'example\tshape\tos\tbuild_static\tdyn_bytes\tstatic_bytes\tgo_bytes\tcold_dyn_ms\tcold_static_ms\tthru_dyn\tthru_static\trss_dyn_mb\trss_static_mb\n' > "$TSV"

for entry in "${EXAMPLES[@]}"; do
  n="${entry%%:*}"; shape="${entry##*:}"
  d="examples/$n"
  [ -f "$d/src/Main.sky" ] || { say "  -- $n: no src/Main.sky, skipping --"; continue; }
  say "  -- $n ($shape) --"

  build_static="fail"
  dyn_b=""; static_b=""; go_b=""
  cold_dyn=""; cold_static=""
  thru_dyn=""; thru_static=""; rss_dyn=""; rss_static=""

  ( cd "$d" && rm -rf sky-out .skycache .skydeps 2>/dev/null ) || true

  # 1. Emit the Rust project (sky build --backend rust also debug-builds; harmless).
  if ! ( cd "$d" && SKY_RUST_FMT=0 timeout "$EMIT_TIMEOUT" "$SKY_BIN" build --backend rust src/Main.sky ) >>"$LOG" 2>&1; then
    say "     sky --backend rust emit FAILED"
    printf '%s\t%s\t%s\tsky-gen-fail\t\t\t\t\t\t\t\t\t\n' "$n" "$shape" "$OS_LABEL" >> "$TSV"
    ( cd "$d" && rm -rf sky-out .skycache .skydeps 2>/dev/null ) || true
    continue
  fi

  # 2. Dynamic release build.
  if ( cd "$d" && timeout "$CARGO_TIMEOUT" cargo build --release --manifest-path sky-out/Rust/Cargo.toml ) >>"$LOG" 2>&1; then
    dyn_b="$(fsize "$CARGO_TARGET_DIR/release/sky-app")"
    DYN_BIN="$CARGO_TARGET_DIR/release/sky-app"
  else
    say "     dynamic release build FAILED"
    DYN_BIN=""
  fi

  # 3. Static release build (per-OS mechanism).
  STATIC_BIN=""
  case "$OS_LABEL" in
    Linux|macOS)
      # musl static-pie + mimalloc (macOS cross-compiles → linux ELF).
      if ( cd "$d" && timeout "$CARGO_TIMEOUT" cargo build --release \
            --target "$MUSL_TRIPLE" --features static_alloc \
            --manifest-path sky-out/Rust/Cargo.toml ) >>"$LOG" 2>&1; then
        build_static="ok"
        STATIC_BIN="$CARGO_TARGET_DIR/$MUSL_TRIPLE/release/sky-app"
        static_b="$(fsize "$STATIC_BIN")"
      fi
      ;;
    Windows)
      # Native target, static MSVC CRT via RUSTFLAGS.
      if ( cd "$d" && RUSTFLAGS="-C target-feature=+crt-static" timeout "$CARGO_TIMEOUT" \
            cargo build --release --manifest-path sky-out/Rust/Cargo.toml ) >>"$LOG" 2>&1; then
        build_static="ok"
        # Windows native release binary (Git Bash sees the .exe).
        STATIC_BIN="$CARGO_TARGET_DIR/release/sky-app.exe"
        [ -f "$STATIC_BIN" ] || STATIC_BIN="$CARGO_TARGET_DIR/release/sky-app"
        static_b="$(fsize "$STATIC_BIN")"
      fi
      ;;
    *)
      say "     unknown OS '$OS_LABEL' — static build skipped"
      ;;
  esac

  # 4. Go release build (fully-static baseline). Best-effort; may fail on composites.
  if ( cd "$d" && timeout "$GO_TIMEOUT" "$SKY_BIN" build src/Main.sky ) >>"$LOG" 2>&1; then
    go_b="$(fsize "$d/sky-out/app")"
  else
    say "     go build n/a (best-effort)"
  fi

  # 5. Static-link assertion (Linux only).
  if [ "$OS_LABEL" = "Linux" ] && [ -n "$STATIC_BIN" ]; then
    link_check="$(assert_static_linux "$STATIC_BIN")"
    say "     static link check: $link_check"
    [ "$link_check" = "no" ] && build_static="ok-but-dynamic"
  fi

  # 6. PERF — Linux + RUNNABLE only.
  if [ "$OS_LABEL" = "Linux" ] && [ "$RUNNABLE" -eq 1 ]; then
    case "$shape" in
      cli|tui)
        [ -n "$DYN_BIN" ]    && cold_dyn="$(coldstart_ms "$DYN_BIN")"
        [ -n "$STATIC_BIN" ] && cold_static="$(coldstart_ms "$STATIC_BIN")"
        ;;
      server|live)
        port="$(server_port_for "$d")"
        if [ -n "$DYN_BIN" ]; then
          ms="$(measure_server "$DYN_BIN" "$port")"; thru_dyn="${ms%%|*}"; rss_dyn="${ms##*|}"
        fi
        if [ -n "$STATIC_BIN" ]; then
          ms="$(measure_server "$STATIC_BIN" "$port")"; thru_static="${ms%%|*}"; rss_static="${ms##*|}"
        fi
        ;;
    esac
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$n" "$shape" "$OS_LABEL" "$build_static" \
    "$dyn_b" "$static_b" "$go_b" \
    "$cold_dyn" "$cold_static" \
    "$thru_dyn" "$thru_static" "$rss_dyn" "$rss_static" >> "$TSV"

  ( cd "$d" && rm -rf sky-out .skycache .skydeps 2>/dev/null ) || true
done

# ── Markdown table (sizes in KiB; ratios; perf where measured) ──────────────
{
  echo "### static-perf — $OS_LABEL ($STAMP)"
  echo
  echo "| Example | Shape | Static build | Dynamic | Static | Go | Static/Dyn | Cold dyn→static | Thru dyn→static | RSS dyn→static |"
  echo "|---|---|---|--:|--:|--:|--:|--:|--:|--:|"
  while IFS=$'\t' read -r ex sh os bstat dynb statb gob cdyn cstat tdyn tstat rdyn rstat; do
    [ "$ex" = example ] && continue
    kib() { [ -n "$1" ] && awk -v b="$1" 'BEGIN{printf "%.0fK", b/1024}' || echo "—"; }
    ratio() { { [ -n "$1" ] && [ -n "$2" ] && [ "$2" -gt 0 ]; } 2>/dev/null && awk -v a="$1" -v b="$2" 'BEGIN{printf "%.2f", a/b}' || echo "—"; }
    pair() { { [ -n "$1" ] || [ -n "$2" ]; } && echo "${1:-—}→${2:-—}" || echo "—"; }
    printf '| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n' \
      "$ex" "$sh" "$bstat" "$(kib "$dynb")" "$(kib "$statb")" "$(kib "$gob")" \
      "$(ratio "$statb" "$dynb")" "$(pair "$cdyn" "$cstat")" \
      "$(pair "$tdyn" "$tstat")" "$(pair "$rdyn" "$rstat")"
  done < "$TSV"
} | tee "$MD" >&2

say ""
say "=== DONE · os=$OS_LABEL · stamp=$STAMP ==="
say "    tsv=$TSV"
say "    md=$MD"
echo "$OS_LABEL $STAMP"   # STDOUT: machine-readable OS label + stamp
exit 0
