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
# The PLAN is both human-readable and machine-readable (PLAN_* lines) so the
# skill can branch on it. Rules (from the skill spec):
#   • examples-sweep              → ALWAYS. ONE sweep that BUILDS, RUNS, and asserts
#                                   Go≡Rust EQUIVALENCE per example (BUILD·RUN·EQUIV
#                                   table; equiv modes DERIVED from shape +
#                                   overrides in equiv-classification.tsv). Folds the
#                                   former build-sweep + run-sweep (+ equiv + web).
#   • examples-perf-sweep         → if ANY new example landed, OR the Go backend
#                                   changed in the merge (perf-relevant — agent
#                                   confirms against the upstream changelog).
# BOTH sweeps are night-gated (22:00–08:00 America/Sao_Paulo; SKY_SWEEP_FORCE=1
# overrides). The `run` subcommand below forces past the gate (the user asked).
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

    # No classification gate: equiv mode is DERIVED from example_shape (equiv_mode
    # in lib/examples.sh), so a new example auto-classifies with no manual step.
    # equiv-classification.tsv is OVERRIDES-only — a missing override is not an
    # error, it just means the derived mode applies.

    PLAN_EXAMPLES=1            # examples-sweep (build+run+equiv) is ALWAYS-run
    PLAN_PERF=0; PERF_WHY="no new example, Go backend unchanged"
    if [ -n "$NEW_EXAMPLES" ]; then PLAN_PERF=1; PERF_WHY="$(echo $NEW_EXAMPLES | wc -w | tr -d ' ') new example(s): $NEW_EXAMPLES"
    elif [ -n "$GO_FILES" ]; then PLAN_PERF=1; PERF_WHY="Go backend changed (confirm perf-relevance vs changelog): $GO_FILES"; fi
}

print_plan() {
    echo "=== keep-go-parity PLAN  ($PRE_SHA → $NOW_SHA) ==="
    echo "NEW_EXAMPLES: ${NEW_EXAMPLES:-none}"
    echo "NEW_WEB_LIVE: ${NEW_WEB:-none}"
    echo "GO_BACKEND_CHANGED: ${GO_FILES:-no}"
    echo "---"
    echo "PLAN_EXAMPLES=1   # examples-sweep — always (BUILD·RUN·EQUIV table; equiv modes DERIVED + overrides)"
    echo "PLAN_PERF=$PLAN_PERF        # examples-perf-sweep — $PERF_WHY"
    if [ -n "$NEW_WEB" ]; then
      echo "---"
      echo "NOTE: new web/live example(s) get true round-trip coverage automatically via"
      echo "      examples-sweep's RUN live-browser dispatch + EQUIV scenario (derived from"
      echo "      the example name, falling back to 'smoke'). Author a richer scenario in"
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
    # Non-agent convenience: auto-run the always-run LOAD-TOLERANT parity sweep
    # after the merge. examples-sweep is the ONE sweep that builds, runs, AND
    # asserts Go≡Rust equivalence per example (BUILD·RUN·EQUIV table). perf is NOT
    # auto-run — it's machine-load-sensitive (close other apps first), so it's only
    # surfaced as a recommendation. Run AFTER you've synced yourself.
    #
    # NIGHT GATE: examples-sweep defers outside 22:00–08:00 BRT unless
    # SKY_SWEEP_FORCE=1. `run` is an explicit user ask → force past the gate.
    compute_plan
    print_plan
    echo ""; echo ">>> examples-sweep (BUILD·RUN·EQUIV table; Go≡Rust equivalence) ..."
    SKY_SWEEP_FORCE=1 bash "$SCRIPTS/examples-sweep.sh"; EX_RC=$?
    echo ""; echo "=== keep-go-parity run complete ==="
    echo "  examples-sweep: rc=$EX_RC"
    if [ "$PLAN_PERF" = 1 ]; then
      echo "  examples-perf-sweep WARRANTED ($PERF_WHY) — NOT auto-run (close other apps first, then:"
      echo "    SKY_SWEEP_FORCE=1 bash $SCRIPTS/examples-perf-sweep.sh )"
    fi
    if [ "$EX_RC" = 0 ]; then
      echo "  ✓ GO PARITY MAINTAINED — examples-sweep green (build + run + Go≡Rust equivalence; no red row)."
      [ "$PLAN_PERF" = 1 ] && echo "    (perf still recommended — see above.)"
      exit 0
    fi
    echo "  ✗ GO PARITY NOT MAINTAINED — RED row(s) in examples-sweep above."
    echo "    Autonomous swarm-fix policy: each RED example (Rust-side build/run/equiv"
    echo "    failure — NOT amber go-ref-broken) is root-caused + fixed in-boundary via"
    echo "    the swarm, adhering to the README principles, AFTER the full sweep."
    exit 1
    ;;

  *)
    echo "usage: keep-go-parity.sh {snapshot|plan|run}" >&2
    echo "  snapshot  record examples/ + HEAD sha BEFORE the upstream sync" >&2
    echo "  plan      AFTER the sync: print which sweeps the merge warrants" >&2
    echo "  run       AFTER the sync: print the plan AND auto-run examples-sweep" >&2
    echo "            (BUILD·RUN·EQUIV; forces past the night gate). perf is surfaced," >&2
    echo "            not run (needs apps closed). For non-agent use." >&2
    exit 2 ;;
esac
