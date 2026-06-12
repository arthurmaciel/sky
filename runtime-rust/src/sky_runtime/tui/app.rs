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
use super::super::ui::Element;
use super::key::decode_key;
use super::layout::element_to_cells;
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

/// Current terminal size in cells; `(80, 24)` if it can't be queried (e.g. the
/// stream isn't a TTY). Re-queried each paint so the Element renderer reflows on
/// resize.
fn term_size() -> (usize, usize) {
    match crossterm::terminal::size() {
        Ok((w, h)) => (w.max(1) as usize, h.max(1) as usize),
        Err(_) => (80, 24),
    }
}

/// Shared terminal TEA driver. `render_frame` turns the current model into the
/// ANSI frame painted each tick — `tui_app` passes the user's `String` view
/// straight through; `tui_app_ui` renders the `Std.Ui` Element tree via
/// `render_element`. Everything else (raw-key reader, `SubManager` ticks,
/// `cli_run_cmd`, RAII teardown) is identical and lives here once.
#[allow(clippy::type_complexity)]
fn tui_run<Model, Msg, E, FInit, FUpdate, FSubs, FOnKey, FRender>(
    init: FInit,
    update: FUpdate,
    subscriptions: FSubs,
    on_key: FOnKey,
    render_frame: FRender,
) -> SkyTask<E, ()>
where
    E: Send + From<String> + 'static,
    Model: Clone + Send + 'static,
    Msg: Clone + Send + 'static,
    FInit: Fn(()) -> (Model, SkyCmd<Msg>) + Send + 'static,
    FUpdate: Fn(Msg, Model) -> (Model, SkyCmd<Msg>) + Send + 'static,
    FSubs: Fn(Model) -> SkySub<Msg> + Send + 'static,
    FOnKey: Fn(String, String) -> Msg + Send + 'static,
    FRender: Fn(&Model) -> String + Send + 'static,
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
        paint(&render_frame(&model));

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
            paint(&render_frame(&model));
        }
        submgr.stop_all();
        ok_res(())
    })
}

/// `Tui.program` — terminal TEA driver for a `view : Model -> String` (the raw
/// frame is painted verbatim). `on_key` receives the decoded key's
/// `(kind, value)` and yields a `Msg` (the codegen wraps the user's
/// `onKey : KeyEvent -> Msg` so the `{ kind, value }` record is built there).
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
    tui_run(init, update, subscriptions, on_key, move |m: &Model| view(m.clone()))
}

/// `Tui.app` — terminal TEA driver for a `view : Model -> Element msg`. The
/// `Std.Ui` Element is the SAME structured tree Sky.Live renders to HTML; here it
/// is laid out to an ANSI frame by walking the typed attributes directly
/// (`element_to_cells`), clipped to the live terminal. Same TEA quartet + key
/// dispatch as `tui_app`.
#[allow(clippy::type_complexity)]
pub fn tui_app_ui<Model, Msg, E, FInit, FUpdate, FView, FSubs, FOnKey>(
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
    FView: Fn(Model) -> Element<Msg> + Send + 'static,
    FSubs: Fn(Model) -> SkySub<Msg> + Send + 'static,
    FOnKey: Fn(String, String) -> Msg + Send + 'static,
{
    tui_run(init, update, subscriptions, on_key, move |m: &Model| {
        let (cols, rows) = term_size();
        element_to_cells(&view(m.clone()), cols, rows)
    })
}
