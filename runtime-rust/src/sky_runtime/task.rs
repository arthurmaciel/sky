// Task combinators — generic over error type E.
use super::*;
use std::future::ready;

fn block_on<E: Send + 'static, A: Send + 'static>(future: SkyTask<E, A>) -> SkyResult<E, A> {
    std::thread::spawn(move || tokio::runtime::Runtime::new().unwrap().block_on(future))
        .join().expect("Internal error: async task panicked")
}

pub fn task_succeed<E: Send + 'static, A: Send + 'static>(a: A) -> SkyTask<E, A> {
    Box::pin(ready(ok_res::<E, A>(a)))
}

pub fn task_map<E: Send + 'static, A: Send + 'static, B: Send + 'static>(
    f: impl FnOnce(A) -> B + Send + 'static,
) -> impl FnOnce(SkyTask<E, A>) -> SkyTask<E, B> + Send + 'static {
    |task| Box::pin(async move {
        match task.await {
            SkyResult::Ok(a) => ok_res(f(a)),
            SkyResult::Err(e) => SkyResult::Err(e),
        }
    })
}

pub fn task_and_then<E: Send + 'static, A: Send + 'static, B: Send + 'static>(
    f: impl FnOnce(A) -> SkyTask<E, B> + Send + 'static,
) -> impl FnOnce(SkyTask<E, A>) -> SkyTask<E, B> + Send + 'static {
    |task| Box::pin(async move {
        match task.await {
            SkyResult::Ok(a) => f(a).await,
            SkyResult::Err(e) => SkyResult::Err(e),
        }
    })
}

pub fn task_on_error<E: Send + 'static + Clone, A: Send + 'static>(
    f: impl FnOnce(E) -> SkyTask<E, A> + Send + 'static,
) -> impl FnOnce(SkyTask<E, A>) -> SkyTask<E, A> + Send + 'static {
    |task| Box::pin(async move {
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

pub fn task_run<E: Send + 'static, A: Send + 'static>(task: SkyTask<E, A>) -> SkyResult<E, A> {
    block_on(task)
}

pub fn task_parallel<E: Send + 'static + Send, A: Send + 'static>(tasks: Vec<SkyTask<E, A>>) -> SkyTask<E, Vec<A>> {
    Box::pin(async move {
        let handles: Vec<tokio::task::JoinHandle<SkyResult<E, A>>> =
            tasks.into_iter().map(|t| tokio::spawn(t)).collect();
        let mut out = Vec::with_capacity(handles.len());
        for h in handles {
            match h.await.expect("Internal error: parallel task panicked") {
                SkyResult::Ok(a) => out.push(a),
                SkyResult::Err(e) => return SkyResult::Err(e),
            }
        }
        ok_res(out)
    })
}
