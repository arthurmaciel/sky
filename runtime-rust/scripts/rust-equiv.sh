#!/usr/bin/env bash
# Differential equivalence for ONE example: generate with a reference compiler
# and the WIP emitter, then check behavioral + structural equivalence.
#
# Reference selection (pluggable):
#   SKY_REF_TARGET=monolith (default) — diff vs a HEAD-monolith sky binary at
#       $SKY_REF (built lazily on first use into .equiv/sky-ref). Used by S0 to
#       stabilize the Builder/ refactor.
#   SKY_REF_TARGET=go — diff the Rust output's behavior vs the SAME compiler's
#       --target go output. Used by S2+ to prove new-capability equivalence
#       against the Go production backend.
#
# Usage: runtime-rust/scripts/rust-equiv.sh <example-name>
# Exit: 0 equivalent · 1 regression · 3 out-of-scope (ref can't build it)
set -uo pipefail
cd "$(dirname "$0")/../.."
EX="$1"
WIP="${SKY_WIP:-$PWD/sky-out/sky}"
REF_TARGET="${SKY_REF_TARGET:-monolith}"
D="examples/$EX"
[ -f "$D/src/Main.sky" ] || { echo "no such example: $EX"; exit 2; }

ensure_ref_binary() { # builds .equiv/sky-ref (HEAD monolith) on first use
  local ref="$PWD/.equiv/sky-ref/sky-out/sky"
  if [ "$REF_TARGET" = monolith ] && [ ! -x "$ref" ]; then
    echo "[equiv] building reference monolith compiler (one-time, slow)…" >&2
    git worktree add --detach .equiv/sky-ref HEAD >/dev/null 2>&1 || true
    ( cd .equiv/sky-ref && timeout 1800 cabal install --overwrite-policy=always \
        --installdir=./sky-out --install-method=copy exe:sky ) >/tmp/equiv-ref-build.log 2>&1 \
      || { echo "[equiv] reference build failed — see /tmp/equiv-ref-build.log" >&2; return 1; }
  fi
  echo "$ref"
}

gen_rust() { # $1=binary $2=outdir
  ( cd "$D" && rm -rf sky-out .skycache .skydeps && timeout 180 "$1" build src/Main.sky --target rust ) \
      >/tmp/equiv-$EX.gen.log 2>&1 || return 1
  rm -rf "$2"; cp -r "$D/sky-out/Rust" "$2"
}
gen_go() { # $1=binary -> echoes the go binary path
  ( cd "$D" && rm -rf sky-out .skycache .skydeps && timeout 180 "$1" build src/Main.sky ) \
      >/tmp/equiv-$EX.gengo.log 2>&1 || return 1
  echo "$D/sky-out/app"
}

WIPD=/tmp/equiv-$EX-wip
gen_rust "$WIP" "$WIPD" || { echo "FAIL[$EX]: WIP rust generate failed"; exit 1; }
cargo build --manifest-path "$WIPD/Cargo.toml" -q || { echo "FAIL[$EX]: WIP cargo-build failed"; exit 1; }
WIPBIN=$(find "$WIPD/target/debug" -maxdepth 1 -type f -executable | head -1)

battery="scripts/equiv-battery/$EX.sh"
run() { if [ -x "$battery" ]; then "$battery" "$1"; else timeout 30 "$1" </dev/null 2>&1 || true; fi ; }

if [ "$REF_TARGET" = go ]; then
  GOBIN=$(gen_go "$WIP") || { echo "OUT-OF-SCOPE[$EX]: go generate failed"; exit 3; }
  if diff <(run "$GOBIN") <(run "$WIPBIN") > /tmp/equiv-$EX.behav.diff; then
    echo "OK[$EX]: behavioral byte-identical vs go"
    exit 0
  else
    echo "FAIL[$EX]: behavioral diff vs go → /tmp/equiv-$EX.behav.diff"; exit 1
  fi
else
  REF=$(ensure_ref_binary) || exit 3
  REFD=/tmp/equiv-$EX-ref
  gen_rust "$REF" "$REFD" || { echo "OUT-OF-SCOPE[$EX]: ref cannot generate it"; exit 3; }
  # Structural review aid: normalized item diff (concat modules, strip plumbing).
  norm() { find "$1/src" -name '*.rs' | sort | xargs cat \
      | rustfmt --emit stdout 2>/dev/null \
      | grep -vE '^\s*(pub )?mod [a-z_]+;|^\s*use (crate|super)::' ; }
  diff <(norm "$REFD") <(norm "$WIPD") > /tmp/equiv-$EX.struct.diff || true
  [ -s /tmp/equiv-$EX.struct.diff ] && \
      echo "STRUCT[$EX]: review /tmp/equiv-$EX.struct.diff — split-plumbing only"
  cargo build --manifest-path "$REFD/Cargo.toml" -q || { echo "OUT-OF-SCOPE[$EX]: ref cargo-build failed"; exit 3; }
  REFBIN=$(find "$REFD/target/debug" -maxdepth 1 -type f -executable | head -1)
  if diff <(run "$REFBIN") <(run "$WIPBIN") > /tmp/equiv-$EX.behav.diff; then
    echo "OK[$EX]: behavioral byte-identical vs monolith"
    exit 0
  else
    echo "FAIL[$EX]: behavioral diff vs monolith → /tmp/equiv-$EX.behav.diff"; exit 1
  fi
fi
