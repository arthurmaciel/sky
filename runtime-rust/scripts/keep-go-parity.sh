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
#   • build-sweep                 → ALWAYS. build-sweep now carries Go≡Rust
#                                   EQUIVALENCE per example (equiv-classification.tsv
#                                   equiv modes) — there is no separate equiv-sweep.
#   • run-sweep                   → ALWAYS. The browser ROUND-TRIP for live/web
#                                   examples is PART of run-sweep (it dispatches
#                                   per shape: cli/server/tui/webview/live-browser);
#                                   there is no separate web-sweep.
#   • perf-sweep                  → if ANY new example landed, OR the Go backend
#                                   changed in the merge (perf-relevant — agent
#                                   confirms against the upstream changelog).
#
# Exit: 0 ok · 2 setup error · 3 no snapshot (plan called before snapshot).
set -uo pipefail

# ── Env + manifest (shared SINGLE SOURCE OF TRUTH under lib/) ───────────────
source "$(dirname "$0")/lib/env.sh"
source "$(dirname "$0")/lib/examples.sh"
if [ -z "$REPO" ] || [ ! -d "$REPO/examples" ]; then
  echo "ERROR: can't locate the Sky repo. cd into it, or set SKY_REPO=/path/to/sky." >&2; exit 2
fi
cd "$REPO"

STATE="$HOME/.cache/sky/keep-go-parity"; mkdir -p "$STATE"
SHA_F="$STATE/pre.sha"; LIST_F="$STATE/pre.examples"

# Top-level example dirs that carry a Sky entry point. runtime-rust/tests/sky/ (our
# fork-local FFI set) is a single top-level entry, so it never shows as "new".
list_examples() { find examples -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort; }

# Compute the post-merge delta + plan into shell vars (used by `plan` and `run`).
compute_plan() {
    [ -f "$SHA_F" ] && [ -f "$LIST_F" ] || { echo "ERROR: no snapshot — run 'keep-go-parity.sh snapshot' BEFORE the sync." >&2; exit 3; }
    PRE_SHA="$(cat "$SHA_F")"; NOW_SHA="$(git rev-parse HEAD)"

    # New top-level example dirs (present now, absent at snapshot).
    NEW_EXAMPLES="$(comm -13 "$LIST_F" <(list_examples) | tr '\n' ' ' | sed 's/ *$//')"
    # New web/live example(s) — informational (run-sweep already browser-drives
    # every live/web example, so no separate sweep is gated on this).
    NEW_WEB=""
    for ex in $NEW_EXAMPLES; do is_web_example "examples/$ex" && NEW_WEB="$NEW_WEB $ex"; done
    NEW_WEB="${NEW_WEB# }"

    # Go backend touched by the merge? (perf-relevant candidate — judge vs changelog.)
    GO_FILES=""
    if [ "$PRE_SHA" != "$NOW_SHA" ]; then
      GO_FILES="$(git diff --name-only "$PRE_SHA" "$NOW_SHA" -- runtime-go src/Sky/Generate/Go 2>/dev/null | head -20 | tr '\n' ' ' | sed 's/ *$//')"
    fi

    # Forced classification: every example MUST have an equiv MODE in the manifest.
    # Any example on disk but absent from the manifest is UNCLASSIFIED — until it
    # is classified, "Go parity maintained" cannot be claimed (build-sweep enforces
    # this too; surfaced here so new examples are caught at plan time).
    MANIFEST="$REPO/runtime-rust/scripts/equiv-classification.tsv"
    UNCLASSIFIED=""
    [ -f "$MANIFEST" ] && UNCLASSIFIED="$(comm -13 <(awk '!/^#/ && NF>=2 {print $1}' "$MANIFEST" | sort -u) <(list_examples) | tr '\n' ' ' | sed 's/ *$//')"

    PLAN_BUILD=1; PLAN_RUN=1   # build-sweep (build+equiv) and run-sweep are ALWAYS-run
    PLAN_PERF=0; PERF_WHY="no new example, Go backend unchanged"
    if [ -n "$NEW_EXAMPLES" ]; then PLAN_PERF=1; PERF_WHY="$(echo $NEW_EXAMPLES | wc -w | tr -d ' ') new example(s): $NEW_EXAMPLES"
    elif [ -n "$GO_FILES" ]; then PLAN_PERF=1; PERF_WHY="Go backend changed (confirm perf-relevance vs changelog): $GO_FILES"; fi
}

print_plan() {
    echo "=== keep-go-parity PLAN  ($PRE_SHA → $NOW_SHA) ==="
    echo "NEW_EXAMPLES: ${NEW_EXAMPLES:-none}"
    echo "NEW_WEB_LIVE: ${NEW_WEB:-none}"
    echo "GO_BACKEND_CHANGED: ${GO_FILES:-no}"
    echo "UNCLASSIFIED_EXAMPLES: ${UNCLASSIFIED:-none}"
    echo "---"
    echo "PLAN_BUILD=1   # build-sweep — always (build + Go≡Rust equivalence + classification gate)"
    echo "PLAN_RUN=1     # run-sweep   — always (browser round-trip for live/web is part of run-sweep)"
    echo "PLAN_PERF=$PLAN_PERF    # perf-sweep  — $PERF_WHY"
    if [ -n "$UNCLASSIFIED" ]; then
      echo "---"
      echo "BLOCKER: classify these in runtime-rust/scripts/equiv-classification.tsv (equiv mode) —"
      echo "         until then build-sweep fails and parity CANNOT be claimed: $UNCLASSIFIED"
    fi
    if [ -n "$NEW_WEB" ]; then
      echo "---"
      echo "NOTE: new web/live example(s) get true round-trip coverage automatically via"
      echo "      run-sweep's live-browser dispatch (scenario derived from the example name,"
      echo "      falling back to 'smoke'). Author a richer scenario in"
      echo "      scripts/verify-scenarios.mjs for$NEW_WEB if the smoke fallback is too thin."
    fi
}

SCRIPTS="$REPO/runtime-rust/scripts"

cmd="${1:-}"
case "$cmd" in
  snapshot)
    git rev-parse HEAD > "$SHA_F"
    list_examples > "$LIST_F"
    echo "keep-go-parity: snapshot @ $(cat "$SHA_F")  ($(wc -l < "$LIST_F" | tr -d ' ') example dirs)"
    echo "  saved: $SHA_F · $LIST_F"
    ;;

  plan)
    compute_plan
    print_plan
    ;;

  run)
    # Non-agent convenience: do the always-run LOAD-TOLERANT parity sweeps
    # automatically after the merge (build(+equiv) → run). build-sweep now carries
    # the Go≡Rust equivalence + classification gate; run-sweep drives the browser
    # round-trip for every live/web example (no separate equiv- or web-sweep).
    # perf is NOT auto-run — it's machine-load-sensitive (close other apps first),
    # so it's only surfaced as a recommendation. Run AFTER you've synced yourself.
    compute_plan
    print_plan
    echo ""; echo ">>> build-sweep (build + Go≡Rust equivalence + classification gate) ..."
    bash "$SCRIPTS/build-sweep.sh"; BUILD_RC=$?
    if [ "$BUILD_RC" != 0 ]; then
      echo "=== keep-go-parity: ✗ GO PARITY NOT MAINTAINED — build/equiv/classification broke (run phase skipped) ==="; exit 1
    fi
    echo ""; echo ">>> run-sweep (cli/server/tui-pty/webview-xvfb/live-browser) ..."
    bash "$SCRIPTS/run-sweep.sh"; RUN_RC=$?
    echo ""; echo "=== keep-go-parity run complete ==="
    echo "  build+equiv: PASS · run: rc=$RUN_RC"
    if [ "$PLAN_PERF" = 1 ]; then
      echo "  perf-sweep WARRANTED ($PERF_WHY) — NOT auto-run (close other apps first, then:"
      echo "    bash $SCRIPTS/perf-sweep.sh )"
    fi
    if [ "$RUN_RC" = 0 ]; then
      echo "  ✓ GO PARITY MAINTAINED — build+equiv(+browser round-trip)+run green; every example classified."
      [ "$PLAN_PERF" = 1 ] && echo "    (perf still recommended — see above.)"
      exit 0
    fi
    echo "  ✗ GO PARITY NOT MAINTAINED — see failures above."
    exit 1
    ;;

  *)
    echo "usage: keep-go-parity.sh {snapshot|plan|run}" >&2
    echo "  snapshot  record examples/ + HEAD sha BEFORE the upstream sync" >&2
    echo "  plan      AFTER the sync: print which sweeps the merge warrants" >&2
    echo "  run       AFTER the sync: print the plan AND auto-run the always-run" >&2
    echo "            parity sweeps (build(+equiv) → run); build-sweep carries the" >&2
    echo "            Go≡Rust equivalence + classification gate, run-sweep drives the" >&2
    echo "            live/web browser round-trip. perf is surfaced, not run (needs" >&2
    echo "            apps closed). For non-agent use." >&2
    exit 2 ;;
esac
