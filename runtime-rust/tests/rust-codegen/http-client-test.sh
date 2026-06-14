#!/usr/bin/env bash
# Sky.Core.Http client regression on target=rust: build a Sky program that
# issues GET / POST / request-builder calls against a local responder, plus a
# pure parseQuery, and assert the typed HttpResponse reads (status/body/headers)
# and the HttpRequest record-construction bridge work. Needs python3.
set -u
cd "$(dirname "$0")"
SKY=../../../sky-out/sky
PORT=8156
work=$(mktemp -d)
pyserver=""
trap '[ -n "$pyserver" ] && kill "$pyserver" 2>/dev/null; pkill -f "echo_srv_$PORT.py" 2>/dev/null; rm -rf "$work"' EXIT
fail=0

command -v python3 >/dev/null || { echo "SKIP http-client: python3 not found"; exit 0; }

cat > "$work/echo_srv_$PORT.py" <<PY
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def _h(self):
        ln=int(self.headers.get("Content-Length","0") or "0")
        body=self.rfile.read(ln) if ln else b""
        xh=self.headers.get("X-Custom","-")
        out=("method=%s xcustom=%s body=%s" % (self.command, xh, body.decode())).encode()
        self.send_response(201)
        self.send_header("Content-Type","application/json")
        self.send_header("Content-Length",str(len(out)))
        self.end_headers(); self.wfile.write(out)
    do_GET=_h; do_POST=_h; do_PUT=_h
    def log_message(self,*a): pass
HTTPServer(("127.0.0.1",$PORT),H).serve_forever()
PY

mkdir -p "$work/src"
cat > "$work/sky.toml" <<EOF
name = "httpc-test"
version = "0.1.0"
entry = "src/Main.sky"
target = "rust"

[source]
root = "src"
EOF
cat > "$work/src/Main.sky" <<EOF
module Main exposing (main)

import Sky.Core.Prelude exposing (..)
import Sky.Core.String as String
import Sky.Core.Task as Task
import Sky.Core.Dict as Dict
import Sky.Core.Error as Error exposing (Error)
import Sky.Core.Http as Http
import Std.Log exposing (println)


showResp : String -> Http.HttpResponse -> String
showResp tag resp =
    tag ++ ": status=" ++ String.fromInt resp.status
        ++ " ctype=" ++ (Dict.get "Content-Type" resp.headers |> Maybe.withDefault "?")
        ++ " " ++ resp.body


run1 : Task Error String -> String
run1 t =
    case Task.run t of
        Ok s -> s
        Err e -> "ERR: " ++ Error.toString e


main =
    let
        getT = Http.get "http://127.0.0.1:$PORT/g" |> Task.map (showResp "GET")
        postT = Http.post "http://127.0.0.1:$PORT/p" "hello-body" |> Task.map (showResp "POST")
        reqT =
            Http.defaultRequest "http://127.0.0.1:$PORT/r"
                |> Http.withMethod "PUT"
                |> Http.withHeader "X-Custom" "skyval"
                |> Http.withBody "put-body"
                |> Http.request
                |> Task.map (showResp "REQ")
        q = Http.parseQuery "a=1&b=two%20words&a=ignored"
        _ = println (run1 getT)
        _ = println (run1 postT)
        _ = println (run1 reqT)
        _ = println ("QUERY: a=" ++ (Dict.get "a" q |> Maybe.withDefault "?") ++ " b=" ++ (Dict.get "b" q |> Maybe.withDefault "?"))
    in
    println "ok"
EOF

( cd "$work" && "$OLDPWD/$SKY" build src/Main.sky >/tmp/httpc-test-build.log 2>&1 )
if [ ! -x "$work/sky-out/Rust/target/debug/sky-app" ]; then
    echo "FAIL http-client: build produced no binary"; tail -5 /tmp/httpc-test-build.log; exit 1
fi

python3 "$work/echo_srv_$PORT.py" & pyserver=$!
# Wait until the responder actually accepts connections (up to ~10s) so the
# Sky app's requests don't race the bind.
ready=0
for _ in $(seq 1 50); do
    if python3 -c "import socket,sys; s=socket.socket(); s.settimeout(0.3); sys.exit(0 if s.connect_ex(('127.0.0.1',$PORT))==0 else 1)" 2>/dev/null; then
        ready=1; break
    fi
    sleep 0.2
done
[ "$ready" -eq 1 ] || { echo "FAIL http-client: responder never came up on :$PORT"; exit 1; }
out=$("$work/sky-out/Rust/target/debug/sky-app" 2>&1)

check() { if echo "$out" | grep -qF "$2"; then echo "  ok: $1"; else echo "  FAIL: $1 — not in output"; fail=1; fi; }
check "GET status+ctype+body" "GET: status=201 ctype=application/json method=GET"
check "POST body"             "POST: status=201 ctype=application/json method=POST xcustom=- body=hello-body"
check "request builder"       "REQ: status=201 ctype=application/json method=PUT xcustom=skyval body=put-body"
check "parseQuery decode+first-wins" "QUERY: a=1 b=two words"

if [ "$fail" -eq 0 ]; then echo "PASS http-client: GET/POST/request/parseQuery"; else echo "FAIL http-client"; echo "--- output ---"; echo "$out"; fi
kill "$pyserver" 2>/dev/null; pyserver=""
exit "$fail"
