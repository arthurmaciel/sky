//! Sky.Tui — the `tui_app` TEA loop.
//!
//! Mirrors `cli_program` (tea.rs) exactly — same `CliEvent` channel, `SubManager`
//! (so `Sub.every` → Tick works) and `cli_run_cmd` (so `Cmd.perform` works) — but
//! reads RAW key bytes (raw mode + `decode_key`) instead of stdin lines, and
//! paints into the alternate screen. A Sky.Tui app quits by calling `System.exit`
//! from `update` (the `Quit` Msg) or by stdin EOF.
//!
//! No panic vectors: a `TuiGuard` restores the TTY (cooked mode, cursor, main
//! screen) on Drop — normal exit AND panic unwind — so no path leaves the
//! terminal wedged. Raw-mode failure returns `Err`; `TERM=dumb` is refused.

use super::super::core::{ok_res, SkyResult, SkyTask};
use super::super::tea::{cli_run_cmd, CliEvent, SkyCmd, SkySub, SubManager};
use super::key::decode_key;
use std::io::{Read, Write};

const ALT_SCREEN_ON: &str = "\x1b[?1049h";
const ALT_SCREEN_OFF: &str = "\x1b[?1049l";
const CLEAR_HOME: &str = "\x1b[2J\x1b[H";
const HIDE_CURSOR: &str = "\x1b[?25l";
const SHOW_CURSOR: &str = "\x1b[?25h";

/// RAII terminal-state guard — restores cooked mode + cursor + main screen on
/// Drop (normal exit or panic unwind). Best-effort, never panics.
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
/// `view` returns the rendered frame as a `String`; `on_key` receives the decoded
/// key's `(kind, value)` and yields a `Msg` (the codegen wraps the user's
/// `onKey : KeyEvent -> Msg` so the `{ kind, value }` record is built there-side).
/// `init`/`update` return `(Model, Cmd Msg)` and `subscriptions` a `Sub Msg` —
/// driven via the shared `SubManager` (Tick) + `cli_run_cmd` (Cmd).
#[allow(clippy::type_complexity)]
pub fn tui_app<Model, Msg, E, FInit, FUpdate, FView, FSubs, FOnKey>(
    init: FInit,
    update: FUpdate,
    view: FView,
    subscriptions: FSubs,
    on_key: FOnKey,
) -> SkyTask<E, ()>
where
    E: Send + From<String> + 'static,
    Model: Clone + Send + 'static,
    Msg: Clone + Send + 'static,
    FInit: Fn(()) -> (Model, SkyCmd<Msg>) + Send + 'static,
    FUpdate: Fn(Msg, Model) -> (Model, SkyCmd<Msg>) + Send + 'static,
    FView: Fn(Model) -> String + Send + 'static,
    FSubs: Fn(Model) -> SkySub<Msg> + Send + 'static,
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

        let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<CliEvent<Msg>>();

        // Blocking raw-key reader → Key(kind, value) events, then Eof. on_key is
        // applied in the main task (keeps it off the blocking thread).
        let key_tx = tx.clone();
        std::thread::spawn(move || {
            let mut buf = [0u8; 64];
            let mut stdin = std::io::stdin();
            loop {
                let n = match stdin.read(&mut buf) {
                    Ok(0) | Err(_) => break,
                    Ok(n) => n,
                };
                let mut i = 0;
                while i < n {
                    let (k, consumed) = decode_key(buf.get(i..n).unwrap_or(&[]));
                    if consumed == 0 {
                        break;
                    }
                    i += consumed;
                    if key_tx.send(CliEvent::Key(k.kind, k.value)).is_err() {
                        return;
                    }
                }
            }
            let _ = key_tx.send(CliEvent::Eof);
        });

        let (mut model, cmd0) = init(());
        cli_run_cmd(cmd0, &tx);
        let mut submgr = SubManager::new(tx.clone());
        submgr.update(subscriptions(model.clone()));
        paint(&view(model.clone()));

        while let Some(ev) = rx.recv().await {
            let msg = match ev {
                CliEvent::Key(kind, value) => on_key(kind, value),
                CliEvent::Msg(m) => m,
                CliEvent::Line(_) => continue, // Tui has no line input
                CliEvent::Eof => break,
            };
            let (next, cmd) = update(msg, model);
            model = next;
            cli_run_cmd(cmd, &tx);
            submgr.update(subscriptions(model.clone()));
            paint(&view(model.clone()));
        }
        submgr.stop_all();
        ok_res(())
    })
}
