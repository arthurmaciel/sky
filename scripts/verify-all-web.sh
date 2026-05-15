#!/usr/bin/env bash
# v0.13.x runtime verification — every Sky.Live + Sky.Http.Server example.
#
# Each app runs on a unique port so a leftover-zombie from a prior run
# can't poison the next test. PASS = server listens + Playwright load
# succeeds + zero console errors + zero server-side panic strings.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RESULTS_DIR="$REPO_ROOT/.skycache/verify"
mkdir -p "$RESULTS_DIR"

# (example-name, scenario, port).
#
# Apps that hardcode port 8000 in their Sky source (05-mux-server,
# 08-notes-app, 15-http-server) must use 8000; others honour
# PORT / SKY_LIVE_PORT env so they can pick a per-app port and run
# without collision. The script kills any prior holder of each
# port before each test, so even the port-8000 group runs cleanly
# in sequence.
TESTS=(
    "05-mux-server smoke 8000"
    "08-notes-app smoke 8000"
    "09-live-counter live-counter 8009"
    "10-live-component smoke 8010"
    "12-skyvote smoke 8012"
    "15-http-server smoke 8000"
    "16-skychess smoke 8016"
    "17-skymon smoke 8017"
    "18-job-queue smoke 8018"
    "19-skyforum smoke 8019"
)

# Skyshop omitted by default — needs Stripe + Firebase live keys to
# get past the index route. Pass SKY_VERIFY_SKYSHOP=1 to include.
[ "${SKY_VERIFY_SKYSHOP:-0}" = "1" ] && TESTS+=("13-skyshop smoke 8013")

pass=0
fail=0
FAILS=()
for entry in "${TESTS[@]}"; do
    set -- $entry
    name=$1; scenario=$2; port=$3
    # Kill any process on this port pre-flight
    pid=$(lsof -ti ":$port" 2>/dev/null || true)
    [ -n "$pid" ] && kill -9 $pid 2>/dev/null || true
    out=$(node "$REPO_ROOT/scripts/verify-live-app.mjs" "$name" "$port" "$scenario" 2>&1)
    if echo "$out" | grep -q "^PASS "; then
        pass=$((pass+1))
        echo "✓ $name (port $port, $scenario)"
    else
        fail=$((fail+1))
        FAILS+=("$name")
        echo "✗ $name (port $port, $scenario)"
        echo "$out" | head -3 | sed 's/^/   /'
    fi
done

echo ""
echo "VERIFY: $pass pass / $fail fail (out of ${#TESTS[@]})"
[ ${#FAILS[@]} -eq 0 ] || echo "FAILED: ${FAILS[*]}"
exit $fail
