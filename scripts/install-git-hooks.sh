#!/usr/bin/env bash
# Install repo-local git hooks. Run once after clone.
#
# Hooks installed:
#   pre-push — if pushing a tag matching v*, refuse unless
#              `scripts/preflight-tag.sh` exited 0 within the last
#              30 minutes (recorded in .git/last-preflight-pass).
#
# Rationale: the v0.13.0 → v0.13.2 release loop shipped two patches
# in a row because the runtime-verify step was not enforced before
# tagging. The hook makes the verification mandatory at the only
# moment that matters: tag-push time.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK_DIR="$REPO_ROOT/.git/hooks"
mkdir -p "$HOOK_DIR"

cat > "$HOOK_DIR/pre-push" <<'EOF'
#!/usr/bin/env bash
# Refuse to push a v*-shaped tag unless preflight passed recently.
# Bypass: git push --no-verify (use ONLY for non-release pushes).

REPO_ROOT="$(git rev-parse --show-toplevel)"
STAMP="$REPO_ROOT/.git/last-preflight-pass"
MAX_AGE_SECONDS=1800   # 30 min

is_tag_push=0
while read -r local_ref local_sha remote_ref remote_sha; do
    case "$remote_ref" in
        refs/tags/v*) is_tag_push=1 ;;
    esac
done

if [ $is_tag_push -eq 0 ]; then
    exit 0
fi

if [ ! -f "$STAMP" ]; then
    echo "✗ Refusing to push tag: scripts/preflight-tag.sh has not run." >&2
    echo "  Run it first, then re-push." >&2
    echo "" >&2
    echo "  cd $REPO_ROOT && scripts/preflight-tag.sh" >&2
    exit 1
fi

now=$(date +%s)
stamp_age=$(( now - $(stat -f %m "$STAMP" 2>/dev/null || stat -c %Y "$STAMP") ))
if [ $stamp_age -gt $MAX_AGE_SECONDS ]; then
    echo "✗ Refusing to push tag: preflight stamp is $stamp_age s old (>${MAX_AGE_SECONDS}s)." >&2
    echo "  Re-run scripts/preflight-tag.sh, then re-push." >&2
    exit 1
fi

echo "✓ Preflight stamp fresh ($stamp_age s old); allowing tag push."
EOF

chmod +x "$HOOK_DIR/pre-push"
echo "✓ Installed $HOOK_DIR/pre-push"
echo ""
echo "  Run scripts/preflight-tag.sh before any tag push to populate"
echo "  the .git/last-preflight-pass stamp."
