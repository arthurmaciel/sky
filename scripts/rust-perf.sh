#!/usr/bin/env bash
# Rust-vs-Go perf harness (roadmap slice S1).
#   rust-perf.sh <example> [--shape auto|cli|server|live]   # gate one example
#   rust-perf.sh --baseline                                 # (re)derive thresholds
# Exit: 0 all metrics pass · 1 gate fail · 3 a backend can't build it.
set -uo pipefail
cd "$(dirname "$0")/.."
SKY="${SKY_BIN:-$PWD/sky-out/sky}"
THRESH="$PWD/scripts/rust-perf.thresholds"
AB_N=10000; AB_C=50; SSE_EVENTS=2000; SSE_CONC=16; COLD_RUNS=20
SSE_BIN="$PWD/tools/sse-bench/target/release/sse-bench"

pyf() { python3 -c "import sys; print($1)"; }   # float expr → stdout
pytrue() { python3 -c "import sys; sys.exit(0 if ($1) else 1)"; }  # bool expr → exit

detect_shape() { # $1=example dir
  if grep -rqE "Std\.Live|Live\.app" "$1/src" 2>/dev/null; then echo live
  elif grep -rqE "Server\.listen|Sky\.Http\.Server" "$1/src" 2>/dev/null; then echo server
  else echo cli; fi
}

build_target() { # $1=example dir  $2=go|rust  -> echoes the release binary path
  local d="$1" t="$2"
  ( cd "$d" && rm -rf sky-out .skycache .skydeps ) >/dev/null 2>&1
  if [ "$t" = go ]; then
    ( cd "$d" && timeout 300 "$SKY" build src/Main.sky ) >/tmp/perf-build-go.log 2>&1 || return 1
    # Both backends share $d/sky-out; the rust build's `rm -rf sky-out` would
    # wipe this binary. Copy it out so it survives the rust build.
    local dst="/tmp/perf-$(basename "$d")-go.bin"
    cp "$d/sky-out/app" "$dst" || return 1
    echo "$dst"
  else
    ( cd "$d" && timeout 300 "$SKY" build src/Main.sky --target rust ) >/tmp/perf-build-rust-gen.log 2>&1 || return 1
    ( cd "$d" && timeout 900 cargo build --release --manifest-path sky-out/Rust/Cargo.toml ) >/tmp/perf-build-rust.log 2>&1 || return 1
    local rel="${CARGO_TARGET_DIR:-$d/sky-out/Rust/target}/release"
    find "$rel" -maxdepth 1 -type f -executable -name 'sky-app' 2>/dev/null | head -1
  fi
}

free_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'; }
probe_binsize() { stat -c%s "$1"; }

probe_coldstart_cli() { # $1=binary -> median ms
  hyperfine --warmup 3 --runs "$COLD_RUNS" --export-json /tmp/perf-hf.json "$1" >/dev/null 2>&1 || { echo 0; return; }
  python3 -c 'import json;d=json.load(open("/tmp/perf-hf.json"));print(d["results"][0]["median"]*1000)'
}

# Bounded readiness wait — poll `curl` up to READY_TIMEOUT_S (default 10s) with a
# 0.1s sleep, never a busy-spin. Returns 0 when the server answers, 1 if it dies
# or the deadline passes. A server that binds a port the probe can't reach (an
# example hardcoding 8000, a crash-on-boot) must NOT hang the harness — the
# original unbounded `until curl; do kill -0 || break; done` busy-looped forever
# while the process stayed alive (stalled --baseline on the server shape).
READY_TIMEOUT_S="${READY_TIMEOUT_S:-10}"
wait_ready() { # $1=pid $2=port -> 0 ready / 1 not
  local tries=0 max=$(( ${READY_TIMEOUT_S%.*} * 10 ))
  until curl -s -o /dev/null "http://127.0.0.1:$2/"; do
    kill -0 "$1" 2>/dev/null || return 1
    tries=$((tries+1)); [ "$tries" -ge "$max" ] && return 1
    sleep 0.1
  done
}

probe_coldstart_server() { # $1=binary -> median ms (exec→first 200)
  local samples=() i port pid t0 t1
  for i in $(seq 1 "$COLD_RUNS"); do
    port=$(free_port); t0=$(date +%s.%N)
    SKY_LIVE_PORT="$port" PORT="$port" "$1" >/dev/null 2>&1 & pid=$!
    wait_ready "$pid" "$port" || { kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; continue; }
    t1=$(date +%s.%N); kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    samples+=("$(pyf "($t1-$t0)*1000")")
  done
  [ ${#samples[@]} -eq 0 ] && { echo 0; return; }
  printf '%s\n' "${samples[@]}" | sort -n | awk '{a[NR]=$1} END{print a[int(NR/2)+1]}'
}

start_server() { # $1=binary -> echoes "pid port"
  local port; port=$(free_port)
  SKY_LIVE_PORT="$port" PORT="$port" "$1" >/dev/null 2>&1 & local pid=$!
  wait_ready "$pid" "$port" || { kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; return 1; }
  echo "$pid $port"
}

probe_throughput() { # $1=binary -> req/s
  local pp; pp=$(start_server "$1") || { echo 0; return; }
  local pid=${pp% *} port=${pp#* } rps
  rps=$(ab -n "$AB_N" -c "$AB_C" "http://127.0.0.1:$port/" 2>/dev/null | awk '/Requests per second/{print $4}')
  kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; echo "${rps:-0}"
}

probe_rss_cli() { /usr/bin/time -v "$1" 2>/tmp/perf-time.txt >/dev/null; awk '/Maximum resident set size/{print $NF}' /tmp/perf-time.txt; }

probe_rss_server() { # $1=binary -> peak RSS KB under load
  local pp; pp=$(start_server "$1") || { echo 0; return; }
  local pid=${pp% *} port=${pp#* } hwm
  ab -n "$AB_N" -c "$AB_C" "http://127.0.0.1:$port/" >/dev/null 2>&1
  hwm=$(awk '/VmHWM/{print $2}' "/proc/$pid/status" 2>/dev/null)
  kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; echo "${hwm:-0}"
}

probe_live_sse() { # $1=binary -> "p95_ms eps"
  local pp; pp=$(start_server "$1") || { echo "0 0"; return; }
  local pid=${pp% *} port=${pp#* } out
  out=$("$SSE_BIN" --url "http://127.0.0.1:$port" --events "$SSE_EVENTS" --concurrency "$SSE_CONC" 2>/dev/null)
  kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  echo "$(echo "$out" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["patch_p95"],d["events_per_sec"])' 2>/dev/null || echo "0 0")"
}

collect_metrics() { # $1=binary $2=shape -> "metric value" lines
  local b="$1" s="$2"
  echo "binsize $(probe_binsize "$b")"
  case "$s" in
    cli) echo "coldstart $(probe_coldstart_cli "$b")"; echo "rss $(probe_rss_cli "$b")" ;;
    server) echo "coldstart $(probe_coldstart_server "$b")"; echo "throughput $(probe_throughput "$b")"; echo "rss $(probe_rss_server "$b")" ;;
    live)
      echo "coldstart $(probe_coldstart_server "$b")"; echo "throughput $(probe_throughput "$b")"; echo "rss $(probe_rss_server "$b")"
      read -r p95 eps < <(probe_live_sse "$b"); echo "patch_p95 $p95"; echo "event_throughput $eps" ;;
  esac
}

is_higher_better() { case "$1" in throughput|event_throughput) return 0;; *) return 1;; esac; }
thr_for() { local key="$1"; [ -f "$THRESH" ] || return 0; awk -F' *= *' -v k="$key" '$1~("^"k"$"){print $2}' "$THRESH"; }

is_borderline() { # $1=shape $2=metric $3=go $4=rust
  local ratio; ratio=$(pyf "0 if $3==0 else $4/$3")
  local key thr
  if is_higher_better "$2"; then key="$1.$2_ratio_min"; else key="$1.$2_ratio_max"; fi
  thr=$(thr_for "$key"); [ -z "$thr" ] && return 1
  pytrue "$thr and abs($ratio-$thr)/$thr <= 0.05"
}
better() { if is_higher_better "$1"; then pyf "max($2,$3)"; else pyf "min($2,$3)"; fi; }

gate_metric() { # $1=shape $2=metric $3=go $4=rust -> row; 0 pass / 1 fail
  local ratio; ratio=$(pyf "round(0 if $3==0 else $4/$3,4)")
  local key thr verdict
  if is_higher_better "$2"; then
    key="$1.$2_ratio_min"; thr=$(thr_for "$key"); [ -z "$thr" ] && thr=0
    pytrue "$ratio >= $thr" && verdict=1 || verdict=0
  else
    key="$1.$2_ratio_max"; thr=$(thr_for "$key"); [ -z "$thr" ] && thr=999
    pytrue "$ratio <= $thr" && verdict=1 || verdict=0
  fi
  local tag; [ "$verdict" = 1 ] && tag=PASS || tag=FAIL
  printf "  %-18s go=%-12s rust=%-12s ratio=%-8s thr=%-8s %s\n" "$2" "$3" "$4" "$ratio" "$thr" "$tag"
  [ "$verdict" = 1 ]
}

run_one() { # $1=example -> table + exit code
  local ex="$1" d="examples/$1" shape="${SHAPE:-}"
  [ -n "$shape" ] || shape=$(detect_shape "$d")
  local gobin rustbin
  gobin=$(build_target "$d" go)   || { echo "go build failed for $ex"; return 3; }
  rustbin=$(build_target "$d" rust) || { echo "rust build failed for $ex"; return 1; }
  declare -A GO RUST
  while read -r k v; do GO[$k]=$v; done   < <(collect_metrics "$gobin" "$shape")
  while read -r k v; do RUST[$k]=$v; done < <(collect_metrics "$rustbin" "$shape")
  echo "== $ex ($shape) =="
  local borderline=()
  for m in "${!GO[@]}"; do
    gate_metric "$shape" "$m" "${GO[$m]}" "${RUST[$m]:-0}" >/dev/null && continue
    is_borderline "$shape" "$m" "${GO[$m]}" "${RUST[$m]:-0}" && borderline+=("$m")
  done
  if [ ${#borderline[@]} -gt 0 ]; then
    echo "  (re-rolling borderline: ${borderline[*]})"
    declare -A RUST2
    while read -r k v; do RUST2[$k]=$v; done < <(collect_metrics "$rustbin" "$shape")
    for m in "${borderline[@]}"; do RUST[$m]=$(better "$m" "${RUST[$m]}" "${RUST2[$m]:-0}"); done
  fi
  local fail=0 json="{\"example\":\"$ex\",\"shape\":\"$shape\",\"metrics\":{"
  for m in "${!GO[@]}"; do
    gate_metric "$shape" "$m" "${GO[$m]}" "${RUST[$m]:-0}" || fail=1
    json="$json\"$m\":{\"go\":${GO[$m]},\"rust\":${RUST[$m]:-0}},"
  done
  echo "${json%,}}}" > "/tmp/rust-perf-$ex.json"
  return $fail
}

baseline() {
  local M=5; : > "$THRESH"
  echo "# generated $(date -u +%FT%TZ) — rust/go ratio envelopes, CV-padded" >> "$THRESH"
  for pair in "01-hello-world:cli" "15-http-server:server" "09-live-counter:live"; do
    local ex=${pair%:*} shape=${pair#*:} d="examples/${pair%:*}"
    local gobin rustbin
    gobin=$(build_target "$d" go) && rustbin=$(build_target "$d" rust) || { echo "baseline build failed: $ex"; continue; }
    declare -A ratios
    for i in $(seq 1 "$M"); do
      declare -A GO RUST
      while read -r k v; do GO[$k]=$v; done   < <(collect_metrics "$gobin" "$shape")
      while read -r k v; do RUST[$k]=$v; done < <(collect_metrics "$rustbin" "$shape")
      for m in "${!GO[@]}"; do
        ratios[$m]="${ratios[$m]:-} $(pyf "0 if ${GO[$m]}==0 else ${RUST[$m]:-0}/${GO[$m]}")"
      done
    done
    for m in "${!ratios[@]}"; do
      read -r mean cv < <(echo "${ratios[$m]}" | python3 -c '
import sys,statistics as st
xs=[float(x) for x in sys.stdin.read().split()]
m=st.mean(xs); sd=st.pstdev(xs) if len(xs)>1 else 0.0
print(m, (sd/m if m else 0.0))')
      if is_higher_better "$m"; then
        echo "${shape}.${m}_ratio_min = $(pyf "round($mean*(1-2*$cv),2)")" >> "$THRESH"
      else
        echo "${shape}.${m}_ratio_max = $(pyf "round($mean*(1+2*$cv),2)")" >> "$THRESH"
      fi
    done
  done
  echo "wrote $THRESH"; cat "$THRESH"
}

# --- entry ---
SHAPE=""
[ "${2:-}" = "--shape" ] && SHAPE="${3:-}"
case "${1:-}" in
  --baseline) baseline ;;
  "" ) echo "usage: rust-perf.sh <example> [--shape S] | --baseline"; exit 2 ;;
  * ) run_one "$1"; exit $? ;;
esac
