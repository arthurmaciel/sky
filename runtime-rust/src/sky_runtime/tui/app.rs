//! Sky.Tui — the `tui_app` TEA loop.
//!
//! Mirrors Go's `tuiProgramRun`: enter raw mode + alternate screen, then loop
//! { render `view(model)` (a String) cleared + printed; read a key from raw
//! stdin via `decode_key`; `on_key(kind, value)` → Msg; `update(msg, model)` }.
//! A Sky.Tui app quits by calling `System.exit` from `update` (the `Quit` Msg) —
//! so the loop runs until the process exits or stdin hits EOF.
//!
//! No panic vectors: a `TuiGuard` restores the TTY (disable raw mode, leave the
//! alt screen, show the cursor) on Drop — both on the normal exit/EOF path AND
//! on any panic unwinding through the loop. Raw-mode entry that fails returns an
//! `Err` rather than panicking; `TERM=dumb` / a non-tty stdin is refused.

use super::super::core::{ok_res, SkyResult, SkyTask};
use super::key::decode_key;
use std::io::{Read, Write};

const ALT_SCREEN_ON: &str = "\x1b[?1049h";
const ALT_SCREEN_OFF: &str = "\x1b[?1049l";
const CLEAR_HOME: &str = "\x1b[2J\x1b[H";
const HIDE_CURSOR: &str = "\x1b[?25l";
const SHOW_CURSOR: &str = "\x1b[?25h";

/// RAII terminal-state guard — restores cooked mode + cursor + main screen on
/// Drop (normal exit or panic unwind). All teardown ignores errors (best-effort,
/// never panics) since it runs on the way out.
struct TuiGuard;

impl TuiGuard {
    fn enter() -> Result<Self, String> {
        crossterm::terminal::enable_raw_mode().map_err(|e| format!("Tui: enable raw mode: {e}"))?;
        let mut out = std::io::stdout();
        let _ = out.write_all(ALT_SCREEN_ON.as_bytes());
        let _ = out.write_all(HIDE_CURSOR.as_bytes());
        let _ = out.flush();
        Ok(TuiGuard)
    }
}

impl Drop for TuiGuard {
    fn drop(&mut self) {
        let mut out = std::io::stdout();
        let _ = out.write_all(SHOW_CURSOR.as_bytes());
        let _ = out.write_all(ALT_SCREEN_OFF.as_bytes());
        let _ = out.flush();
        let _ = crossterm::terminal::disable_raw_mode();
    }
}

fn paint(frame: &str) {
    let mut out = std::io::stdout();
    let _ = out.write_all(CLEAR_HOME.as_bytes());
    let _ = out.write_all(frame.as_bytes());
    let _ = out.flush();
}

/// `Std.Tui.app` / `Tui.program` — the terminal TEA driver.
///
/// `view` returns the rendered frame as a `String`; `on_key` receives the
/// decoded key's `(kind, value)` and yields a `Msg` (the codegen wraps the
/// user's `onKey : KeyEvent -> Msg` so the `{ kind, value }` record is built
/// here-side). `update` returns the next model; its `Cmd` is currently driven
/// only for its model effect (subscriptions/Tick + async Cmd are a follow-up).
#[allow(clippy::type_complexity)]
pub fn tui_app<E, Model, Msg, FInit, FUpdate, FView, FOnKey>(
    init: FInit,
    update: FUpdate,
    view: FView,
    on_key: FOnKey,
) -> SkyTask<E, ()>
where
    E: Send + From<String> + 'static,
    Model: Send + 'static,
    Msg: Send + 'static,
    FInit: FnOnce() -> Model + Send + 'static,
    FUpdate: Fn(Msg, Model) -> Model + Send + 'static,
    FView: Fn(&Model) -> String + Send + 'static,
    FOnKey: Fn(String, String) -> Msg + Send + 'static,
{
    Box::pin(async move {
        if std::env::var("TERM").as_deref() == Ok("dumb") {
            return SkyResult::Err("Tui: TERM=dumb is not an interactive terminal".to_string().into());
        }
        let _guard = match TuiGuard::enter() {
            Ok(g) => g,
            Err(e) => return SkyResult::Err(e.into()),
        };

        let mut model = init();
        let mut buf = [0u8; 64];
        let mut stdin = std::io::stdin();
        loop {
            paint(&view(&model));
            let n = match stdin.read(&mut buf) {
                Ok(0) => break,                 // EOF
                Ok(n) => n,
                Err(_) => break,                // read error — leave (guard restores TTY)
            };
            // Decode every key in the chunk; dispatch each through update.
            let mut i = 0;
            while i < n {
                let (k, consumed) = decode_key(buf.get(i..n).unwrap_or(&[]));
                if consumed == 0 {
                    break;
                }
                i += consumed;
                let msg = on_key(k.kind, k.value);
                model = update(msg, model);
            }
        }
        ok_res(())
    })
}
