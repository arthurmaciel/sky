// Task combinators — generic over error type E.
use super::*;
use std::future::ready;

pub fn block_on<E, A>(future: SkyTask<E, A>) -> SkyResult<E, A>
where E: From<String> + Send + 'static, A: Send + 'static {
    let rt = match tokio::runtime::Runtime::new() {
        Ok(r) => r,
        Err(e) => return SkyResult::Err(format!("tokio runtime init failed: {}", e).into()),
    };
    match std::thread::spawn(move || rt.block_on(future)).join() {
        Ok(r) => r,
        Err(_) => SkyResult::Err("async task panicked".to_string().into()),
    }
}

pub fn task_succeed<E: Send + 'static, A: Send + 'static>(a: A) -> SkyTask<E, A> {
    Box::pin(ready(ok_res::<E, A>(a)))
}

pub fn task_map<E, A, B>(f: impl FnOnce(A) -> B + Send + 'static, task: SkyTask<E, A>) -> SkyTask<E, B>
where E: Send + 'static, A: Send + 'static, B: Send + 'static {
    Box::pin(async move {
        match task.await {
            SkyResult::Ok(a) => ok_res(f(a)),
            SkyResult::Err(e) => SkyResult::Err(e),
        }
    })
}

pub fn task_and_then<E, A, B>(f: impl FnOnce(A) -> SkyTask<E, B> + Send + 'static, task: SkyTask<E, A>) -> SkyTask<E, B>
where E: Send + 'static, A: Send + 'static, B: Send + 'static {
    Box::pin(async move {
        match task.await {
            SkyResult::Ok(a) => f(a).await,
            SkyResult::Err(e) => SkyResult::Err(e),
        }
    })
}

pub fn task_map_error<E1, E2, A>(f: impl FnOnce(E1) -> E2 + Send + 'static, task: SkyTask<E1, A>) -> SkyTask<E2, A>
where E1: Send + 'static, E2: Send + 'static, A: Send + 'static {
    Box::pin(async move { match task.await {
        SkyResult::Ok(a) => ok_res(a),
        SkyResult::Err(e) => SkyResult::Err(f(e)),
    }})
}

pub fn task_lazy<E: Send + 'static, A: Send + 'static>(
    f: impl FnOnce() -> SkyTask<E, A> + Send + 'static,
) -> SkyTask<E, A> {
    Box::pin(async move { f().await })
}

pub fn task_from_result<E: Send + 'static, A: Send + 'static>(r: SkyResult<E, A>) -> SkyTask<E, A> {
    Box::pin(ready(r))
}

pub fn task_and_then_result<E, A, B>(f: impl FnOnce(A) -> SkyResult<E, B> + Send + 'static, task: SkyTask<E, A>) -> SkyTask<E, B>
where E: Send + 'static, A: Send + 'static, B: Send + 'static {
    Box::pin(async move { match task.await {
        SkyResult::Ok(a) => f(a),
        SkyResult::Err(e) => SkyResult::Err(e),
    }})
}

pub fn task_on_error<E, A>(f: impl FnOnce(E) -> SkyTask<E, A> + Send + 'static, task: SkyTask<E, A>) -> SkyTask<E, A>
where E: Send + 'static, A: Send + 'static {
    Box::pin(async move {
        match task.await {
            SkyResult::Ok(a) => ok_res(a),
            SkyResult::Err(e) => f(e).await,
        }
    })
}

pub fn task_fail<E: Send + 'static, A: Send + 'static>(e: E) -> SkyTask<E, A> {
    Box::pin(ready(SkyResult::Err(e)))
}

pub fn task_perform<E: Send + 'static, A: Send + 'static>(task: SkyTask<E, A>) -> SkyTask<E, ()> {
    Box::pin(async move { match task.await { SkyResult::Ok(_) => ok_res(()), SkyResult::Err(e) => SkyResult::Err(e) } })
}

pub fn task_sequence<E: Send + 'static, A: Send + 'static>(tasks: Vec<SkyTask<E, A>>) -> SkyTask<E, Vec<A>> {
    Box::pin(async move {
        let mut out = Vec::with_capacity(tasks.len());
        for t in tasks { match t.await { SkyResult::Ok(a) => out.push(a), SkyResult::Err(e) => return SkyResult::Err(e) } }
        ok_res(out)
    })
}

pub fn task_run<E: From<String> + Send + 'static, A: Send + 'static>(task: SkyTask<E, A>) -> SkyResult<E, A> {
    block_on(task)
}

pub fn task_parallel<E: From<String> + Send + 'static, A: Send + 'static>(tasks: Vec<SkyTask<E, A>>) -> SkyTask<E, Vec<A>> {
    Box::pin(async move {
        let handles: Vec<tokio::task::JoinHandle<SkyResult<E, A>>> =
            tasks.into_iter().map(tokio::spawn).collect();
        let mut out = Vec::with_capacity(handles.len());
        for h in handles {
            let result = match h.await {
                Ok(r) => r,
                Err(_) => SkyResult::Err("parallel task panicked".to_string().into()),
            };
            match result {
                SkyResult::Ok(a) => out.push(a),
                SkyResult::Err(e) => return SkyResult::Err(e),
            }
        }
        ok_res(out)
    })
}

// Task.retryWith : RetryPolicy e -> Task e a -> Task e a
//
// LIMITATION (run-once on target=rust). A faithful retry loop needs two things
// Rust can't give here: (1) re-running the task — a `SkyTask` is `Pin<Box<dyn
// Future>>`, a one-shot value consumed when awaited, not a re-runnable thunk;
// (2) reading the policy's `maxAttempts` / `shouldRetry` / delay fields — the
// `RetryPolicy` struct is generated per-project and opaque to this runtime
// crate, and Rust has no reflection (the Go backend reads it reflectively).
// So we run the task exactly once and return its result. This is correct for
// the common deterministic cases (a task that always succeeds → Ok on the first
// try; a task that always fails → the same Err every attempt would produce) and
// is what `examples/00-standard-libs` exercises. A transient-failure task will
// NOT be re-tried. A faithful implementation requires either a thunk-shaped
// `retryWith : RetryPolicy e -> (() -> Task e a) -> Task e a` (upstream) or
// codegen that passes the policy fields as primitives + wraps the task arg in a
// closure. Tracked in runtime-rust/README.md "Known limitations".
// Takes ONLY the task — the codegen peephole for `retryWith` drops the policy
// argument (see Builder.hs). Run-once ignores the policy entirely, and dropping
// it at the call site avoids emitting the policy builder's phantom error-type
// var (`RetryPolicy e` with `e` never used), which Rust can't infer (E0283).
pub fn task_retry_with<E, A>(task: SkyTask<E, A>) -> SkyTask<E, A> {
    task
}
