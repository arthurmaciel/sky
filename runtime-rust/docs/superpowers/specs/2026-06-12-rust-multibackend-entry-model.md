# Rust backend: a coherent program-entry model (multibackend mains)

## Context

Unmodified upstream `examples/24-tui-kitchen-sink` does not build on `--target
rust`. Its `main` picks a UI backend at runtime and runs it:

```elm
main =
    case List.head argsList of
        Just "live" -> Live.app { init, update, view = viewLive, subscriptions, routes, notFound } |> Task.run
        _           -> Tui.app  { init, update, view, subscriptions, onKey } |> Task.run
```

`init` / `update` / `subscriptions` are shared across both backends. Two
codegen failures, both rooted in the entry model assuming a *single* backend:

1. **E0631 — shared `init`.** `collectLiveInitFns` marks `init` (referenced by
   `Live.app`), so `ModuleEmitter` force-pins its param-0 to `sky_runtime::LiveReq`
   (the `#417` `req` feature). But the same `init` is handed to `tui_app_ui`,
   whose bound is `Fn(()) -> …`. One Sky function, two required Rust signatures.
2. **E0308 — `main`'s type.** `ret` is `SkyTask<()>` because `ecLiveInitFns` is
   non-empty (the `#56` "keep the serve future" rule), but each `case` arm is
   `App {…} |> Task.run` → `task_run(app(...))` → `SkyResult`. `#56` assumed
   `Task.run` was incidental with the app future as the real entry — but here
   `Task.run` *is* what runs the app, inline.

The `#56`/`mainIsTask`/`Task.run`/LiveReq-pin interaction has been patched
repeatedly. This spec replaces the heuristics with one coherent model.

## Principles honoured

No Go change; no `Any`; no panic vectors; no runtime errors; sound + efficient.
Every backend-app main keeps identical *runtime behaviour* — only the codegen
shape unifies.

## The model

**A "backend entry" is a `SkyTask<()>`.** `Live.app{}`, `Tui.app{}`,
`Tui.program{}`, `Webview.app{}`, `Cli.program{}` already lower (via their
peepholes) to the runtime driver future (`live_app` / `tui_app_ui` / … →
`SkyTask<()>`).

**Tenet 2 — `Task.run` on a backend entry is the program entry, uniformly.**
`<backend-entry> |> Task.run` lowers to just `<backend-entry>` (drop the
`Task.run`) — *anywhere*: top-level OR inside a `case` arm / `let`. The entry
`block_on`s it. This subsumes the `#56` top-level special-case. For `24`, both
`case` arms become app-futures, so the `case` is a `SkyTask<()>`.

Detection: the operand of `Task.run` is (transitively) a backend-entry kernel
call (`Live.app` / `Tui.app` / `Tui.program` / `Webview.app` / `Cli.program`).
Implemented in the `Task.run` lowering (ExprEmitter): peel `App.x {...} |> Task.run`
/ `Task.run (App.x {...})` to the app peephole output, no `task_run`.

**Tenet 3 — `mainIsTask` derives from the body, not `usesLive`.**
`mainIsTask = usesBackendApp || not usesTaskRun`, where
`usesBackendApp = usesLive || usesTui || usesWebview || usesCliProgram`. A main
that yields a backend entry (Tenet 2 dropped its `Task.run`) is a `SkyTask` →
`block_on`. A bare-`Task` main (no `Task.run`) is a `SkyTask` → `block_on`. A
pure-CLI `someTask |> Task.run` (no backend app) runs inline → `()`. `ret`
(ModuleEmitter) mirrors this: `()` only for `usesTaskRun && not usesBackendApp`.

This changes the *codegen* of pure-Tui `Tui.app{} |> Task.run` mains (21/38/41)
from "run `task_run` inline, `main : ()`" to "drop + `main : SkyTask` + entry
`block_on`" — **behaviour-identical** (`task_run` ≡ `block_on`). All examples
re-verified.

**Tenet 4 — init signature per-call-site (decision: adapt at the non-Live seam).**
The global LiveReq pin stays (every Live example byte-identical). When a
LiveReq-pinned init (`name ∈ ecLiveInitFns`) feeds a *non-Live* backend
(`Tui.app` / `Tui.program` / `Cli.program`), the peephole wraps it:
`{ let __i = main_init; move |()| __i(sky_runtime::LiveReq::default()) }`. The
default `LiveReq` is harmless: a shared init across Live+Tui is necessarily
unit-shaped (Tui has no request), so it ignores the value. `LiveReq` gains
`#[derive(Default)]` (all fields `String` / `SkyDict` are `Default`).

> Alternative (fuller-principled, deferred): remove the global pin entirely and
> derive init's param from its Sky type, with `Live.app` wrapping a unit-init
> `move |_:LiveReq| init(())` at the call site. Broader blast radius (re-pins
> every Live example); tracked, not in this spec.

## Components touched (all in-boundary)

- `runtime-rust/src/sky_runtime/live/req.rs` — `#[derive(Default)]` on `LiveReq`
  (+ `SkyDict: Default` if missing).
- `src/Sky/Generate/Rust/Builder/Walker.hs` — `usesBackendApp` flag (extend the
  usage analysis: Tui / Webview / Cli.program as backend entries).
- `src/Sky/Generate/Rust/Builder/Emitter.hs` — `mainIsTask = usesBackendApp || not usesTaskRun`.
- `src/Sky/Generate/Rust/Builder/ModuleEmitter.hs` — `ret` condition mirrors it.
- `src/Sky/Generate/Rust/Builder/ExprEmitter.hs` — (a) drop `Task.run` on a
  backend-entry app-future uniformly; (b) `Tui.app`/`Tui.program`/`Cli.program`
  peepholes wrap a LiveReq-pinned init with the unit adapter.

## Verification

- **Target:** unmodified `examples/24-tui-kitchen-sink` builds + runs on `--target rust`.
- **Regression (hard gate):** every backend-app example re-verifies — Tui
  (`21`, `examples/rust/38`, `41`, `22`), Live (`examples/rust/28`, `29`, `30`,
  `33`, `40`), Webview (`examples/rust/39`), pure-CLI (`examples/rust/01`, `37`).
  Each builds; the Live ones still serve (40-live-ui HTML byte-identical; the
  S7 console endpoints still respond).
- `cargo test` + `clippy` green; runtime behaviour unchanged.

## Residual / risk

Tenet 2's "is the operand a backend entry" detection must peel through `|>`
*and* direct application, and recurse through `case`/`let` tails only as far as
the arm's own tail expression (not arbitrary nesting). The blast radius is the
entry shape of every backend-app main, so the regression sweep is the safety net.
