# Pub/sub `any` Dict payloads + `Db.get*` on a generic row — design

**Date:** 2026-06-12
**Branch:** `feat/runtime-rust` (fork `arthurmaciel/sky` only)
**Task:** #52 — "Rust codegen: `Db.getString`/`getInt`/`getBool` on an `any`/Dict row".

## Boundary (load-bearing)

The fix lives **entirely** in `runtime-rust/` and `src/Sky/Generate/Rust/`.
The triggering example — `examples/27-multi-session-chat` — is the **Sky
author's upstream code** and MUST NOT be edited. It is already written to the
documented idiom; the gap is that our Rust backend cannot yet lower that idiom.

## The upstream idiom (authored correctly)

`docs/skylive/pubsub.md` (upstream) states: **"Dict-shaped payloads
(`Dict.fromList […]`) are the safest portable choice."** Payloads are opaque
`any` in v0.15.x; v0.16+ cross-process broker tiers JSON-encode them, so dicts
are the most portable shape. The stdlib API is `any`-typed on both backends:

```
Cmd.publish     : String -> any -> Cmd msg
Sub.subscribeTopic : String -> (any -> msg) -> Sub msg
Db.getString    : String -> row -> String      -- row is a free type var
```

Example 27 follows this exactly: a `Dict String String` payload, a
`MessageReceived any` Msg constructor, an app-specific `decodeChatMessage : any
-> ChatMessage` decoder that reads fields with `Db.getString`, and an `init`
that reads `req` via `Db.getString "path" req`.

## Root cause

`any` is a Sky type variable; the Rust backend already lowers it to a generic
(`decode_chat_message<any: Clone + … + 'static>(payload: any)`). Two things
break:

1. **Generic body vs. concrete accessor.** Rust type-checks a generic body
   **once against its bounds**, not per-instantiation. The runtime accessor
   `db_get_string(field: String, row: HashMap<String,String>)` demands a
   concrete `HashMap`; a bound-less `any` generic is not one → E0308 at the
   generic *definition*. Monomorphization never gets a chance.
2. **`init`'s `req` is a concrete `LiveReq`.** The Live runtime pins `init`'s
   first param to `sky_runtime::LiveReq` (a struct: `path`/`query`/`method` +
   `params`/`headers`/`cookies : SkyDict<String>`). `db_get_string("path",
   req)` → `LiveReq` ≠ `HashMap` → E0308.

The publisher side already works: `Cmd.publish topic payloadDict` infers `T =
Dict String String` from the concrete argument, so `Broker<Dict>` is created.

## Why "just monomorphize the generic" is *almost* the whole answer

Treating `any` as a generic `T` and monomorphizing is the right model — with
**one** exception the type system forces:

- **`Msg` is monomorphic.** `update : Msg -> …`, `view : Model -> Html Msg`,
  and `live_app_routed::<…, Msg, …>` are all instantiated with a *single*
  concrete `Msg`. A `MessageReceived any` field would make `enum Msg<P>`
  generic — impossible here.
- **The S6 broker keys on `TypeId::of::<T>()`.** The publisher publishes a
  concrete `Dict` (`Broker<Dict>`); the subscriber's `T` is read from
  `MessageReceived`'s field type. If that field stays generic there is no
  concrete `TypeId` to match the publisher's broker → pub/sub silently fails
  to connect.

So the **Msg-ADT payload `any` field** is the one place a generic cannot
survive; it must resolve to a concrete carrier. Per upstream docs that carrier
is **`Dict String String`** (= `HashMap<String,String>`). Everywhere else, the
generic stays and monomorphizes.

## Design

### Part 1 — `SkyRow` trait + generic `db_get_*` (runtime-rust/)

```rust
/// A value a Sky `Db.get*` accessor can read string-keyed fields from.
/// Total: returns "" for an absent field (never panics).
pub trait SkyRow {
    fn sky_get(&self, field: &str) -> String;
}

impl SkyRow for SkyDict<String> {          // = HashMap<String,String> (transparent alias)
    fn sky_get(&self, field: &str) -> String {
        self.get(field).cloned().unwrap_or_default()
    }
}

impl SkyRow for LiveReq {                   // init's typed request
    fn sky_get(&self, field: &str) -> String {
        match field {
            "path" => self.path.clone(),
            "query" => self.query.clone(),
            "method" => self.method.clone(),
            _ => self.params.get(field)
                .or_else(|| self.headers.get(field))
                .or_else(|| self.cookies.get(field))
                .cloned().unwrap_or_default(),
        }
    }
}

pub fn db_get_string<R: SkyRow>(field: String, row: R) -> String { row.sky_get(&field) }
pub fn db_get_field<R: SkyRow>(field: String, row: R) -> String { row.sky_get(&field) }
pub fn db_get_int<R: SkyRow>(field: String, row: R) -> i64 {
    row.sky_get(&field).parse::<i64>().unwrap_or(0)
}
pub fn db_get_bool<R: SkyRow>(field: String, row: R) -> bool {
    matches!(row.sky_get(&field).as_str(), "1" | "true" | "TRUE" | "t" | "T")
}
```

`SkyDict<String>` stays a transparent alias for `HashMap<String,String>` (the
impl *is* the HashMap impl, named for intent). A genuine newtype is tracked
separately as task #55 — deliberately out of scope here (backend-wide
wrap/unwrap blast radius). The four query/row helpers `db_query`,
`row_to_map`, etc. keep producing `HashMap<String,String>`, which satisfies
`SkyRow`.

### Part 2 — `SkyRow` bound on `any` generics used as a row (codegen)

When a function parameter typed `any` flows into a `Db.get*` call in the body,
add `SkyRow` to that generic's bound. So `decode_chat_message<any: SkyRow +
Clone + …>(payload: any)` type-checks generically and **monomorphizes per call
site** (`any = HashMap` from the pub/sub path; `any = LiveReq` would be reached
directly without a generic, since `req` is a concrete pinned type — Part 1
covers it). This is the dataflow-narrow rule: a bare `any` generic gains
`SkyRow` *only* when consumed as a Db row, never otherwise (no blast radius on
unrelated `any` generics).

### Part 3 — Msg-ADT payload `any` field → `Dict String String` (codegen)

Resolve a bare `any` **ADT-constructor field** to `Dict String String` (=
`HashMap<String,String>`), mirroring the existing `anyCarrierField`
(`TypeEmitter.hs`) mechanism that already resolves Std.Ui `AttrEvent`/`Raw`
`any` fields to their carriers. Scope: an `any` constructor field with no
existing Std.Ui carrier → `Dict String String`. A concrete-typed payload field
(e.g. `Received String` in `examples/rust/33-live-pubsub`) is **unaffected** —
only bare `any` fields resolve. This makes `MessageReceived(HashMap)`, so:

- `Msg` stays a single concrete type.
- `subscribeTopic … MessageReceived` infers `T = HashMap` →
  `Broker<HashMap>` — matching the publisher's `Broker<HashMap>` → pub/sub
  connects.
- `MessageReceived payload` yields a concrete `HashMap`, which flows into the
  decoder and the `Db.get*` calls.

## Why this honours `runtime-rust/CLAUDE.md`

- **No erasure.** No `dyn Any` for payloads; the Dict travels as its real type
  `HashMap<String,String>` through `Broker<HashMap>`. `db_get_*` is statically
  total over `SkyRow`.
- **No panics.** `SkyRow::sky_get` returns `""` on a missing field; `db_get_int`
  defaults to 0; `db_get_bool` to false.
- **Graceful payload-type disagreement.** If a publisher published a non-Dict
  `any` payload, its `Broker<OtherT>` would simply not match the subscriber's
  `Broker<Dict>` — drop, no panic — exactly the documented degradation.

## Out of scope

- Editing any upstream file (esp. `examples/27-multi-session-chat`).
- A `SkyDict` newtype (task #55).
- `init`'s top-level `Task.run (Db.connect ())` deadlock — a **separate**
  runtime gap (block_on inside the tokio runtime) discovered while smoke-testing
  example 27; blocks the *runtime* of any top-level-`Task.run`+`Db` Live app, not
  the codegen this spec fixes. Filed separately.
- The three `HashMap<String,String>`-row *mutation* kernels (`db_insert_row`,
  `db_update_by_id`, `db_find_by_conditions`) — they take a genuinely-Dict
  argument from `Dict.fromList`, never an `any`/`LiveReq`, so they are not
  affected.

## Testing

- **Build, both backends:** `examples/rust/` Rust sweep stays green; a focused
  Rust example exercising an `any` Dict pub/sub payload + `Db.get*` (and an
  `init` reading `req` via `Db.getString`) builds clean on Rust. Go regression:
  `examples/01-hello-world` + the existing Go sweep unaffected (codegen change
  is Rust-target-gated).
- **Runtime:** the focused Rust example serves and delivers a cross-session
  Dict broadcast over SSE (mirrors `examples/rust/33-live-pubsub`'s
  `verify.sh`, with a Dict payload instead of a String).
- **Acceptance example** lives in `examples/rust/` (ours), never in the
  upstream `examples/` set.

## Done-criteria

- `db_get_string/int/bool/field` are generic over `SkyRow`; `SkyRow` impl'd for
  `SkyDict<String>` + `LiveReq`; runtime tests green.
- Codegen: a Db-row `any` generic gains a `SkyRow` bound (Part 2); a bare `any`
  Msg-ctor field resolves to `Dict String String` (Part 3).
- A new `examples/rust/` acceptance example builds **and runs** on Rust with an
  `any` Dict pub/sub payload + `Db.get*` decode; cross-session broadcast proven.
- Go backend byte-identical / unaffected; full Rust `examples/rust/` sweep green.
- The upstream `examples/27-multi-session-chat` is **untouched**.
