# Sky.Tui backend on Rust — design (S4)

**Date:** 2026-06-12
**Branch:** `feat/runtime-rust` (fork only). **Depends on:** S3 (Std.Ui→Html, DONE).
**Gate examples:** `21-tui-stopwatch`, `22-tui-stopwatch-ui`, `23-tui-todo` (+`24` once S4 lands).

## Goal

A TEA-shaped terminal backend mirroring `runtime-go/rt/tui.go` (+ `tui_safety.go`,
`tui_sanitize.go`): `Std.Tui.app cfg` renders the SAME `view : Model -> Element msg`
that Sky.Live / Sky.Webview render, but to ANSI cells instead of HTML — reusing
the S3 Std.Ui→Html lowering. Same `init`/`update`/`view`/`subscriptions` shape;
`onKey : KeyEvent -> msg`; a logical-pixel canvas (default 1280×720) mapped to
terminal cells.

## Constraints (load-bearing)

- **No runtime errors / no panic vectors.** Raw-mode entry/teardown is total;
  a panic or signal (SIGINT/SIGTERM/SIGHUP/SIGQUIT) MUST restore the TTY
  (cooked mode, cursor shown, alt-screen left) before exit — mirroring Go's
  `safeGo` + signal trap. No `unwrap`/`expect`/indexing in Sky-reachable paths
  (the `#![cfg_attr(not(test), deny(...))]` gate applies).
- **No `dyn Any`, concrete types.** The renderer is monomorphic over the cell
  grid; `Element msg` lowers via the existing S3 path (no erasure).
- **Boundary:** only `runtime-rust/`, `src/Sky/Generate/Rust/`, `examples/rust/`.

## Dependency decision

**`crossterm`** (pure-Rust, cross-platform: Linux/macOS/Windows; no C deps —
unlike `termion`). Gives: raw mode, alternate screen, cursor control, key/resize
events, ANSI styling. Width via **`unicode-width`** (mirrors Go's `uniseg`
display-width; full grapheme segmentation with `unicode-segmentation` only if a
gate example needs ZWJ/emoji width — start with `unicode-width`, widen if 23/24
require it). Both gated behind a new `tui` cargo feature; `Project.hs` declares
`pub mod tui` when `usesTui`.

## Architecture

```
Std.Tui.app cfg
  └─ tui_app<Model, Msg>(init, update, view, subscriptions, on_key)   [tui.rs]
       ├─ enter raw mode + alt screen (RAII TuiGuard: Drop restores TTY)
       ├─ install signal handler (SIGINT/TERM/HUP/QUIT → teardown → exit 128+n)
       ├─ loop:
       │    model, cmds := init() / update(msg, model)
       │    html := view(model)                         ← S3 Std.Ui→Html (reused)
       │    cells := render_cells(html, canvas, term_size)   [tui_render.rs]
       │    diff + flush changed cells to stdout (ANSI)       [tui_diff.rs]
       │    ev := crossterm::event::read()  → KeyEvent | Resize | Tick(sub)
       │    msg := on_key(ev) / subscription msg
       └─ on quit/EOF: TuiGuard::drop restores TTY
```

### Modules (`runtime-rust/src/sky_runtime/tui/`)

| File | Responsibility |
|---|---|
| `mod.rs` | `tui_app` entry (the TEA loop) + `TuiGuard` (RAII TTY restore) + signal trap |
| `render.rs` | `Html<Msg>` → a `Vec<Cell>` grid: walk the VNode tree, convert `Ui.padding`/`px`/layout to cells via `px_per_cell` (canvas→terminal), inline styles → ANSI attrs. Reuses the S3 `Html`/`render` types. |
| `cell.rs` | `Cell { ch: char, width: u8, fg, bg, attrs }`; `Grid` + `sanitize_rune` (strip control bytes, total) |
| `diff.rs` | previous-grid vs new-grid diff → minimal ANSI cursor-moves + writes |
| `key.rs` | crossterm `KeyEvent` → Sky `KeyEvent` record (key string + Ctrl/Shift/Alt) |

### Safety floor (mirror `tui_safety.go`)

- `TuiGuard` impls `Drop` → leave alt-screen, show cursor, disable raw mode —
  runs on normal exit AND panic unwind. (No `panic!`; but a kernel-level panic
  from elsewhere still unwinds through Drop.)
- Signal handler (via `signal-hook`, pure-Rust) sets an `AtomicBool`; the loop
  checks it, tears down, `std::process::exit(128 + signum)`.
- `TERM=dumb` / non-TTY stdin → refuse with a friendly `Err Error` (Go parity).
- `tuiMaxContentH = 50_000` hard cap; control-byte sanitisation on all user text.
- Unsupported Std.Ui attrs (gradients, fine letter-spacing, image fills) emit a
  deduped warn (honour `SKY_TUI_QUIET=1`), never panic.

### Codegen (`src/Sky/Generate/Rust/`)

- `Kernel.hs`: `("Std.Tui","app") → "tui_app"` (+ the kernel auto-snake path
  already covers most). Reuse the S3 Html lowering for `view`.
- `Walker.hs`: `usesTui` flag when `Std.Tui` is imported → pulls `tui` feature +
  the module + crossterm/unicode-width deps in `emitCargoToml`.
- `Project.hs`: `tuiMod = if usesTui then ["pub mod tui;"] else []`.
- Entry: `Tui.app cfg |> Task.run` — `tui_app` returns `SkyTask<()>` so the
  `block_on` entry (mainIsTask) drives it, same as Live/Server.
- `Element msg` → `Html msg` via the existing `Ui.layout` wrap (the view MUST
  wrap in `Ui.layout` — same convention as Live/Webview).

## Testing / gate

- Unit: `cell.rs` sanitisation + width; `diff.rs` minimal-write correctness;
  `render.rs` a known Element → expected cell grid (golden).
- Integration (the triple): build `21,22,23` on `--target rust` (sweep); run
  under a PTY harness (`scripts/verify-cli.sh`-style) feeding keystrokes and
  asserting the rendered frame; `SKY_REF_TARGET=go scripts/rust-equiv.sh` for
  frame equivalence where deterministic. `24-tui-kitchen-sink` becomes green
  (its S3 dep already met).
- A fork-local `examples/rust/` minimal Tui acceptance (counter + onKey) is the
  primary proof, since `21–24` are upstream (never edited).

## Plan (sub-tasks, each its own commit)

1. `cell.rs` + `key.rs` (+ unit tests) — pure, no terminal I/O. Committable alone.
2. `render.rs` — Html→Grid (golden test against a small Element). Committable.
3. `diff.rs` — grid diff → ANSI (unit test). Committable.
4. `mod.rs` — `tui_app` TEA loop + `TuiGuard` + signal trap (the integration).
5. Codegen wiring (Kernel/Walker/Project/emitCargoToml) + `tui` feature.
6. Fork-local acceptance example + verify.sh; build 21–23 on Rust; flip README.

## Out of scope (this slice)

- Mouse events, bracketed-paste beyond 1 MiB cap (Go caps; mirror), full
  grapheme/ZWJ width (start `unicode-width`, widen only if a gate example needs).
- Sky.Webview (S5) and Console (S7) — separate slices.
