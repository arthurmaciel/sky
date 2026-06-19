#!/usr/bin/env bash
# Sub-E step 4 regression: the Sky.Core.WebSocket CLIENT receive path on
# target=rust. A tiny raw-socket WS server pushes a frame on connect; the Sky
# client (Cli.program) connects and surfaces it via onMessage -> update -> view.
# Needs python3.
set -u
cd "$(dirname "$0")"
SKY=../../../sky-out/sky
PORT=9044
work=$(mktemp -d)
trap 'pkill -f "ws_srv_$PORT.py" 2>/dev/null; rm -rf "$work"' EXIT
fail=0
command -v python3 >/dev/null || { echo "SKIP ws-client: python3 not found"; exit 0; }

# Raw WS server: handshake, then push one text frame "hello", keep open briefly.
cat > "$work/ws_srv_$PORT.py" <<PY
import socket, hashlib, base64, struct, time
GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", $PORT)); srv.listen(1)
c, _ = srv.accept()
req = c.recv(2048).decode(errors="replace")
key = ""
for line in req.split("\r\n"):
    if line.lower().startswith("sec-websocket-key:"): key = line.split(":",1)[1].strip()
acc = base64.b64encode(hashlib.sha1((key+GUID).encode()).digest()).decode()
c.sendall(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
           "Connection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n" % acc).encode())
payload = b"hello"
c.sendall(bytes([0x81, len(payload)]) + payload)  # unmasked text frame (server->client)
time.sleep(1.0)
PY
python3 "$work/ws_srv_$PORT.py" &
# wait for bind
for _ in $(seq 1 50); do python3 -c "import socket,sys;s=socket.socket();s.settimeout(0.3);sys.exit(0 if s.connect_ex(('127.0.0.1',$PORT))==0 else 1)" 2>/dev/null && break; sleep 0.2; done

mkdir -p "$work/src"
cat > "$work/sky.toml" <<EOF
name = "wsc-test"
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
import Sky.Core.WebSocket as Ws exposing (WebSocketMessage(..))
import Std.Cli as Cli
import Std.Cmd as Cmd
import Std.Sub as Sub

type Msg = Connected (Result Error Ws.WebSocket) | Got Ws.WebSocketMessage | NoOp
type alias Model = { sock : Maybe Ws.WebSocket, last : String }

init : () -> ( Model, Cmd Msg )
init _ = ( { sock = Nothing, last = "(none)" }, Cmd.perform (Ws.connect "ws://127.0.0.1:$PORT/") Connected )

frameText : Ws.WebSocketMessage -> String
frameText m = case m of
    Text s -> s
    Binary _ -> "<bin>"

update : Msg -> Model -> ( Model, Cmd Msg )
update msg model = case msg of
    Connected (Ok s) -> ( { model | sock = Just s }, Cmd.none )
    Connected (Err _) -> ( { model | last = "(connect failed)" }, Cmd.none )
    Got m -> ( { model | last = frameText m }, Cmd.none )
    NoOp -> ( model, Cmd.none )

view : Model -> String
view model = "last=" ++ model.last ++ "\n"

subscriptions : Model -> Sub Msg
subscriptions model = case model.sock of
    Just s -> Ws.onMessage s Got
    Nothing -> Sub.none

onLine : String -> Msg
onLine _ = NoOp

main = Cli.program { init = init, update = update, view = view, subscriptions = subscriptions, onLine = onLine } |> Task.run
EOF

( cd "$work" && "$OLDPWD/$SKY" build src/Main.sky >/tmp/ws-client-build.log 2>&1 )
if [ ! -x "$work/sky-out/rust/target/debug/sky-app" ]; then
    echo "FAIL ws-client: build produced no binary"; tail -8 /tmp/ws-client-build.log; exit 1
fi

out=$(sleep 0.8 | "$work/sky-out/rust/target/debug/sky-app")
if echo "$out" | grep -q "last=hello"; then
    echo "PASS ws-client: onMessage delivered the frame"
else
    echo "FAIL ws-client: expected last=hello, got:"; echo "$out"; fail=1
fi
exit "$fail"
