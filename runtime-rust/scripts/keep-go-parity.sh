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

# ── Run-state file — the resume frontier for the v2 chain (spec §B) ──────────
# Gitignored, in-repo. NOT commit-derived: several phases (skydex update, scoped
# sweep, a clean audit) produce zero commits, so a commit-derived frontier would
# mis-locate. BASE is the phase-0 pre-run HEAD, fixed for the whole run.
STATE_FILE="${SKY_KGP_STATE:-$REPO/.skycache/keep-go-parity.state}"

state_init() {
  mkdir -p "$(dirname "$STATE_FILE")"
  printf 'BASE=%s\nlast_completed_phase=0\n' "$(git rev-parse HEAD)" > "$STATE_FILE"
}
state_get() {  # state_get <key> → value (empty if absent)
  [ -f "$STATE_FILE" ] || return 0
  sed -n "s/^$1=//p" "$STATE_FILE" | tail -1
}
state_set() {  # state_set <key> <value> — portable (no in-place sed)
  local k="$1" v="$2" tmp
  [ -f "$STATE_FILE" ] || state_init
  tmp="$(mktemp)"
  awk -v k="$k" -v v="$v" '
    $0 ~ "^"k"=" { print k"="v; done=1; next } { print }
    END { if (!done) print k"="v }' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}
state_done() { state_set last_completed_phase "$1"; state_set "phase_$1" ok; }   # phase N complete
state_clear() { rm -f "$STATE_FILE"; }

# Top-level example dirs that carry a Sky entry point. runtime-rust/tests/sky/ (our
# fork-local FFI set) is a single top-level entry, so it never shows as "new".
list_examples() { find examples -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort; }

# Compute the post-merge delta + plan into shell vars (used by `plan` and `run`).
compute_plan() {
    [ -f "$SHA_F" ] && [ -f "$LIST_F" ] || { echo "ERROR: no snapshot — run 'keep-go-parity.sh snapshot' BEFORE the sync." >&2; exit 3; }
    PRE_SHA="$(cat "$SHA_F")"
    # Fail closed if HEAD can't be resolved (not a git repo / detached weirdness):
    # an empty NOW_SHA would silently mis-diff every example as "new".
    NOW_SHA="$(git rev-parse HEAD)" || { echo "ERROR: 'git rev-parse HEAD' failed — not a git checkout?" >&2; exit 2; }
    [ -n "$NOW_SHA" ] || { echo "ERROR: empty HEAD sha from git rev-parse." >&2; exit 2; }

    # New top-level example dirs (present now, absent at snapshot). Read into an
    # array so a dir name with whitespace can't mis-iterate / mis-count; keep the
    # space-joined string only for human-readable display.
    mapfile -t NEW_EXAMPLES_ARR < <(comm -13 "$LIST_F" <(list_examples))
    NEW_EXAMPLES="${NEW_EXAMPLES_ARR[*]}"
    # New web/live example(s) — informational (run-sweep already browser-drives
    # every live/web example, so no separate sweep is gated on this).
    NEW_WEB=""
    for ex in "${NEW_EXAMPLES_ARR[@]}"; do is_web_example "examples/$ex" && NEW_WEB="$NEW_WEB $ex"; done
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
    if [ "${#NEW_EXAMPLES_ARR[@]}" -gt 0 ]; then PLAN_PERF=1; PERF_WHY="${#NEW_EXAMPLES_ARR[@]} new example(s): $NEW_EXAMPLES"
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
    # Bound the unattended post-merge sweep so a wedged example build/run can't
    # block forever (project timeout-bounded-long-command mandate). 2h ceiling;
    # exit 124 = the sweep timed out → treat as parity-NOT-maintained below.
    # `timeout` may be absent (e.g. macOS base); fall back to a raw run there.
    if command -v timeout >/dev/null 2>&1; then
      SKY_SWEEP_FORCE=1 timeout 7200 bash "$SCRIPTS/examples-sweep.sh"; EX_RC=$?
    else
      SKY_SWEEP_FORCE=1 bash "$SCRIPTS/examples-sweep.sh"; EX_RC=$?
    fi
    echo ""; echo "=== keep-go-parity run complete ==="
    if [ "$EX_RC" = 124 ]; then
      echo "  examples-sweep: rc=124 (TIMED OUT after 7200s — a wedged example build/run)"
    else
      echo "  examples-sweep: rc=$EX_RC"
    fi
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

  state-init)  state_init; echo "keep-go-parity: state @ $STATE_FILE (BASE=$(state_get BASE))" ;;
  state-get)   state_get "${2:?state-get <key>}" ;;
  state-done)  state_done "${2:?state-done <phase-number>}"; echo "phase ${2} done (frontier=$(state_get last_completed_phase))" ;;
  state-show)  [ -f "$STATE_FILE" ] && cat "$STATE_FILE" || echo "(no run-state — fresh run)" ;;
  --restart)   state_clear; echo "keep-go-parity: run-state cleared — next run starts at phase 0" ;;

  scoped-sweep)
    # Phase-5 helper: scope examples-sweep to the change blast-radius since BASE.
    # changed_examples lives in lib/examples.sh (already sourced). RUST_EXAMPLES
    # is examples-sweep's subset override. --dry-run prints the plan only.
    base="$(state_get BASE)"
    [ -n "$base" ] || { echo "ERROR: no BASE in run-state — run 'keep-go-parity.sh state-init' first." >&2; exit 3; }
    mapfile -t SCOPED < <(changed_examples "$base")
    list="${SCOPED[*]}"
    echo "scoped-sweep: ${#SCOPED[@]} example(s) since $base"
    echo "RUST_EXAMPLES=$list"
    if [ "${2:-}" = "--dry-run" ]; then
      echo "would run: SKY_SWEEP_FORCE=1 bash $SCRIPTS/examples-sweep.sh (with RUST_EXAMPLES set as above)"
      exit 0
    fi
    if command -v timeout >/dev/null 2>&1; then
      SKY_SWEEP_FORCE=1 RUST_EXAMPLES="$list" timeout 7200 bash "$SCRIPTS/examples-sweep.sh"; exit $?
    else
      SKY_SWEEP_FORCE=1 RUST_EXAMPLES="$list" bash "$SCRIPTS/examples-sweep.sh"; exit $?
    fi
    ;;

  *)
    echo "usage: keep-go-parity.sh {snapshot|plan|run|state-init|state-get|state-done|state-show|scoped-sweep|--restart}" >&2
    echo "  snapshot    record examples/ + HEAD sha BEFORE the upstream sync" >&2
    echo "  plan        AFTER the sync: print which sweeps the merge warrants" >&2
    echo "  run         AFTER the sync: print the plan AND auto-run examples-sweep" >&2
    echo "              (BUILD·RUN·EQUIV; forces past the night gate). perf is surfaced," >&2
    echo "              not run (needs apps closed). For non-agent use." >&2
    echo "  state-init  start a new v2-chain run (records BASE=HEAD, phase=0)" >&2
    echo "  state-get   <key>  read a value from the run-state file" >&2
    echo "  state-done  <N>    mark phase N complete, advance the frontier" >&2
    echo "  state-show  dump the full run-state file" >&2
    echo "  scoped-sweep       phase-5: run examples-sweep scoped to changed_examples since BASE" >&2
    echo "  --restart   clear the run-state file (force fresh run)" >&2
    exit 2 ;;
esac
