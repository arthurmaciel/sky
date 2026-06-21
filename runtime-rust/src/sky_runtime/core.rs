#![allow(clippy::ptr_arg)]
// Sky Runtime — Core types (always included)
// Generic over E (error type).  Builder.hs emits `use sky_runtime::*;`
// and thin wrappers that instantiate E = SkyError.
//
// This module is the home for the core TYPES (SkyMaybe / SkyResult / SkyTask)
// and their combinators, plus the byte-sequence FFI coercion. The String and
// List kernels live in their named Sky-module homes — `string.rs` and
// `list.rs` — re-exported through `mod.rs`'s glob so call sites are unaffected.

use std::pin::Pin;
use std::future::Future;

// ===========================================
// Task type (generic over error type E)
// ===========================================
pub type SkyTask<E, A> = Pin<Box<dyn Future<Output = SkyResult<E, A>> + Send + 'static>>;

/// Construct Ok with generic error type.  Use `ok_res::<SkyError>` to
/// instantiate with the project's concrete error type.
pub fn ok_res<E, A>(a: A) -> SkyResult<E, A> { SkyResult::Ok(a) }

/// Construct an error value from a string.  Requires `E: From<String>`.
/// When E = SkyCoreErrorError, the generated code provides the impl.
pub fn str_err<E: From<String>>(s: &str) -> E { s.to_string().into() }

// ===========================================
// Disconnected-store placeholders (closure-Model `Default`)
// ===========================================
// A Sky.Live Model with function-typed fields (`Arc<dyn Fn(..) -> SkyTask<..>>`,
// e.g. the console's `store`) can't be serialized, so the codegen serde-skips
// those fields and reconstructs them via `Default` from these helpers. Each is a
// closure of the right arity that yields a STRUCTURED `Task` error (never a
// panic / unwrap) — a closure-Model whose session is restored gets a disconnected
// store and the app re-fetches. Closure-Models are memory-store-only (the memory
// store never serialises, so these are never instantiated at runtime there); the
// codegen makes persisting a closure-Model a hard compile error.
const DISCONNECTED_MSG: &str =
    "disconnected store: a closure-Model session was restored — closure-Models require [live] store = memory";

pub fn disconnected_fn0<T: Send + 'static, E: From<String> + Send + 'static>(
) -> std::sync::Arc<dyn Fn() -> SkyTask<E, T> + Send + Sync> {
    std::sync::Arc::new(|| -> SkyTask<E, T> {
        Box::pin(std::future::ready(SkyResult::Err(str_err::<E>(DISCONNECTED_MSG))))
    })
}
pub fn disconnected_fn1<A: 'static, T: Send + 'static, E: From<String> + Send + 'static>(
) -> std::sync::Arc<dyn Fn(A) -> SkyTask<E, T> + Send + Sync> {
    std::sync::Arc::new(|_a| -> SkyTask<E, T> {
        Box::pin(std::future::ready(SkyResult::Err(str_err::<E>(DISCONNECTED_MSG))))
    })
}
pub fn disconnected_fn2<A1: 'static, A2: 'static, T: Send + 'static, E: From<String> + Send + 'static>(
) -> std::sync::Arc<dyn Fn(A1, A2) -> SkyTask<E, T> + Send + Sync> {
    std::sync::Arc::new(|_a1, _a2| -> SkyTask<E, T> {
        Box::pin(std::future::ready(SkyResult::Err(str_err::<E>(DISCONNECTED_MSG))))
    })
}
pub fn disconnected_fn3<A1: 'static, A2: 'static, A3: 'static, T: Send + 'static, E: From<String> + Send + 'static>(
) -> std::sync::Arc<dyn Fn(A1, A2, A3) -> SkyTask<E, T> + Send + Sync> {
    std::sync::Arc::new(|_a1, _a2, _a3| -> SkyTask<E, T> {
        Box::pin(std::future::ready(SkyResult::Err(str_err::<E>(DISCONNECTED_MSG))))
    })
}

// ===========================================
// Byte-sequence FFI coercion (Sky List Int <-> Rust bytes)
// ===========================================

/// Sky `List Int` (Vec<i64>) -> owned bytes. Each element is narrowed `as u8`,
/// mirroring the numeric param narrowing the FFI codegen already emits.
/// Used for `&[u8]` and `Vec<u8>` parameters.
pub fn to_u8_vec(xs: &[i64]) -> Vec<u8> {
    xs.iter().map(|&x| x as u8).collect()
}

/// Owned/borrowed bytes -> Sky `List Int` (Vec<i64>). Used for byte results.
pub fn from_u8_slice(bs: &[u8]) -> Vec<i64> {
    bs.iter().map(|&b| b as i64).collect()
}

/// Sky `List Int` -> `[u8; N]`. A length mismatch returns `Err` and never
/// panics (honours "no runtime panic from well-typed Sky code"). Used for
/// `[u8; N]` / `&[u8; N]` parameters; the generated wrapper instantiates
/// `E = SkyError` and the concrete `N`.
pub fn to_u8_array<E: From<String>, const N: usize>(xs: &[i64]) -> SkyResult<E, [u8; N]> {
    if xs.len() != N {
        return SkyResult::Err(format!("expected {} bytes, got {}", N, xs.len()).into());
    }
    let mut a = [0u8; N];
    // len == N checked above; zip is total (no indexing).
    for (slot, &x) in a.iter_mut().zip(xs.iter()) {
        *slot = x as u8;
    }
    ok_res(a)
}

/// Sky `List T` (Rust `&[T]`) -> fixed-size `[T; N]` with length check.
/// Mirrors `to_u8_array`'s never-panic discipline: returns `SkyResult::Err`
/// with a clear message on length mismatch. T: Clone is sufficient — the
/// elements are cloned out into the array.
pub fn to_array<E: From<String>, T: Clone, const N: usize>(xs: &[T]) -> SkyResult<E, [T; N]> {
    if xs.len() != N {
        return SkyResult::Err(format!("expected array of length {}, got {}", N, xs.len()).into());
    }
    let v: Vec<T> = xs.to_vec();
    match v.try_into() {
        Ok(a) => ok_res(a),
        Err(_) => SkyResult::Err("array length conversion failed".to_string().into()),
    }
}

// ===========================================
// Maybe
// ===========================================
// serde derives are CONDITIONAL (the macro emits `impl<T: Serialize> … for
// SkyMaybe<T>`), so a `SkyMaybe<NonSerde>` is unaffected — but a Sky.Live model
// carrying a `Maybe X` field (X serde-able) now serialises for the session
// store. Without this, any model with a `Maybe`/`Result` field failed E0277.
#[derive(Clone, Debug, PartialEq, serde::Serialize, serde::Deserialize)]
pub enum SkyMaybe<T> {
    Nothing,
    Just(T),
}

impl<T> SkyMaybe<T> {
    pub fn with_default(self, def: T) -> T {
        match self { SkyMaybe::Just(v) => v, SkyMaybe::Nothing => def }
    }
    pub fn is_just(&self) -> bool { matches!(self, SkyMaybe::Just(_)) }
    pub fn is_nothing(&self) -> bool { matches!(self, SkyMaybe::Nothing) }
}

pub fn sky_maybe_map<T, U>(m: SkyMaybe<T>, f: impl FnOnce(T) -> U) -> SkyMaybe<U> {
    match m { SkyMaybe::Just(v) => SkyMaybe::Just(f(v)), SkyMaybe::Nothing => SkyMaybe::Nothing }
}

pub fn sky_maybe_and_then<T, U>(m: SkyMaybe<T>, f: impl FnOnce(T) -> SkyMaybe<U>) -> SkyMaybe<U> {
    match m { SkyMaybe::Just(v) => f(v), SkyMaybe::Nothing => SkyMaybe::Nothing }
}

/// `SkyMaybe<T>` -> `Option<T>` for FFI parameter coercion: a Sky `Maybe X`
/// argument reaches the wrapper as `SkyMaybe<X>` but the underlying crate fn
/// takes `Option<…>`. The generated wrapper calls this then adapts the inner
/// value (`.as_deref()` for `Option<&str>`, `.map(|x| x as u16)` for narrowed
/// numerics, identity otherwise). Total: `Just -> Some`, `Nothing -> None`.
pub fn sky_maybe_to_option<T>(m: SkyMaybe<T>) -> Option<T> {
    match m {
        SkyMaybe::Just(v) => Some(v),
        SkyMaybe::Nothing => None,
    }
}

// ===========================================
// Result (generic over error type E)
// ===========================================
#[derive(Clone, Debug, PartialEq, serde::Serialize, serde::Deserialize)]
pub enum SkyResult<E, A> {
    Ok(A),
    Err(E),
}

impl<E, A> SkyResult<E, A> {
    pub fn is_ok(&self) -> bool { matches!(self, SkyResult::Ok(_)) }
    pub fn is_err(&self) -> bool { matches!(self, SkyResult::Err(_)) }
    pub fn with_default(self, def: A) -> A {
        match self { SkyResult::Ok(v) => v, SkyResult::Err(_) => def }
    }
}

pub fn sky_result_map<E, A, B>(r: SkyResult<E, A>, f: impl FnOnce(A) -> B) -> SkyResult<E, B> {
    match r { SkyResult::Ok(v) => SkyResult::Ok(f(v)), SkyResult::Err(e) => SkyResult::Err(e) }
}

pub fn sky_result_and_then<E, A, B>(r: SkyResult<E, A>, f: impl FnOnce(A) -> SkyResult<E, B>) -> SkyResult<E, B> {
    match r { SkyResult::Ok(v) => f(v), SkyResult::Err(e) => SkyResult::Err(e) }
}

// ===========================================
// Maybe / Result default + traverse helpers
// ===========================================
pub fn result_with_default<E, A>(def: A, r: SkyResult<E, A>) -> A {
    match r { SkyResult::Ok(v) => v, SkyResult::Err(_) => def }
}

pub fn maybe_with_default<A>(def: A, m: SkyMaybe<A>) -> A {
    match m { SkyMaybe::Just(v) => v, SkyMaybe::Nothing => def }
}

pub fn result_traverse<T0: Clone, T1: Clone, E>(f: impl Fn(T0) -> SkyResult<E, T1>, items: Vec<T0>) -> SkyResult<E, Vec<T1>> {
    let mut out = Vec::with_capacity(items.len());
    for item in items { match f(item) { SkyResult::Ok(v) => out.push(v), SkyResult::Err(e) => return SkyResult::Err(e) } }
    SkyResult::Ok(out)
}

// ===========================================
// Synchronous-panic gate (Go parity: rt.LogPanicAndExit)
// ===========================================
// The generated `fn main()` installs this FIRST so any panic that escapes the
// synchronous Sky path — a div-by-zero (`a / 0`), an index-out-of-range, an
// arithmetic overflow, etc. — is CLASSIFIED into a Sky error kind, logged
// structurally with a short correlation id, and the process exits 1 — instead of
// dumping a raw Rust backtrace. Mirrors Go's `defer rt.LogPanicAndExit()` on
// every emitted `func main()` (CLAUDE.md "Synchronous-panic gate"). The hook is
// total (no unwrap/index/panic of its own) and honours `SKY_LOG_FORMAT=json`.

/// Map a Rust panic message to a Sky error classification (Go's panic-class
/// taxonomy, restricted to the kinds reachable from well-typed Sky on the typed
/// Rust backend — TypeMismatch/CoerceFailure are Go-runtime-only).
fn classify_panic(msg: &str) -> &'static str {
    let m = msg.to_ascii_lowercase();
    if m.contains("divide by zero") || m.contains("divisor of zero") {
        "DivisionByZero"
    } else if m.contains("index out of bounds") || m.contains("out of range") {
        "IndexOutOfRange"
    } else if m.contains("overflow") {
        "ArithmeticOverflow"
    } else {
        "Unexpected"
    }
}

/// 8 hex chars (4 bytes) of correlation id — derives from the wall-clock
/// sub-second component so two panics in one process don't collide. Total: a
/// clock read failure falls back to `0`.
fn short_err_id() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let n = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.subsec_nanos())
        .unwrap_or(0);
    format!("{n:08x}")
}

/// Install the classifying panic hook. Idempotent in effect (re-installing just
/// replaces the hook). Called at the top of generated `fn main()`.
pub fn install_panic_classifier() {
    std::panic::set_hook(Box::new(|info| {
        let msg = if let Some(s) = info.payload().downcast_ref::<&str>() {
            (*s).to_string()
        } else if let Some(s) = info.payload().downcast_ref::<String>() {
            s.clone()
        } else {
            "panic".to_string()
        };
        let kind = classify_panic(&msg);
        let err_id = short_err_id();
        let json = std::env::var("SKY_LOG_FORMAT")
            .map(|v| v.eq_ignore_ascii_case("json"))
            .unwrap_or(false);
        if json {
            eprintln!(
                "{{\"level\":\"error\",\"kind\":\"{}\",\"errId\":\"{}\",\"message\":\"{}\"}}",
                kind,
                err_id,
                crate::sky_runtime::telemetry::json_escape(&msg)
            );
        } else {
            eprintln!("[error] {kind} (ref {err_id}): {msg}");
        }
        std::process::exit(1);
    }));
}
