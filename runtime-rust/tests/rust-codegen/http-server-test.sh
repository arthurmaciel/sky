#!/usr/bin/env bash
# Sub-D.1 regression: a Sky.Http.Server app on target=rust must build, serve,
# and answer GET (with path param), POST (body), static files, and 404 — via
# the axum serve loop. Separate from run.sh because a server doesn't print to
# stdout and exit; it has to be started, curled, and killed.
set -u
cd "$(dirname "$0")"
SKY=../../../sky-out/sky
PORT=8231
work=$(mktemp -d)
trap 'pkill -f "sky-out/Rust/target/debug/sky-app" 2>/dev/null; rm -rf "$work"' EXIT
fail=0

mkdir -p "$work/src" "$work/public"
echo 'static-ok' > "$work/public/f.txt"
cat > "$work/sky.toml" <<EOF
name = "httpd-test"
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


home : Server.Request -> Task Error Server.Response
home req =
    Task.succeed (Server.html "<h1>home</h1>")


greet : Server.Request -> Task Error Server.Response
greet req =
    Task.succeed (Server.json ("{\"hi\":\"" ++ (Server.param "name" req |> Maybe.withDefault "x") ++ "\"}"))


echo : Server.Request -> Task Error Server.Response
echo req =
    Task.succeed (Server.text ("echo:" ++ req.body))


main =
    Server.listen $PORT
        [ Server.get "/" home
        , Server.get "/greet/:name" greet
        , Server.post "/echo" echo
        , Server.static "/assets" "./public"
        ]
EOF

( cd "$work" && "$OLDPWD/$SKY" build src/Main.sky >/tmp/httpd-test-build.log 2>&1 )
if [ ! -x "$work/sky-out/Rust/target/debug/sky-app" ]; then
    echo "FAIL http-server: build produced no binary"; tail -5 /tmp/httpd-test-build.log; exit 1
fi

( cd "$work" && setsid ./sky-out/Rust/target/debug/sky-app >/tmp/httpd-test-run.log 2>&1 < /dev/null & )
srv_pid=$!
sleep 1.5

check() { # name expected actual
    if [ "$2" = "$3" ]; then echo "  ok: $1"; else echo "  FAIL: $1 — expected [$2] got [$3]"; fail=1; fi
}
check "GET /"            "<h1>home</h1>"     "$(curl -s http://127.0.0.1:$PORT/)"
check "GET /greet/:name" '{"hi":"Sky"}'      "$(curl -s http://127.0.0.1:$PORT/greet/Sky)"
check "POST /echo body"  "echo:ping"         "$(curl -s -X POST --data ping http://127.0.0.1:$PORT/echo)"
check "static file"      "static-ok"         "$(curl -s http://127.0.0.1:$PORT/assets/f.txt)"
check "404 unknown"      "404"               "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:$PORT/nope)"
check "content-type html" "text/html"        "$(curl -s -D - -o /dev/null http://127.0.0.1:$PORT/ | grep -i '^content-type' | tr -d '\r' | sed 's/.*: *//')"

if [ "$fail" -eq 0 ]; then echo "PASS http-server: all routes answered"; else echo "FAIL http-server"; fi
# Kill the server explicitly and reap it so the trap's later pkill (and the
# job-control teardown) can't reflect a signal into this script's exit code.
kill "$srv_pid" 2>/dev/null
pkill -f "sky-out/Rust/target/debug/sky-app" 2>/dev/null
wait "$srv_pid" 2>/dev/null
exit "$fail"
