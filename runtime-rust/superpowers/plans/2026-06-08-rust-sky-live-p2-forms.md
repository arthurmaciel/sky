# Rust Sky.Live P2 — Typed Form Submit Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** `Ui.form [onSubmit DoSignIn]` / `Html.form [Ev.onSubmit DoSignIn]` where
`DoSignIn : AuthCreds -> Msg` (a typed record) works on the Rust backend — the
browser form POST is decoded into the typed record `T` and dispatched as a Msg
through the live loop; a malformed/incomplete form dispatches no Msg + a warn log.

**Architecture:** Builds on P0+P1 (`feat/runtime-rust`). The `Event::OnForm`
variant + `resolve_form` already exist (T1/T7). P2 adds: a `decode_form::<T>`
runtime fn, the `onSubmit` codegen peephole that wraps a handler with
`decode_form`, the form-target serde-derive stamping (the hard codegen bit), the
event-handler form-data wire path, and a gate example. URL routing is **P3**, not
this phase.

**Tech stack:** Rust runtime (`runtime-rust/src/sky_runtime/live/*`), Haskell
codegen (`src/Sky/Generate/Rust/Builder.hs`), serde/serde_json (already deps when
`usesLive`). Reuses the ported Go client JS (handles form submit → POST already).

**Design source:** `runtime-rust/superpowers/specs/2026-06-07-rust-sky-live-design.md` §3.

---

## Wire contract (confirmed from `live/client.js`)

Form submit POSTs JSON `{sessionId, seq, msg, args, handlerId}` where for a
`submit` event `args = [data]` and `data` is a plain object `{name: value, …}`
(only the submitter button's name/value + non-submit fields; checkboxes/radios
only when checked). So `args[0]` is a JSON **object**, unlike click/input where
`args[0]` is a string. `handlerId` is the form's sky-id; `msg` defaults empty.

---

## Task 1: `OnForm` returns `Option<M>` (decode-failure = no Msg)

**Files:**
- Modify: `runtime-rust/src/sky_runtime/live/html.rs`
- Modify: `runtime-rust/src/sky_runtime/live/dispatch.rs`

The decode-failure path needs the form closure to be able to produce *no* Msg.
Change the `OnForm` payload from `Fn(FormData) -> M` to `Fn(FormData) -> Option<M>`.

- [ ] **Step 1: Update the enum variant** (`html.rs`)

Find `OnForm(String, std::sync::Arc<dyn Fn(FormData) -> M + Send + Sync>)` and
change the return type to `Option<M>`:
```rust
OnForm(String, std::sync::Arc<dyn Fn(FormData) -> Option<M> + Send + Sync>),
```
Leave `OnMsg`/`OnString`/`OnBool` unchanged. The `name()` accessor's `OnForm(n, _)`
arm is unaffected.

- [ ] **Step 2: Update `resolve_form`** (`dispatch.rs`)

```rust
pub fn resolve_form(&self, sky_id: &str, event: &str, fd: FormData) -> Option<M> {
    match self.map.get(&(sky_id.to_string(), event.to_string()))? {
        Event::OnForm(_, f) => f(fd),   // f already returns Option<M>
        _ => None,
    }
}
```
(Was `Some(f(fd))`.)

- [ ] **Step 3: Update the existing dispatch.rs OnForm test**

The `resolves_onform` test constructs `Event::OnForm("submit", Arc::new(|fd| Msg::Typed(...)))`.
Change the closure to return `Option<Msg>`:
```rust
Event::OnForm("submit".into(), std::sync::Arc::new(|fd: FormData| {
    Some(Msg::Typed(fd.get("name").cloned().unwrap_or_default()))
})),
```
The assertions (`resolve` returns None for OnForm; `resolve_form` returns `Some(Msg::Typed("alice"))`) stay the same.

- [ ] **Step 4: Build + test**

Run: `cd runtime-rust && cargo test --features live resolves_onform 2>&1 | tail -8`
Expected: PASS. Also `cargo build --features live` clean (the codegen-emitted
OnForm closures don't exist yet, so only the runtime + test change here).

- [ ] **Step 5: Commit** (NO co-author trailer)

```bash
git add runtime-rust/src/sky_runtime/live/html.rs runtime-rust/src/sky_runtime/live/dispatch.rs
git commit -m "feat(rust): Sky.Live OnForm returns Option<M> — decode failure dispatches no Msg"
```

---

## Task 2: `decode_form` runtime helper

**Files:**
- Modify: `runtime-rust/src/sky_runtime/live/mod.rs` (or a new `live/form.rs` + wire into mod.rs)

- [ ] **Step 1: Write the failing test**

In a `#[cfg(test)] mod tests` in the file you add `decode_form` to:
```rust
#[derive(serde::Deserialize, PartialEq, Debug)]
struct Creds { email: String, password: String }

#[test]
fn decode_form_ok_and_missing() {
    let mut fd = std::collections::HashMap::new();
    fd.insert("email".to_string(), "a@b.c".to_string());
    fd.insert("password".to_string(), "pw".to_string());
    let r: Result<Creds, String> = decode_form(fd);
    assert_eq!(r, Ok(Creds { email: "a@b.c".into(), password: "pw".into() }));

    let mut bad = std::collections::HashMap::new();
    bad.insert("email".to_string(), "a@b.c".to_string()); // missing password
    let r2: Result<Creds, String> = decode_form(bad);
    assert!(r2.is_err());
}
```

- [ ] **Step 2: Run — verify fail** (`cannot find function decode_form`)

`cd runtime-rust && cargo test --features live decode_form_ok 2>&1 | tail -6`

- [ ] **Step 3: Implement `decode_form`**

Decode the `FormData` (`HashMap<String,String>`) into a typed record `T`. Every
form value arrives as a String; the Sky form-target records in P2 are
all-String-field records (email/password/etc.), so a direct
`serde_json::from_value` over a `Map<String, Value::String>` works. Implement:
```rust
use crate::sky_runtime::live::html::FormData;

/// Decode browser form data into a typed Sky record `T`. Form values are always
/// strings; `T`'s fields are matched by name (Sky record fields are camelCase,
/// matching the HTML `name=` attributes the view emits). Missing/extra fields:
/// serde reports missing required fields as an error → the caller dispatches no Msg.
pub fn decode_form<T: serde::de::DeserializeOwned>(fd: FormData) -> Result<T, String> {
    let map: serde_json::Map<String, serde_json::Value> = fd
        .into_iter()
        .map(|(k, v)| (k, serde_json::Value::String(v)))
        .collect();
    serde_json::from_value(serde_json::Value::Object(map)).map_err(|e| e.to_string())
}
```
> P2 scope: all-String form records. Numeric/bool form fields (serde would reject
> `"42"` into an `i64`) are P-later — note it in a `// FIXME(P-later)` comment.
> If a field is `Bool`/`Int`, the form-target record won't decode; the guard in
> Task 5 plus the decode-failure path keep this safe (no Msg), not a panic.

- [ ] **Step 4: Wire (if new file) + test** — if you made `live/form.rs`, add
`pub mod form; pub use form::*;` to `live/mod.rs`. Run:
`cd runtime-rust && cargo test --features live decode_form_ok 2>&1 | tail -6` → PASS.

- [ ] **Step 5: Commit** (NO co-author trailer)
```bash
git add runtime-rust/src/sky_runtime/live/
git commit -m "feat(rust): Sky.Live decode_form — FormData -> typed record via serde"
```

---

## Task 3: Event-handler form-data wire path

**Files:**
- Modify: `runtime-rust/src/sky_runtime/live/mod.rs` (`EventBody` + `event_handler`)

The handler currently parses `args: Vec<String>` and only calls `resolve`. For a
`submit` event `args[0]` is a JSON **object** (the form data), so it must parse
flexibly and route to `resolve_form`.

- [ ] **Step 1: Make `args` flexible**

Change `EventBody`'s `args` field from `Vec<String>` to `Vec<serde_json::Value>`
(with `#[serde(default)]`). Add a helper to coerce a `Value` to a display string
for the existing click/input path:
```rust
fn value_to_string(v: &serde_json::Value) -> String {
    match v { serde_json::Value::String(s) => s.clone(), other => other.to_string() }
}
```
For the existing `resolve(hid, event, &args_as_strings)` call, map the args to
strings via `value_to_string` (so click/input/keydown keep working exactly as
before — confirm 28-live-counter still round-trips after this task).

- [ ] **Step 2: Route submit → `resolve_form`**

In `event_handler`, after resolving `hid`/`event`, branch:
```rust
let msg = if event == "submit" {
    // args[0] is the form-data object {name: value, …}; lower-case keys so the
    // serde field match is case-insensitive against camelCase Sky fields.
    let fd: FormData = parsed.args.first()
        .and_then(|v| v.as_object())
        .map(|o| o.iter()
            .map(|(k, v)| (k.clone(), value_to_string(v)))
            .collect())
        .unwrap_or_default();
    let e = entry.lock().unwrap();
    e.index.resolve_form(&hid, &event, fd)
} else {
    let args: Vec<String> = parsed.args.iter().map(value_to_string).collect();
    let e = entry.lock().unwrap();
    e.index.resolve(&hid, &event, &args)
};
```
(Keep the lock short — drop before `msg_tx.send`, as the existing code does.)

> Key-case note: the design flags HTML `name=` vs Sky-field case. Sky record
> fields are camelCase and the view emits matching `name=` attributes, so a direct
> match works for the canonical case. Do NOT force-lowercase if it would break the
> camelCase match — verify against the Task 6 example (`email`/`password` are
> already lowercase). If a mismatch appears, normalise in `decode_form` instead.

- [ ] **Step 3: Build + regression** — `cargo build --features live` clean; then
re-run the 28-live-counter round-trip (click still works) per Task 6's harness or
the P1 gate steps. Confirm `"text":"1"` still arrives.

- [ ] **Step 4: Commit** (NO co-author trailer)
```bash
git add runtime-rust/src/sky_runtime/live/mod.rs
git commit -m "feat(rust): Sky.Live event handler — submit routes form-data to resolve_form"
```

---

## Task 4: Codegen — `onSubmit` peephole → `Event::OnForm`

**Files:**
- Modify: `src/Sky/Generate/Rust/Builder.hs`

`Ev.onSubmit handler` must lower to `Attribute::EventAttr(Event::OnForm("submit",
Arc::new(move |fd| decode_form::<T>(fd).ok().map(handler))))` where `T` is the
handler's form-record arg type. (For a plain-Msg `onSubmit DoThing` with no record
arg — `onSubmit : a -> Attribute msg` also accepts a bare Msg — emit an OnForm that
ignores `fd`: `Arc::new(move |_fd| Some(handler.clone()))`. Detect which by the
handler's arity/type.)

- [ ] **Step 1: Find how event attributes lower today**

`grep -n "EventAttr\|onClick\|on_click\|Event::OnMsg\|\"onSubmit\"\|\"onClick\"" src/Sky/Generate/Rust/Builder.hs`
and read how `Ev.onClick msg` / `Ev.onInput f` currently emit `Event::OnMsg` /
`Event::OnString`. The onSubmit arm sits beside them. Identify the head form:
`Can.Call (Can.VarKernel "Std.Html.Events" "onSubmit") [handler]` (or the
canonicalised module name — confirm by inspecting the AST / how onClick matches).

- [ ] **Step 2: Determine the handler's form-record type `T`**

From the solved type of `handler` (an `EmitCtx`/`ecSolvedTypes` lookup at the
handler expr's region), get its argument type. If it's a record/alias type `T`,
that's the form target → emit the `decode_form::<T>` wrapper. If the handler is a
bare Msg value (no function arg), emit the fd-ignoring wrapper. Mirror how other
peepholes read solved types (e.g. the `cmd_perform` / partial-application logic
already reads `ecSolvedTypes`). Emit the Rust type string for `T` via the existing
`typeToRustString`/`rustifyExpectedType` helper.

- [ ] **Step 3: Emit the OnForm wrapper**

Record-handler case:
```
Event::OnForm("submit".to_string(), std::sync::Arc::new({
    let h = <handler-expr>;
    move |fd| sky_runtime::decode_form::<<RustT>>(fd).ok().map(|t| h(t))
}))
```
Bare-Msg case:
```
Event::OnForm("submit".to_string(), std::sync::Arc::new({
    let m = <handler-expr>;
    move |_fd| Some(m.clone())
}))
```
Wrap as `Attribute::EventAttr(...)` exactly like the onClick/onInput emission does.
Register `T` for serde-derive stamping (Task 5) — collect it into a set the type
emitter consults. Use a shared mechanism (e.g. an IORef/Writer of form-target type
names threaded through codegen, OR a post-hoc scan — see Task 5).

- [ ] **Step 4: Build the compiler**
`timeout 1800 cabal install --overwrite-policy=always --installdir=./sky-out --install-method=copy exe:sky 2>&1 | grep -iE "error:|Copying 'sky'"`

(Functional verification happens in Task 6 once the derive lands in Task 5.)

- [ ] **Step 5: Commit** (NO co-author trailer)
```bash
git add src/Sky/Generate/Rust/Builder.hs
git commit -m "feat(rust): codegen — onSubmit lowers to Event::OnForm with decode_form::<T>"
```

---

## Task 5: Codegen — stamp `#[derive(serde::Deserialize)]` on form-target records

**Files:**
- Modify: `src/Sky/Generate/Rust/Builder.hs`

The form-target record `T` (e.g. `AuthCreds`) must derive `serde::Deserialize` so
`decode_form::<T>` compiles. Today record structs derive `Clone, Debug` (and
`PartialEq`?) — confirm and add `serde::Deserialize` for form-target types only
(deriving it on *every* record would force serde bounds on non-form records and
their fields, risking E0277 on function-typed fields).

- [ ] **Step 1: Find record struct emission + its derive list**

`grep -n "derive(\|RustTypeDef\|RStructDef\|unionToRustTypeDef\|toRustStruct\|pub struct" src/Sky/Generate/Rust/Builder.hs`
Identify where a Sky record/alias becomes `#[derive(...)] pub struct Name_R { … }`.

- [ ] **Step 2: Thread the form-target set into struct emission**

Collect the set of form-target type names from Task 4 (the `T`s passed to
`decode_form::<T>`). When emitting a struct whose codegen name is in that set, add
`serde::Deserialize` to its derive list. Field names must match the form `name=`
attributes — Sky record fields are camelCase and serde uses the field name
verbatim, so no `#[serde(rename)]` needed for the canonical case (note it).

Mechanism options (pick the simplest that fits the existing code flow):
- (a) An `IORef (Set String)` populated during expr lowering (Task 4) and read when
  the type-defs are emitted — matches the existing `globalKernelAlias`/region-types
  IORef pattern.
- (b) A pre-pass over all modules collecting `onSubmit` handler arg types before
  type emission.
Report which you used.

- [ ] **Step 3: Guard non-serde-able form targets**

If a form-target record has a field serde can't derive (function/task-typed), the
derive would fail to compile. The design treats this as a compile error by design.
For P2, simply let the Rust compiler reject it (clear E0277) — do NOT silently skip
the derive. Add a one-line comment noting a friendlier Sky-side error is P-later.

- [ ] **Step 4: Build the compiler** (as Task 4 Step 4).

- [ ] **Step 5: Commit** (NO co-author trailer)
```bash
git add src/Sky/Generate/Rust/Builder.hs
git commit -m "feat(rust): codegen — stamp serde::Deserialize on form-target records"
```

---

## Task 6: P2 gate — `examples/rust/29-live-form`

**Files:**
- Create: `examples/rust/29-live-form/sky.toml`, `examples/rust/29-live-form/src/Main.sky`

A live form that, on submit, decodes a typed record and updates the model
(rendered back over SSE).

- [ ] **Step 1: Write the example**

`sky.toml`: standard `target = "rust"` + `[source] root = "src"`, name `29-live-form`.

`src/Main.sky` (adjust import paths to what builds — verify `Ev.onSubmit` /
`Attr.*` names):
```elm
module Main exposing (main)

import Sky.Core.Prelude exposing (..)
import Sky.Core.Task as Task
import Std.Html as Html
import Std.Html.Attributes as Attr
import Std.Html.Events as Ev
import Std.Live as Live
import Std.Cmd as Cmd
import Std.Sub as Sub
import Sky.Core.Error exposing (Error)


type alias Creds = { email : String, password : String }


type Msg = SignIn Creds


type alias Model = { lastEmail : String }


init : () -> ( Model, Cmd Msg )
init _ = ( { lastEmail = "(none)" }, Cmd.none )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        SignIn creds -> ( { model | lastEmail = creds.email }, Cmd.none )


view : Model -> Html.Html Msg
view model =
    Html.div []
        [ Html.form [ Ev.onSubmit SignIn ]
            [ Html.input [ Attr.type_ "email", Attr.name "email" ] []
            , Html.input [ Attr.type_ "password", Attr.name "password" ] []
            , Html.button [ Attr.type_ "submit" ] [ Html.text "Sign in" ]
            ]
        , Html.p [] [ Html.text ("last: " ++ model.lastEmail) ]
        ]


subscriptions : Model -> Sub Msg
subscriptions _ = Sub.none


main : Task Error ()
main =
    Live.app
        { init = init, update = update, view = view, subscriptions = subscriptions
        , routes = [ Live.route "/" () ]
        , notFound = ()
        }
```
> Confirm `Attr.type_` / `Attr.name` exist: `grep -nE "type_|^name|\"name\"" sky-stdlib/Std/Html/Attributes.sky`.
> If `type_` is spelled differently, adjust. The password field has no `value`/
> `onInput` (the mandatory password pattern).

- [ ] **Step 2: Build**
```bash
cd examples/rust/29-live-form && rm -rf sky-out .skycache
/home/arthur/Documentos/comp/sky/sky-out/sky build src/Main.sky 2>&1 | tail -4
grep -n "decode_form\|OnForm\|Deserialize" sky-out/rust/src/main.rs | head   # confirm codegen
```
Expected: `Build complete`; `decode_form::<…Creds…>` + `Event::OnForm` present; the
`Creds` struct derives `Deserialize`.

- [ ] **Step 3: Round-trip gate**

Start the server (background, self-timeout) and drive the form via curl, matching
the wire shape (`args=[{email,password}]`, `event="submit"`, `handlerId=<form sky-id>`):
```bash
cd examples/rust/29-live-form
timeout 45 ./sky-out/rust/target/debug/sky-app &   # or run_in_background
sleep 1.5
curl -s -c /tmp/jar29 http://localhost:8000/ -o /tmp/p29.html
FORM=$(grep -oE 'sky-id="[^"]*"' /tmp/p29.html | grep -iE 'form|_form' | head -1 | sed 's/sky-id="//;s/"//')
# (the form element's sky-id; inspect /tmp/p29.html if the grep needs adjusting)
( curl -s -N -b /tmp/jar29 http://localhost:8000/_sky/sse > /tmp/sse29.out & ); sleep 0.5
curl -s -b /tmp/jar29 -X POST http://localhost:8000/_sky/event \
  -H 'content-type: application/json' \
  -d "{\"handlerId\":\"$FORM\",\"event\":\"submit\",\"args\":[{\"email\":\"a@b.c\",\"password\":\"pw\"}]}"
sleep 0.7
grep -i 'a@b.c' /tmp/sse29.out && echo "FORM-OK: model updated from decoded record"
pkill -9 -f "29-live-form/sky-out"
```
Expected: `FORM-OK` — an SSE patch sets the `<p>` text to `last: a@b.c`, proving the
form decoded into `Creds` and dispatched `SignIn`.

Also: post a MALFORMED form (missing password) and assert NO patch + the server
logs a warn (decode-failure path) — no panic, server stays up.

- [ ] **Step 4: Commit** (NO co-author trailer)
```bash
git add examples/rust/29-live-form
git commit -m "feat(rust): P2 gate — 29-live-form decodes typed record on submit over SSE"
```

---

## Task 7: Regression + README

**Files:**
- Modify: `runtime-rust/README.md`

- [ ] **Step 1: Live + form regression**
- `cargo test --features live` → all pass (incl. updated OnForm test + decode_form).
- 28-live-counter round-trip still green (click path via the Task 3 string-coercion).
- 27-live-static still prints byte-correct HTML.

- [ ] **Step 2: Go parity** — `cd examples/01-hello-world && rm -rf sky-out .skycache .skydeps && sky build src/Main.sky` → `Build complete: sky-out/app`; `timeout 300 cabal test --test-options='--match "FfiGenGoKernelJson"'` → 0 failures.

- [ ] **Step 3: README** — bump example count to 29; add a 29-live-form row to the
examples table; update the Sky.Live "In progress" section to note P2 (typed form
submit) landed; move OnForm/form-decode out of the "Ahead (P2–P6)" list.

- [ ] **Step 4: Commit** (NO co-author trailer)
```bash
git add runtime-rust/README.md
git commit -m "docs(rust): sync README — Sky.Live P2 (typed form submit)"
```

---

## Self-review notes

- **OnForm → Option<M>** is the load-bearing shape change; everything else composes
  on it. Decode failure = `None` = no Msg + warn, never a panic.
- **Two codegen tasks (4 + 5) are the hard part** — emitting the `decode_form::<T>`
  wrapper AND stamping serde on `T`. They must agree on the set of form-target types
  (Task 4 collects, Task 5 consumes). Deriving serde only on form targets avoids
  forcing serde bounds on every record.
- **Scope:** all-String form records (P2). Numeric/bool fields, multi-value fields,
  file inputs, and `#[serde(rename)]` key-normalisation are P-later. URL routing is
  **P3**.
- **No Go changes; no shared `.sky` changes** beyond what already type-checks
  (`onSubmit : a -> Attribute msg` already exists). All codegen is `--target rust`.
