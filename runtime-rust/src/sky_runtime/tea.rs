//! Sky TEA runtime core (Sub-E) — Cmd/Sub + the Sky.Cli line-oriented loop.
//!
//! Cmd/Sub are generic over the message type M (NOT `any`): the intermediate
//! value `a` in `Cmd.perform` is erased inside a boxed M-producing future, but M
//! stays concrete. Step 1 (this file) ships the types, the simple kernels, and a
//! blocking Cli.program loop (stdin -> onLine -> update -> view). Sub.every
//! tickers + async Cmd.perform delivery land in steps 2-3 (a subManager + an
//! mpsc msg channel + tokio::select over stdin and the channel).

use super::*;
use std::future::Future;
use std::pin::Pin;

/// Sky `Cmd msg`. Perform carries a boxed thunk producing the message (the
/// task's success/error type is erased inside; M is concrete).
pub enum SkyCmd<M> {
    None,
    Batch(Vec<SkyCmd<M>>),
    Perform(Box<dyn FnOnce() -> Pin<Box<dyn Future<Output = M> + Send>> + Send>),
}

/// A custom subscription event source: given an `emit` callback, spawn a task
/// that pushes messages into the loop, returning its JoinHandle (aborted on
/// re-subscribe). Keeps SkySub decoupled from source-specific runtimes (e.g. the
/// WebSocket client builds one of these for `onMessage`).
pub type SubSpawn<M> =
    Box<dyn FnOnce(std::sync::Arc<dyn Fn(M) + Send + Sync>) -> tokio::task::JoinHandle<()> + Send>;

/// Sky `Sub msg`.
pub enum SkySub<M> {
    None,
    Batch(Vec<SkySub<M>>),
    Every { ms: i64, msg: M },
    Source(SubSpawn<M>),
}

// ─── Cmd kernels ──────────────────────────────────────────────────────────

pub fn cmd_none<M>() -> SkyCmd<M> { SkyCmd::None }
pub fn cmd_batch<M>(list: Vec<SkyCmd<M>>) -> SkyCmd<M> { SkyCmd::Batch(list) }

/// Cmd.perform : Task err a -> (Result err a -> msg) -> Cmd msg.
/// Composes the task and the toMsg decoder (which receives the SkyResult) into a
/// single message-producing thunk fired by the run loop.
pub fn cmd_perform<E, A, M, F>(task: SkyTask<E, A>, to_msg: F) -> SkyCmd<M>
where
    E: Send + 'static,
    A: Send + 'static,
    M: Send + 'static,
    F: FnOnce(SkyResult<E, A>) -> M + Send + 'static,
{
    SkyCmd::Perform(Box::new(move || Box::pin(async move { to_msg(task.await) })))
}

// ─── Sub kernels ──────────────────────────────────────────────────────────

pub fn sub_none<M>() -> SkySub<M> { SkySub::None }
pub fn sub_batch<M>(list: Vec<SkySub<M>>) -> SkySub<M> { SkySub::Batch(list) }

/// Sub.every : Int -> msg -> Sub msg — dispatch `msg` every `ms` milliseconds.
pub fn sub_every<M>(ms: i64, msg: M) -> SkySub<M> { SkySub::Every { ms, msg } }

/// Sky.Core.Http.Stream.chunks → `Sub_subscribeStream`. The Sub-tier chunk
/// driver dispatches `ChunkEvent` Msgs into a TEA update loop — its real home is
/// Sky.Live, which is not yet ported to the Rust backend. This stub returns an
/// empty Sub so the module surface compiles; the synchronous
/// `Sky.Core.Http.Stream.forEachChunk` covers the self-contained relay use case
/// (see http_stream.rs). `C` is the ChunkEvent type (a generated Sky enum the
/// runtime can't name); it's inferred from `to_msg` and never constructed here.
pub fn sub_subscribe_stream<C, M, F>(_id: i64, _to_msg: F) -> SkySub<M>
where
    F: Fn(C) -> M,
{
    SkySub::None
}

// ─── TEA event loop plumbing (Sub.every tickers + Cmd firing) ───────────────

/// Internal loop event: a raw stdin line, an already-built Msg (from a ticker or
/// a Cmd.perform result), or EOF.
enum CliEvent<M> {
    Line(String),
    Msg(M),
    Eof,
}

/// Tracks the goroutine-equivalent ticker tasks spawned for the active
/// `Sub.every` subscriptions. `update` stops all + respawns from the new Sub
/// (mirrors tea_subs.go: one program, one model, re-evaluated each tick).
struct SubManager<M> {
    tx: tokio::sync::mpsc::UnboundedSender<CliEvent<M>>,
    handles: Vec<tokio::task::JoinHandle<()>>,
}

impl<M: Clone + Send + 'static> SubManager<M> {
    fn new(tx: tokio::sync::mpsc::UnboundedSender<CliEvent<M>>) -> Self {
        SubManager { tx, handles: Vec::new() }
    }
    fn stop_all(&mut self) {
        for h in self.handles.drain(..) {
            h.abort();
        }
    }
    fn update(&mut self, sub: SkySub<M>) {
        self.stop_all();
        self.spawn(sub);
    }
    fn spawn(&mut self, sub: SkySub<M>) {
        match sub {
            SkySub::None => {}
            SkySub::Batch(items) => {
                for it in items {
                    self.spawn(it);
                }
            }
            SkySub::Every { ms, msg } => {
                if ms <= 0 {
                    return;
                }
                let tx = self.tx.clone();
                let dur = std::time::Duration::from_millis(ms as u64);
                // First tick after `ms` (sleep-loop, matching Go's time.After).
                let h = tokio::spawn(async move {
                    loop {
                        tokio::time::sleep(dur).await;
                        if tx.send(CliEvent::Msg(msg.clone())).is_err() {
                            break;
                        }
                    }
                });
                self.handles.push(h);
            }
            SkySub::Source(spawn) => {
                // Hand the source an emit callback that funnels Msgs into the loop.
                let tx = self.tx.clone();
                let emit: std::sync::Arc<dyn Fn(M) + Send + Sync> =
                    std::sync::Arc::new(move |m| { let _ = tx.send(CliEvent::Msg(m)); });
                self.handles.push(spawn(emit));
            }
        }
    }
}

/// Fire a Cmd: None/Batch recurse; Perform spawns the composed task→toMsg thunk
/// and pushes the resulting Msg back into the loop channel.
fn cli_run_cmd<M: Send + 'static>(cmd: SkyCmd<M>, tx: &tokio::sync::mpsc::UnboundedSender<CliEvent<M>>) {
    match cmd {
        SkyCmd::None => {}
        SkyCmd::Batch(items) => {
            for c in items {
                cli_run_cmd(c, tx);
            }
        }
        SkyCmd::Perform(thunk) => {
            let tx = tx.clone();
            tokio::spawn(async move {
                let msg = thunk().await;
                let _ = tx.send(CliEvent::Msg(msg));
            });
        }
    }
}

// ─── Sky.Cli — line-oriented TEA loop ──────────────────────────────────────

/// Cli.program { init, update, view, subscriptions, onLine } : Task Error ().
///
/// init -> fire cmd -> subs -> view; then fold each event (stdin line via
/// onLine, ticker/Cmd.perform Msg) through update -> re-fire cmd -> re-subs ->
/// view, until stdin EOF. Stdin is read on a blocking task; tickers + perform
/// results merge into the same single-threaded update sequence via one channel.
pub fn cli_program<Model, Msg, E, FInit, FUpdate, FView, FSubs, FOnLine>(
    init: FInit,
    update: FUpdate,
    view: FView,
    subscriptions: FSubs,
    on_line: FOnLine,
) -> SkyTask<E, ()>
where
    E: Send + 'static,
    Model: Clone + Send + 'static,
    Msg: Clone + Send + 'static,
    FInit: Fn(()) -> (Model, SkyCmd<Msg>) + Send + 'static,
    FUpdate: Fn(Msg, Model) -> (Model, SkyCmd<Msg>) + Send + 'static,
    FView: Fn(Model) -> String + Send + 'static,
    FSubs: Fn(Model) -> SkySub<Msg> + Send + 'static,
    FOnLine: Fn(String) -> Msg + Send + 'static,
{
    Box::pin(async move {
        use std::io::Write;
        let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<CliEvent<Msg>>();

        // Blocking stdin reader → raw Line events, then Eof. onLine is applied in
        // the main task (keeps it off the blocking thread / out of Send bounds).
        let line_tx = tx.clone();
        std::thread::spawn(move || {
            use std::io::BufRead;
            let stdin = std::io::stdin();
            for line in stdin.lock().lines() {
                match line {
                    Ok(l) => { if line_tx.send(CliEvent::Line(l)).is_err() { return; } }
                    Err(_) => break,
                }
            }
            let _ = line_tx.send(CliEvent::Eof);
        });

        let (mut model, cmd0) = init(());
        cli_run_cmd(cmd0, &tx);
        let mut submgr = SubManager::new(tx.clone());
        submgr.update(subscriptions(model.clone()));
        // Inline render (a closure borrowing `view` would make the future non-Send).
        print!("{}", view(model.clone()));
        let _ = std::io::stdout().flush();

        while let Some(ev) = rx.recv().await {
            let msg = match ev {
                CliEvent::Line(l) => on_line(l),
                CliEvent::Msg(m) => m,
                CliEvent::Eof => break,
            };
            let (next, cmd) = update(msg, model);
            model = next;
            cli_run_cmd(cmd, &tx);
            submgr.update(subscriptions(model.clone()));
            print!("{}", view(model.clone()));
            let _ = std::io::stdout().flush();
        }
        submgr.stop_all();
        println!();
        ok_res(())
    })
}
