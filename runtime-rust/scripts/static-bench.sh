#!/usr/bin/env bash
# Static-vs-dynamic binary benchmark (Linux) for the Sky Rust backend.
#
# For every STATICALLY-COMPILABLE example it builds the RELEASE binary three
# ways and records size + cold-start:
#   dynamic  — `cargo build --release` (glibc-dynamic, the default)
#   static   — `cargo build --release --target x86_64-unknown-linux-musl
#              --features static_alloc` (musl static-pie + mimalloc)
#   go       — `sky build` (the Go backend, fully static) for the size baseline
# "Statically-compilable" = every Rust-buildable example MINUS webview/fyne
# (they link system GUI libs and can't be static). Go-FFI examples build no Rust
# at all and are skipped by perf_set already.
#
# Output: a TSV + a ready-to-paste markdown table (dynamic vs static vs Go size,
# the static/dynamic + static/go ratios, and cold-start dynamic vs static). This
# answers the "Go is fully static, Rust wasn't — is the size comparison fair?"
# question with a like-for-like (static-vs-static) number.
#
# Exit 0 always (informational). Heavy: each example builds release ×2 (+Go);
# the musl dep tree compiles once then caches in the shared CARGO_TARGET_DIR.
set -uo pipefail

source "$(dirname "$0")/lib/env.sh"
source "$(dirname "$0")/lib/examples.sh"
source "$(dirname "$0")/lib/checks.sh"

MUSL_TRIPLE="x86_64-unknown-linux-musl"
# Point cargo at the musl C cross-linker for the C deps (zstd/sqlite/ring), if present.
if command -v x86_64-linux-musl-gcc >/dev/null 2>&1; then
  export CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_LINKER="x86_64-linux-musl-gcc"
fi

HIST="$HOME/.cache/sky/static-bench"; mkdir -p "$HIST"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
TSV="$HIST/static-bench-$STAMP.tsv"
LOG="$HIST/static-bench-$STAMP.log"
MD="$HIST/static-bench-$STAMP.md"
say() { echo "$@" | tee -a "$LOG"; }

command -v "$SKY_BIN" >/dev/null 2>&1 || SKY_BIN="$REPO/sky-out/sky"
[ -x "$SKY_BIN" ] || { echo "ERROR: sky binary not at $SKY_BIN" >&2; exit 2; }
rustup target list --installed 2>/dev/null | grep -qx "$MUSL_TRIPLE" || {
  echo "ERROR: musl target missing — run: rustup target add $MUSL_TRIPLE" >&2; exit 2; }

cd "$REPO"
TBASE="${CARGO_TARGET_DIR:-}"
[ -n "$TBASE" ] || { echo "ERROR: export CARGO_TARGET_DIR first (see lib/env.sh)" >&2; exit 2; }

# size in bytes of an existing file, or empty
fsize() { [ -f "$1" ] && stat -c%s "$1" 2>/dev/null || echo ""; }
# cold-start ms (best of 5) of a cli/simple binary; "" for non-runnable shapes
coldstart_ms() {
  local bin="$1" best="" i t0 t1 ms
  [ -x "$bin" ] || { echo ""; return; }
  for i in 1 2 3 4 5; do
    t0="$({ gdate +%s%N 2>/dev/null || date +%s%N; })"
    timeout 10 "$bin" >/dev/null 2>&1 </dev/null || true
    t1="$({ gdate +%s%N 2>/dev/null || date +%s%N; })"
    ms=$(( (t1 - t0) / 1000000 ))
    { [ -z "$best" ] || [ "$ms" -lt "$best" ]; } && best="$ms"
  done
  echo "$best"
}

# Build set: Rust-buildable minus webview/fyne.
EX=()
while IFS= read -r d; do
  n="$(basename "$d")"; shape="$(example_shape "$d")"
  case "$shape" in webview|fyne) continue ;; esac
  EX+=("$n")
done < <(perf_set)

say "=== static-vs-dynamic bench @ $STAMP · ${#EX[@]} examples ==="
printf 'example\tshape\tdyn_bytes\tstatic_bytes\tgo_bytes\tcold_dyn_ms\tcold_static_ms\tstatus\n' > "$TSV"

for n in "${EX[@]}"; do
  d="examples/$n"; [ -f "$d/src/Main.sky" ] || continue
  shape="$(example_shape "$d")"
  say "  -- $n ($shape) --"
  ( cd "$d" && rm -rf sky-out .skycache .skydeps sky-out/rust 2>/dev/null ) || true

  # Generate the Rust project (sky build also debug-builds; harmless, we rebuild release).
  if ! ( cd "$d" && SKY_RUST_FMT=0 timeout 600 "$SKY_BIN" build --backend rust src/Main.sky ) >>"$LOG" 2>&1; then
    printf '%s\t%s\t\t\t\t\t\tsky-gen-fail\n' "$n" "$shape" >> "$TSV"; continue
  fi
  MAN="$d/sky-out/rust/Cargo.toml"

  # Dynamic release.
  dyn_b=""; status="ok"
  if ( cd "$d" && timeout 900 cargo build --release --manifest-path sky-out/rust/Cargo.toml ) >>"$LOG" 2>&1; then
    dyn_b="$(fsize "$TBASE/release/sky-app")"
  else
    status="dyn-build-fail"
  fi
  # only cli/simple have a meaningful cold-start-to-exit; skip the call entirely
  # for server/live/tui shapes (their binary never exits → 5× timeout 10 waste).
  cold_d=""; [ "$shape" = cli ] && cold_d="$(coldstart_ms "$TBASE/release/sky-app")"

  # Static (musl) release.
  st_b=""
  if ( cd "$d" && timeout 1200 cargo build --release --target "$MUSL_TRIPLE" --features static_alloc --manifest-path sky-out/rust/Cargo.toml ) >>"$LOG" 2>&1; then
    st_b="$(fsize "$TBASE/$MUSL_TRIPLE/release/sky-app")"
  else
    { [ "$status" = ok ] && status="static-build-fail"; } || status="$status,static-build-fail"
  fi
  cold_s=""; [ "$shape" = cli ] && cold_s="$(coldstart_ms "$TBASE/$MUSL_TRIPLE/release/sky-app")"

  # Go release (fully-static baseline). Best-effort; Go-FFI/absent-go → blank.
  go_b=""; if ( cd "$d" && timeout 600 "$SKY_BIN" build src/Main.sky ) >>"$LOG" 2>&1; then
    go_b="$(fsize "$d/sky-out/app")"; fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$n" "$shape" "$dyn_b" "$st_b" "$go_b" "$cold_d" "$cold_s" "$status" >> "$TSV"
  ( cd "$d" && rm -rf sky-out .skycache .skydeps 2>/dev/null ) || true
done

# ── Markdown table (sizes in MiB, ratios) ───────────────────────────────────
mib() { [ -n "$1" ] && awk -v b="$1" 'BEGIN{printf "%.2fM", b/1048576}' || echo "—"; }
ratio() { { [ -n "$1" ] && [ -n "$2" ] && [ "$2" -gt 0 ]; } 2>/dev/null && awk -v a="$1" -v b="$2" 'BEGIN{printf "%.2f", a/b}' || echo "—"; }
{
  echo "| Example | Shape | Dynamic | Static (musl) | Go | Static/Dyn | Static/Go | Cold dyn→static (cli) |"
  echo "|---|---|--:|--:|--:|--:|--:|--:|"
  while IFS=$'\t' read -r n shape dyn st go cd cs status; do
    [ "$n" = example ] && continue
    cold="—"; { [ -n "$cd" ] && [ -n "$cs" ]; } && cold="${cd}→${cs} ms"
    note=""; [ "$status" != ok ] && note=" ⚠$status"
    printf '| %s | %s | %s | %s | %s | %s | %s | %s |%s\n' \
      "$n" "$shape" "$(mib "$dyn")" "$(mib "$st")" "$(mib "$go")" \
      "$(ratio "$st" "$dyn")" "$(ratio "$st" "$go")" "$cold" "$note"
  done < "$TSV"
} | tee "$MD" | tee -a "$LOG"

say ""; say "=== DONE · tsv=$TSV · md=$MD ==="
exit 0
