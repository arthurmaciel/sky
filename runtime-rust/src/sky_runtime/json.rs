#![allow(clippy::type_complexity)]
// JSON encode/decode, pipeline, and currying helpers.
// Generic over E for error type.
use super::*;

pub type JsonVal = serde_json::Value;

/// `Decoder<E, T>` — the unified decoder type shared by JsonDec, DbDec, and Config.
///
/// Changed from a bare `Box<dyn Fn>` type alias to a struct carrying:
///   - `run`: the decoding function (called against a `&JsonVal`).
///   - `fields`: the object fields this decoder reads from the input JsonVal::Object.
///     ∅ for leaf / combinator decoders (succeed, fail, string, int, …).
///     Named fields for `decode_field` and the `db_decode_*` primitives.
///     Union of inner fields for combinators (map2..5, and_map).
///     This is the same concept as Go's `DbDecoder.cols` — used by `db_decode_nullable`
///     to determine whether ALL the fields the inner decoder reads are NULL/absent
///     before delegating to the inner run.
///
/// The struct is `Send`:  `Box<dyn Fn + Send>` is Send; `Vec<String>` is Send.
pub struct Decoder<E, T> {
    pub run: Box<dyn Fn(&JsonVal) -> SkyResult<E, T> + Send>,
    pub fields: Vec<String>,
}

impl<E, T> Decoder<E, T> {
    pub fn new(run: Box<dyn Fn(&JsonVal) -> SkyResult<E, T> + Send>, fields: Vec<String>) -> Self {
        Decoder { run, fields }
    }
}

/// Append every field from `extra` into `base` that isn't already present.
/// The shared field-union used by every multi-decoder combinator (map2..5,
/// and_map, the pipeline helpers) so the open-coded O(n²) merge lives in one
/// place instead of ~10 copies.
fn union_fields(base: &mut Vec<String>, extra: &[String]) {
    for fld in extra {
        if !base.contains(fld) {
            base.push(fld.clone());
        }
    }
}

pub fn decode_ok<E, T>(t: T) -> SkyResult<E, T> { SkyResult::Ok(t) }
pub fn decode_err_str<E: From<String>, T>(s: String) -> SkyResult<E, T> { SkyResult::Err(str_err(&s)) }

// --- Encode ---
pub fn json_enc_encode(indent: i64, val: JsonVal) -> String {
    // serde_json::to_string never fails on a well-constructed Value;
    // unwrap_or_default preserves the total signature of the Sky-side
    // `encode : Int -> Value -> String` (pure, no Task wrapper).
    if indent > 0 { serde_json::to_string_pretty(&val).unwrap_or_default() }
    else { serde_json::to_string(&val).unwrap_or_default() }
}
pub fn json_enc_string(s: String) -> JsonVal { JsonVal::String(s) }
pub fn json_enc_int(i: i64) -> JsonVal { JsonVal::Number(i.into()) }
pub fn json_enc_float(f: f64) -> JsonVal { JsonVal::from(f) }
pub fn json_enc_bool(b: bool) -> JsonVal { JsonVal::Bool(b) }
pub fn json_enc_null() -> JsonVal { JsonVal::Null }
pub fn json_enc_list<A>(f: impl Fn(A) -> JsonVal, items: Vec<A>) -> JsonVal {
    JsonVal::Array(items.into_iter().map(f).collect())
}
pub fn json_enc_object(pairs: Vec<(String, JsonVal)>) -> JsonVal {
    JsonVal::Object(pairs.into_iter().collect())
}

// --- Decode primitives ---
pub fn json_decode_string<E: From<String> + 'static>() -> Decoder<E, String> {
    Decoder::new(
        Box::new(|v| match v { JsonVal::String(s) => decode_ok(s.clone()), _ => decode_err_str("expected string".into()) }),
        vec![],
    )
}
pub fn json_decode_int<E: From<String> + 'static>() -> Decoder<E, i64> {
    Decoder::new(
        Box::new(|v| match v.as_i64() { Some(i) => decode_ok(i), None => decode_err_str("expected int".into()) }),
        vec![],
    )
}
pub fn json_decode_float<E: From<String> + 'static>() -> Decoder<E, f64> {
    Decoder::new(
        Box::new(|v| match v.as_f64() { Some(f) => decode_ok(f), None => decode_err_str("expected float".into()) }),
        vec![],
    )
}
pub fn json_decode_bool<E: From<String> + 'static>() -> Decoder<E, bool> {
    Decoder::new(
        Box::new(|v| match v.as_bool() { Some(b) => decode_ok(b), None => decode_err_str("expected bool".into()) }),
        vec![],
    )
}
pub fn json_decode_null<E: From<String> + 'static, A: Default + Send>() -> Decoder<E, A> {
    Decoder::new(
        Box::new(|v| match v { JsonVal::Null => decode_ok(A::default()), _ => decode_err_str("expected null".into()) }),
        vec![],
    )
}

// --- Decode combinators ---
pub fn decode_field<E: From<String> + 'static, T: 'static + Send>(name: String, decoder: Decoder<E, T>) -> Decoder<E, T> {
    let fields = vec![name.clone()];
    Decoder::new(
        Box::new(move |v| match v.get(&name) {
            Some(field) => (decoder.run)(field),
            None => decode_err_str(format!("missing field: {}", name)),
        }),
        fields,
    )
}

/// `JsonDec.index : Int -> Decoder a -> Decoder a` — decode the n-th element
/// of a JSON array. Out-of-bounds or non-array input is `Err`. Matches Go's
/// `JsonDec_index` which checks `[]any` bounds and prepends `"[N]"` to error
/// paths (we inline the path prefix in the error message for parity).
pub fn decode_index<E: From<String> + 'static, T: 'static + Send>(n: i64, decoder: Decoder<E, T>) -> Decoder<E, T> {
    let inner_fields = decoder.fields.clone();
    Decoder::new(
        Box::new(move |v| match v.as_array() {
            None => decode_err_str(format!("[{}]: expected array", n)),
            Some(arr) => {
                let idx = n as usize;
                match arr.get(idx) {
                    None => decode_err_str(format!("[{}]: index out of range (len={})", n, arr.len())),
                    Some(elem) => (decoder.run)(elem),
                }
            }
        }),
        inner_fields,
    )
}

pub fn decode_at<E: From<String> + 'static, T: 'static + Send>(path: Vec<String>, decoder: Decoder<E, T>) -> Decoder<E, T> {
    let inner_fields = decoder.fields.clone();
    Decoder::new(
        Box::new(move |v| {
            let mut cur = v;
            for key in &path { match cur.get(key) { Some(n) => cur = n, None => return decode_err_str(format!("missing path: {}", key)) } }
            (decoder.run)(cur)
        }),
        inner_fields,
    )
}
pub fn decode_list<E: From<String> + 'static, T: 'static + Send>(decoder: impl Fn() -> Decoder<E, T> + Send + 'static) -> Decoder<E, Vec<T>> {
    Decoder::new(
        Box::new(move |v| match v.as_array() {
            Some(arr) => {
                let mut out = Vec::with_capacity(arr.len());
                // `Decoder::run` is a `Fn` — a single decoder instance decodes
                // every element. Build it ONCE outside the loop (was O(N) Box
                // allocations: one fresh Decoder + boxed closure per element).
                let d = decoder();
                for item in arr {
                    match (d.run)(item) {
                        SkyResult::Ok(t) => out.push(t),
                        // Surface the REAL inner-element error rather than
                        // collapsing it to a generic "decode error" — keeps the
                        // diagnostic Go's `JsonDec.list` preserves.
                        SkyResult::Err(e) => return SkyResult::Err(e),
                    }
                }
                decode_ok(out)
            },
            None => decode_err_str("expected array".into())
        }),
        vec![],
    )
}
pub fn decode_map<E: From<String> + 'static, A: 'static + Send, B: 'static + Send>(f: impl Fn(A) -> B + Send + 'static, decoder: Decoder<E, A>) -> Decoder<E, B> {
    let inner_fields = decoder.fields.clone();
    Decoder::new(
        Box::new(move |v| match (decoder.run)(v) { SkyResult::Ok(a) => decode_ok(f(a)), SkyResult::Err(e) => SkyResult::Err(e) }),
        inner_fields,
    )
}
// `map2`/`map3`/`map4` — combine 2/3/4 decoders over the SAME JSON value with an
// N-ary function. Each runs against `v`; the first Err short-circuits (real
// error propagated, not collapsed to a generic string). Total, no panic.
pub fn decode_map2<E: From<String> + 'static, A: 'static + Send, B: 'static + Send, C: 'static + Send>(
    f: impl Fn(A, B) -> C + Send + 'static, da: Decoder<E, A>, db: Decoder<E, B>,
) -> Decoder<E, C> {
    let mut fields = da.fields.clone();
    union_fields(&mut fields, &db.fields);
    Decoder::new(
        Box::new(move |v| {
            let a = match (da.run)(v) { SkyResult::Ok(a) => a, SkyResult::Err(e) => return SkyResult::Err(e) };
            let b = match (db.run)(v) { SkyResult::Ok(b) => b, SkyResult::Err(e) => return SkyResult::Err(e) };
            decode_ok(f(a, b))
        }),
        fields,
    )
}
pub fn decode_map3<E: From<String> + 'static, A: 'static + Send, B: 'static + Send, C: 'static + Send, D: 'static + Send>(
    f: impl Fn(A, B, C) -> D + Send + 'static, da: Decoder<E, A>, db: Decoder<E, B>, dc: Decoder<E, C>,
) -> Decoder<E, D> {
    let mut fields = da.fields.clone();
    union_fields(&mut fields, &db.fields);
    union_fields(&mut fields, &dc.fields);
    Decoder::new(
        Box::new(move |v| {
            let a = match (da.run)(v) { SkyResult::Ok(a) => a, SkyResult::Err(e) => return SkyResult::Err(e) };
            let b = match (db.run)(v) { SkyResult::Ok(b) => b, SkyResult::Err(e) => return SkyResult::Err(e) };
            let c = match (dc.run)(v) { SkyResult::Ok(c) => c, SkyResult::Err(e) => return SkyResult::Err(e) };
            decode_ok(f(a, b, c))
        }),
        fields,
    )
}
pub fn decode_map4<E: From<String> + 'static, A: 'static + Send, B: 'static + Send, C: 'static + Send, D: 'static + Send, G: 'static + Send>(
    f: impl Fn(A, B, C, D) -> G + Send + 'static, da: Decoder<E, A>, db: Decoder<E, B>, dc: Decoder<E, C>, dd: Decoder<E, D>,
) -> Decoder<E, G> {
    let mut fields = da.fields.clone();
    union_fields(&mut fields, &db.fields);
    union_fields(&mut fields, &dc.fields);
    union_fields(&mut fields, &dd.fields);
    Decoder::new(
        Box::new(move |v| {
            let a = match (da.run)(v) { SkyResult::Ok(a) => a, SkyResult::Err(e) => return SkyResult::Err(e) };
            let b = match (db.run)(v) { SkyResult::Ok(b) => b, SkyResult::Err(e) => return SkyResult::Err(e) };
            let c = match (dc.run)(v) { SkyResult::Ok(c) => c, SkyResult::Err(e) => return SkyResult::Err(e) };
            let d = match (dd.run)(v) { SkyResult::Ok(d) => d, SkyResult::Err(e) => return SkyResult::Err(e) };
            decode_ok(f(a, b, c, d))
        }),
        fields,
    )
}
// `map5` — combine 5 decoders over the SAME value with a 5-arg function.
// Mirrors map2/map3/map4 exactly; first Err short-circuits with the real error.
pub fn decode_map5<E: From<String> + 'static, A: 'static + Send, B: 'static + Send, C: 'static + Send, D: 'static + Send, G: 'static + Send, H: 'static + Send>(
    f: impl Fn(A, B, C, D, G) -> H + Send + 'static,
    da: Decoder<E, A>, db: Decoder<E, B>, dc: Decoder<E, C>, dd: Decoder<E, D>, de: Decoder<E, G>,
) -> Decoder<E, H> {
    let mut fields = da.fields.clone();
    union_fields(&mut fields, &db.fields);
    union_fields(&mut fields, &dc.fields);
    union_fields(&mut fields, &dd.fields);
    union_fields(&mut fields, &de.fields);
    Decoder::new(
        Box::new(move |v| {
            let a = match (da.run)(v) { SkyResult::Ok(a) => a, SkyResult::Err(e) => return SkyResult::Err(e) };
            let b = match (db.run)(v) { SkyResult::Ok(b) => b, SkyResult::Err(e) => return SkyResult::Err(e) };
            let c = match (dc.run)(v) { SkyResult::Ok(c) => c, SkyResult::Err(e) => return SkyResult::Err(e) };
            let d = match (dd.run)(v) { SkyResult::Ok(d) => d, SkyResult::Err(e) => return SkyResult::Err(e) };
            let e = match (de.run)(v) { SkyResult::Ok(e) => e, SkyResult::Err(err) => return SkyResult::Err(err) };
            decode_ok(f(a, b, c, d, e))
        }),
        fields,
    )
}

/// `andMap : Decoder a -> Decoder (a -> b) -> Decoder b` — applicative apply.
/// Sky's pipe form: `succeed Ctor |> andMap decA |> andMap decB` chains as
/// `andMap decB (andMap decA (succeed Ctor))` — the VALUE decoder is the first
/// arg, the FUNCTION decoder is the second.
/// Matches Sky's `Std.Db.Decode.sky` line: `andMap : Decoder a -> Decoder (a -> b) -> Decoder b`.
pub fn decode_and_map<E: From<String> + 'static, A: 'static + Send, B: 'static + Send>(
    dec_val: Decoder<E, A>,
    dec_fn: Decoder<E, Box<dyn FnOnce(A) -> B + Send>>,
) -> Decoder<E, B> {
    let mut fields = dec_fn.fields.clone();
    union_fields(&mut fields, &dec_val.fields);
    Decoder::new(
        Box::new(move |v| {
            // Evaluate the function decoder first (pipeline accumulator), then the value.
            let f = match (dec_fn.run)(v) { SkyResult::Ok(f) => f, SkyResult::Err(e) => return SkyResult::Err(e) };
            let a = match (dec_val.run)(v) { SkyResult::Ok(a) => a, SkyResult::Err(e) => return SkyResult::Err(e) };
            decode_ok(f(a))
        }),
        fields,
    )
}
pub fn decode_and_then<E: From<String> + 'static, A: 'static + Send, B: 'static + Send>(
    decoder: Decoder<E, A>, f: impl Fn(A) -> Decoder<E, B> + Send + 'static
) -> Decoder<E, B> {
    let inner_fields = decoder.fields.clone();
    Decoder::new(
        Box::new(move |val| match (decoder.run)(val) { SkyResult::Ok(a) => (f(a).run)(val), SkyResult::Err(e) => SkyResult::Err(e) }),
        inner_fields,
    )
}

// --- Succeed / Fail / OneOf ---
/// `Decode.succeed : a -> Decoder a`
///
/// Accepts a **factory** `Box<dyn Fn() -> A + Send>` that produces a fresh `A`
/// on every call to the decoder's `run`.  This makes the decoder reusable across
/// multiple rows (`db_query_decode` calls `run` once per row).
///
/// The generated Rust code always calls this as `decode_succeed(curryN(ctor))`
/// where `curryN` now returns a factory closure that produces a fresh `FnOnce`
/// chain on each invocation.  Since `ctor` is either a `fn` pointer (Copy) or a
/// non-capturing closure (also Copy/Clone in Rust), the factory can capture it
/// by value and produce fresh chains on demand.
///
/// Multi-row correctness: each call to `succeed.run` calls `factory()` to get a
/// fresh `A`; the `FnOnce` chain is consumed exactly once per row by the
/// enclosing pipeline combinators — correct by construction.
pub fn decode_succeed<E: From<String> + 'static, A: 'static + Send>(
    factory: Box<dyn Fn() -> A + Send>,
) -> Decoder<E, A> {
    Decoder::new(
        Box::new(move |_| decode_ok((factory)())),
        vec![],
    )
}
pub fn decode_fail<E: From<String> + 'static, A: 'static + Send>(msg: String) -> Decoder<E, A> {
    let m = msg;
    Decoder::new(
        Box::new(move |_| decode_err_str(m.clone())),
        vec![],
    )
}
pub fn decode_one_of<E: From<String> + 'static, T: 'static + Send>(decoders: Vec<Decoder<E, T>>) -> Decoder<E, T> {
    Decoder::new(
        Box::new(move |v| {
            // Try each branch; on total failure surface the LAST branch's real
            // error rather than a generic "oneOf: no match" (Go's `oneOf`
            // likewise reports the underlying failure).
            let mut last_err: Option<SkyResult<E, T>> = None;
            for d in &decoders {
                let r = (d.run)(v);
                if r.is_ok() { return r; }
                last_err = Some(r);
            }
            last_err.unwrap_or_else(|| decode_err_str("oneOf: no match".into()))
        }),
        vec![],
    )
}
pub fn decode_from_json_string<E: From<String> + 'static, T>(decoder: Decoder<E, T>, json: String) -> SkyResult<E, T> {
    match serde_json::from_str(&json) {
        Ok(val) => (decoder.run)(&val),
        Err(e) => decode_err_str(format!("json parse: {}", e))
    }
}

// --- Currying helpers (for pipeline decoder composition) ---
//
// Each helper now returns a FACTORY: `Box<dyn Fn() -> Box<dyn FnOnce(A1) -> ...> + Send>`.
//
// This is the key change that enables multi-row decoding.  `decode_succeed`
// stores this factory and calls it once per `run` invocation (once per DB row).
// Each factory call produces a fresh `FnOnce` chain that can be threaded through
// the pipeline combinators exactly once — which is all that's needed per row.
//
// Correctness argument:
//   - The factory closure captures `f` by COPY (fn pointers and non-capturing
//     closures in Rust are `Copy`, hence `Clone`; `F: Fn + Clone` covers both).
//   - Each factory call produces a genuinely fresh `Box<dyn FnOnce>` chain —
//     no shared state, no interior mutability, fully total.
//   - `decode_pipeline_required` / `db_decode_required` etc. call `(nd.run)(v)` once
//     per row, consuming the `FnOnce` exactly once — correct.
//   - Total: no panic, no unwrap — only `SkyResult::Err` on decode failure.
//
// Bounds: `F: Fn(A1,..) -> R + Clone + Send` — fn pointers are Copy ⊆ Clone;
// non-capturing closures in Rust are Copy ⊆ Clone.
pub fn curry1<A: 'static + Send, R: 'static + Send, F: Fn(A) -> R + Clone + Send + 'static>(f: F)
-> Box<dyn Fn() -> Box<dyn FnOnce(A) -> R + Send> + Send>
{
    Box::new(move || { let f = f.clone(); Box::new(f) })
}
pub fn curry2<A1: 'static + Send, A2: 'static + Send, R: 'static + Send, F: Fn(A1, A2) -> R + Clone + Send + 'static>(
    f: F,
) -> Box<dyn Fn() -> Box<dyn FnOnce(A1) -> Box<dyn FnOnce(A2) -> R + Send> + Send> + Send> {
    Box::new(move || { let f = f.clone(); Box::new(move |a1| { let f = f; Box::new(move |a2| f(a1, a2)) }) })
}
pub fn curry3<A1: 'static + Send, A2: 'static + Send, A3: 'static + Send, R: 'static + Send, F: Fn(A1, A2, A3) -> R + Clone + Send + 'static>(
    f: F,
) -> Box<dyn Fn() -> Box<dyn FnOnce(A1) -> Box<dyn FnOnce(A2) -> Box<dyn FnOnce(A3) -> R + Send> + Send> + Send> + Send> {
    Box::new(move || { let f = f.clone(); Box::new(move |a1| { let f = f; Box::new(move |a2| { let f = f; Box::new(move |a3| f(a1, a2, a3)) }) }) })
}
pub fn curry4<A1: 'static + Send, A2: 'static + Send, A3: 'static + Send, A4: 'static + Send, R: 'static + Send, F: Fn(A1, A2, A3, A4) -> R + Clone + Send + 'static>(
    f: F,
) -> Box<dyn Fn() -> Box<dyn FnOnce(A1) -> Box<dyn FnOnce(A2) -> Box<dyn FnOnce(A3) -> Box<dyn FnOnce(A4) -> R + Send> + Send> + Send> + Send> + Send> {
    Box::new(move || { let f = f.clone(); Box::new(move |a1| { let f = f; Box::new(move |a2| { let f = f; Box::new(move |a3| { let f = f; Box::new(move |a4| f(a1, a2, a3, a4)) }) }) }) })
}
pub fn curry5<A1: 'static + Send, A2: 'static + Send, A3: 'static + Send, A4: 'static + Send, A5: 'static + Send, R: 'static + Send, F: Fn(A1, A2, A3, A4, A5) -> R + Clone + Send + 'static>(
    f: F,
) -> Box<dyn Fn() -> Box<dyn FnOnce(A1) -> Box<dyn FnOnce(A2) -> Box<dyn FnOnce(A3) -> Box<dyn FnOnce(A4) -> Box<dyn FnOnce(A5) -> R + Send> + Send> + Send> + Send> + Send> + Send> {
    Box::new(move || { let f = f.clone(); Box::new(move |a1| { let f = f; Box::new(move |a2| { let f = f; Box::new(move |a3| { let f = f; Box::new(move |a4| { let f = f; Box::new(move |a5| f(a1, a2, a3, a4, a5)) }) }) }) }) })
}
pub fn curry6<A1: 'static + Send, A2: 'static + Send, A3: 'static + Send, A4: 'static + Send, A5: 'static + Send, A6: 'static + Send, R: 'static + Send, F: Fn(A1, A2, A3, A4, A5, A6) -> R + Clone + Send + 'static>(
    f: F,
) -> Box<dyn Fn() -> Box<dyn FnOnce(A1) -> Box<dyn FnOnce(A2) -> Box<dyn FnOnce(A3) -> Box<dyn FnOnce(A4) -> Box<dyn FnOnce(A5) -> Box<dyn FnOnce(A6) -> R + Send> + Send> + Send> + Send> + Send> + Send> + Send> {
    Box::new(move || { let f = f.clone(); Box::new(move |a1| { let f = f; Box::new(move |a2| { let f = f; Box::new(move |a3| { let f = f; Box::new(move |a4| { let f = f; Box::new(move |a5| { let f = f; Box::new(move |a6| f(a1, a2, a3, a4, a5, a6)) }) }) }) }) }) })
}
pub fn curry7<A1: 'static + Send, A2: 'static + Send, A3: 'static + Send, A4: 'static + Send, A5: 'static + Send, A6: 'static + Send, A7: 'static + Send, R: 'static + Send, F: Fn(A1, A2, A3, A4, A5, A6, A7) -> R + Clone + Send + 'static>(
    f: F,
) -> Box<dyn Fn() -> Box<dyn FnOnce(A1) -> Box<dyn FnOnce(A2) -> Box<dyn FnOnce(A3) -> Box<dyn FnOnce(A4) -> Box<dyn FnOnce(A5) -> Box<dyn FnOnce(A6) -> Box<dyn FnOnce(A7) -> R + Send> + Send> + Send> + Send> + Send> + Send> + Send> + Send> {
    Box::new(move || { let f = f.clone(); Box::new(move |a1| { let f = f; Box::new(move |a2| { let f = f; Box::new(move |a3| { let f = f; Box::new(move |a4| { let f = f; Box::new(move |a5| { let f = f; Box::new(move |a6| { let f = f; Box::new(move |a7| f(a1, a2, a3, a4, a5, a6, a7)) }) }) }) }) }) }) })
}
pub fn curry8<A1: 'static + Send, A2: 'static + Send, A3: 'static + Send, A4: 'static + Send, A5: 'static + Send, A6: 'static + Send, A7: 'static + Send, A8: 'static + Send, R: 'static + Send, F: Fn(A1, A2, A3, A4, A5, A6, A7, A8) -> R + Clone + Send + 'static>(
    f: F,
) -> Box<dyn Fn() -> Box<dyn FnOnce(A1) -> Box<dyn FnOnce(A2) -> Box<dyn FnOnce(A3) -> Box<dyn FnOnce(A4) -> Box<dyn FnOnce(A5) -> Box<dyn FnOnce(A6) -> Box<dyn FnOnce(A7) -> Box<dyn FnOnce(A8) -> R + Send> + Send> + Send> + Send> + Send> + Send> + Send> + Send> + Send> {
    Box::new(move || { let f = f.clone(); Box::new(move |a1| { let f = f; Box::new(move |a2| { let f = f; Box::new(move |a3| { let f = f; Box::new(move |a4| { let f = f; Box::new(move |a5| { let f = f; Box::new(move |a6| { let f = f; Box::new(move |a7| { let f = f; Box::new(move |a8| f(a1, a2, a3, a4, a5, a6, a7, a8)) }) }) }) }) }) }) }) })
}
// type_complexity (accepted, cosmetic): the nested `Box<dyn FnOnce>` tower IS the
// 9-arity curry shape; no type alias can simplify a per-arity boxed-closure
// chain. Not a soundness concern.
#[allow(clippy::type_complexity)]
pub fn curry9<A1: 'static + Send, A2: 'static + Send, A3: 'static + Send, A4: 'static + Send, A5: 'static + Send, A6: 'static + Send, A7: 'static + Send, A8: 'static + Send, A9: 'static + Send, R: 'static + Send, F: Fn(A1, A2, A3, A4, A5, A6, A7, A8, A9) -> R + Clone + Send + 'static>(
    f: F,
) -> Box<dyn Fn() -> Box<dyn FnOnce(A1) -> Box<dyn FnOnce(A2) -> Box<dyn FnOnce(A3) -> Box<dyn FnOnce(A4) -> Box<dyn FnOnce(A5) -> Box<dyn FnOnce(A6) -> Box<dyn FnOnce(A7) -> Box<dyn FnOnce(A8) -> Box<dyn FnOnce(A9) -> R + Send> + Send> + Send> + Send> + Send> + Send> + Send> + Send> + Send> + Send> {
    Box::new(move || { let f = f.clone(); Box::new(move |a1| { let f = f; Box::new(move |a2| { let f = f; Box::new(move |a3| { let f = f; Box::new(move |a4| { let f = f; Box::new(move |a5| { let f = f; Box::new(move |a6| { let f = f; Box::new(move |a7| { let f = f; Box::new(move |a8| { let f = f; Box::new(move |a9| f(a1, a2, a3, a4, a5, a6, a7, a8, a9)) }) }) }) }) }) }) }) }) })
}
// type_complexity (accepted, cosmetic): the nested `Box<dyn FnOnce>` tower IS the
// 10-arity curry shape; no type alias can simplify a per-arity boxed-closure
// chain. Not a soundness concern.
#[allow(clippy::type_complexity)]
pub fn curry10<A1: 'static + Send, A2: 'static + Send, A3: 'static + Send, A4: 'static + Send, A5: 'static + Send, A6: 'static + Send, A7: 'static + Send, A8: 'static + Send, A9: 'static + Send, A10: 'static + Send, R: 'static + Send, F: Fn(A1, A2, A3, A4, A5, A6, A7, A8, A9, A10) -> R + Clone + Send + 'static>(
    f: F,
) -> Box<dyn Fn() -> Box<dyn FnOnce(A1) -> Box<dyn FnOnce(A2) -> Box<dyn FnOnce(A3) -> Box<dyn FnOnce(A4) -> Box<dyn FnOnce(A5) -> Box<dyn FnOnce(A6) -> Box<dyn FnOnce(A7) -> Box<dyn FnOnce(A8) -> Box<dyn FnOnce(A9) -> Box<dyn FnOnce(A10) -> R + Send> + Send> + Send> + Send> + Send> + Send> + Send> + Send> + Send> + Send> + Send> {
    Box::new(move || { let f = f.clone(); Box::new(move |a1| { let f = f; Box::new(move |a2| { let f = f; Box::new(move |a3| { let f = f; Box::new(move |a4| { let f = f; Box::new(move |a5| { let f = f; Box::new(move |a6| { let f = f; Box::new(move |a7| { let f = f; Box::new(move |a8| { let f = f; Box::new(move |a9| { let f = f; Box::new(move |a10| f(a1, a2, a3, a4, a5, a6, a7, a8, a9, a10)) }) }) }) }) }) }) }) }) }) })
}

// --- Pipeline (curried decoder combinators) ---
// Curried by design. Pipeline-decoder helpers
// thread Box<dyn FnOnce> chains that Rust's static trait system can't
// express in tupled form. These are the ONLY functions in the runtime
// that intentionally return impl FnOnce.
// UNCURRIED: the codegen lowers `decode |> Pipeline.required "x" dec` to a
// direct 3-arg call `decode_pipeline_required("x", dec, decode)` (the accumulator
// decoder is the pipe's left side, threaded as the last arg). Taking
// next_decoder as a normal parameter — rather than returning a closure over it
// — matches that shape (35-composite-generics; was a 2-arg curried fn → E0061).
pub fn decode_pipeline_required<E: From<String> + 'static, T: 'static, F: 'static>(name: String, decoder: Decoder<E, T>, next_decoder: Decoder<E, Box<dyn FnOnce(T) -> F + Send>>) -> Decoder<E, F> {
    let mut fields = next_decoder.fields.clone();
    union_fields(&mut fields, &decoder.fields);
    let n = name; let d = decoder; let nd = next_decoder;
    Decoder::new(
        Box::new(move |v| {
            let field_val = match v.get(&n) { Some(f) => match (d.run)(f) { SkyResult::Ok(t) => t, SkyResult::Err(e) => return SkyResult::Err(e) }, None => return decode_err_str(format!("missing required: {}", n)) };
            match (nd.run)(v) { SkyResult::Ok(f) => ok_res(f(field_val)), SkyResult::Err(e) => SkyResult::Err(e) }
        }),
        fields,
    )
}
pub fn decode_pipeline_optional<E: From<String> + 'static, T: Clone + 'static + Send, F: 'static>(name: String, decoder: Decoder<E, T>, default: T, next_decoder: Decoder<E, Box<dyn FnOnce(T) -> F + Send>>) -> Decoder<E, F> {
    let mut fields = next_decoder.fields.clone();
    union_fields(&mut fields, &decoder.fields);
    let n = name; let d = decoder; let nd = next_decoder; let def = default;
    Decoder::new(
        Box::new(move |v| {
            let field_val = match v.get(&n) { Some(val) => match (d.run)(val) { SkyResult::Ok(t) => t, _ => def.clone() }, None => def.clone() };
            match (nd.run)(v) { SkyResult::Ok(f) => SkyResult::Ok(f(field_val)), SkyResult::Err(e) => SkyResult::Err(e) }
        }),
        fields,
    )
}

/// `JsonDecP.requiredAt : List String -> Decoder a -> Decoder (a -> b) -> Decoder b`.
/// Like `required` but walks a nested path before decoding. Matches Go's
/// `JsonDecP_requiredAt` which iterates the `List String` path by successive
/// `.get(key)` calls, hard-erroring on any missing segment or non-object node.
pub fn decode_pipeline_required_at<E: From<String> + 'static, T: 'static, F: 'static>(
    path: Vec<String>,
    decoder: Decoder<E, T>,
    next_decoder: Decoder<E, Box<dyn FnOnce(T) -> F + Send>>,
) -> Decoder<E, F> {
    let mut fields = next_decoder.fields.clone();
    union_fields(&mut fields, &decoder.fields);
    let p = path;
    let d = decoder;
    let nd = next_decoder;
    Decoder::new(
        Box::new(move |v| {
            // Walk the path into the JSON value.
            let mut cur: &JsonVal = v;
            for key in &p {
                match cur.get(key) {
                    Some(next) => cur = next,
                    None => return decode_err_str(format!("requiredAt: missing path segment {:?}", key)),
                }
            }
            // Decode the target value.
            let field_val = match (d.run)(cur) {
                SkyResult::Ok(t) => t,
                SkyResult::Err(e) => return SkyResult::Err(e),
            };
            // Apply the accumulator function from the pipeline.
            match (nd.run)(v) {
                SkyResult::Ok(f) => ok_res(f(field_val)),
                SkyResult::Err(e) => SkyResult::Err(e),
            }
        }),
        fields,
    )
}

/// `JsonDec.Pipeline.custom decoder next` — like `required`, but the custom
/// `decoder` runs on the WHOLE value (not a single field) and supplies the next
/// pipeline argument. A custom decode failure aborts the pipeline.
pub fn decode_pipeline_custom<E: From<String> + 'static, T: 'static, F: 'static>(decoder: Decoder<E, T>, next_decoder: Decoder<E, Box<dyn FnOnce(T) -> F + Send>>) -> Decoder<E, F> {
    let mut fields = next_decoder.fields.clone();
    union_fields(&mut fields, &decoder.fields);
    let d = decoder; let nd = next_decoder;
    Decoder::new(
        Box::new(move |v| {
            let t = match (d.run)(v) { SkyResult::Ok(t) => t, SkyResult::Err(e) => return SkyResult::Err(e) };
            match (nd.run)(v) { SkyResult::Ok(f) => SkyResult::Ok(f(t)), SkyResult::Err(e) => SkyResult::Err(e) }
        }),
        fields,
    )
}
