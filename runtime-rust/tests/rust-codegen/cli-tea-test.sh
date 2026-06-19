#!/usr/bin/env bash
# Sub-E step 1 regression: the Sky.Cli TEA loop on target=rust. Builds a
# line-oriented counter (init/update/view/onLine + Cmd.none/Sub.none), pipes
# stdin lines, and checks the rendered view sequence. No server/background —
# just stdin -> stdout, so it's deterministic.
set -u
cd "$(dirname "$0")"
SKY=../../../sky-out/sky
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail=0

mkdir -p "$work/src"
cat > "$work/sky.toml" <<EOF
name = "clic-test"
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
import Sky.Core.Task as Task
import Std.Cli as Cli
import Std.Cmd as Cmd
import Std.Sub as Sub


type Msg = Increment | Decrement | Reset | NoOp

type alias Model = { count : Int }

init : () -> ( Model, Cmd Msg )
init _ = ( { count = 0 }, Cmd.none )

update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        Increment -> ( { model | count = model.count + 1 }, Cmd.none )
        Decrement -> ( { model | count = model.count - 1 }, Cmd.none )
        Reset -> ( { count = 0 }, Cmd.none )
        NoOp -> ( model, Cmd.none )

view : Model -> String
view model = "count=" ++ String.fromInt model.count ++ " "

subscriptions : Model -> Sub Msg
subscriptions _ = Sub.none

onLine : String -> Msg
onLine line =
    case String.trim line of
        "+" -> Increment
        "-" -> Decrement
        "r" -> Reset
        _ -> NoOp

main =
    Cli.program
        { init = init, update = update, view = view
        , subscriptions = subscriptions, onLine = onLine
        }
        |> Task.run
EOF

( cd "$work" && "$OLDPWD/$SKY" build src/Main.sky >/tmp/cli-tea-build.log 2>&1 )
if [ ! -x "$work/sky-out/rust/target/debug/sky-app" ]; then
    echo "FAIL cli-tea: build produced no binary"; tail -6 /tmp/cli-tea-build.log; exit 1
fi

out=$(printf '+\n+\n-\nr\n+\n' | "$work/sky-out/rust/target/debug/sky-app" | tr -d '\n')
want="count=0 count=1 count=2 count=1 count=0 count=1 "
if [ "$out" = "$want" ]; then
    echo "PASS cli-tea: view sequence correct"
else
    echo "FAIL cli-tea: expected [$want] got [$out]"; fail=1
fi
exit "$fail"
