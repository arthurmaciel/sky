#!/usr/bin/env bash
# keep-go-parity — the deterministic PLANNER behind the
# sky-rust-backend:keep-go-parity skill. It does NOT run the sweeps or the
# upstream sync (those are agent-orchestrated: sync needs conflict judgement,
# perf needs the close-apps reminder). It captures pre-sync state and, after
# the merge, tells the agent exactly which sweeps the merge warrants and why.
#
# Usage:
#   keep-go-parity.sh snapshot   # BEFORE sync — record examples/ list + HEAD sha
#   keep-go-parity.sh plan       # AFTER sync  — diff vs snapshot, emit the PLAN
#
# The PLAN is both human-readable and machine-readable (PLAN_BUILD=… lines) so
# the skill can branch on it. Rules (from the skill spec):
#   • build-sweep, run-sweep      → ALWAYS.
#   • web-sweep                   → if any NEW example is web/live.
#   • perf-sweep                  → if ANY new example landed, OR the Go backend
#                                   changed in the merge (perf-relevant — agent
#                                   confirms against the upstream changelog).
#
# Exit: 0 ok · 2 setup error · 3 no snapshot (plan called before snapshot).
set -uo pipefail

REPO="${SKY_REPO:-}"
[ -z "$REPO" ] && [ -f "$PWD/scripts/rust-sweep.sh" ] && REPO="$PWD"
[ -z "$REPO" ] && [ -f "$HOME/Documentos/comp/sky/scripts/rust-sweep.sh" ] && REPO="$HOME/Documentos/comp/sky"
if [ -z "$REPO" ] || [ ! -d "$REPO/examples" ]; then
  echo "ERROR: can't locate the Sky repo. cd into it, or set SKY_REPO=/path/to/sky." >&2; exit 2
fi
cd "$REPO"

STATE="$HOME/.cache/sky/keep-go-parity"; mkdir -p "$STATE"
SHA_F="$STATE/pre.sha"; LIST_F="$STATE/pre.examples"

# Top-level example dirs that carry a Sky entry point. examples/rust/ (our
# fork-local FFI set) is a single top-level entry, so it never shows as "new".
list_examples() { find examples -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort; }

is_web_live() { # $1 = example dir name → prints "web" if Sky.Live/Http.Server
  local s="examples/$1/src"
  grep -rqE "Std\.Live|Live\.app|Server\.listen|Sky\.Http\.Server" "$s" 2>/dev/null && echo web || echo other
}

cmd="${1:-}"
case "$cmd" in
  snapshot)
    git rev-parse HEAD > "$SHA_F"
    list_examples > "$LIST_F"
    echo "keep-go-parity: snapshot @ $(cat "$SHA_F")  ($(wc -l < "$LIST_F" | tr -d ' ') example dirs)"
    echo "  saved: $SHA_F · $LIST_F"
    ;;

  plan)
    [ -f "$SHA_F" ] && [ -f "$LIST_F" ] || { echo "ERROR: no snapshot — run 'keep-go-parity.sh snapshot' BEFORE the sync." >&2; exit 3; }
    PRE_SHA="$(cat "$SHA_F")"; NOW_SHA="$(git rev-parse HEAD)"

    # New top-level example dirs (present now, absent at snapshot).
    NEW_EXAMPLES="$(comm -13 "$LIST_F" <(list_examples) | tr '\n' ' ' | sed 's/ *$//')"
    NEW_WEB=""
    for ex in $NEW_EXAMPLES; do [ "$(is_web_live "$ex")" = web ] && NEW_WEB="$NEW_WEB $ex"; done
    NEW_WEB="${NEW_WEB# }"

    # Go backend touched by the merge? (perf-relevant candidate — agent judges.)
    GO_FILES=""
    if [ "$PRE_SHA" != "$NOW_SHA" ]; then
      GO_FILES="$(git diff --name-only "$PRE_SHA" "$NOW_SHA" -- runtime-go src/Sky/Generate/Go 2>/dev/null | head -20 | tr '\n' ' ' | sed 's/ *$//')"
    fi

    PLAN_BUILD=1; PLAN_RUN=1
    PLAN_WEB=0; WEB_WHY="no new web/live example"
    PLAN_PERF=0; PERF_WHY="no new example, Go backend unchanged"
    [ -n "$NEW_WEB" ] && { PLAN_WEB=1; WEB_WHY="new web/live example:$NEW_WEB"; }
    if [ -n "$NEW_EXAMPLES" ]; then PLAN_PERF=1; PERF_WHY="$(echo $NEW_EXAMPLES | wc -w | tr -d ' ') new example(s): $NEW_EXAMPLES"
    elif [ -n "$GO_FILES" ]; then PLAN_PERF=1; PERF_WHY="Go backend changed (confirm perf-relevance vs changelog): $GO_FILES"; fi

    echo "=== keep-go-parity PLAN  ($PRE_SHA → $NOW_SHA) ==="
    echo "NEW_EXAMPLES: ${NEW_EXAMPLES:-none}"
    echo "NEW_WEB_LIVE: ${NEW_WEB:-none}"
    echo "GO_BACKEND_CHANGED: ${GO_FILES:-no}"
    echo "---"
    echo "PLAN_BUILD=1   # build-sweep — always"
    echo "PLAN_RUN=1     # run-sweep   — always"
    echo "PLAN_WEB=$PLAN_WEB     # web-sweep   — $WEB_WHY"
    echo "PLAN_PERF=$PLAN_PERF    # perf-sweep  — $PERF_WHY"
    if [ -n "$NEW_WEB" ]; then
      echo "---"
      echo "NOTE: new web/live example(s) have no scripts/verify-scenarios.mjs scenario yet —"
      echo "      web-sweep will regression-guard the existing live set, but author a scenario"
      echo "      for$NEW_WEB to get true round-trip coverage."
    fi
    ;;

  *)
    echo "usage: keep-go-parity.sh {snapshot|plan}" >&2
    echo "  snapshot  record examples/ + HEAD sha BEFORE the upstream sync" >&2
    echo "  plan      AFTER the sync: emit which sweeps the merge warrants" >&2
    exit 2 ;;
esac
