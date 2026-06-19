#!/usr/bin/env bash
# Sub-E step 2 regression: Sub.every tickers + the async TEA loop on target=rust.
# A ticking counter (Sub.every 100 Tick) auto-increments; we run it with a timed
# stdin window and assert periodic ticks fired. Tolerant to ±1 tick (timing).
set -u
cd "$(dirname "$0")"
SKY=../../../sky-out/sky
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail=0

mkdir -p "$work/src"
cat > "$work/sky.toml" <<EOF
name = "tick-test"
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


type Msg = Tick | NoOp

type alias Model = { count : Int }

init : () -> ( Model, Cmd Msg )
init _ = ( { count = 0 }, Cmd.none )

update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        Tick -> ( { model | count = model.count + 1 }, Cmd.none )
        NoOp -> ( model, Cmd.none )

view : Model -> String
view model = "tick=" ++ String.fromInt model.count ++ "\n"

subscriptions : Model -> Sub Msg
subscriptions _ = Sub.every 100 Tick

onLine : String -> Msg
onLine _ = NoOp

main =
    Cli.program
        { init = init, update = update, view = view
        , subscriptions = subscriptions, onLine = onLine
        }
        |> Task.run
EOF

( cd "$work" && "$OLDPWD/$SKY" build src/Main.sky >/tmp/cli-ticker-build.log 2>&1 )
if [ ! -x "$work/sky-out/rust/target/debug/sky-app" ]; then
    echo "FAIL cli-ticker: build produced no binary"; tail -6 /tmp/cli-ticker-build.log; exit 1
fi

# ~0.45s window @ 100ms ticks → expect tick=0..4ish. Assert >=2 ticks fired.
out=$(sleep 0.45 | "$work/sky-out/rust/target/debug/sky-app")
if echo "$out" | grep -q "tick=0" && echo "$out" | grep -q "tick=2"; then
    echo "PASS cli-ticker: Sub.every fired periodic ticks"
else
    echo "FAIL cli-ticker: expected >=2 ticks, got:"; echo "$out"; fail=1
fi
exit "$fail"
