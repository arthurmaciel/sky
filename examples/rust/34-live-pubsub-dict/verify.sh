#!/usr/bin/env bash
# #52 acceptance — cross-session pub/sub with an `any`-typed Dict payload.
#
# Proves the upstream pub/sub idiom lowers on the Rust backend: clicking
# "Broadcast" in session A publishes a Dict {text:"ping"} (typed `any` at the
# API) to topic "room"; the subscriber decodes it via `Db.getString "text"`
# (a Dict accessor) to "ping". Session B (subscribed via Sub.subscribeTopic
# with `Received any`) receives it over SSE (cross-session) — proving the
# per-type Broker connects publisher and subscriber on the concrete
# Dict String String payload, with zero erasure. Session A receives its own
# publish too (echo-default).
#
# Bounded + self-cleaning: server is killed -9, every wait is timeout-bounded,
# temp files are removed on exit. Random free port.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The Rust binary lands under CARGO_TARGET_DIR when that env is set (shared
# cargo target — see runtime-rust workflow), else under the project sky-out.
if [ -n "${CARGO_TARGET_DIR:-}" ] && [ -x "$CARGO_TARGET_DIR/debug/sky-app" ]; then
    BIN="$CARGO_TARGET_DIR/debug/sky-app"
else
    BIN="$HERE/sky-out/Rust/target/debug/sky-app"
fi
TMP="$(mktemp -d)"
SRV_PID=""
SSE_PID=""

cleanup() {
    [ -n "${SSE_PID:-}" ] && kill -9 "$SSE_PID" 2>/dev/null
    [ -n "${SSEA_PID:-}" ] && kill -9 "$SSEA_PID" 2>/dev/null
    [ -n "${SRV_PID:-}" ] && kill -9 "$SRV_PID" 2>/dev/null
    rm -rf "$TMP"
}
trap cleanup EXIT

fail() { echo "FAIL: $1"; exit 1; }

[ -x "$BIN" ] || fail "binary not found at $BIN (build first: sky build src/Main.sky --target rust)"

# Random free port in the ephemeral range.
PORT=$(( (RANDOM % 20000) + 20000 ))
echo "== starting server on port $PORT =="
SKY_LIVE_PORT=$PORT PORT=$PORT "$BIN" >"$TMP/srv.log" 2>&1 &
SRV_PID=$!

# Bounded wait until GET / returns 200.
up=0
for _ in $(seq 1 50); do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://127.0.0.1:$PORT/" 2>/dev/null)
    if [ "$code" = "200" ]; then up=1; break; fi
    kill -0 "$SRV_PID" 2>/dev/null || fail "server exited early; log: $(cat "$TMP/srv.log")"
    sleep 0.2
done
[ "$up" = "1" ] || fail "server never served 200 on /; log: $(cat "$TMP/srv.log")"
echo "  GET / -> 200 OK"

# ── Session A: get cookie + initial HTML, extract Broadcast button sky-id ──
curl -s -c "$TMP/jarA.txt" "http://127.0.0.1:$PORT/" >"$TMP/pageA.html"
grep -q 'sky_sid' "$TMP/jarA.txt" || fail "session A got no sky_sid cookie"
echo "== session A page (button region) =="
grep -o '<button[^>]*>' "$TMP/pageA.html" | head -1

# The button carries id="broadcast" + a runtime-assigned sky-id. Pull the
# sky-id from the <button ...> element.
BTN_TAG=$(grep -o '<button[^>]*>' "$TMP/pageA.html" | grep 'id="broadcast"' | head -1)
[ -n "$BTN_TAG" ] || fail "broadcast button not found in page A"
SKYID=$(echo "$BTN_TAG" | grep -o 'sky-id="[^"]*"' | head -1 | sed 's/sky-id="//; s/"//')
[ -n "$SKYID" ] || fail "no sky-id on broadcast button; tag=$BTN_TAG"
echo "  broadcast button sky-id = $SKYID"

# ── Session B: distinct cookie, then open its SSE stream (bounded) ──
curl -s -c "$TMP/jarB.txt" "http://127.0.0.1:$PORT/" >/dev/null
grep -q 'sky_sid' "$TMP/jarB.txt" || fail "session B got no sky_sid cookie"
SIDA=$(grep sky_sid "$TMP/jarA.txt" | awk '{print $NF}')
SIDB=$(grep sky_sid "$TMP/jarB.txt" | awk '{print $NF}')
[ "$SIDA" != "$SIDB" ] || fail "sessions A and B share a sid ($SIDA) — not two sessions"
echo "  session A sid=$SIDA  session B sid=$SIDB (distinct)"

# Open B's SSE stream in the background, bounded by timeout.
timeout 10 curl -sN -b "$TMP/jarB.txt" "http://127.0.0.1:$PORT/_sky/sse" >"$TMP/sseB.txt" 2>/dev/null &
SSE_PID=$!
# Also open A's SSE so we can observe the echo delivery to the publisher.
timeout 10 curl -sN -b "$TMP/jarA.txt" "http://127.0.0.1:$PORT/_sky/sse" >"$TMP/sseA.txt" 2>/dev/null &
SSEA_PID=$!

# Give B a moment to connect its SSE (subscription was already materialised at
# session init; the SSE stream is what carries the patch).
sleep 1

# ── Session A clicks Broadcast → POST /_sky/event ──
EVENT_BODY="{\"sessionId\":\"$SIDA\",\"handlerId\":\"$SKYID\",\"msg\":\"click\",\"args\":[],\"seq\":1}"
echo "== POST /_sky/event (session A) =="
echo "  body: $EVENT_BODY"
RESP=$(curl -s -b "$TMP/jarA.txt" -H 'Content-Type: application/json' \
    --max-time 3 -X POST --data "$EVENT_BODY" \
    "http://127.0.0.1:$PORT/_sky/event")
echo "  resp: $RESP"

# ── Wait (bounded) for B's SSE to carry a patch containing "ping" ──
got_b=0
for _ in $(seq 1 40); do
    if grep -q 'ping' "$TMP/sseB.txt" 2>/dev/null; then got_b=1; break; fi
    sleep 0.25
done

got_a=0
for _ in $(seq 1 12); do
    if grep -q 'ping' "$TMP/sseA.txt" 2>/dev/null; then got_a=1; break; fi
    sleep 0.25
done

# Stop the SSE streams.
kill -9 "$SSE_PID" "$SSEA_PID" 2>/dev/null
SSE_PID=""

echo
echo "===== session B SSE capture (cross-session) ====="
grep -a 'patches' "$TMP/sseB.txt" 2>/dev/null | head -5 || true
echo "===== session A SSE capture (echo-default) ====="
grep -a 'patches' "$TMP/sseA.txt" 2>/dev/null | head -5 || true
echo

if [ "$got_b" = "1" ]; then
    echo "PASS: session B received session A's broadcast 'ping' over SSE (CROSS-SESSION)"
else
    fail "session B did NOT receive 'ping' (cross-session broadcast broken). sseB:
$(cat "$TMP/sseB.txt")"
fi

if [ "$got_a" = "1" ]; then
    echo "PASS: session A received its own 'ping' over SSE (ECHO-DEFAULT)"
else
    echo "WARN: session A echo not observed over SSE; checking restored model via fresh GET..."
    curl -s -b "$TMP/jarA.txt" "http://127.0.0.1:$PORT/" >"$TMP/pageA2.html"
    if grep -q 'ping' "$TMP/pageA2.html"; then
        echo "PASS: session A's restored model renders 'ping' in feed (ECHO-DEFAULT)"
    else
        fail "session A did not receive its own publish (echo-default broken)"
    fi
fi

echo
echo "ALL CHECKS PASSED — cross-session broadcast + echo-default verified on Rust backend."
