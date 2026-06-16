# shellcheck shell=bash
# runtime-rust/scripts/lib/env.sh — SINGLE SOURCE OF TRUTH for the Rust-backend
# sweep command env. SOURCE this (never execute it): `source "$(dirname "$0")/lib/env.sh"`.
#
# Every sweep runner (build / run / web / perf / equiv) and the wrappers
# (build-sweep / keep-go-parity) source this so the env gotchas live in ONE place
# and can't drift. Any VERIFIED speed improvement is added HERE so every skill
# inherits it automatically (CLAUDE.md directive).
#
# It is idempotent: safe to source even when the caller has already cd'd into the
# repo or pre-set CARGO_TARGET_DIR / RUSTC_WRAPPER (all `${VAR:-default}` forms).
# It defines REPO + SKY_BIN; it does NOT cd (callers `cd "$REPO"` themselves so
# the failure path stays theirs).

# ── PATH: self-contained, deterministic across tool calls ───────────────────
# cargo + go must resolve from their canonical dirs; .ghcup/bin trails so cargo/go
# win (sky is always invoked by absolute SKY_BIN, never via PATH). A web runner
# that needs node prepends its own NODE_BIN BEFORE sourcing — this is the base.
export PATH="$HOME/.cargo/bin:/usr/local/go/bin:/usr/local/bin:/usr/bin:/bin:$HOME/.ghcup/bin"

# ── Shared cargo target + sccache + CARGO_INCREMENTAL=0 (all mandatory) ──────
# A shared CARGO_TARGET_DIR *outside* each example's sky-out/ compiles the heavy
# deps (axum/tokio/serde/sqlx/…) ONCE and persists across the per-example
# `rm -rf sky-out`. sccache (RUSTC_WRAPPER) additionally caches each rustc by
# content hash. CARGO_INCREMENTAL=0 is NON-NEGOTIABLE: sccache silently caches
# NOTHING when incremental=true (every request lands "non-cacheable: incremental");
# with it off, cold builds drop ~75s → ~15s (verified). The sweeps are sequential,
# so no target-dir lock contention. Override CARGO_TARGET_DIR to relocate the cache.
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$HOME/.cache/sky-rust-target}"
export CARGO_INCREMENTAL=0
command -v sccache >/dev/null 2>&1 && export RUSTC_WRAPPER="${RUSTC_WRAPPER:-sccache}"
mkdir -p "$CARGO_TARGET_DIR"

# ── Repo-root detection → REPO + SKY_BIN ────────────────────────────────────
# Honour an explicit SKY_REPO; else detect via the runner-script anchor (works
# whether sourced from $PWD or a known checkout). Don't cd — that's the caller's.
REPO="${SKY_REPO:-${REPO:-}}"
[ -z "$REPO" ] && [ -f "$PWD/runtime-rust/scripts/rust-sweep.sh" ] && REPO="$PWD"
[ -z "$REPO" ] && [ -f "$HOME/Documentos/comp/sky/runtime-rust/scripts/rust-sweep.sh" ] && REPO="$HOME/Documentos/comp/sky"
export REPO
export SKY_BIN="${SKY_BIN:-$REPO/sky-out/sky}"
