#!/usr/bin/env bash
# Differential equivalence for ONE example: generate with a reference compiler
# and the WIP emitter, then check behavioral + structural equivalence.
#
# Reference selection (pluggable):
#   SKY_REF_TARGET=monolith (default) — diff vs a HEAD-monolith sky binary at
#       $SKY_REF (built lazily on first use into .equiv/sky-ref). Used by S0 to
#       stabilize the Builder/ refactor.
#   SKY_REF_TARGET=go — diff the Rust output's behavior vs the SAME compiler's
#       --backend go output. Used by S2+ to prove new-capability equivalence
#       against the Go production backend.
#
# Usage: runtime-rust/scripts/rust-equiv.sh <example-name>
# Exit: 0 equivalent · 1 regression · 3 out-of-scope (ref can't build it)
set -uo pipefail
cd "$(dirname "$0")/../.." || { echo "cannot cd to repo root"; exit 2; }
EX="${1:-}"
[ -n "$EX" ] || { echo "usage: rust-equiv.sh <example-name>"; exit 2; }
WIP="${SKY_WIP:-$PWD/sky-out/sky}"
REF_TARGET="${SKY_REF_TARGET:-monolith}"
D="examples/$EX"
[ -f "$D/src/Main.sky" ] || { echo "no such example: $EX"; exit 2; }

# Per-run private working dir (0700, unpredictable name) for all logs + outputs.
# Avoids fixed /tmp paths an attacker can pre-create / symlink-follow
# (CWE-377/CWE-59). Left on disk after exit so the diff/log paths printed below
# stay inspectable.
WORK=$(mktemp -d "${TMPDIR:-/tmp}/equiv-XXXXXX") || { echo "cannot create work dir"; exit 2; }

ensure_ref_binary() { # builds .equiv/sky-ref (HEAD monolith) on first use
  local ref="$PWD/.equiv/sky-ref/sky-out/sky"
  if [ "$REF_TARGET" = monolith ] && [ ! -x "$ref" ]; then
    echo "[equiv] building reference monolith compiler (one-time, slow)…" >&2
    git worktree add --detach .equiv/sky-ref HEAD >/dev/null 2>&1 || true
    ( cd .equiv/sky-ref && timeout 1800 cabal install --overwrite-policy=always \
        --installdir=./sky-out --install-method=copy exe:sky ) >"$WORK/ref-build.log" 2>&1 \
      || { echo "[equiv] reference build failed — see $WORK/ref-build.log" >&2; return 1; }
  fi
  echo "$ref"
}

gen_rust() { # $1=binary $2=outdir
  ( cd "$D" && rm -rf sky-out .skycache .skydeps && timeout 180 "$1" build src/Main.sky --backend rust ) \
      >"$WORK/gen.log" 2>&1 || return 1
  rm -rf "$2"; cp -r "$D/sky-out/rust" "$2"
}
gen_go() { # $1=binary -> echoes the go binary path
  ( cd "$D" && rm -rf sky-out .skycache .skydeps && timeout 180 "$1" build src/Main.sky ) \
      >"$WORK/gengo.log" 2>&1 || return 1
  echo "$D/sky-out/app"
}

WIPD="$WORK/wip"
gen_rust "$WIP" "$WIPD" || { echo "FAIL[$EX]: WIP rust generate failed"; exit 1; }
# Pin the cargo target dir per-project so an exported (shared) CARGO_TARGET_DIR
# can't clobber it / hide the binary; bound the build per the timeout-gate rule.
CARGO_TARGET_DIR="$WIPD/target" timeout 600 cargo build --manifest-path "$WIPD/Cargo.toml" -q \
    || { echo "FAIL[$EX]: WIP cargo-build failed/timed out"; exit 1; }
WIPBIN=$(find "$WIPD/target/debug" -maxdepth 1 -type f -executable | head -1)
[ -n "$WIPBIN" ] || { echo "FAIL[$EX]: no WIP binary produced"; exit 1; }

battery="scripts/equiv-battery/$EX.sh"
run() { if [ -x "$battery" ]; then "$battery" "$1"; else timeout 30 "$1" </dev/null 2>&1 || true; fi ; }

if [ "$REF_TARGET" = go ]; then
  GOBIN=$(gen_go "$WIP") || { echo "OUT-OF-SCOPE[$EX]: go generate failed"; exit 3; }
  if diff <(run "$GOBIN") <(run "$WIPBIN") > "$WORK/behav.diff"; then
    echo "OK[$EX]: behavioral byte-identical vs go"
    exit 0
  else
    echo "FAIL[$EX]: behavioral diff vs go → $WORK/behav.diff"; exit 1
  fi
else
  REF=$(ensure_ref_binary) || exit 3
  REFD="$WORK/ref"
  gen_rust "$REF" "$REFD" || { echo "OUT-OF-SCOPE[$EX]: ref cannot generate it"; exit 3; }
  # Structural review aid: normalized item diff (concat modules, strip plumbing).
  norm() { find "$1/src" -name '*.rs' | sort | xargs cat \
      | rustfmt --emit stdout 2>/dev/null \
      | grep -vE '^\s*(pub )?mod [a-z_]+;|^\s*use (crate|super)::' ; }
  # diff exit: 0 = identical, 1 = differs (both fine), >1 = norm pipeline error.
  diff <(norm "$REFD") <(norm "$WIPD") > "$WORK/struct.diff"
  struct_rc=$?
  if [ "$struct_rc" -gt 1 ]; then
      echo "STRUCT[$EX]: normalization pipeline failed (rc=$struct_rc) — struct diff unreliable" >&2
  elif [ -s "$WORK/struct.diff" ]; then
      echo "STRUCT[$EX]: review $WORK/struct.diff — split-plumbing only"
  fi
  CARGO_TARGET_DIR="$REFD/target" timeout 600 cargo build --manifest-path "$REFD/Cargo.toml" -q \
      || { echo "OUT-OF-SCOPE[$EX]: ref cargo-build failed/timed out"; exit 3; }
  REFBIN=$(find "$REFD/target/debug" -maxdepth 1 -type f -executable | head -1)
  [ -n "$REFBIN" ] || { echo "OUT-OF-SCOPE[$EX]: no ref binary produced"; exit 3; }
  if diff <(run "$REFBIN") <(run "$WIPBIN") > "$WORK/behav.diff"; then
    echo "OK[$EX]: behavioral byte-identical vs monolith"
    exit 0
  else
    echo "FAIL[$EX]: behavioral diff vs monolith → $WORK/behav.diff"; exit 1
  fi
fi
