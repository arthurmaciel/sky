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

/// Convert a foreign async error into a SkyError (= String).
///
/// Used by the fallible-async FFI wrapper bodies to flatten a foreign
/// `Result<T, E>` Err arm into a Sky-compatible error string:
///
///   `Ok(Err(e)) => SkyResult::Err(sky_error_from_foreign(e))`
///
/// C5: `tokio::task::spawn(...).await` already catches panics via JoinError;
/// this fn handles the non-panic `Err(e)` arm.  Any `Debug`-able foreign
/// error type is accepted — `Debug` is universal, safe, and always available.
/// Convert a foreign async error into the project's error type.
///
/// Same generic `E: From<String>` contract as `str_err` — the project
/// provides `impl From<String> for SkyCoreErrorError` so both arms of
/// the fallible-async match resolve to the same `SkyResult<E, A>`.
///
/// Requires `Debug` on the foreign error (universally available).
pub fn sky_error_from_foreign<ForeignE: std::fmt::Debug, E: From<String>>(e: ForeignE) -> E {
    format!("{e:?}").into()
}

/// Bake a config-derived default for an env var: set `key=val` ONLY when the
/// var is unset, so shell env / `.env` still win (precedence: process env >
/// baked default). Go parity: the generated `init()`'s `rt.SetPortDefault` +
/// `tomlSkyEnv` family. The generated `main()` calls this BEFORE the async
/// runtime / any thread starts, so the `set_var` is race-free (the one window
/// where mutating the process environment is sound).
pub fn set_env_default(key: &str, val: &str) {
    if std::env::var_os(key).is_none() {
        std::env::set_var(key, val);
    }
}

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
// The serde derive is UNCONDITIONAL but its impls are generic-BOUND (the macro
// emits `impl<T: Serialize> … for SkyMaybe<T>`), so a `SkyMaybe<NonSerde>` is
// unaffected — yet a Sky.Live model carrying a `Maybe X` field (X serde-able)
// serialises for the session store. Without this, any model with a `Maybe`/
// `Result` field failed E0277. NOTE: `serde` is therefore a NON-OPTIONAL dep in
// the runtime crate (core.rs is always compiled) — do NOT re-add `optional = true`.
//
// `Deserialize` is NOT derived — we use a manual impl (see below) that accepts
// BOTH the externally-tagged repr (session-store round-trip) AND a bare value
// (form data: `note=hello` → `Just("hello")`). `Serialize` stays derived (tagged)
// so the session store writes `{"Just":"x"}` / `"Nothing"` and the manual
// `Deserialize` reads those back correctly (#42).
#[derive(Clone, Debug, PartialEq, serde::Serialize)]
pub enum SkyMaybe<T> {
    Nothing,
    Just(T),
}

// Custom `Deserialize` for `SkyMaybe<T>` (#42).
//
// Accepted input shapes:
//   - Externally-tagged map `{"Just": v}` → `Just(T::deserialize(v))`.
//     This is what `Serialize` emits → session-store round-trip is preserved.
//   - Externally-tagged string `"Nothing"` (unit variant) → `Nothing`.
//   - Bare non-null value `v` → `Just(T::deserialize(v))`.
//     This is the form-data case: `note=hello` → the urlencoded deserialiser
//     presents a bare string, which the tagged derive rejected (#42 bug).
//   - `null` / absent (handled by `Default` + `#[serde(default)]` at the struct
//     field level) → `Nothing`.
//
// The "Nothing" string-variant sentinel is accepted for backward compat with
// any stored sessions, even though the serialiser now no longer writes bare
// `"Nothing"` (it stays externally-tagged as the unit variant string).
//
// Edge case: a bare string value of exactly `"Nothing"` in form data decodes as
// `Nothing`, not `Just("Nothing")`. This is the same trade-off as the tagged
// derive and is acceptable — form fields named `note` with the literal value
// "Nothing" are pathological; real user notes should not hit this.
impl<'de, T: serde::de::Deserialize<'de>> serde::de::Deserialize<'de> for SkyMaybe<T> {
    fn deserialize<D: serde::de::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        d.deserialize_any(SkyMaybeVisitor(std::marker::PhantomData))
    }
}

struct SkyMaybeVisitor<T>(std::marker::PhantomData<T>);

impl<'de, T: serde::de::Deserialize<'de>> serde::de::Visitor<'de> for SkyMaybeVisitor<T> {
    type Value = SkyMaybe<T>;

    fn expecting(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("a SkyMaybe value: `{\"Just\": v}`, `\"Nothing\"`, or a bare value")
    }

    // --- bare unit / null → Nothing ---
    fn visit_unit<E: serde::de::Error>(self) -> Result<SkyMaybe<T>, E> {
        Ok(SkyMaybe::Nothing)
    }
    fn visit_none<E: serde::de::Error>(self) -> Result<SkyMaybe<T>, E> {
        Ok(SkyMaybe::Nothing)
    }
    fn visit_some<D: serde::de::Deserializer<'de>>(self, d: D) -> Result<SkyMaybe<T>, D::Error> {
        T::deserialize(d).map(SkyMaybe::Just)
    }

    // --- bare string → "Nothing" sentinel OR Just(T) ---
    fn visit_str<E: serde::de::Error>(self, v: &str) -> Result<SkyMaybe<T>, E> {
        if v == "Nothing" {
            return Ok(SkyMaybe::Nothing);
        }
        // Bare non-sentinel string: deserialize T from it.
        T::deserialize(serde::de::value::StrDeserializer::new(v)).map(SkyMaybe::Just)
    }

    fn visit_string<E: serde::de::Error>(self, v: String) -> Result<SkyMaybe<T>, E> {
        if v == "Nothing" {
            return Ok(SkyMaybe::Nothing);
        }
        T::deserialize(serde::de::value::StringDeserializer::new(v)).map(SkyMaybe::Just)
    }

    // --- externally-tagged map `{"Just": v}` → Just(T) ---
    fn visit_map<A: serde::de::MapAccess<'de>>(
        self,
        mut map: A,
    ) -> Result<SkyMaybe<T>, A::Error> {
        use serde::de::Error as _;
        let key: Option<String> = map.next_key()?;
        match key.as_deref() {
            Some("Just") => {
                let val: T = map.next_value()?;
                // Consume any remaining entries (defensive; tagged enums have one).
                while map.next_key::<serde::de::IgnoredAny>()?.is_some() {
                    let _: serde::de::IgnoredAny = map.next_value()?;
                }
                Ok(SkyMaybe::Just(val))
            }
            Some("Nothing") => {
                // Unit variant as a map key (edge case from some serialisers).
                while map.next_key::<serde::de::IgnoredAny>()?.is_some() {
                    let _: serde::de::IgnoredAny = map.next_value()?;
                }
                Ok(SkyMaybe::Nothing)
            }
            Some(other) => Err(A::Error::unknown_variant(other, &["Just", "Nothing"])),
            None => Err(A::Error::missing_field("Just")),
        }
    }

    // --- bare numerics / bool → Just(T) ---
    fn visit_bool<E: serde::de::Error>(self, v: bool) -> Result<SkyMaybe<T>, E> {
        T::deserialize(serde::de::value::BoolDeserializer::new(v)).map(SkyMaybe::Just)
    }
    fn visit_i64<E: serde::de::Error>(self, v: i64) -> Result<SkyMaybe<T>, E> {
        T::deserialize(serde::de::value::I64Deserializer::new(v)).map(SkyMaybe::Just)
    }
    fn visit_u64<E: serde::de::Error>(self, v: u64) -> Result<SkyMaybe<T>, E> {
        T::deserialize(serde::de::value::U64Deserializer::new(v)).map(SkyMaybe::Just)
    }
    fn visit_f64<E: serde::de::Error>(self, v: f64) -> Result<SkyMaybe<T>, E> {
        T::deserialize(serde::de::value::F64Deserializer::new(v)).map(SkyMaybe::Just)
    }
}

impl<T> SkyMaybe<T> {
    pub fn with_default(self, def: T) -> T {
        match self { SkyMaybe::Just(v) => v, SkyMaybe::Nothing => def }
    }
    pub fn is_just(&self) -> bool { matches!(self, SkyMaybe::Just(_)) }
    pub fn is_nothing(&self) -> bool { matches!(self, SkyMaybe::Nothing) }
}

// `Nothing` is the natural zero of an absent `Maybe`, mirroring Go's
// `json.Unmarshal` decoding a missing nullable field to nil. This MANUAL impl
// (the derive would demand `T: Default`, which a `SkyMaybe<NonDefault>` field
// cannot satisfy) lets a form-target record carrying a `Maybe X` field qualify
// for the #37 lenient `#[serde(default)]` form-decode stamp without an E0277.
// Deliberately NOT provided for `SkyResult`: an absent `Result` has no canonical
// zero (`Ok` vs `Err` is undecidable), so a Result-typed form field keeps the
// strict (non-Default) emission instead — see Emitter.hs `allFieldsDefaultable`.
//
// NOT `#[derive(Default)]` (clippy::derivable_impls): the derive stamps a
// `T: Default` bound on EVERY type param, which would defeat the point — a
// `SkyMaybe<NonDefault>` field must still have a default (its inner `T` is never
// constructed in the `Nothing` zero). This MANUAL impl is unbounded in `T`.
#[allow(clippy::derivable_impls)]
impl<T> Default for SkyMaybe<T> {
    fn default() -> Self { SkyMaybe::Nothing }
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

/// Extract a panic payload's message, classify it, emit the structured/plain
/// server-side log line (honouring `SKY_LOG_FORMAT=json`), and RETURN the 8-hex
/// correlation errId. SHARED by the exit-on-panic hook (`install_panic_classifier`,
/// used for Sky.Cli/Tui binaries) and the server/live `CatchPanicLayer` responder
/// (`server::panic_response`).
///
/// Two load-bearing properties:
/// 1. **Total** — it runs in a panic-unwinding context; a panic of ITS OWN would
///    abort the process. Downcast falls back to `"panic"`; no unwrap/index.
/// 2. **Does NOT exit** — the raw message goes to the SERVER LOG only; the caller
///    decides the fate (the hook adds `process::exit(1)`; the HTTP layer returns a
///    500 carrying ONLY the errId, never the message — so a panic message that
///    happens to contain a secret / PII / internal path is never sent to a client).
pub fn classify_and_log_panic(payload: &(dyn std::any::Any + Send)) -> String {
    let msg = if let Some(s) = payload.downcast_ref::<&str>() {
        (*s).to_string()
    } else if let Some(s) = payload.downcast_ref::<String>() {
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
    err_id
}

/// The JSON body for a server `CatchPanicLayer` 500: classifies + logs the panic
/// SERVER-SIDE (errId) via `classify_and_log_panic`, then returns a body carrying
/// ONLY the errId — NEVER the panic message. The SINGLE source of the 500 body
/// shape, shared by Sky.Http.Server and Sky.Live (each wraps it in a 500 Response
/// at its own `CatchPanicLayer::custom` site). Axum-free, so it lives in the
/// always-compiled `core` — the generated project includes `server.rs` only for
/// Sky.Http.Server apps, so a Live-only app can't reference a server-module fn.
///
/// SECURITY: `err_id` (8 lowercase-hex chars) is the ONLY value interpolated; the
/// rest is a fixed literal. A panic message (free-form, may carry secrets / PII /
/// paths) never reaches this body.
pub fn panic_500_body(payload: &(dyn std::any::Any + Send)) -> String {
    let err_id = classify_and_log_panic(payload);
    format!("{{\"error\":\"internal server error\",\"ref\":\"{err_id}\"}}")
}

/// Install the classifying panic hook. Idempotent in effect (re-installing just
/// replaces the hook). Called at the top of generated `fn main()` for non-server
/// shapes (Sky.Cli/Tui); server/live binaries rely on the per-request
/// `CatchPanicLayer` instead (so a handler panic returns a 500, not exit).
///
/// **Design note — hook logs then RESUMES the unwind (never calls exit).** Calling
/// `process::exit(1)` from the hook would prevent `catch_unwind` anywhere in the
/// process from absorbing panics, which breaks two load-bearing mechanisms:
///
///   1. `tokio::task::spawn(...)` internally uses `catch_unwind` to turn a task
///      panic into a `JoinError`.  The async-FFI binding bodies use this to satisfy
///      C5 (foreign `async fn` panics → `SkyResult::Err`) — see #44.
///
///   2. `block_on`'s `std::thread::spawn(…).join()` catches a panicking entry
///      future at the OS-thread boundary and maps it to `SkyResult::Err`.
///
/// By resuming the unwind, both mechanisms can absorb the panic after the hook
/// has logged the classified error.  For a truly uncaught panic (nothing catches
/// it), the Rust runtime prints a backtrace and aborts/exits — still a clean
/// non-zero exit. The classified log line always fires first.
pub fn install_panic_classifier() {
    std::panic::set_hook(Box::new(|info| {
        // Log (classified, with errId) — diagnostic fires regardless of whether
        // the panic is subsequently caught by catch_unwind / tokio::task::spawn.
        let _ = classify_and_log_panic(info.payload());
        // Do NOT call process::exit — let the panic unwind propagate so that
        // catch_unwind callers (tokio task spawn, block_on thread join, async-FFI
        // wrappers) can absorb it and map it to a Sky Err value.
    }));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn classify_and_log_panic_returns_8hex_errid_and_never_panics() {
        // &str, String, and a non-string payload all yield an 8-hex errId — and
        // the call itself never panics (it runs in a panic-unwinding context).
        let s: &str = "divide by zero";
        let e1 = classify_and_log_panic(&s);
        let owned: String = "index out of bounds: the len is 0".to_string();
        let e2 = classify_and_log_panic(&owned);
        let other: i32 = 42; // non-string payload → "panic" fallback
        let e3 = classify_and_log_panic(&other);
        for id in [&e1, &e2, &e3] {
            assert_eq!(id.len(), 8, "errId not 8 chars: {id}");
            // The errId is the ONLY value interpolated into the HTTP 500 body, so
            // its charset MUST be [0-9a-f] — proving the body can carry nothing
            // attacker-influenced.
            assert!(
                id.chars().all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase()),
                "errId not lowercase hex: {id}"
            );
        }
    }

    #[test]
    fn classify_panic_maps_known_kinds() {
        assert_eq!(classify_panic("attempt to divide by zero"), "DivisionByZero");
        assert_eq!(classify_panic("index out of bounds: the len is 3"), "IndexOutOfRange");
        assert_eq!(classify_panic("attempt to add with overflow"), "ArithmeticOverflow");
        assert_eq!(classify_panic("something else entirely"), "Unexpected");
    }
}
