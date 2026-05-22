// Task combinators — generic over error type E.
use super::*;
use std::future::ready;

fn block_on<E, A>(future: SkyTask<E, A>) -> SkyResult<E, A>
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
            tasks.into_iter().map(|t| tokio::spawn(t)).collect();
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
