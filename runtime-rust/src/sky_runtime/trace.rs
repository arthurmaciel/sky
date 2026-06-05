// Std.Trace — opt-in app-level tracing spans / events / attributes.
//
// Mirrors the contract from the Go runtime: `span name task` runs `task` and
// returns its result UNCHANGED (the value/error flow through untouched), plus a
// span around it; `event` / `attr` mark a point / annotate the active span.
// Output is opt-in via SKY_TRACE (off by default → zero noise), but the wrapped
// task ALWAYS runs regardless, so spans never change program behaviour.
use super::*;
use std::time::Instant;

fn trace_enabled() -> bool {
    std::env::var("SKY_TRACE")
        .map(|v| !v.is_empty() && v != "0" && v != "false")
        .unwrap_or(false)
}

// Trace.span : String -> Task e a -> Task e a
pub fn trace_span<E: Send + 'static, A: Send + 'static>(name: String, task: SkyTask<E, A>) -> SkyTask<E, A> {
    Box::pin(async move {
        let on = trace_enabled();
        let start = Instant::now();
        if on {
            eprintln!("[trace] span start {}", name);
        }
        let result = task.await;
        if on {
            let outcome = match &result {
                SkyResult::Ok(_) => "ok",
                SkyResult::Err(_) => "err",
            };
            eprintln!("[trace] span end {} ({} ms, {})", name, start.elapsed().as_millis(), outcome);
        }
        result
    })
}

// Trace.event : String -> Task Error ()
pub fn trace_event<E: Send + 'static>(name: String) -> SkyTask<E, ()> {
    if trace_enabled() {
        eprintln!("[trace] event {}", name);
    }
    Box::pin(async move { ok_res(()) })
}

// Trace.attr : String -> String -> Task Error ()
// Keys are namespaced under `sky.trace.` to match the Go runtime.
pub fn trace_attr<E: Send + 'static>(key: String, value: String) -> SkyTask<E, ()> {
    if trace_enabled() {
        eprintln!("[trace] attr sky.trace.{} = {}", key, value);
    }
    Box::pin(async move { ok_res(()) })
}
