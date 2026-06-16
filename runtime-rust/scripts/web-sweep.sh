#!/usr/bin/env bash
# Sky Rust-backend WEB sweep — build each live/web example on --target rust and
# drive it through a REAL headless browser (system chromium), replaying the
# repo's maintained per-example scenario and hard-failing the "click is a no-op"
# class (a scenario click that never POSTs /_sky/event). This is the depth its
# sibling /run-sweep deliberately skips (that one is a curl GET → 200 boot
# check). Build / run / perf are the other three phases.
#
# This script IS the procedure (the /web-sweep skill). Don't re-decide the
# steps ad-hoc; if a run reveals a better way (a new scenario, a flake, a
# launch quirk), IMPROVE THIS SCRIPT (and/or runtime-rust/scripts/web-verify.mjs).
#
# Exit: 0 = every example PASS · 1 = a web/build failure · 2 = setup error.
set -uo pipefail

# ── Resolve the repo ───────────────────────────────────────────────────────
REPO="${SKY_REPO:-}"
[ -z "$REPO" ] && [ -f "$PWD/runtime-rust/scripts/rust-sweep.sh" ] && REPO="$PWD"
[ -z "$REPO" ] && [ -f "$HOME/Documentos/comp/sky/runtime-rust/scripts/rust-sweep.sh" ] && REPO="$HOME/Documentos/comp/sky"
if [ -z "$REPO" ] || [ ! -d "$REPO/examples" ]; then
  echo "ERROR: can't locate the Sky repo. cd into it, or set SKY_REPO=/path/to/sky." >&2; exit 2
fi
cd "$REPO"

# ── Env (the gotchas, baked in) ────────────────────────────────────────────
# node lives under nvm; chromium is the system binary (no bundled Playwright).
NODE_BIN="$(ls -d "$HOME"/.nvm/versions/node/*/bin 2>/dev/null | sort -V | tail -1)"
export PATH="${NODE_BIN:+$NODE_BIN:}$HOME/.ghcup/bin:$HOME/.cargo/bin:/usr/local/go/bin:/usr/local/bin:/usr/bin:/bin"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$HOME/.cache/sky-rust-target}"  # shared; run right after build
command -v sccache >/dev/null 2>&1 && export RUSTC_WRAPPER="${RUSTC_WRAPPER:-sccache}"
export SKY_BIN="$REPO/sky-out/sky"
export SKY_CHROMIUM="${SKY_CHROMIUM:-/usr/bin/chromium}"
export SKY_CONSOLE_EMBED=off            # don't spawn the console child while smoke-driving
[ -x "$SKY_BIN" ]      || { echo "ERROR: sky binary not at $SKY_BIN — build it (cabal build exe:sky)." >&2; exit 2; }
command -v node >/dev/null 2>&1 || { echo "ERROR: node not on PATH (looked under ~/.nvm)." >&2; exit 2; }
[ -x "$SKY_CHROMIUM" ] || { echo "ERROR: chromium not at $SKY_CHROMIUM (set SKY_CHROMIUM=…)." >&2; exit 2; }
[ -d "$REPO/node_modules/playwright" ] || { echo "ERROR: playwright not in $REPO/node_modules — npm i." >&2; exit 2; }
mkdir -p "$CARGO_TARGET_DIR"

DRIVER="$REPO/runtime-rust/scripts/web-verify.mjs"
[ -f "$DRIVER" ] || { echo "ERROR: driver missing: $DRIVER" >&2; exit 2; }

HIST="$HOME/.cache/sky/web-sweep"; mkdir -p "$HIST"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOG="$HIST/web-$STAMP.log"
say() { echo "$@" | tee -a "$LOG"; }
say "=== Sky Rust WEB sweep @ $STAMP (repo: $REPO · chromium: $SKY_CHROMIUM) ==="

reap() { for p in sky-app app sky-console; do pkill -x "$p" 2>/dev/null; done
         pkill -f "examples/.*/sky-out/" 2>/dev/null; pkill -f web-verify.mjs 2>/dev/null; }
ps -u "$USER" -o pid,args 2>/dev/null | awk '/\/sky (lsp|doc)/{print $1}' | xargs -r kill 2>/dev/null
reap; sync; sleep 1

free_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()' 2>/dev/null || echo 8743; }

# ── Live/web set: examples with a maintained round-trip scenario in
# scripts/verify-scenarios.mjs that ALSO build on --target rust. Each row is
# "example  scenario". (Port is allocated free per-run; the scenario keys are
# the same the Go-backend verify-all-web.sh drives.)
#   RUST_WEB="09-live-counter:live-counter 12-skyvote:skyvote"  → explicit override.
WEB_FULL=(
  "09-live-counter live-counter"
  "10-live-component live-component"
  "12-skyvote skyvote"
  "16-skychess skychess"
  "17-skymon skymon"
  "18-job-queue job-queue"
  "19-skyforum skyforum"
)
if [ -n "${RUST_WEB:-}" ]; then
  ENTRIES=(); for tok in $RUST_WEB; do ENTRIES+=("${tok/:/ }"); done
else
  ENTRIES=("${WEB_FULL[@]}")
fi

PASS=0; FAIL=0; SKIP=0; FAILED=""
for entry in "${ENTRIES[@]}"; do
  set -- $entry; ex="$1"; scen="${2:-smoke}"
  d="examples/$ex"
  [ -f "$d/src/Main.sky" ] || { say "  SKIP   $ex (absent)"; SKIP=$((SKIP+1)); continue; }

  # Build on --target rust (run right after, while the shared target binary is this example's).
  ( cd "$d" && rm -rf sky-out .skycache .skydeps && timeout 240 "$SKY_BIN" build src/Main.sky --target rust ) \
    >"$HIST/$ex.build.log" 2>&1
  if [ "$(cd "$d" && timeout 600 cargo build --manifest-path sky-out/Rust/Cargo.toml -q >>"$HIST/$ex.build.log" 2>&1; echo $?)" != 0 ]; then
    say "  BUILD-FAIL $ex"; FAIL=$((FAIL+1)); FAILED="$FAILED $ex(build)"; ( cd "$d" && rm -rf sky-out .skycache .skydeps ); continue
  fi
  bin="$CARGO_TARGET_DIR/debug/sky-app"; [ -x "$bin" ] || bin="$d/sky-out/Rust/target/debug/sky-app"
  [ -x "$bin" ] || { say "  BUILD-FAIL $ex (no binary)"; FAIL=$((FAIL+1)); FAILED="$FAILED $ex(nobin)"; continue; }

  port="$(free_port)"
  if node "$DRIVER" "$ex" "$port" "$scen" "$bin" >"$HIST/$ex.web.log" 2>&1; then
    say "  WEB-OK    $ex ($(grep -oE 'scenario [a-z0-9-]+.*' "$HIST/$ex.web.log" | head -1))"; PASS=$((PASS+1))
  else
    say "  WEB-FAIL  $ex ($(grep -m1 '^FAIL' "$HIST/$ex.web.log" | sed 's/^FAIL [^ ]* — //'))"; FAIL=$((FAIL+1)); FAILED="$FAILED $ex(web)"
  fi
  reap
  ( cd "$d" && rm -rf sky-out .skycache .skydeps )
done

reap
say ""; say "=== WEB SWEEP: $PASS pass · $FAIL fail · $SKIP skipped ==="
[ -n "$FAILED" ] && say "  failures:$FAILED"
say "  per-example logs: $HIST/<ex>.{build,web}.log · browser artefacts: $REPO/.skycache/verify-rust/<ex>/"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
