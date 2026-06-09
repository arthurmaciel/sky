# S1 Perf-Harness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the Rust-vs-Go performance-benchmark harness that gates every later parity slice — a bash orchestrator reusing `hyperfine`/`ab` plus a standalone Rust `sse-bench` client for the deep Sky.Live SSE round-trip.

**Architecture:** `scripts/rust-perf.sh` release-builds an example on both backends, detects its app shape, runs per-shape probes, and pass/fails the Rust numbers against data-derived Go-relative envelopes in `scripts/rust-perf.thresholds`. The one thing no off-the-shelf tool measures — `POST /_sky/event` → SSE-patch round-trip latency — is `tools/sse-bench/`, a small async-Rust binary with hermetic tests.

**Tech Stack:** Bash, `hyperfine` (cargo-installed), `ab` (present), `/usr/bin/time`; Rust (tokio + reqwest + clap + serde_json; axum as a dev-dependency for the mock SSE server).

---

## Spec

`runtime-rust/docs/superpowers/specs/2026-06-09-rust-perf-harness-design.md`. Read it first.

## Preconditions

- S0 floor far enough that `sky build --target rust` works and `01-hello-world`, `15-http-server`, `09-live-counter` build on **both** `--target go` (default) and `--target rust`. Confirm before Task 8.
- Never run `sky build` from the repo root; `cd` into the example dir first.
- Timeout-bound every load phase; kill every spawned server before exit (no orphans).
- Commits carry no co-author line; docs/tooling stay in the fork.

## File Structure

| File | Responsibility |
|---|---|
| `tools/sse-bench/Cargo.toml` | Standalone cargo bin manifest + deps. |
| `tools/sse-bench/src/lib.rs` | Pure, unit-tested core: percentile math + `Summary` JSON. |
| `tools/sse-bench/src/main.rs` | CLI args + the concurrent SSE session loop. |
| `tools/sse-bench/tests/integration.rs` | Hermetic test: mock axum SSE server + bench logic. |
| `scripts/rust-perf.sh` | The orchestrator: build, shape-detect, probe, gate, report. |
| `scripts/rust-perf.thresholds` | Generated Go-relative envelopes (committed). |

---

## Task 1: Scaffold `sse-bench` + the percentile core (test-first)

**Files:**
- Create: `tools/sse-bench/Cargo.toml`, `tools/sse-bench/src/lib.rs`

- [ ] **Step 1: Create the manifest**

`tools/sse-bench/Cargo.toml`:
```toml
[package]
name = "sse-bench"
version = "0.1.0"
edition = "2021"

[dependencies]
tokio = { version = "1", features = ["rt-multi-thread", "macros", "time", "sync"] }
reqwest = { version = "0.12", features = ["stream"] }
clap = { version = "4", features = ["derive"] }
serde_json = "1"
futures-util = "0.3"

[dev-dependencies]
axum = "0.7"
tokio = { version = "1", features = ["full"] }
```

- [ ] **Step 2: Write the failing unit test for percentiles**

`tools/sse-bench/src/lib.rs`:
```rust
/// Round-trip latency summary for an sse-bench run.
#[derive(Debug, Clone, PartialEq)]
pub struct Summary {
    pub patch_p50: f64,
    pub patch_p95: f64,
    pub patch_p99: f64,
    pub events_per_sec: f64,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn percentiles_on_known_sample() {
        // 1..=100 ms; nearest-rank percentile.
        let xs: Vec<f64> = (1..=100).map(|n| n as f64).collect();
        let s = Summary::from_latencies_ms(&xs, 1.0); // 100 events in 1 s
        assert_eq!(s.patch_p50, 50.0);
        assert_eq!(s.patch_p95, 95.0);
        assert_eq!(s.patch_p99, 99.0);
        assert_eq!(s.events_per_sec, 100.0);
    }

    #[test]
    fn percentiles_empty_is_zero() {
        let s = Summary::from_latencies_ms(&[], 1.0);
        assert_eq!(s, Summary { patch_p50: 0.0, patch_p95: 0.0, patch_p99: 0.0, events_per_sec: 0.0 });
    }
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `cd tools/sse-bench && cargo test percentiles 2>&1 | tail -5`
Expected: FAIL — `Summary::from_latencies_ms` not found.

- [ ] **Step 4: Implement the core to pass**

Prepend to `tools/sse-bench/src/lib.rs` (above the `#[cfg(test)]`):
```rust
impl Summary {
    /// Build a summary from per-event round-trip latencies (ms) and the wall
    /// time (s) the run took. Nearest-rank percentiles; empty → all zero.
    pub fn from_latencies_ms(latencies_ms: &[f64], wall_secs: f64) -> Summary {
        if latencies_ms.is_empty() {
            return Summary { patch_p50: 0.0, patch_p95: 0.0, patch_p99: 0.0, events_per_sec: 0.0 };
        }
        let mut v = latencies_ms.to_vec();
        v.sort_by(|a, b| a.partial_cmp(b).unwrap());
        let pct = |p: f64| -> f64 {
            // nearest-rank: rank = ceil(p/100 * N), 1-indexed
            let rank = ((p / 100.0) * v.len() as f64).ceil().max(1.0) as usize;
            v[rank.min(v.len()) - 1]
        };
        let eps = if wall_secs > 0.0 { v.len() as f64 / wall_secs } else { 0.0 };
        Summary { patch_p50: pct(50.0), patch_p95: pct(95.0), patch_p99: pct(99.0), events_per_sec: eps }
    }

    /// Emit the run as a single-line JSON object (the harness contract).
    pub fn to_json(&self) -> String {
        serde_json::json!({
            "patch_p50": self.patch_p50,
            "patch_p95": self.patch_p95,
            "patch_p99": self.patch_p99,
            "events_per_sec": self.events_per_sec,
        }).to_string()
    }
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd tools/sse-bench && cargo test 2>&1 | tail -5`
Expected: PASS — both tests green.

- [ ] **Step 6: Commit**

```bash
git add tools/sse-bench/Cargo.toml tools/sse-bench/src/lib.rs
git commit -m "feat(perf): sse-bench percentile core + Summary JSON"
```

---

## Task 2: The `sse-bench` session loop + CLI

**Files:**
- Create: `tools/sse-bench/src/main.rs`
- Modify: `tools/sse-bench/src/lib.rs` (add `run_session` so it's integration-testable)

- [ ] **Step 1: Add the session runner to the library (so the integration test can call it)**

Append to `tools/sse-bench/src/lib.rs` (above `#[cfg(test)]`):
```rust
use std::time::Instant;
use futures_util::StreamExt;

/// One session: open the SSE stream, then fire `events` POSTs sequentially,
/// timing each from send to the next SSE patch frame. Returns the latencies (ms).
/// Per-session sequential firing makes event→patch correlation unambiguous.
pub async fn run_session(base: &str, events: usize) -> Result<Vec<f64>, String> {
    let client = reqwest::Client::new();
    let sse = client.get(format!("{base}/_sky/sse"))
        .send().await.map_err(|e| format!("sse connect: {e}"))?;
    let mut stream = sse.bytes_stream();

    // Drain the initial `hello` frame so the first measured event isn't skewed.
    let _ = next_frame(&mut stream).await;

    let mut lat = Vec::with_capacity(events);
    for _ in 0..events {
        let t0 = Instant::now();
        client.post(format!("{base}/_sky/event"))
            .header("content-type", "application/json")
            .body("{\"id\":\"bench\",\"event\":\"click\",\"args\":[]}")
            .send().await.map_err(|e| format!("post: {e}"))?;
        next_frame(&mut stream).await.ok_or("sse closed".to_string())?;
        lat.push(t0.elapsed().as_secs_f64() * 1000.0);
    }
    Ok(lat)
}

/// Read bytes until one complete SSE frame (terminated by a blank line) arrives.
async fn next_frame<S>(stream: &mut S) -> Option<String>
where S: futures_util::Stream<Item = reqwest::Result<bytes::Bytes>> + Unpin {
    let mut buf = String::new();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.ok()?;
        buf.push_str(&String::from_utf8_lossy(&chunk));
        if buf.contains("\n\n") { return Some(buf); }
    }
    None
}
```
Add `bytes = "1"` to `[dependencies]` in `Cargo.toml` (reqwest re-exports it, but name it explicitly for the signature).

- [ ] **Step 2: Write `main.rs` — CLI + concurrent aggregation**

`tools/sse-bench/src/main.rs`:
```rust
use clap::Parser;
use sse_bench::{run_session, Summary};
use std::time::Instant;

#[derive(Parser)]
struct Args {
    #[arg(long)] url: String,
    #[arg(long, default_value_t = 2000)] events: usize,
    #[arg(long, default_value_t = 16)] concurrency: usize,
}

#[tokio::main]
async fn main() {
    let args = Args::parse();
    let per = (args.events + args.concurrency - 1) / args.concurrency; // ceil
    let start = Instant::now();
    let mut handles = Vec::new();
    for _ in 0..args.concurrency {
        let url = args.url.clone();
        handles.push(tokio::spawn(async move { run_session(&url, per).await }));
    }
    let mut all = Vec::new();
    for h in handles {
        match h.await {
            Ok(Ok(mut v)) => all.append(&mut v),
            Ok(Err(e)) => { eprintln!("session error: {e}"); std::process::exit(1); }
            Err(e) => { eprintln!("join error: {e}"); std::process::exit(1); }
        }
    }
    let wall = start.elapsed().as_secs_f64();
    println!("{}", Summary::from_latencies_ms(&all, wall).to_json());
}
```

- [ ] **Step 3: Verify it compiles**

Run: `cd tools/sse-bench && cargo build 2>&1 | tail -5`
Expected: compiles (warnings ok). No server to hit yet — Task 3 tests it.

- [ ] **Step 4: Commit**

```bash
git add tools/sse-bench/src/main.rs tools/sse-bench/src/lib.rs tools/sse-bench/Cargo.toml
git commit -m "feat(perf): sse-bench session loop + CLI"
```

---

## Task 3: Hermetic integration test (mock SSE server)

**Files:**
- Create: `tools/sse-bench/tests/integration.rs`

- [ ] **Step 1: Write the failing integration test**

`tools/sse-bench/tests/integration.rs`:
```rust
// A mock Sky.Live endpoint: GET /_sky/sse streams frames; each POST /_sky/event
// triggers one patch frame. Exercises run_session without a real Sky app.
use axum::{routing::{get, post}, Router, response::IntoResponse, http::header};
use std::sync::Arc;
use tokio::sync::broadcast;

async fn spawn_mock() -> (String, tokio::task::JoinHandle<()>) {
    let (tx, _rx) = broadcast::channel::<()>(1024);
    let tx = Arc::new(tx);
    let tx_sse = tx.clone();
    let app = Router::new()
        .route("/_sky/sse", get(move || {
            let mut rx = tx_sse.subscribe();
            async move {
                let stream = async_stream::stream! {
                    // initial hello frame
                    yield Ok::<_, std::convert::Infallible>(axum::body::Bytes::from("event: hello\ndata: {}\n\n"));
                    while rx.recv().await.is_ok() {
                        yield Ok(axum::body::Bytes::from("event: patch\ndata: []\n\n"));
                    }
                };
                ([(header::CONTENT_TYPE, "text/event-stream")], axum::body::Body::from_stream(stream))
            }
        }))
        .route("/_sky/event", post(move || { let tx = tx.clone(); async move { let _ = tx.send(()); "ok".into_response() } }));
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let h = tokio::spawn(async move { axum::serve(listener, app).await.unwrap(); });
    (format!("http://{addr}"), h)
}

#[tokio::test]
async fn run_session_measures_roundtrips() {
    let (base, _h) = spawn_mock().await;
    let lat = sse_bench::run_session(&base, 20).await.expect("session ok");
    assert_eq!(lat.len(), 20, "one latency per event");
    assert!(lat.iter().all(|&x| x >= 0.0 && x < 5000.0), "latencies sane: {lat:?}");
}
```
Add to `Cargo.toml` `[dev-dependencies]`: `async-stream = "0.3"`.

- [ ] **Step 2: Run it to verify it fails first (before deps wired)**

Run: `cd tools/sse-bench && cargo test --test integration 2>&1 | tail -8`
Expected: FAIL to compile until `async-stream` is added; after adding, the test runs.

- [ ] **Step 3: Add the dev-dep and make it pass**

Ensure `Cargo.toml` `[dev-dependencies]` has `axum`, `async-stream`, and full-feature `tokio`. Run:
`cd tools/sse-bench && cargo test --test integration 2>&1 | tail -8`
Expected: PASS — `run_session_measures_roundtrips ... ok` (20 latencies, all sane).

- [ ] **Step 4: Commit**

```bash
git add tools/sse-bench/tests/integration.rs tools/sse-bench/Cargo.toml
git commit -m "test(perf): hermetic mock-SSE integration test for sse-bench"
```

---

## Task 4: Orchestrator — build both targets + shape detection

**Files:**
- Create: `scripts/rust-perf.sh`

- [ ] **Step 1: Write the orchestrator skeleton (build + shape detect)**

`scripts/rust-perf.sh`:
```bash
#!/usr/bin/env bash
# Rust-vs-Go perf harness. Usage: rust-perf.sh <example> [--shape auto|cli|server|live]
#                                  rust-perf.sh --baseline
set -uo pipefail
cd "$(dirname "$0")/.."
SKY="${SKY_BIN:-$PWD/sky-out/sky}"
THRESH="$PWD/scripts/rust-perf.thresholds"
AB_N=10000; AB_C=50; SSE_EVENTS=2000; SSE_CONC=16; COLD_RUNS=20

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
    echo "$d/sky-out/app"
  else
    ( cd "$d" && timeout 300 "$SKY" build src/Main.sky --target rust ) >/tmp/perf-build-rust-gen.log 2>&1 || return 1
    ( cd "$d" && timeout 900 cargo build --release --manifest-path sky-out/Rust/Cargo.toml ) >/tmp/perf-build-rust.log 2>&1 || return 1
    find "$d/sky-out/Rust/target/release" -maxdepth 1 -type f -executable | head -1
  fi
}
```

- [ ] **Step 2: Add a temporary debug tail and self-check shape detection**

Append temporarily:
```bash
if [ "${1:-}" = "--selftest-shape" ]; then
  echo "01:$(detect_shape examples/01-hello-world) 15:$(detect_shape examples/15-http-server) 09:$(detect_shape examples/09-live-counter)"
  exit 0
fi
```
Run: `chmod +x scripts/rust-perf.sh && scripts/rust-perf.sh --selftest-shape`
Expected: `01:cli 15:server 09:live`. Then delete the temporary `--selftest-shape` block.

- [ ] **Step 3: Commit**

```bash
git add scripts/rust-perf.sh
git commit -m "feat(perf): rust-perf orchestrator skeleton (build + shape detect)"
```

---

## Task 5: Orchestrator — the per-shape probes

**Files:**
- Modify: `scripts/rust-perf.sh` (append probe functions)

- [ ] **Step 1: Append the probe functions**

Append to `scripts/rust-perf.sh`:
```bash
# All probes echo a single number. Servers/live get a spawn→ready cold-start.
free_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'; }

probe_binsize() { stat -c%s "$1"; }

probe_coldstart_cli() { # $1=binary -> median ms
  hyperfine --warmup 3 --runs "$COLD_RUNS" --export-json /tmp/perf-hf.json "$1" >/dev/null 2>&1 || { echo 0; return; }
  python3 -c 'import json;d=json.load(open("/tmp/perf-hf.json"));print(d["results"][0]["median"]*1000)'
}

probe_coldstart_server() { # $1=binary -> median ms (exec→first 200)
  local samples=() i port pid t0 t1
  for i in $(seq 1 "$COLD_RUNS"); do
    port=$(free_port)
    t0=$(date +%s.%N)
    SKY_LIVE_PORT="$port" PORT="$port" "$1" >/dev/null 2>&1 &
    pid=$!
    until curl -s -o /dev/null "http://127.0.0.1:$port/"; do
      kill -0 "$pid" 2>/dev/null || break
    done
    t1=$(date +%s.%N)
    kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    samples+=("$(echo "($t1-$t0)*1000" | bc -l)")
  done
  printf '%s\n' "${samples[@]}" | sort -n | awk '{a[NR]=$1} END{print a[int(NR/2)+1]}'
}

start_server() { # $1=binary -> echoes "pid port"
  local port; port=$(free_port)
  SKY_LIVE_PORT="$port" PORT="$port" "$1" >/dev/null 2>&1 &
  local pid=$!
  until curl -s -o /dev/null "http://127.0.0.1:$port/"; do kill -0 "$pid" 2>/dev/null || return 1; done
  echo "$pid $port"
}

probe_throughput() { # $1=binary -> req/s
  local pp; pp=$(start_server "$1") || { echo 0; return; }
  local pid=${pp% *} port=${pp#* }
  local rps; rps=$(ab -n "$AB_N" -c "$AB_C" "http://127.0.0.1:$port/" 2>/dev/null \
      | awk '/Requests per second/{print $4}')
  kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  echo "${rps:-0}"
}

probe_rss_cli() { # $1=binary -> peak RSS KB
  /usr/bin/time -v "$1" 2>/tmp/perf-time.txt >/dev/null
  awk '/Maximum resident set size/{print $NF}' /tmp/perf-time.txt
}

probe_rss_server() { # $1=binary -> peak RSS KB under load
  local pp; pp=$(start_server "$1") || { echo 0; return; }
  local pid=${pp% *} port=${pp#* }
  ab -n "$AB_N" -c "$AB_C" "http://127.0.0.1:$port/" >/dev/null 2>&1
  local hwm; hwm=$(awk '/VmHWM/{print $2}' "/proc/$pid/status" 2>/dev/null)
  kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  echo "${hwm:-0}"
}

probe_live_sse() { # $1=binary -> "p95_ms eps" under sse-bench
  local pp; pp=$(start_server "$1") || { echo "0 0"; return; }
  local pid=${pp% *} port=${pp#* }
  local out; out=$(tools/sse-bench/target/release/sse-bench --url "http://127.0.0.1:$port" \
      --events "$SSE_EVENTS" --concurrency "$SSE_CONC" 2>/dev/null)
  kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  echo "$(echo "$out" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["patch_p95"],d["events_per_sec"])' 2>/dev/null || echo "0 0")"
}
```

- [ ] **Step 2: Build sse-bench release (probe_live_sse needs it)**

Run: `cd tools/sse-bench && cargo build --release 2>&1 | tail -2`
Expected: `Finished release`.

- [ ] **Step 3: Commit**

```bash
git add scripts/rust-perf.sh
git commit -m "feat(perf): per-shape probes (cold-start/throughput/RSS/binsize/SSE)"
```

---

## Task 6: Orchestrator — threshold engine, table, gate, `--baseline`

**Files:**
- Modify: `scripts/rust-perf.sh` (append the gate driver + `main`)

- [ ] **Step 1: Append the metric collection, gate, and main driver**

Append to `scripts/rust-perf.sh`:
```bash
# collect_metrics <bindir-binary> <shape> -> writes assoc lines "metric value" to stdout
collect_metrics() { # $1=binary $2=shape
  local b="$1" s="$2"
  echo "binsize $(probe_binsize "$b")"
  case "$s" in
    cli)
      echo "coldstart $(probe_coldstart_cli "$b")"
      echo "rss $(probe_rss_cli "$b")" ;;
    server)
      echo "coldstart $(probe_coldstart_server "$b")"
      echo "throughput $(probe_throughput "$b")"
      echo "rss $(probe_rss_server "$b")" ;;
    live)
      echo "coldstart $(probe_coldstart_server "$b")"
      echo "throughput $(probe_throughput "$b")"
      echo "rss $(probe_rss_server "$b")"
      read -r p95 eps < <(probe_live_sse "$b")
      echo "patch_p95 $p95"; echo "event_throughput $eps" ;;
  esac
}

# direction: lower-is-better unless metric is throughput-like
is_higher_better() { case "$1" in throughput|event_throughput) return 0;; *) return 1;; esac; }

gate_metric() { # $1=shape $2=metric $3=go $4=rust -> prints row, returns 0 pass / 1 fail
  local shape="$1" m="$2" go="$3" rust="$4"
  local ratio; ratio=$(echo "scale=4; if($go==0) 0 else $rust/$go" | bc -l)
  local key thr verdict
  if is_higher_better "$m"; then
    key="${shape}.${m}_ratio_min"; thr=$(awk -F'= *' -v k="$key" '$1~k{print $2}' "$THRESH")
    [ -z "$thr" ] && thr=0
    verdict=$(echo "$ratio >= $thr" | bc -l)
  else
    key="${shape}.${m}_ratio_max"; thr=$(awk -F'= *' -v k="$key" '$1~k{print $2}' "$THRESH")
    [ -z "$thr" ] && thr=999
    verdict=$(echo "$ratio <= $thr" | bc -l)
  fi
  local tag; [ "$verdict" = 1 ] && tag=PASS || tag=FAIL
  printf "  %-18s %12s %12s  ratio=%-7s thr=%-7s %s\n" "$m" "$go" "$rust" "$ratio" "$thr" "$tag"
  [ "$verdict" = 1 ]
}

# within ±5% of the threshold boundary → eligible for a single re-roll.
is_borderline() { # $1=shape $2=metric $3=go $4=rust
  local shape="$1" m="$2" go="$3" rust="$4"
  local ratio; ratio=$(echo "scale=4; if($go==0) 0 else $rust/$go" | bc -l)
  local key thr
  if is_higher_better "$m"; then key="${shape}.${m}_ratio_min"; else key="${shape}.${m}_ratio_max"; fi
  thr=$(awk -F'= *' -v k="$key" '$1~k{print $2}' "$THRESH"); [ -z "$thr" ] && return 1
  python3 -c "import sys; t=$thr; r=$ratio; sys.exit(0 if t and abs(r-t)/t<=0.05 else 1)"
}
# better of two rust samples for a metric (min if lower-is-better, max otherwise)
better() { # $1=metric $2=a $3=b
  if is_higher_better "$1"; then python3 -c "print(max($2,$3))"; else python3 -c "print(min($2,$3))"; fi
}

run_one() { # $1=example  -> table + exit code
  local ex="$1" d="examples/$1" shape="${SHAPE:-}"
  [ -n "$shape" ] || shape=$(detect_shape "$d")
  local gobin rustbin
  gobin=$(build_target "$d" go)   || { echo "go build failed for $ex"; return 3; }
  rustbin=$(build_target "$d" rust) || { echo "rust build failed for $ex"; return 1; }
  declare -A GO RUST
  while read -r k v; do GO[$k]=$v; done   < <(collect_metrics "$gobin" "$shape")
  while read -r k v; do RUST[$k]=$v; done < <(collect_metrics "$rustbin" "$shape")
  echo "== $ex ($shape) =="
  # First gate pass: collect borderline fails for a single re-roll.
  local borderline=()
  for m in "${!GO[@]}"; do
    gate_metric "$shape" "$m" "${GO[$m]}" "${RUST[$m]:-0}" >/dev/null && continue
    is_borderline "$shape" "$m" "${GO[$m]}" "${RUST[$m]:-0}" && borderline+=("$m")
  done
  # Re-roll: re-measure rust once; borderline metrics take the better sample.
  if [ ${#borderline[@]} -gt 0 ]; then
    echo "  (re-rolling borderline: ${borderline[*]})"
    declare -A RUST2
    while read -r k v; do RUST2[$k]=$v; done < <(collect_metrics "$rustbin" "$shape")
    for m in "${borderline[@]}"; do RUST[$m]=$(better "$m" "${RUST[$m]}" "${RUST2[$m]:-0}"); done
  fi
  # Final gate + table + JSON from the (possibly re-rolled) rust values.
  local fail=0 json="{\"example\":\"$ex\",\"shape\":\"$shape\",\"metrics\":{"
  for m in "${!GO[@]}"; do
    gate_metric "$shape" "$m" "${GO[$m]}" "${RUST[$m]:-0}" || fail=1
    json="$json\"$m\":{\"go\":${GO[$m]},\"rust\":${RUST[$m]:-0}},"
  done
  echo "${json%,}}}" > "/tmp/rust-perf-$ex.json"
  return $fail
}

# --- entry ---
SHAPE=""
[ "${2:-}" = "--shape" ] && SHAPE="${3:-}"
case "${1:-}" in
  --baseline) baseline ;;             # defined in Task 7
  "" ) echo "usage: rust-perf.sh <example> [--shape S] | --baseline"; exit 2 ;;
  * ) run_one "$1"; exit $? ;;
esac
```

- [ ] **Step 2: Commit (baseline stub follows in Task 7)**

```bash
git add scripts/rust-perf.sh
git commit -m "feat(perf): threshold gate engine + table + JSON artifact"
```

---

## Task 7: `--baseline` mode (derive + write thresholds)

**Files:**
- Modify: `scripts/rust-perf.sh` (add `baseline`)
- Create: `scripts/rust-perf.thresholds` (generated)

- [ ] **Step 1: Add the `baseline` function above the entry block**

Insert into `scripts/rust-perf.sh` before `# --- entry ---`:
```bash
# Baseline: run each representative example M times, write variance-padded
# Go-relative envelopes. CV-padded: threshold = ratio*(1+2*CV), rounded 2dp.
baseline() {
  local M=5; : > "$THRESH"
  echo "# generated $(date -u +%FT%TZ) — rust/go ratio envelopes, CV-padded" >> "$THRESH"
  for pair in "01-hello-world:cli" "15-http-server:server" "09-live-counter:live"; do
    local ex=${pair%:*} shape=${pair#*:} d="examples/${pair%:*}"
    declare -A ratios
    local gobin rustbin
    gobin=$(build_target "$d" go) && rustbin=$(build_target "$d" rust) || { echo "baseline build failed: $ex"; continue; }
    for i in $(seq 1 "$M"); do
      declare -A GO RUST
      while read -r k v; do GO[$k]=$v; done   < <(collect_metrics "$gobin" "$shape")
      while read -r k v; do RUST[$k]=$v; done < <(collect_metrics "$rustbin" "$shape")
      for m in "${!GO[@]}"; do
        local r; r=$(echo "scale=4; if(${GO[$m]}==0) 0 else ${RUST[$m]:-0}/${GO[$m]}" | bc -l)
        ratios[$m]="${ratios[$m]:-} $r"
      done
    done
    for m in "${!ratios[@]}"; do
      read -r mean cv < <(echo "${ratios[$m]}" | python3 -c '
import sys,statistics as st
xs=[float(x) for x in sys.stdin.read().split()]
m=st.mean(xs); sd=st.pstdev(xs) if len(xs)>1 else 0.0
print(m, (sd/m if m else 0.0))')
      local pad; pad=$(python3 -c "print(round($mean*(1+2*$cv),2))")
      if [ "$m" = throughput ] || [ "$m" = event_throughput ]; then
        local lo; lo=$(python3 -c "print(round($mean*(1-2*$cv),2))")
        echo "${shape}.${m}_ratio_min = $lo" >> "$THRESH"
      else
        echo "${shape}.${m}_ratio_max = $pad" >> "$THRESH"
      fi
    done
  done
  echo "wrote $THRESH"; cat "$THRESH"
}
```

- [ ] **Step 2: Install hyperfine (cold-start probe needs it)**

Run: `command -v hyperfine || cargo install hyperfine`
Expected: `hyperfine` on PATH.

- [ ] **Step 3: Generate the baseline thresholds**

Run: `timeout 1800 scripts/rust-perf.sh --baseline`
Expected: builds 01/15/09 on both backends, prints + writes `scripts/rust-perf.thresholds` with `cli.* / server.* / live.*` ratio lines. (Requires S0: the three examples build on `--target rust`.)

- [ ] **Step 4: Commit the script + the committed baseline**

```bash
git add scripts/rust-perf.sh scripts/rust-perf.thresholds
git commit -m "feat(perf): --baseline derives + commits Go-relative envelopes"
```

---

## Task 8: Self-test + negative test (prove the gate gates)

**Files:**
- Modify: none (verification only); optionally `scripts/verify-rust-target.sh` to call the self-test.

- [ ] **Step 1: Positive self-test — CLI example passes its own baseline**

Run: `scripts/rust-perf.sh 01-hello-world; echo "exit=$?"`
Expected: a `== 01-hello-world (cli) ==` table with `coldstart/rss/binsize` rows all `PASS`; `exit=0`; `/tmp/rust-perf-01-hello-world.json` written.

- [ ] **Step 2: Negative test — impossible threshold forces a fail**

```bash
cp scripts/rust-perf.thresholds /tmp/thr.bak
sed -i 's/cli.coldstart_ratio_max = .*/cli.coldstart_ratio_max = 0.01/' scripts/rust-perf.thresholds
scripts/rust-perf.sh 01-hello-world; echo "exit=$?"
cp /tmp/thr.bak scripts/rust-perf.thresholds
```
Expected: the `coldstart` row shows `FAIL`; `exit=1` — proving the gate actually blocks. (Thresholds restored afterward.)

- [ ] **Step 3: Server + Live smoke**

Run: `scripts/rust-perf.sh 15-http-server; echo "exit=$?"` then `scripts/rust-perf.sh 09-live-counter; echo "exit=$?"`
Expected: server table includes `throughput`; live table includes `patch_p95` + `event_throughput`; both `exit=0` (within their own baselines).

- [ ] **Step 4: Confirm no orphan servers remain**

Run: `pgrep -af 'sky-out/Rust/target/release|sky-out/app' || echo "  no orphans"`
Expected: `no orphans` (every probe kills its server).

- [ ] **Step 5: Commit (mark S1 gate verified)**

```bash
git commit --allow-empty -m "test(perf): S1 gate verified — positive + negative + no orphans"
```

---

## Task 9: Wire into the verify gate + final cleanup

**Files:**
- Modify: `scripts/verify-rust-target.sh`

- [ ] **Step 1: Add an informational perf step to the verify gate**

Append before the final "All checks passed" in `scripts/verify-rust-target.sh`:
```bash
echo ""
echo "=== 7. Perf harness smoke (informational) ==="
scripts/rust-perf.sh 01-hello-world || echo "perf gate FAIL on 01-hello-world"
```
(Informational here; the per-slice hard gate is invoked by each capability slice, not the floor gate.)

- [ ] **Step 2: Reclaim disk (release builds + cargo are heavy)**

```bash
for d in examples/01-hello-world examples/15-http-server examples/09-live-counter; do
  ( cd "$d" && rm -rf sky-out .skycache .skydeps )
done
go clean -cache 2>/dev/null || true
df -h / | tail -1
```

- [ ] **Step 3: Commit**

```bash
git add scripts/verify-rust-target.sh
git commit -m "feat(perf): wire informational perf smoke into verify-rust-target.sh"
```

---

## Self-Review (completed by author)

- **Spec coverage:** four units (sse-bench Cargo/lib/main/tests → Tasks 1–3; rust-perf.sh → Tasks 4–7; thresholds → Task 7) all built. Metrics-per-shape → Task 5 `collect_metrics`. Cold-start CLI-vs-server split → `probe_coldstart_cli`/`probe_coldstart_server` (Task 5). Hard noise-robust gate → hyperfine warmup + median (Task 5), CV-padded envelopes (Task 7), directional `gate_metric` (Task 6). Deep Live → `sse-bench` + `probe_live_sse` (Tasks 1–3, 5). Fairness/release-only → `build_target` rust path uses `cargo build --release` (Task 4); readiness-gated load via `start_server` poll (Task 5); no-orphans verified (Task 8 Step 4). Output contract (table + JSON + exit code) → Task 6 `run_one`. `--baseline` → Task 7. Self-test + negative test → Task 8. Gate invocation unchanged for later slices (`rust-perf.sh <example>`) → Task 6 entry block.
- **Borderline re-run:** the spec's ±5% re-roll is implemented in `run_one` (Task 6) via `is_borderline` + `better` — a first gate pass flags borderline fails, rust is re-measured once, and the better sample is taken before the final verdict. No spec item deferred.
- **Placeholder scan:** none — every step has runnable code/commands. Discovery is confined to the baseline *values* (data-derived by design), not to logic.
- **Consistency:** `Summary::from_latencies_ms` / `to_json` / `run_session` signatures match across Tasks 1–3; metric names (`coldstart`, `throughput`, `rss`, `binsize`, `patch_p95`, `event_throughput`) match between `collect_metrics` (Task 5), `gate_metric` (Task 6), and `baseline` (Task 7); threshold keys (`<shape>.<metric>_ratio_{min,max}`) are identical in `gate_metric` and `baseline`.
