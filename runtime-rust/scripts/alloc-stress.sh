#!/usr/bin/env bash
#
# alloc-stress.sh — allocator stress test for the Sky Rust backend.
#
# Validates the mimalloc global allocator and ISOLATES its effect from the
# static-vs-dynamic linking effect via a 2×2 matrix (linking × allocator):
#
#                  system malloc                 mimalloc
#   dynamic(glibc)  A  cargo build               B  cargo build --features static_alloc
#   static(musl)    D  --target musl             C  --target musl --features static_alloc
#
# All four are built RELEASE from ONE emitted crate (codegen is identical; only
# the cargo invocation differs), each captured to a distinct binary. Each is then
# driven under sustained allocation-heavy load while its RSS is sampled. Reading:
#   • allocator effect, linking held constant : B vs A (dynamic) · C vs D (static)
#   • linking effect, allocator held constant : D vs A · C vs B
#
# Assertions (on the deploy artifact C = static+mimalloc):
#   (a) C's RSS growth (end/start, post-warmup) is bounded — no leak/fragmentation;
#   (b) C's throughput >= STATIC_THROUGHPUT_FLOOR × A (dynamic+system) — mimalloc
#       on musl must not regress throughput vs the default dynamic build.
#
# Every server/load run is timeout-bounded; servers are reaped (TERM→KILL) and
# orphans swept on exit. Exits non-zero on a real assertion failure.
#
# Usage:  runtime-rust/scripts/alloc-stress.sh
set -uo pipefail

# ── Build env (isolated CARGO_TARGET_DIR + sccache per project convention) ──
export PATH="$HOME/.cargo/bin:/usr/local/go/bin:/usr/local/bin:/usr/bin:/bin"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$HOME/.cache/sky-stress-target}"
export RUSTC_WRAPPER="${RUSTC_WRAPPER:-sccache}"
export CARGO_INCREMENTAL="${CARGO_INCREMENTAL:-0}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FIXTURE_DIR="$REPO_ROOT/runtime-rust/tests/sky/alloc-stress"
RUST_DIR="$FIXTURE_DIR/sky-out/Rust"
SKY_BIN="${SKY_BIN:-$REPO_ROOT/sky-out/sky}"
MUSL_TRIPLE="x86_64-unknown-linux-musl"
SERVER_PORT=8080      # the fixture's Server.listen port is hardcoded in Main.sky

# Tunables (override via env).
LOAD_SECONDS="${LOAD_SECONDS:-60}"
AB_N="${AB_N:-20000}"
AB_C="${AB_C:-50}"
RSS_SAMPLE_SEC="${RSS_SAMPLE_SEC:-2}"
SERVER_CEILING="${SERVER_CEILING:-240}"
STATIC_GROWTH_MAX="${STATIC_GROWTH_MAX:-1.5}"
STATIC_THROUGHPUT_FLOOR="${STATIC_THROUGHPUT_FLOOR:-0.85}"

# ── Orphan reaping ──────────────────────────────────────────────────────────
SERVER_PIDS=()
cleanup() {
    for pid in "${SERVER_PIDS[@]:-}"; do [ -n "${pid:-}" ] && kill -TERM "$pid" 2>/dev/null; done
    sleep 1
    for pid in "${SERVER_PIDS[@]:-}"; do [ -n "${pid:-}" ] && kill -KILL "$pid" 2>/dev/null; done
    pkill -f "$CARGO_TARGET_DIR/.*sky-app" 2>/dev/null
}
trap cleanup EXIT INT TERM

die()  { echo "FATAL: $*" >&2; exit 2; }
info() { echo "[alloc-stress] $*" >&2; }   # STDERR → never pollutes captured result lines

command -v cargo >/dev/null || die "cargo not on PATH"
command -v curl  >/dev/null || die "curl not on PATH"
[ -x "$SKY_BIN" ]           || die "sky binary not found at $SKY_BIN"
[ -d "$FIXTURE_DIR" ]       || die "fixture missing: $FIXTURE_DIR"
HAVE_AB=0; command -v ab >/dev/null && HAVE_AB=1

# ── 1. Emit the Rust project once, then build the four variants ─────────────
info "Emitting Rust project (sky build --target rust) ..."
( cd "$FIXTURE_DIR" && timeout 600 "$SKY_BIN" build --target rust src/Main.sky ) \
    >/tmp/alloc-stress-emit.log 2>&1 || { tail -20 /tmp/alloc-stress-emit.log; die "sky emit/build failed"; }
[ -d "$RUST_DIR" ] || die "emitted Rust dir missing: $RUST_DIR"

DYN_SRC="$CARGO_TARGET_DIR/release/sky-app"
MUSL_SRC="$CARGO_TARGET_DIR/$MUSL_TRIPLE/release/sky-app"
BIN_A="/tmp/alloc-stress-A-dyn-sys"     # dynamic glibc, system malloc (default)
BIN_B="/tmp/alloc-stress-B-dyn-mi"      # dynamic glibc, mimalloc
BIN_C="/tmp/alloc-stress-C-musl-mi"     # static musl, mimalloc (the deploy artifact)
BIN_D="/tmp/alloc-stress-D-musl-sys"    # static musl, musl's own malloc

# build_variant <desc> <src-binary> <dest> [extra cargo args...]
build_variant() {
    local desc="$1" src="$2" dest="$3"; shift 3
    info "Building $desc ..."
    timeout 1200 cargo build --release --manifest-path "$RUST_DIR/Cargo.toml" "$@" \
        >/tmp/alloc-stress-build.log 2>&1 || { tail -25 /tmp/alloc-stress-build.log; die "$desc build failed"; }
    [ -x "$src" ] || die "$desc: expected binary missing at $src"
    cp -f "$src" "$dest"
}
build_variant "A dynamic + system malloc"   "$DYN_SRC"  "$BIN_A"
build_variant "B dynamic + mimalloc"        "$DYN_SRC"  "$BIN_B"  --features static_alloc
build_variant "C static(musl) + mimalloc"   "$MUSL_SRC" "$BIN_C"  --target "$MUSL_TRIPLE" --features static_alloc
build_variant "D static(musl) + musl malloc" "$MUSL_SRC" "$BIN_D"  --target "$MUSL_TRIPLE"

# Sanity: C is static and links mimalloc; D is static and does NOT. Release
# binaries are stripped, so verify via cargo tree (dep presence) + `strings`.
ST_LINK="$(ldd "$BIN_C" 2>&1 | head -1)"
MI_DEP="$(cargo tree --manifest-path "$RUST_DIR/Cargo.toml" --target "$MUSL_TRIPLE" --features static_alloc -i mimalloc 2>/dev/null | grep -c '^mimalloc ')"
MI_STR_C="$(strings "$BIN_C" 2>/dev/null | grep -c -i 'mimalloc')"
MI_STR_D="$(strings "$BIN_D" 2>/dev/null | grep -c -i 'mimalloc')"
info "C static link: $ST_LINK ; mimalloc dep-edges: $MI_DEP ; mimalloc strings C=$MI_STR_C D=$MI_STR_D"
{ [ "$MI_DEP" -gt 0 ] && [ "$MI_STR_C" -gt 0 ]; } || die "C does not link mimalloc (dep=$MI_DEP str=$MI_STR_C)"

# ── Helpers ─────────────────────────────────────────────────────────────────
wait_for_server() {
    local pid="$1" i
    for i in $(seq 1 80); do
        kill -0 "$pid" 2>/dev/null || return 1
        curl -fsS -m 2 "http://127.0.0.1:$SERVER_PORT/healthz" >/dev/null 2>&1 && return 0
        sleep 0.25
    done
    return 1
}
rss_kb() { local v; v="$(awk '/^VmRSS:/{print $2}' "/proc/$1/status" 2>/dev/null)"; echo "${v:-0}"; }

# run_variant <label> <binary> → echoes "throughput peakRSS startRSS endRSS growth"
run_variant() {
    local label="$1" bin="$2"
    local logf="/tmp/alloc-stress-server-$label.log" abf="/tmp/alloc-stress-ab-$label.log"
    info "[$label] launching server ..."
    "$bin" >"$logf" 2>&1 &
    local srv=$!; SERVER_PIDS+=("$srv")
    ( sleep "$SERVER_CEILING"; kill -KILL "$srv" 2>/dev/null ) &
    local watchdog=$!
    if ! wait_for_server "$srv"; then tail -20 "$logf" >&2; die "[$label] server did not become ready"; fi
    info "[$label] server up (pid $srv); driving load ~${LOAD_SECONDS}s ..."
    : > "$abf"
    (
        local deadline=$(( $(date +%s) + LOAD_SECONDS ))
        if [ "$HAVE_AB" -eq 1 ]; then
            while [ "$(date +%s)" -lt "$deadline" ]; do
                timeout 90 ab -n "$AB_N" -c "$AB_C" "http://127.0.0.1:$SERVER_PORT/" 2>/dev/null \
                    | grep -E 'Requests per second' >> "$abf"
            done
        else
            local total=0
            while [ "$(date +%s)" -lt "$deadline" ]; do
                for _ in $(seq 1 "$AB_C"); do curl -s -o /dev/null -m 5 "http://127.0.0.1:$SERVER_PORT/" & done
                wait; total=$(( total + AB_C ))
            done
            echo "CURL_TOTAL $total" >> "$abf"
        fi
    ) &
    local loadpid=$!
    local samples=() start_kb=0 end_kb=0 peak_kb=0 warmup_done=0
    while kill -0 "$loadpid" 2>/dev/null; do
        local r; r="$(rss_kb "$srv")"
        if [ "$r" -gt 0 ]; then
            samples+=("$r"); [ "$r" -gt "$peak_kb" ] && peak_kb="$r"
            if [ "$warmup_done" -eq 0 ] && [ "${#samples[@]}" -ge 3 ]; then start_kb="$r"; warmup_done=1; fi
            end_kb="$r"
        fi
        sleep "$RSS_SAMPLE_SEC"
    done
    wait "$loadpid" 2>/dev/null
    [ "$start_kb" -eq 0 ] && [ "${#samples[@]}" -gt 0 ] && start_kb="${samples[0]}"
    [ "$end_kb"   -eq 0 ] && [ "${#samples[@]}" -gt 0 ] && end_kb="${samples[-1]}"
    local thr=0
    if [ "$HAVE_AB" -eq 1 ]; then
        thr="$(awk '/Requests per second/{s+=$4; n++} END{ if(n>0) printf "%.1f", s/n; else print 0 }' "$abf")"
    else
        local ct; ct="$(awk '/CURL_TOTAL/{print $2}' "$abf" | tail -1)"
        thr="$(awk -v c="${ct:-0}" -v s="$LOAD_SECONDS" 'BEGIN{ if(s>0) printf "%.1f", c/s; else print 0 }')"
    fi
    kill "$watchdog" 2>/dev/null
    kill -TERM "$srv" 2>/dev/null; sleep 0.5; kill -KILL "$srv" 2>/dev/null
    local growth; growth="$(awk -v e="$end_kb" -v s="$start_kb" 'BEGIN{ if(s>0) printf "%.3f", e/s; else print 0 }')"
    info "[$label] samples=${#samples[@]} thr=${thr}/s peak=$((peak_kb/1024))MB start=$((start_kb/1024))MB end=$((end_kb/1024))MB growth=${growth}x"
    echo "$thr $peak_kb $start_kb $end_kb $growth"
}

# ── 2. Run the four variants ────────────────────────────────────────────────
read -r A_THR A_PEAK A_START A_END A_GROWTH < <(run_variant "A-dyn-sys"  "$BIN_A")
read -r B_THR B_PEAK B_START B_END B_GROWTH < <(run_variant "B-dyn-mi"   "$BIN_B")
read -r C_THR C_PEAK C_START C_END C_GROWTH < <(run_variant "C-musl-mi"  "$BIN_C")
read -r D_THR D_PEAK D_START D_END D_GROWTH < <(run_variant "D-musl-sys" "$BIN_D")

# ── 3. Report — 2×2 matrix + isolated effects ───────────────────────────────
mb() { awk -v k="$1" 'BEGIN{ printf "%.1f", k/1024 }'; }
ratio() { awk -v a="$1" -v b="$2" 'BEGIN{ if(b>0) printf "%.2f", a/b; else print "—" }'; }

echo
echo "================ ALLOCATOR STRESS — 2×2 (linking × allocator) ================"
printf "%-28s | %11s | %8s | %12s | %7s\n" "variant" "throughput" "peakRSS" "start->end" "growth"
printf "%-28s-+-%11s-+-%8s-+-%12s-+-%7s\n" "----------------------------" "-----------" "--------" "------------" "-------"
printf "%-28s | %8s/s | %5sMB | %4sMB->%4sMB | %5sx\n" "A dynamic + system malloc" "$A_THR" "$(mb "$A_PEAK")" "$(mb "$A_START")" "$(mb "$A_END")" "$A_GROWTH"
printf "%-28s | %8s/s | %5sMB | %4sMB->%4sMB | %5sx\n" "B dynamic + mimalloc"      "$B_THR" "$(mb "$B_PEAK")" "$(mb "$B_START")" "$(mb "$B_END")" "$B_GROWTH"
printf "%-28s | %8s/s | %5sMB | %4sMB->%4sMB | %5sx\n" "C static(musl) + mimalloc" "$C_THR" "$(mb "$C_PEAK")" "$(mb "$C_START")" "$(mb "$C_END")" "$C_GROWTH"
printf "%-28s | %8s/s | %5sMB | %4sMB->%4sMB | %5sx\n" "D static(musl) + musl malloc" "$D_THR" "$(mb "$D_PEAK")" "$(mb "$D_START")" "$(mb "$D_END")" "$D_GROWTH"
echo "------------------------------------------------------------------------------"
echo "isolated effects (throughput ratio):"
echo "  allocator, dynamic linking : B/A (mimalloc vs glibc malloc)  = $(ratio "$B_THR" "$A_THR")x"
echo "  allocator, static  linking : C/D (mimalloc vs musl malloc)   = $(ratio "$C_THR" "$D_THR")x"
echo "  linking, system allocator  : D/A (musl static vs glibc dyn)  = $(ratio "$D_THR" "$A_THR")x"
echo "  deploy artifact vs default : C/A (static+mimalloc vs dyn+sys)= $(ratio "$C_THR" "$A_THR")x"
echo "=============================================================================="
echo "load: ${LOAD_SECONDS}s, ab -n ${AB_N} -c ${AB_C} (loop); RSS every ${RSS_SAMPLE_SEC}s"
[ "$HAVE_AB" -eq 0 ] && echo "NOTE: apache-bench absent — curl-loop fallback for throughput."
echo

# ── 4. Assertions on the deploy artifact (C) ────────────────────────────────
FAIL=0
GROWTH_OK="$(awk -v g="$C_GROWTH" -v m="$STATIC_GROWTH_MAX" 'BEGIN{ print (g>0 && g<m)?1:0 }')"
if [ "$GROWTH_OK" -eq 1 ]; then
    echo "PASS (a) C (static+mimalloc) RSS growth ${C_GROWTH}x < ${STATIC_GROWTH_MAX}x — bounded, no leak/fragmentation."
else
    echo "FAIL (a) C RSS growth ${C_GROWTH}x >= ${STATIC_GROWTH_MAX}x — possible leak/fragmentation."; FAIL=1
fi
THR_FLOOR="$(awk -v d="$A_THR" -v f="$STATIC_THROUGHPUT_FLOOR" 'BEGIN{ printf "%.1f", d*f }')"
THR_OK="$(awk -v s="$C_THR" -v floor="$THR_FLOOR" 'BEGIN{ print (s>=floor)?1:0 }')"
if [ "$THR_OK" -eq 1 ]; then
    echo "PASS (b) C throughput ${C_THR}/s >= ${THR_FLOOR}/s (=${STATIC_THROUGHPUT_FLOOR}x dynamic+system ${A_THR}/s); ratio $(ratio "$C_THR" "$A_THR")x."
else
    echo "FAIL (b) C throughput ${C_THR}/s < ${THR_FLOOR}/s floor — mimalloc-on-musl regressed throughput."; FAIL=1
fi
echo
[ "$FAIL" -eq 0 ] \
    && echo "RESULT: PASS — static+mimalloc keeps RSS bounded under sustained churn and holds throughput." \
    || echo "RESULT: FAIL — see assertions above."
exit "$FAIL"
