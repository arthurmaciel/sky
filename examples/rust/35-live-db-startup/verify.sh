#!/usr/bin/env bash
# #56 regression — a Sky.Live app with a top-level `Task.run (Db.connect ())`
# binding (the exact shape in upstream examples/27) must still BIND + SERVE.
#
# Before the fix, `usesTaskRun` (set by the top-level Task.run) made the codegen
# emit `fn main() { sky_main(); }` with `sky_main() -> ()`, dropping the
# `live_app(...)` serve future — the binary stayed alive but never bound a port.
# The fix forces the block_on entry for any Live program (usesLive) regardless of
# usesTaskRun.
#
# Bounded + self-cleaning. Random free port.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -n "${CARGO_TARGET_DIR:-}" ] && [ -x "$CARGO_TARGET_DIR/debug/sky-app" ]; then
    BIN="$CARGO_TARGET_DIR/debug/sky-app"
else
    BIN="$HERE/sky-out/Rust/target/debug/sky-app"
fi
SRV_PID=""
cleanup() {
    [ -n "${SRV_PID:-}" ] && kill -9 "$SRV_PID" 2>/dev/null
    rm -f "$HERE/startup.db" 2>/dev/null
}
trap cleanup EXIT
fail() { echo "FAIL: $1"; exit 1; }

[ -x "$BIN" ] || fail "binary not found at $BIN (build: sky build src/Main.sky --target rust)"

PORT=$(( (RANDOM % 20000) + 20000 ))
echo "== starting server on port $PORT =="
rm -f "$HERE/startup.db" 2>/dev/null
( cd "$HERE" && SKY_LIVE_PORT=$PORT PORT=$PORT "$BIN" >"$HERE/srv.log" 2>&1 ) &
SRV_PID=$!

up=0
for _ in $(seq 1 40); do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://127.0.0.1:$PORT/" 2>/dev/null)
    if [ "$code" = "200" ]; then up=1; break; fi
    kill -0 "$SRV_PID" 2>/dev/null || fail "server exited early; log: $(cat "$HERE/srv.log" 2>/dev/null)"
    sleep 0.2
done
[ "$up" = "1" ] || fail "server never bound/served 200 (the #56 drop-serve-future regression). log: $(cat "$HERE/srv.log" 2>/dev/null)"
echo "  GET / -> 200 OK (init ran: top-level Task.run Db.connect + Db.execRaw)"

# Second request — the pool must survive across requests.
code2=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:$PORT/" 2>/dev/null)
[ "$code2" = "200" ] || fail "second request did not return 200 (got $code2)"
echo "  GET / (2nd) -> 200 OK (DB pool survives across requests)"

rm -f "$HERE/srv.log" 2>/dev/null
echo
echo "PASS — Live + top-level Task.run(Db.connect) binds, serves, and handles requests."
