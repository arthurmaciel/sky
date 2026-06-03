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

/// Sky `Sub msg`.
pub enum SkySub<M> {
    None,
    Batch(Vec<SkySub<M>>),
    Every { ms: i64, msg: M },
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

// ─── Sky.Cli — line-oriented TEA loop ──────────────────────────────────────

/// Cli.program { init, update, view, subscriptions, onLine } : Task Error ().
///
/// STEP 1: init -> view, then read stdin lines, dispatch onLine through update,
/// re-render view, until EOF. The returned Cmd/Sub are accepted but not yet
/// fired (Cmd.perform / Sub.every land in steps 2-3 once the msg channel +
/// subManager + tokio::select loop are in place).
pub fn cli_program<Model, Msg, E, FInit, FUpdate, FView, FSubs, FOnLine>(
    init: FInit,
    update: FUpdate,
    view: FView,
    _subscriptions: FSubs,
    on_line: FOnLine,
) -> SkyTask<E, ()>
where
    E: Send + 'static,
    Model: Clone + Send + 'static,
    Msg: Send + 'static,
    FInit: Fn(()) -> (Model, SkyCmd<Msg>) + Send + 'static,
    FUpdate: Fn(Msg, Model) -> (Model, SkyCmd<Msg>) + Send + 'static,
    FView: Fn(Model) -> String + Send + 'static,
    FSubs: Fn(Model) -> SkySub<Msg> + Send + 'static,
    FOnLine: Fn(String) -> Msg + Send + 'static,
{
    Box::pin(async move {
        use std::io::{self, BufRead, Write};
        let (mut model, _cmd) = init(());
        print!("{}", view(model.clone()));
        let _ = io::stdout().flush();
        let stdin = io::stdin();
        for line in stdin.lock().lines() {
            let line = match line {
                Ok(l) => l,
                Err(_) => break,
            };
            let msg = on_line(line);
            let (next, _cmd) = update(msg, model);
            model = next;
            print!("{}", view(model.clone()));
            let _ = io::stdout().flush();
        }
        println!();
        ok_res(())
    })
}
