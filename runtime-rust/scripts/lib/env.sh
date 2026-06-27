# shellcheck shell=bash
# runtime-rust/scripts/lib/env.sh — SINGLE SOURCE OF TRUTH for the Rust-backend
# sweep command env. SOURCE this (never execute it): `source "$(dirname "$0")/lib/env.sh"`.
#
# Every sweep runner (examples-sweep / examples-perf-sweep) and the wrappers
# (keep-go-parity) source this so the env gotchas live in ONE place
# and can't drift. Any VERIFIED speed improvement is added HERE so every skill
# inherits it automatically (CLAUDE.md directive).
#
# It is idempotent: safe to source even when the caller has already cd'd into the
# repo or pre-set CARGO_TARGET_DIR / RUSTC_WRAPPER (all `${VAR:-default}` forms).
# It defines REPO + SKY_BIN; it does NOT cd (callers `cd "$REPO"` themselves so
# the failure path stays theirs).

# ── PATH: prepend the canonical dev dirs, PRESERVE the inherited PATH ────────
# cargo + go resolve from their canonical local dirs first; .ghcup/bin trails so
# cargo/go win (sky is always invoked by absolute SKY_BIN, never via PATH). The
# trailing `$PATH` is LOAD-BEARING on CI: GitHub's setup-go / setup-node and
# Windows Git Bash put `go` / `node` / `curl` on the runner PATH at non-canonical
# locations — clobbering PATH (dropping the trailing `$PATH`) hid them and aborted
# the sweep at its `command -v go` / `curl` preflight on macOS + Windows. A web
# runner that needs node still prepends its own NODE_BIN BEFORE sourcing.
export PATH="$HOME/.cargo/bin:/usr/local/go/bin:/usr/local/bin:/usr/bin:/bin:$HOME/.ghcup/bin:$PATH"

# ── Shared cargo target + sccache + CARGO_INCREMENTAL=0 ─────────────────────
# A shared CARGO_TARGET_DIR *outside* each example's sky-out/ compiles the heavy
# deps (axum/tokio/serde/sqlx/…) ONCE and persists across the per-example
# `rm -rf sky-out`. Override CARGO_TARGET_DIR to relocate the cache.
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$HOME/.cache/sky-rust-target}"
mkdir -p "$CARGO_TARGET_DIR" || {
  echo "env.sh: could not create CARGO_TARGET_DIR='$CARGO_TARGET_DIR' (perms/ENOSPC?)" >&2
  return 1 2>/dev/null || exit 1
}

# sccache (RUSTC_WRAPPER) additionally caches each rustc by content hash — the
# big LOCAL win. It is coupled to CARGO_INCREMENTAL=0, which is NON-NEGOTIABLE
# *when sccache is on*: sccache caches NOTHING with incremental=true (every
# request lands "non-cacheable: incremental"); with it off, cold builds drop
# ~75s → ~15s (verified). So set incremental=0 ONLY inside the sccache branch —
# when sccache is OFF (e.g. CI), leave CARGO_INCREMENTAL at cargo's default so a
# persisted (actions/cache'd) target dir does incremental rebuilds.
#
# SKY_NO_SCCACHE=1 force-disables sccache even when the binary is on PATH. CI
# sets it: GitHub retired the v1 Actions-Cache API that sccache's GHA backend
# (SCCACHE_GHA_ENABLED) depends on, so an sccache RUSTC_WRAPPER fails at the very
# first `rustc -vV` ("ghac … services aren't available", HTTP 400) and kills
# every cargo build. CI persists CARGO_TARGET_DIR + ~/.cargo via actions/cache
# instead — equivalent cross-run warmth without the dead GHA dependency.
if [ -z "${SKY_NO_SCCACHE:-}" ] && command -v sccache >/dev/null 2>&1; then
    export RUSTC_WRAPPER="${RUSTC_WRAPPER:-sccache}"
    export CARGO_INCREMENTAL=0
fi

# ── Repo-root detection → REPO + SKY_BIN ────────────────────────────────────
# Honour an explicit SKY_REPO; else detect via the runner-script anchor (works
# whether sourced from $PWD or a known checkout). Don't cd — that's the caller's.
# Only SKY_REPO seeds the root — never a pre-existing $REPO. REPO is a common var
# unrelated tooling/CI exports; trusting an inherited value would poison every
# "$REPO/..." path. Autodetection below re-derives the same root, so re-sourcing
# stays idempotent.
REPO="${SKY_REPO:-}"
[ -z "$REPO" ] && [ -f "$PWD/runtime-rust/scripts/lib/examples.sh" ] && REPO="$PWD"
# Checkout-agnostic fallback: ask git for the repo root (works from any subdir of
# any clone). Anchored on THIS file's location so it's independent of $PWD.
if [ -z "$REPO" ]; then
  _env_sh_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
  if [ -n "$_env_sh_dir" ]; then
    REPO="$(git -C "$_env_sh_dir" rev-parse --show-toplevel 2>/dev/null)"
  fi
  unset _env_sh_dir
fi
# Fail closed: an empty REPO would poison every "$REPO/..." path (leading-slash).
if [ -z "$REPO" ]; then
  echo "env.sh: could not locate repo root (set SKY_REPO to override)" >&2
  return 1 2>/dev/null || exit 1
fi
export REPO
export SKY_BIN="${SKY_BIN:-$REPO/sky-out/sky}"
