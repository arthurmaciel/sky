#!/usr/bin/env bash
# Sub-D.2 regression: a Sky.Http.Server.WebSocket echo server on target=rust must
# build, accept a WS upgrade, and echo messages — exercising the cfg bridge
# (defaultCfg |> withOnMessage), the task-local upgrade path, ws_loop, and
# sendToClient through the registry. Uses a hand-rolled raw WS client (plain
# sockets) so it doesn't depend on a particular python websockets version.
set -u
cd "$(dirname "$0")"
SKY=../../../sky-out/sky
PORT=8162
work=$(mktemp -d)
trap 'pkill -f "sky-out/rust/target/debug/sky-app" 2>/dev/null; rm -rf "$work"' EXIT
fail=0
command -v python3 >/dev/null || { echo "SKIP websocket: python3 not found"; exit 0; }

mkdir -p "$work/src"
cat > "$work/sky.toml" <<EOF
name = "wsd-test"
version = "0.1.0"
entry = "src/Main.sky"
target = "rust"

[source]
root = "src"
EOF
cat > "$work/src/Main.sky" <<EOF
module Main exposing (main)

import Sky.Core.Prelude exposing (..)
import Sky.Core.Task as Task
import Sky.Core.Error as Error exposing (Error)
import Sky.Http.Server as Server
import Sky.Http.Server.WebSocket as Ws


handleWs : Server.Request -> Task Error Server.Response
handleWs req =
    Ws.upgrade req
        (Ws.defaultCfg
            |> Ws.withOnMessage (\sock msg -> Ws.sendToClient sock ("echo: " ++ msg))
        )


main =
    Server.listen $PORT [ Server.get "/ws" handleWs ]
EOF

( cd "$work" && "$OLDPWD/$SKY" build src/Main.sky >/tmp/ws-test-build.log 2>&1 )
if [ ! -x "$work/sky-out/rust/target/debug/sky-app" ]; then
    echo "FAIL websocket: build produced no binary"; tail -6 /tmp/ws-test-build.log; exit 1
fi

( cd "$work" && setsid ./sky-out/rust/target/debug/sky-app >/tmp/ws-test-run.log 2>&1 < /dev/null & )
# Wait for the port to accept.
for _ in $(seq 1 50); do
    python3 -c "import socket,sys; s=socket.socket(); s.settimeout(0.3); sys.exit(0 if s.connect_ex(('127.0.0.1',$PORT))==0 else 1)" 2>/dev/null && break
    sleep 0.2
done

out=$(python3 - "$PORT" <<'PY'
import socket, base64, os, struct, sys
port = int(sys.argv[1])
def frame(payload):
    b = payload.encode(); mask = os.urandom(4)
    masked = bytes(c ^ mask[i % 4] for i, c in enumerate(b))
    return bytes([0x81, 0x80 | len(b)]) + mask + masked
def read_text(sock):
    h = sock.recv(2); ln = h[1] & 0x7f
    if ln == 126: ln = struct.unpack(">H", sock.recv(2))[0]
    data = b""
    while len(data) < ln: data += sock.recv(ln - len(data))
    return data.decode()
try:
    s = socket.create_connection(("127.0.0.1", port), timeout=3)
    key = base64.b64encode(os.urandom(16)).decode()
    s.sendall(("GET /ws HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
               "Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n" % key).encode())
    status = s.recv(1024).decode(errors="replace").split("\r\n")[0]
    s.sendall(frame("hello")); r1 = read_text(s)
    s.sendall(frame("world")); r2 = read_text(s)
    s.close()
    print(status); print(r1); print(r2)
except Exception as e:
    print("ERR:", repr(e))
PY
)

check() { if echo "$out" | grep -qF "$2"; then echo "  ok: $1"; else echo "  FAIL: $1"; fail=1; fi; }
check "101 upgrade"   "101 Switching Protocols"
check "echo hello"    "echo: hello"
check "echo world"    "echo: world"

if [ "$fail" -eq 0 ]; then echo "PASS websocket: upgrade + echo round-trip"; else echo "FAIL websocket"; echo "--- output ---"; echo "$out"; fi
pkill -f "sky-out/rust/target/debug/sky-app" 2>/dev/null
exit "$fail"
