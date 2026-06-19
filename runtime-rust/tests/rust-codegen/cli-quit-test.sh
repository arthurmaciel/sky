#!/usr/bin/env bash
# Sub-E step 3 regression: Cmd.perform with a diverging task (System.exit) on
# target=rust. Mirrors examples/20-cli-counter's `q` quit. Builds a counter,
# pipes `+ + q`, asserts the view advanced and the process exited 0 (the
# System.exit fired through Cmd.perform). Pure stdin -> stdout.
set -u
cd "$(dirname "$0")"
SKY=../../../sky-out/sky
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail=0

mkdir -p "$work/src"
cat > "$work/sky.toml" <<EOF
name = "cliq-test"
version = "0.1.0"
entry = "src/Main.sky"
target = "rust"

[source]
root = "src"
EOF
cat > "$work/src/Main.sky" <<'EOF'
module Main exposing (main)

import Sky.Core.Prelude exposing (..)
import Sky.Core.String as String
import Sky.Core.System as System
import Sky.Core.Task as Task
import Std.Cli as Cli
import Std.Cmd as Cmd
import Std.Sub as Sub


type Msg = Increment | Quit | NoOp

type alias Model = { count : Int }

init : () -> ( Model, Cmd Msg )
init _ = ( { count = 0 }, Cmd.none )

update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        Increment -> ( { model | count = model.count + 1 }, Cmd.none )
        Quit -> ( model, Cmd.perform (System.exit 0) (\_ -> NoOp) )
        NoOp -> ( model, Cmd.none )

view : Model -> String
view model = "count=" ++ String.fromInt model.count ++ " "

subscriptions : Model -> Sub Msg
subscriptions _ = Sub.none

onLine : String -> Msg
onLine line = case String.trim line of
    "+" -> Increment
    "q" -> Quit
    _ -> NoOp

main =
    Cli.program
        { init = init, update = update, view = view
        , subscriptions = subscriptions, onLine = onLine
        }
        |> Task.run
EOF

( cd "$work" && "$OLDPWD/$SKY" build src/Main.sky >/tmp/cli-quit-build.log 2>&1 )
if [ ! -x "$work/sky-out/rust/target/debug/sky-app" ]; then
    echo "FAIL cli-quit: build produced no binary (diverging Cmd.perform?)"; tail -8 /tmp/cli-quit-build.log; exit 1
fi

out=$(printf '+\n+\nq\n' | "$work/sky-out/rust/target/debug/sky-app")
rc=$?
if echo "$out" | grep -q "count=2" && [ "$rc" -eq 0 ]; then
    echo "PASS cli-quit: System.exit via Cmd.perform (count=2, exit 0)"
else
    echo "FAIL cli-quit: rc=$rc out=[$out]"; fail=1
fi
exit "$fail"
