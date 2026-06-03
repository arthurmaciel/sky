# Sub-D.2 — Sky.Http.Server.WebSocket on the Rust runtime (axum ws)

Status: **runtime foundation built + compiling; Sky→Rust path BLOCKED on a
general codegen curry/uncurry inconsistency** (see "Blocker" below). Builds on
Sub-D.1 (the axum server runtime). Target example: `examples/33-websocket-echo`.

## Blocker (2026-06-03) — curry/uncurry inconsistency in the Rust codegen

The 5 kernels + the upgrade/registry/ws_loop machinery + the WsHandle/WsServerCfg
bridges are implemented and the runtime crate compiles. The echo example does
NOT yet compile, blocked on a *general* Rust-backend bug surfaced by WS's
multi-arg callbacks:

- Function **types/signatures** lower **curried**: Sky `A -> B -> C` →
  `fn(A) -> fn(B) -> C`. So `withOnMessage`'s callback param is curried.
- Multi-arg lambda/closure **values** lower **uncurried**: `\sock msg ->` and
  `defaultCfg`'s `\_ _ ->` → `|sock, msg|` / `|_, _|`.

These disagree with each other, so no fixed `WsServerCfg` field shape compiles
all three sites (defaultCfg record literal · withX body `result.onX = cb` ·
user call `withOnMessage (\sock msg -> …)`). Errors: E0308 + E0593.

**Fix (separate sub-project, regression risk):** render `TLambda` arrow-chains
uncurried in `typeToRustString` — `A -> B -> C` → `fn(A, B) -> C` — to match the
uncurried value lowering. This touches every higher-order function's param type
across the Rust backend, so it needs its own careful sweep + regression pass
(List.map / foldl / every HOF). The WS runtime fields are already set to the
uncurried target so they'll line up once that lands.

The committed Builder.hs changes (collectUndefinedTypes base-name matching;
typeToRustString dropping Sky args for runtimeOpaque types; the parametric
runtimeOpaque alias branch) are general improvements that stand on their own and
are regression-checked.

## Surface (5 kernels + 2 types)

From `sky-stdlib/Sky/Http/Server/WebSocket.sky`:

| Kernel | Sky type | snake_case (codegen) |
|---|---|---|
| `ServerWebSocket_upgrade` | `Request -> WebSocketServerCfg msg -> Task Error Response` | `server_web_socket_upgrade` |
| `ServerWebSocket_sendToClient` | `Int -> String -> Task Error ()` | `server_web_socket_send_to_client` |
| `ServerWebSocket_sendBinaryToClient` | `Int -> String -> Task Error ()` | `server_web_socket_send_binary_to_client` |
| `ServerWebSocket_broadcast` | `List Int -> String -> Task Error ()` | `server_web_socket_broadcast` |
| `ServerWebSocket_closeClient` | `Int -> Task Error ()` | `server_web_socket_close_client` |

Types: `WebSocketServer = WebSocketServer Int` (opaque per-peer handle);
`WebSocketServerCfg msg = { onConnect, onMessage, onClose, onError,
maxMessageBytes, originPatterns }` — built via `defaultCfg |> withOnX`.

## Crux finding (2026-06-02)

Compiling a minimal WS server on `target=rust` reached cargo with only
mechanical errors:

- The codegen lowered the cfg callbacks as **`fn(...)` pointers**, NOT generic
  closures. All `fn(A)->B` share one type, so `withOnMessage cb cfg = { cfg |
  onMessage = cb }` (a record update that "swaps" a callback) compiles — the
  closure-type-swap problem that blocks Std.Cache does NOT apply here.
- E0593 (callback "takes 2 args, expected 1"): the generated cfg struct typed
  callbacks curried; the lambdas are written multi-arg. Bridging the cfg to a
  runtime struct with **uncurried** fn-pointer fields fixes the shape.
- E0392 (phantom `msg` param): bridging replaces the generated struct, so the
  unused param disappears.

## Architecture

1. **Bridge** (`runtimeOpaqueTypes`): `WebSocketServerCfg` → `WsServerCfg`,
   `WebSocketServer` → `WsHandle`. `WsServerCfg` has fn-pointer fields:
   ```rust
   pub struct WsServerCfg {
       pub onConnect: fn(WsHandle) -> SkyTask<SkyError, ()>,
       pub onMessage: fn(WsHandle, String) -> SkyTask<SkyError, ()>,
       pub onClose:   fn(WsHandle) -> SkyTask<SkyError, ()>,
       pub onError:   fn(WsHandle, SkyError) -> SkyTask<SkyError, ()>,
       pub maxMessageBytes: i64,
       pub originPatterns: Vec<String>,
   }
   ```
   `defaultCfg` (stdlib record literal of no-op lambdas) + `withOnX` (stdlib
   record updates) construct/update it directly — no override module needed.

2. **Per-peer registry**: `static REGISTRY: Lazy<Mutex<HashMap<i64,
   UnboundedSender<WsOut>>>>` (WsOut = Text|Binary|Close). `send_to_client` /
   `broadcast` / `close_client` look up the sender by id and push.

3. **Upgrade via task-local**. The HTTP handler pipeline (Sub-D.1
   `method_router`) builds a plain `ServerRequest`, losing the axum upgrade
   capability. So before calling the Sky handler, the wrapper extracts an
   optional `WebSocketUpgrade` and stashes it in a tokio task-local
   (`WS_UPGRADER`), running the handler inside `.scope(...)`.
   `server_web_socket_upgrade` reads the task-local, calls
   `ws.on_upgrade(move |sock| ws_loop(sock, cfg, id))`, stashes the resulting
   axum `Response` in a second task-local (`WS_RESPONSE`), and returns a
   sentinel `ServerResponse` (101). The wrapper, after the handler returns,
   prefers `WS_RESPONSE` if set.

4. **ws_loop**: assign id, register the write-sender, fire `onConnect`, then
   select over (a) incoming frames → `onMessage`/`onError`, (b) the mpsc
   receiver → `ws.send`. On close: `onClose`, deregister. Origin validation:
   in `ENV=production`, empty `originPatterns` → 403 before upgrade.

## Known limitation (first cut)

fn-pointer callbacks **cannot capture**, so handlers that close over app state
(chat broadcasting to a stored client list) won't compile. Non-capturing
handlers (echo, per-client logging, broadcast-to-all-via-registry) work.
Capturing handlers need `Arc<dyn Fn>` cfg fields + closure boxing at record
construction (the same erasure Std.Cache needs) — a separate follow-up.

## Steps

1. axum `ws` feature; `server_ws.rs` runtime module; bridge + kernel pins; wiring.
2. Crux spike: echo via inline on_upgrade loop (no registry) — prove the
   task-local upgrade path + cfg bridge compile and a client round-trips.
3. Registry + send/broadcast/close kernels.
4. Origin validation + production gate.
5. `examples/33-websocket-echo` build + a client round-trip regression test.
