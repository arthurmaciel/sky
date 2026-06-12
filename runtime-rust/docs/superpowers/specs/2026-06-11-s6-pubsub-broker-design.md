# S6 — PubSub / Broker (Rust backend) — design

**Date:** 2026-06-11
**Branch:** `feat/runtime-rust` (fork `arthurmaciel/sky` only)
**Roadmap slice:** S6 (PubSub / Broker). Dependency-independent of the Std.Ui
line; needs only the floor + shipped Live. Perf-gated by S1.

## Purpose

Bring the Sky pub/sub surface to the Rust backend: `Cmd.publish` /
`Cmd.publishNoEcho` (update-return), `Sub.subscribeTopic` (receive), and
`PubSub.publish` / `PubSub.publishNoEcho` (Task-shaped, any context). This is
the in-process broker that lets independent Sky.Live sessions broadcast to one
another (multi-session chat, live carts, presence), with a trait seam the
Console slice (S7) can later extend cross-process.

This unblocks `27-multi-session-chat` (the canonical pub/sub fixture, today
`sky-build-fails` on Rust because the kernels are unmapped) and the pub/sub leg
of `37-composite-live-shop`.

## The governing constraint: no runtime errors

Per `runtime-rust/CLAUDE.md`, the Rust backend exists to make "if it compiles,
it works" a guarantee. Pub/sub is the first feature where that constraint bites,
because Sky's pub/sub is **dynamically typed at the language level**: a topic is
a runtime `String`, publisher and subscriber are decoupled, and the library
signature is `subscribeTopic : String -> (any -> msg) -> Sub msg`. Sky's own
type checker cannot catch a publisher/subscriber payload-type mismatch — the
dynamism is upstream of every backend.

The Go backend implements this with a single reflect-based registry that carries
payloads as `any` and can panic-then-recover on a mismatch. **Reproducing that
risk surface in Rust is a defect, not parity.** The design below monomorphises
the dynamism away using the concrete payload type the Sky type-checker already
knows at each call site, so the payload never becomes `any` and is never
downcast. The result is a statically-typed broker with **zero payload-type
runtime errors** — categorically safer than Go, which is the existential
justification for the slice.

## Current state

### Go reference (`runtime-go/rt`)

- `live_topics.go` — `Broker` interface (`Subscribe` / `SubscribeWithOwner` /
  `Publish`) + the in-process `topicRegistry` impl. `SessionEvent { topic,
  payload any, Origin string, SkipOrigin bool }`, channel fan-out, mutex-guarded
  `entries` map.
- `live.go` — `Cmd_publish` / `Cmd_publishNoEcho` (build SkyCmd),
  `Sub_subscribeTopic` (build SkySub), `liveApp.Publish` (dispatch-path fan-out;
  injects `session.sid` as `Origin`).
- `live_pubsub_task.go` — `PubSub_publish` / `PubSub_publishNoEcho` (Task-shaped,
  via `atomic.Pointer` to the live app; server-side publishes carry empty
  `Origin`).
- Semantics: **echo-by-default** (`publish`); **SkipOrigin self-suppression**
  (`publishNoEcho`, issue #359) — the broker skips the subscriber whose
  `ownerSid == Origin`.

### Rust gap

- `tea.rs` has `SkyCmd<M>` / `SkySub<M>` enums but **no `Publish` variant and no
  broker**.
- `ws_client.rs` already establishes the exact receive pattern S6 needs: a
  `SkySub::Source(Box::new(move |emit| { … }))` that spawns a task tapping a
  `tokio::sync::broadcast` channel and calls `emit(to_msg(event))` per frame.
- The Live runtime already carries type-erased values for `Event::OnRaw`
  (`Arc<dyn Any + Send + Sync>`) — precedent, but NOT what this design uses for
  payloads.
- `kernelToRust` (Types.hs) maps none of `Cmd_publish` / `Cmd_publishNoEcho` /
  `Sub_subscribeTopic` / `PubSub_publish` / `PubSub_publishNoEcho`. This is why
  `27` currently fails to emit Rust at all.

## Scope decision

**In-process broker + a `Broker` trait seam, in-process impl only.** Mirror
Go's design (an interface plus one concrete registry). Do NOT build the
cross-process tier now — S7 (Console) adds a cross-process impl behind the same
trait once its exact needs are pinned. YAGNI-clean and dependency-faithful.

## Design

### The per-type monomorphic broker (`live/pubsub.rs`)

New module `runtime-rust/src/sky_runtime/live/pubsub.rs`, peer of `dispatch.rs`
/ `sse.rs`. One broker **per concrete payload type `T`**; the payload travels as
its real Rust type end-to-end.

```rust
struct Event<T> { payload: T, origin: String, skip_origin: bool }

struct Subscriber<T> {
    tx: tokio::sync::broadcast::Sender<Event<T>>,
    owner_sid: String,
}

pub struct Broker<T> {
    topics: Mutex<HashMap<String, Vec<Subscriber<T>>>>,
}

impl<T: Clone + Send + 'static> Broker<T> {
    fn subscribe(&self, topic: &str, owner_sid: String)
        -> tokio::sync::broadcast::Receiver<Event<T>>;
    // returns the count of subscribers that received the broadcast
    fn publish(&self, topic: &str, payload: T, origin: &str, skip_origin: bool) -> i64;
}

// Global registry keyed by TypeId. The ONE cast (Box<dyn Any> -> Arc<Broker<T>>)
// is correct by construction: a Broker<T> is only ever stored under
// TypeId::of::<T>(). The PAYLOAD is never erased and never downcast.
fn broker<T: Clone + Send + Sync + 'static>() -> Arc<Broker<T>>;
//   REGISTRY: Lazy<Mutex<HashMap<TypeId, Box<dyn Any + Send + Sync>>>>
```

`broker::<T>()` is the only `dyn Any` site in the slice, and it is
provably-correct-by-construction (TypeId-keyed). It is coded with a total
`downcast_ref` + `match`; the structurally-impossible `None` arm re-creates the
broker rather than `unwrap`.

### The three Sky surfaces (all monomorphic)

`tea.rs` gains one variant whose closure is **not** generic over `T` (the
payload `T` is captured inside, exactly like the existing `SkyCmd::Perform`):

```rust
SkyCmd::Publish(Box<dyn FnOnce(&str /*origin sid*/) -> i64 + Send>)
```

- **`cmd_publish::<T, Msg>(topic: String, payload: T) -> SkyCmd<Msg>`**
  → `SkyCmd::Publish(Box::new(move |origin| broker::<T>().publish(&topic, payload, origin, false)))`.
  `cmd_publish_no_echo` is identical with `skip_origin = true`.
- **`sub_subscribe_topic::<T, Msg, F: Fn(T) -> Msg + …>(topic: String, f: F) -> SkySub<Msg>`**
  → `SkySub::Source(Box::new(move |emit| { let owner_sid = current_session_sid(); let mut rx = broker::<T>().subscribe(&topic, owner_sid); spawn: while let Ok(ev) = rx.recv().await { emit(f(ev.payload)) } }))`.
  `ev.payload: T`, `f(ev.payload): Msg` — no downcast anywhere. The codegen-facing
  signature carries NO `owner_sid` (the Sky kernel has no sid); the Source closure
  reads the session sid from the materialisation context the Live runtime provides
  when it starts the subscription — the same per-session context that routes
  `emit`ted Msgs back to the right TEA loop. For a non-session materialisation the
  sid is `""` (echo-default no-op, matching Go).
- **`pubsub_publish::<T>(topic: String, payload: T) -> SkyTask<Error, i64>`**
  (+ `pubsub_publish_no_echo`) — Task-shaped, callable from any context; resolves
  to the subscriber count, or `Err Unavailable` when no Live app is registered in
  this process. Runs outside any session → `origin = ""`.

### Origin injection (dispatch-time, not build-time)

The publishing sid is unknown when `cmd_publish` runs inside `update`. The
`SkyCmd::Publish` closure therefore **takes the origin as a parameter**; the
Live dispatch loop calls `thunk(&session.sid)` when it processes the Cmd —
matching Go, where `liveApp.Publish` injects `session.sid` as `Origin`. The
Task-shaped `pubsub_publish` has no session and passes `origin = ""` (Go's
server-side publishes carry empty `Origin`, so echo-default is a structural
no-op for them).

### Codegen (`src/Sky/Generate/Rust/Builder/Types.hs`)

Add to `kernelToRust`:

| Sky kernel | Rust fn |
|---|---|
| `Cmd_publish` | `cmd_publish` |
| `Cmd_publishNoEcho` | `cmd_publish_no_echo` |
| `Sub_subscribeTopic` | `sub_subscribe_topic` |
| `PubSub_publish` | `pubsub_publish` |
| `PubSub_publishNoEcho` | `pubsub_publish_no_echo` |

Rust infers `T` from the closure parameter / payload expression — no type
annotations are emitted. The analyzer marks pub/sub usage so the `live` module +
its deps are pulled into the generated `Cargo.toml` (the broker lives under
`live/`). Codegen emits the `(topic, to_msg)` pair only; the session sid the
broker needs for `SkipOrigin` is threaded by the Live runtime at
subscription-materialisation time (see `sub_subscribe_topic` above), so there is
no Sky-visible signature change.

### Data flow

```
update returns SkyCmd::Publish(thunk)
  -> dispatch loop calls thunk(&session.sid)
    -> broker::<T>().publish(topic, payload, sid, skip)
      -> for each Subscriber<T> on topic (minus origin if skip_origin):
           tx.send(Event{ payload, origin, skip_origin })
  -> each subscribed session's SkySub::Source task: rx.recv() -> Event<T>
    -> emit(f(ev.payload))  // Msg into THAT session's TEA loop
      -> update -> re-render -> SSE patch
```

The payload is `T` the entire way; the only erasure is the TypeId-keyed broker
container.

## Error handling — the no-runtime-errors rule, applied

- **Registry cast:** TypeId-keyed; total `downcast_ref` + `match`; impossible
  `None` arm re-creates, never `unwrap`.
- **Mutex poisoning:** `lock().unwrap_or_else(|e| e.into_inner())` everywhere —
  a poisoned lock never aborts the app (the map is valid data).
- **`broadcast::send` with zero receivers:** returns count `0`, not an error.
- **Subscriber `recv()`:** `Lagged(n)` → structured `warn` + continue; `Closed`
  → end the task cleanly. Never `unwrap`.
- **`pubsub_publish` with no Live app:** `Err Unavailable` (typed Task error),
  matching Go.
- **Type-mismatched publisher/subscriber:** structurally isolated by `Broker<T>`
  → silent non-delivery (optional `debug` note if a topic string is observed at
  more than one `T`), never a panic.

## Subscriber lifecycle

A session's `SkySub::Source` task owns its `broadcast::Receiver`; when the
session ends the task drops and the receiver with it. The broker lazily prunes
any topic entry whose `Sender::receiver_count() == 0`, so the topic/subscriber
maps stay bounded — mirroring Go's unsubscribe-func cleanup.

## Out of scope

- The cross-process / Redis broker tier (S7's concern; the trait seam is the
  only forward-looking artefact built here).
- `37-composite-live-shop`'s anon-struct / field-method gap (a separate
  codegen item; S6 delivers only `37`'s pub/sub leg).
- Any change to the Go backend or shared codegen outside the `TargetRust ->`
  seam.

## Testing

- **Runtime unit tests** (`pubsub.rs` `#[cfg(test)]`): N-subscriber fan-out;
  echo-by-default delivers to the publisher; `SkipOrigin` suppresses exactly the
  origin subscriber; zero-subscriber count `0`; **per-type isolation** (same
  topic string, two `T`s → no cross-talk); no panic on `Lagged` / `Closed`;
  `pubsub_publish` → `Err Unavailable` with no Live app; lazy prune drops a
  zero-receiver topic entry.
- **Codegen:** `27-multi-session-chat` emits Rust and `cargo build`s (today
  `sky-build-fails`).
- **No-panic audit:** `grep` the new code for `unwrap` / `expect` / `panic!` /
  unchecked `[i]` / unchecked `downcast` — none in Sky-reachable paths.

## Acceptance (the per-slice triple)

- **Example acceptance:** `scripts/rust-sweep.sh | grep 27-multi-session-chat`
  shows `builds`.
- **Go-backend equivalence:** `SKY_REF_TARGET=go scripts/rust-equiv.sh
  27-multi-session-chat` prints `OK[27-multi-session-chat]` (same broadcast
  behaviour: a message published in one session reaches the other subscriber;
  echo-by-default reaches the publisher).
- **Perf gate:** `scripts/rust-perf.sh 27-multi-session-chat` within the live
  envelope (re-baseline note from S1 applies on a quiet host).

`37`'s pub/sub leg builds; flip the `37` line only once its anon-struct gap is
also closed.

## Done-criteria

- `Cmd.publish` / `Cmd.publishNoEcho` / `Sub.subscribeTopic` / `PubSub.publish`
  / `PubSub.publishNoEcho` emit and run on the Rust backend with **zero payload
  erasure** (per-type brokers).
- `27-multi-session-chat` passes the acceptance triple.
- No `unwrap` / `panic!` / unchecked downcast in any Sky-reachable pub/sub path.
- S6 flipped DONE in the roadmap tracking table; README notes pub/sub parity.
