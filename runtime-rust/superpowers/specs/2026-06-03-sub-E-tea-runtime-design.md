# Sub-E — TEA runtime (Cmd/Sub) on Rust, starting with Sky.Cli

Goal: bring the TEA event loop (init/update/view/subscriptions + Cmd/Sub) to the
Rust backend. This is the groundwork the WebSocket **client** receive path needs
(`onMessage` → `Sub_subscribeWebSocket` → a subscription feeding `update`), and
the foundation for Sky.Tui / Sky.Live later.

Strategy: start with **Sky.Cli** — the line-oriented TEA backend. It has the full
Cmd/Sub core (subManager, tickers, `Cmd.perform` async) but `view : Model ->
String` (no Std.Ui/ANSI rendering to port), so it isolates the runtime core from
the rendering subsystem. Reference: `runtime-go/rt/cli.go` (~210 lines) +
`runtime-go/rt/tea_subs.go` (~100 lines). Test: `examples/20-cli-counter`.

## Surface

- `Std.Cli.program { init, update, view, subscriptions, onLine } : Task Error ()`
  (kernel `Cli_program`). cfg is an ANONYMOUS record of 5 functions.
  - `init : () -> (Model, Cmd Msg)`
  - `update : Msg -> Model -> (Model, Cmd Msg)`
  - `view : Model -> String`
  - `subscriptions : Model -> Sub Msg`
  - `onLine : String -> Msg`
- `Std.Cmd`: `none`, `batch : List (Cmd msg) -> Cmd msg`,
  `perform : Task err a -> (Result err a -> msg) -> Cmd msg`.
- `Std.Sub`: `none`, `batch : List (Sub msg) -> Sub msg`,
  `every : Int -> msg -> Sub msg`.

## Obstacles + decisions

1. **Anonymous cfg record** — the runtime can't name the synthesized Anon
   struct. DECISION: a call-site **peephole** on `Cli.program { … }` splices the
   5 field exprs into a generic `cli_program(init, update, view, subs, on_line)`.
   Avoids any cfg bridge. (Falls back to the generic path if cfg isn't a literal
   — acceptable; the canonical form is a literal.)
2. **Cmd/Sub generic over Msg with erased intermediate** — `Cmd<M>` /
   `Sub<M>` carry boxed, Msg-producing closures (the `a` in `perform` is erased
   inside the composed future; M stays concrete — NOT `any`).
   ```rust
   pub enum SkyCmd<M> { None, Batch(Vec<SkyCmd<M>>),
       Perform(Box<dyn FnOnce() -> Pin<Box<dyn Future<Output=M> + Send>> + Send>) }
   pub enum SkySub<M> { None, Batch(Vec<SkySub<M>>), Every { ms: i64, msg: M } }
   ```
3. **subManager** — tokio task per `Sub.every` + an `mpsc` msg channel + an
   abort handle per sub (mirror tea_subs.go's cancel channel).
4. **The loop** — `cli_program` runs init → fire cmd → subs → print view →
   `tokio::select!` over (stdin line → onLine → Msg) and (msgCh → Msg) → update →
   re-subs → re-view, until EOF.

## Step plan

1. ✅ **TEA core + Cli.program loop** (DONE) — SkyCmd/SkySub types + `cmd_none`/
   `cmd_batch`/`cmd_perform`/`sub_none`/`sub_batch`/`sub_every` kernels, the
   `cli_program` anonymous-record peephole, the stdin→onLine→update→view loop,
   `Cmd msg`/`Sub msg` type rendering, and `Cmd.none`/`Sub.none` zero-arg handling.
   Validated: a line counter (`+ - r`, EOF) renders the right view sequence
   (`tests/rust-codegen/cli-tea-test.sh`). The `cli_program` loop ignores the
   returned Cmd/Sub for now (no msg channel yet) — so `Cmd.perform` builds but
   doesn't fire and `Sub.every` doesn't tick; those are steps 2-3. The stock
   `examples/20-cli-counter` uses `Cmd.perform (System.exit 0)` (a diverging task
   → free `A`, E0283) — that inference case lands with step 3.
2. **Sub.every tickers** — subManager spawns tokio tickers; validate a ticking
   clock.
3. **Cmd.perform async** — compose task→toMsg(Result) into the msgCh; validate
   the counter's `q` (System.exit via perform) + an async-fetch counter.
4. **WS client Sub source** — `Sub_subscribeWebSocket` feeds the msgCh; the
   Task-tier WS client (connect/send/close via tokio-tungstenite) + onMessage
   subscription → completes the Rust WebSocket client.
5. **Sky.Tui** (later) — reuse the core, add the Std.Ui→ANSI renderer.
6. **Sky.Live** (later, large) — per-session managers, SSE, stores, VNode diff.

## Notes

- `SkyCmd<M>` / `SkySub<M>` render via runtimeOpaque-style handling generic over
  M (the curry fix + collectRenderedTVars from Sub-D.2 already help function-typed
  fields and phantom vars).
- Non-capturing vs capturing: the cfg functions are top-level (init/update/…),
  passed by name → fn pointers, fine. `Cmd.perform`'s toMsg may be a lambda
  (`\_ -> NoOp`) — non-capturing, fn-pointer-coercible.
