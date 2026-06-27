#!/usr/bin/env bash
#
# push.sh — push the current branch to the user's FORK (origin), never upstream.
#
# The whole point of this script is the hard upstream guard: it REFUSES to push
# to anzellai/sky (the upstream repo) under any circumstance. The only
# acceptable target is the user's fork, arthurmaciel/sky.
#
# Usage:
#   bash runtime-rust/scripts/push.sh            # push current branch to origin
#   bash runtime-rust/scripts/push.sh <remote>   # push to a named remote (still guarded)
#   bash runtime-rust/scripts/push.sh --dry-run  # run all guards, do `git push --dry-run`
#   DRY_RUN=1 bash runtime-rust/scripts/push.sh   # same, via env
#
# Exit 0 on a successful push (or dry-run); non-zero on any guard failure or
# push error.

set -euo pipefail

# --- the forbidden upstream repo (case-insensitive). The user's fork is
# --- arthurmaciel/sky and is the ONLY acceptable target. ---
UPSTREAM_PATTERN='anzellai/sky'

# --- argument parsing: optional remote name + --dry-run flag (env DRY_RUN=1 too) ---
REMOTE='origin'
DRY_RUN="${DRY_RUN:-0}"
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        -*) echo "REFUSING: unknown flag '$arg'" >&2; exit 2 ;;
        *)  REMOTE="$arg" ;;
    esac
done

cd "$(git rev-parse --show-toplevel)"

# --- GUARD 1: the remote name must not be 'upstream' ---
if [ "$REMOTE" = "upstream" ]; then
    echo "REFUSING: target remote is 'upstream' — this script never pushes to the upstream repo." >&2
    echo "          Push to your fork instead (origin)." >&2
    exit 3
fi

# --- GUARD 2: the remote must exist ---
if ! REMOTE_URL="$(git remote get-url "$REMOTE" 2>/dev/null)"; then
    echo "REFUSING: remote '$REMOTE' does not exist." >&2
    echo "          Available remotes: $(git remote | tr '\n' ' ')" >&2
    exit 4
fi

# --- GUARD 3: NO configured URL may point at upstream (anzellai/sky).
# --- Covers github.com:anzellai/sky, github.com/anzellai/sky, and a .git suffix.
# --- CRITICAL: check the PUSH url(s) too, not just the fetch url. A remote can
# --- carry a separate `pushurl` (git remote set-url --push), even several — and
# --- the PUSH destination is exactly what this guard exists to stop. `get-url
# --- --push --all` lists every push url (falling back to the fetch url when none
# --- is set). Checking only the fetch url was a bypass.
ALL_REMOTE_URLS="$REMOTE_URL
$(git remote get-url --push --all "$REMOTE" 2>/dev/null)"
if printf '%s\n' "$ALL_REMOTE_URLS" | grep -qi "$UPSTREAM_PATTERN"; then
    echo "REFUSING: remote '$REMOTE' has a URL matching the upstream repo '$UPSTREAM_PATTERN'." >&2
    echo "          (both fetch and push urls are checked.) This script never pushes to upstream." >&2
    echo "          The only acceptable target is your fork (arthurmaciel/sky)." >&2
    exit 5
fi

# --- branch + ahead-count summary ---
BRANCH="$(git branch --show-current)"
if [ -z "$BRANCH" ]; then
    echo "REFUSING: not on a branch (detached HEAD)." >&2
    exit 6
fi

# how many commits ahead of the remote tracking branch (tolerate no-tracking)
if AHEAD="$(git rev-list --count "$REMOTE/$BRANCH..HEAD" 2>/dev/null)"; then
    AHEAD_NOTE="$AHEAD commit(s) ahead of $REMOTE/$BRANCH"
else
    AHEAD_NOTE="no tracking branch on $REMOTE yet (new branch)"
fi

echo "push.sh — pushing current branch"
echo "  remote : $REMOTE"
echo "  url    : $REMOTE_URL"
echo "  branch : $BRANCH"
echo "  ahead  : $AHEAD_NOTE"

# --- CI hygiene (root CLAUDE.md "Workflow rules"): only on the 'main' branch,
# --- cancel in-progress CI runs before pushing. Skip on feature branches. ---
if [ "$BRANCH" = "main" ]; then
    echo "  branch is main — cancelling in-progress CI runs before push (CLAUDE.md hygiene)"
    if command -v gh >/dev/null 2>&1; then
        gh run list --branch main --status in_progress --workflow CI --json databaseId --jq '.[].databaseId' 2>/dev/null \
            | xargs -I{} gh run cancel {} 2>/dev/null || true
    else
        echo "  (gh not on PATH — skipping CI cancel)"
    fi
fi

# --- push (or dry-run). Never force-push; never interactive. ---
if [ "$DRY_RUN" = "1" ]; then
    echo "  DRY-RUN — running 'git push --dry-run $REMOTE $BRANCH' (no real push)"
    git push --dry-run "$REMOTE" "$BRANCH"
    echo "push.sh: dry-run OK (nothing was actually pushed)"
else
    git push "$REMOTE" "$BRANCH"
    echo "push.sh: pushed $BRANCH → $REMOTE ($REMOTE_URL)"
fi
