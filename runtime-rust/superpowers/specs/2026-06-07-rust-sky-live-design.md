# Rust Sky.Live — design

**Date:** 2026-06-07
**Status:** approved (brainstorm) → ready for `writing-plans`
**Scope:** Full Sky.Live runtime (S1–S5) + `Std.Html` rendering + `Std.Ui`
layout engine, on the Rust backend (`target = rust`). Reuses Go's wire
protocol + embedded client verbatim.

This is the largest deferred arc of the Rust backend. The design fits the
backend's hard constraints — **no `any` / `Box<dyn Any>`, static dispatch
only** — and maximises reuse of the already-shipped `tea.rs` (Cmd/Sub/msg
channel/SubManager), the axum server (routing/cookies/middleware), the
`http_stream` Sub Sources, and the Go diff algorithm + patch schema + client JS.

---

## 1. Architecture & core representation

A `Live.app` is **monomorphic over `(Model, Msg)`**, instantiated once via
`live_app::<Model, Msg>(cfg)` — the same shape as `cli_program` and the existing
axum server. `cfg` carries `init / update / view / subscriptions / routes /
notFound` plus optional `head` / `consoleAuth` / `status` (later phases).

**The load-bearing insight:** render + diff need only *structure* (tag, attr
names/values, event *names*, sky-ids, text) — never `Msg` values. Only
**event dispatch** needs `Msg` (turn a fired `(sky-id, event, args)` into a
`Msg`). This is why a fully generic-over-`Msg` runtime works with zero `any`.

**Bridged types** (the `ChunkEvent` mechanism, scaled to a recursive family).
Three fixed stdlib ADTs bridge to runtime generic enums so the runtime can name
and walk them:

```rust
pub enum Html<M> {
    Element(String, Vec<Attribute<M>>, Vec<Html<M>>),
    Text(String),
    Raw(String),
}
pub enum Attribute<M> {
    Attr(String, String),
    BoolAttr(String, bool),
    Event(Event<M>),
    NoAttr,
}
pub enum Event<M> {
    OnMsg(String, M),
    OnString(String, Box<dyn Fn(String) -> M + Send + Sync>),
    OnBool(String, Box<dyn Fn(bool) -> M + Send + Sync>),
    OnForm(String, Box<dyn Fn(FormData) -> M + Send + Sync>), // replaces OnRaw String any
}
```

**The new codegen wrinkle.** `Html msg` is parametric over the **app's `msg`
type**, not a pinned concrete type. So unlike `ChunkEvent<SkyError>` (instantiated
bridge), these bridge to `Html<M>` carrying the Sky type variable through:
`unionToRustTypeDef` gains a **third case** — a *generic alias* that preserves
the type var, emitting `pub type StdHtmlHtml<M> = sky_runtime::Html<M>;` (today's
two cases are plain `pub use` for a non-generic path, and instantiated `pub type`
for `...<SkyError>`). `Attribute`/`Event` bridge the same way.

`Event<M>` drops the `OnRaw String any` variant (the `any`-in-field the Rust
codegen rejects by design) for the typed `OnForm` closure — see §3.

**Per-session state** (one entry per browser session, in the store):

```rust
struct LiveSession<Model, Msg> {
    model: Model,
    last_view: Html<Msg>,                              // for diffing
    handler_index: HashMap<(SkyId, EventName), HandlerRef<Msg>>, // for O(1) dispatch
    seq: u64,
    sse_tx: Option<mpsc::Sender<SsePatch>>,
    msg_tx: mpsc::UnboundedSender<Msg>,                // Cmd/Sub results re-enter here
    // … TTL, owned stream ids, sub handles …
}
```

`last_view` and `handler_index` are both derived from `view(model)` on each
commit. The handler index makes dispatch O(1) (Go keeps the analogous
`handlers map[string]any`).

**Module layout** (new, under `runtime-rust/src/sky_runtime/`):

- `live/mod.rs` — `live_app`, axum mount, session lifecycle
- `live/html.rs` — bridged `Html/Attribute/Event` + `assign_sky_ids` + `render_html`
- `live/diff.rs` — `diff<M>(old, new) -> Vec<Patch>` + `Patch` (structure-only)
- `live/dispatch.rs` — POST `/_sky/event` → resolve handler → Msg → update → diff → SSE
- `live/sse.rs` — `/_sky/sse` channel, hello/heartbeat, bounded buffer
- `live/session.rs` — `LiveStore` trait + in-memory impl (S1); persisted (S3)
- `live/client.js` — Go's embedded client, ported verbatim

---

## 2. Data flow

**(a) Initial page load — full HTML.** `GET /any-route`:
1. match `routes` in declaration order, capture `:param`s, build the `Page` value
   from the captured strings → initial `Model` via `init`. **No reflection** (Go
   reflect-calls the Page ctor; Rust can't): each `route "/apps/:slug" AppDetail`
   stores a `Fn(Vec<String>) -> Page` closure built at the `route` call site where
   the ctor + arity are known — the same closure-capture trick as `OnForm`. Params
   are always `String`. (Routing detail is P3; S1 uses the single `"/"` route.)
2. `view(model)` → `Html<Msg>` → `assign_sky_ids` → `render_html` → full doc
   (runtime wraps `<meta sky-base>`, the `head` list, inline reset, client
   `<script>`).
3. create `LiveSession`, store `last_view` + derived `handler_index`, set the
   session cookie, return HTML.

**(b) SSE attach.** `GET /_sky/sse` → register `sse_tx`; send `event: hello`
immediately + 2 KB pad + `X-Accel-Buffering: no`; 15 s heartbeats. Client flips
"connected" only on `hello`.

**(c) Event round-trip — the core loop.** Client POSTs `/_sky/event`
`{sky_id, event, args, seq}`:
1. `handler_index[(sky_id, event)]` → `Event<Msg>` → produce `Msg`
   (`OnMsg` clone · `OnString`/`OnBool`/`OnForm` call the closure — §3).
2. `update(msg, model)` → `(model', cmd)`.
3. `view(model')` → new `Html<Msg>`; `assign_sky_ids`; `diff(last_view, new)` →
   `Vec<Patch>`; rebuild `handler_index`; store `model'` + new `last_view`.
4. serialize patches to the Go patch JSON; push over `sse_tx` with the next
   `seq`. **Empty patch set → JSON-ack** (preserves uncontrolled inputs).
5. run `cmd` (next bullet).

**(d) Cmd / Sub — reuse `tea.rs`.** `update` returns `(Model, Cmd Msg)`.
`Cmd.perform task toMsg` spawns the task (existing `cmd_perform`); the produced
`Msg` re-enters the loop at **(c.2)** via the session's `msg_tx`. The Live session
owns a `SubManager<Msg>`-style channel exactly like `cli_program`, but the output
side emits **SSE patches instead of printing**. `subscriptions(model)`
re-evaluates after each commit; `Sub.every` tickers + `Http.Stream.chunks`
Sources reuse the **already-shipped `SubManager`** (keyed/detached patterns from
the chunks arc) verbatim.

> Sky.Live on Rust is **`cli_program` with an HTTP+SSE front end instead of
> stdin+stdout.** The TEA machinery (Cmd firing, Sub diffing, msg channel) is
> `tea.rs`, already shipped and tested.

**(e) Navigation.** `sky-nav` links + `data-sky-path` sentinel + popstate →
client re-`GET`s with `X-Sky-Nav: 1` → server returns a full-body patch + the
client pushes history. Routing match logic is Msg-agnostic (P3).

---

## 3. Dispatch + form decode

**Dispatch.** `handler_index[(sky_id, event)]` → produce `Msg`:
- `OnMsg(_, m)` → `m.clone()`
- `OnString(_, f)` → `f(args[0])` · `OnBool(_, f)` → `f(args[0])`
- `OnForm(_, f)` → `f(decode_form(args))` — the one hard case.

A lookup miss (stale sky-id after a race) → no-op + `debug` log (matches Go's
null-`querySelector` tolerance), never a panic.

**Form decode — F-A (serde auto-decode), the chosen approach.** Go auto-decodes
form data into a **typed record** (`onSubmit DoSignIn`, `DoSignIn : AuthCreds ->
Msg`) via reflection; Rust has none. To keep the **same Sky source compiling on
both backends** (cross-backend rule), `onSubmit` becomes a **codegen-aware
kernel**: at each call site the form-record type `T` is known (HM), so codegen
emits

```rust
Event::OnForm("submit".into(), Box::new(move |fd| handler(decode_form::<T>(fd))))
```

and stamps `#[derive(serde::Deserialize)]` on `T` (detected as a form-target
record — a record type flowing into `onSubmit`'s argument position). The runtime
`decode_form::<T: DeserializeOwned>(fd: FormData) -> Result<T, _>` decodes the
form `Dict` via `serde_json`/`serde_urlencoded`.

- **Case-insensitivity:** Go uses case-insensitive `json.Unmarshal`; serde is
  case-sensitive. The runtime lower-cases form keys and the codegen emits the
  matching field names (Sky record fields are already camelCase matching form
  `name=` attributes in the common case); a `#[serde(alias = …)]` or a
  normalising pre-pass covers the mismatch. Final mechanism chosen in the P2 plan.
- **Decode failure** (malformed/missing field) → the closure's `decode_form`
  yields `Err` → **dispatch no Msg** + a `warn` log (the form simply doesn't
  submit), never a fabricated partial record.
- **Guard:** a form-target record with a non-serde-able field (function, task)
  is a hard codegen error with an actionable message, not a silent failure.

This is the single biggest new codegen cost in the arc; it is justified by
cross-backend source compatibility (`onSubmit DoSignIn` must run unchanged on
Go and Rust).

---

## 4. Diff, rendering specifics & Std.Ui

**Diff engine (`live/diff.rs`).** Port Go's `diffTrees` faithfully — generic
`diff<M>(old: &Html<M>, new: &Html<M>) -> Vec<Patch>`, reading structure only.
Patch variants mirror Go's wire schema exactly so the **ported client applies
them unchanged**: `ReplaceNode`, `SetAttr`, `RemoveAttr`, `SetText`,
`InsertChild`, `RemoveChild`, `ReorderKeyed`. Serialized to the identical
patch JSON.

**sky-id stability.** `assign_sky_ids` stamps every element (not text/raw) with a
path-derived id (`r_0_div_1…`); diff matches by sky-id, and by **`sky-key`** when
present (the `Keyed` escape hatch) for stable identity across reorders. Same
algorithm as Go — this is what makes attribute patches land on the right node and
uncontrolled inputs survive.

**Style hoist (P6).** Pseudo-class / transition / animation / media-query
attributes emit a sky-id-scoped `<style data-sky-pc=…>` element. For **void
elements** (`<input>`) the style hoists to a **sibling** slot (the v0.15.57 fix).
Pure render-side; no protocol change.

**Std.Ui (P7).** `Std.Ui` is a **pure transformation `Element msg -> Html msg`**
(row/column/el → inline-styled `div`s; `Background`/`Border`/`Font` → `style=`
strings; `fill`/`spacing`/alignment → flexbox CSS; pseudo-classes → the style
hoist above). It sits **above** the Live runtime and emits the `Html<Msg>` the
runtime already diffs/renders — **zero new runtime/protocol work**, only a port
of the ~2k-line layout lowering (much already Sky source that lowers per-backend,
plus whatever kernels it bottoms out on). A layout bug is a CSS-string bug in a
pure function, not a runtime fault.

**New vs reused:**
- *New:* the `Html/Attribute/Event` bridge (incl. the `msg`-var generic-alias
  codegen case), `render_html`, `assign_sky_ids`, `diff`, dispatch + `decode_form`
  + form-target serde codegen, the SSE endpoint wiring, the HTML page wrap.
- *Reused as-is:* `tea.rs` (Cmd/Sub/msg-channel/SubManager), the axum server +
  routing/cookies/middleware, `http_stream` Sources, the Go client JS, the Go
  patch schema, the Go diff algorithm (transliterated).

---

## 5. Error handling, session stores & testing

**Error handling.**
- **Handler panics / update faults:** `update` runs inside the axum server's
  per-request `catch_unwind`/`SafeGo` boundary → on panic, structured `Error`
  log with a 4-byte errId + a 500, session survives. Mirrors the
  synchronous-panic gate.
- **`Cmd.perform` task failures** surface as the `Result err a` the `toMsg`
  decoder receives — handled in `update` (Task-everywhere two-level pattern).
  Goroutine wrapped in `SafeGo`.
- **Dispatch misses:** no-op + `debug` log.
- **`decode_form` failure:** dispatch no Msg + `warn` log (see §3).
- **SSE backpressure / drops:** bounded buffer + `sky_live_sse_drops_total`-style
  counter + client reconnect/`hello`/heartbeat recovery (inherited from the Go
  protocol).
- **Session eviction (TTL/delete):** closes every owned stream + Sub
  (`http_stream` close + `SubManager` `stop_all`) — no orphaned drains.

**Session stores.** A `LiveStore<Model, Msg>` trait — `get / put / delete / gc`.
P1 ships the in-memory impl (concurrent map + TTL gc task). P5 adds
sqlite/redis/postgres/firestore; the persisted stores serialise `Model` through
the same serde path as forms (`Model: Serialize + DeserializeOwned`), an honest
constraint surfaced as a clear compile error if a `Model` holds a
non-serialisable field. The in-memory store carries no such bound.

**Testing** (three-tier, mirroring the project gate):
- **Rust unit tests** (`#[cfg(test)]` per `live/*.rs`): `diff` golden cases
  (attr set/remove, text, keyed reorder, void-element style hoist);
  `assign_sky_ids` determinism; `decode_form` round-trips incl. case-insensitivity
  + missing-field; a render snapshot for a small tree.
- **Example-driven e2e** (`examples/rust/NN-live-*`): a counter app (click
  round-trip), a form app (`onSubmit DoSignIn` typed decode), a
  streaming-into-view app (reuses the `chunks` arc) — driven by curl + a tiny SSE
  reader asserting the patch JSON (same harness style as 21/22/24).
- **Cross-backend parity:** the same Sky source builds on Go *and* Rust and
  produces the same initial HTML / patch shapes (shared diff schema); a parity
  fixture guards drift.
- **Playwright** (optional, later): the Go suite's `verify-all-web.sh` scenarios
  can point at the Rust binary once P1–P3 land, since client + protocol are
  identical.

---

## 6. Phase sequencing

Eight phases, each its own `writing-plans` → implement → verify cycle with a
concrete gate.

| Phase | Scope | Gate (done =) |
|---|---|---|
| **P0 — Bridge foundation** | `Html/Attribute/Event<M>` bridge incl. the new `msg`-var generic-alias codegen case; `render_html`; `assign_sky_ids`; HTML page wrap | A static `view : Model -> Html Msg` renders byte-correct full HTML (no interactivity) |
| **P1 — Core loop (S1)** | `live_app::<Model,Msg>`, in-memory session, SSE channel, `diff` engine, one event round-trip; Cmd/Sub via `tea.rs` reuse | Counter example: click → update → diff → SSE patch increments live |
| **P2 — Forms (F-A)** | `onSubmit` codegen kernel + `decode_form::<T>` + serde-derive on form-target records | Form example: `onSubmit DoSignIn` (typed `AuthCreds`) round-trips, same source as Go |
| **P3 — Routing (S2)** | `routes`, `:param` capture, `sky-nav`, `data-sky-path`, popstate | Multi-page example navigates; back/forward works |
| **P4 — Pub/sub (S4)** | `Cmd.publish` / `publishNoEcho` / `Sub.subscribeTopic` + broker | Two-session broadcast example: one session's publish patches the other |
| **P5 — Stores (S3)** | `LiveStore` sqlite/redis/postgres/firestore + `Model: Serialize` bound + TTL gc | Counter survives across each persisted store backend |
| **P6 — Polish (S5)** | style-hoist (pseudo-class/transition/animation/media-query), status banner, console mount, input-preservation edges | Pseudo-class example renders scoped `<style>`; reconnect banner recovers |
| **P7 — Std.Ui** | `Element msg -> Html msg` layout lowering (layout/row/column/el, Background/Border/Font, fill/spacing/align, `Input.*`) | A `Ui.layout`-written example renders + interacts identically to Go |

**Dependency spine:** P0 → P1 → {P2, P3, P4} (P3/P4 are largely Msg-agnostic,
parallelisable after P1) → P5 (needs P2's serde) → P6 → P7 (pure render-layer,
needs P6's hoist for pseudo-classes). The first plan after this spec is
**P0 + P1** (the irreducible "it's alive" slice); each later phase gets its own
plan.

---

## Constraints honoured

- **No `any` / `Box<dyn Any>`** — `Msg` stays a real generic parameter end to
  end; the only erasure is `Box<dyn Fn(..) -> M>` for handler closures (M
  concrete). The `OnRaw String any` landmine is removed in favour of typed
  `OnForm`.
- **Static dispatch** — `live_app::<Model, Msg>` monomorphises once per app.
- **Reuse over reinvention** — `tea.rs`, axum server, `http_stream` Sources, Go
  client JS, Go patch schema + diff algorithm all carried over.
- **Cross-backend source compat** — the same Sky app (incl. `onSubmit DoSignIn`
  typed forms) compiles and behaves identically on Go and Rust.
- **Go backend untouched** — all new work is `target = rust`-gated
  (`src/Sky/Generate/Rust/*` + `runtime-rust/*`).
