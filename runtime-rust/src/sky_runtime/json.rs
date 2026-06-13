#![allow(clippy::type_complexity)]
// JSON encode/decode, pipeline, and currying helpers.
// Generic over E for error type.
use super::*;

pub type JsonVal = serde_json::Value;
pub type Decoder<E, T> = Box<dyn Fn(&JsonVal) -> SkyResult<E, T> + Send>;

fn json_dec_ok<E, T>(t: T) -> SkyResult<E, T> { SkyResult::Ok(t) }
fn json_dec_err_str<E: From<String>, T>(s: String) -> SkyResult<E, T> { SkyResult::Err(str_err(&s)) }

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
pub fn json_dec_string<E: From<String> + 'static>() -> Decoder<E, String> {
    Box::new(|v| match v { JsonVal::String(s) => json_dec_ok(s.clone()), _ => json_dec_err_str("expected string".into()) })
}
pub fn json_dec_int<E: From<String> + 'static>() -> Decoder<E, i64> {
    Box::new(|v| match v.as_i64() { Some(i) => json_dec_ok(i), None => json_dec_err_str("expected int".into()) })
}
pub fn json_dec_float<E: From<String> + 'static>() -> Decoder<E, f64> {
    Box::new(|v| match v.as_f64() { Some(f) => json_dec_ok(f), None => json_dec_err_str("expected float".into()) })
}
pub fn json_dec_bool<E: From<String> + 'static>() -> Decoder<E, bool> {
    Box::new(|v| match v.as_bool() { Some(b) => json_dec_ok(b), None => json_dec_err_str("expected bool".into()) })
}
pub fn json_dec_null<E: From<String> + 'static, A: Default + Send>() -> Decoder<E, A> {
    Box::new(|v| match v { JsonVal::Null => json_dec_ok(A::default()), _ => json_dec_err_str("expected null".into()) })
}

// --- Decode combinators ---
pub fn json_dec_field<E: From<String> + 'static, T: 'static + Send>(name: String, decoder: Decoder<E, T>) -> Decoder<E, T> {
    Box::new(move |v| match v.get(&name) { Some(field) => decoder(field), None => json_dec_err_str(format!("missing field: {}", name)) })
}
pub fn json_dec_at<E: From<String> + 'static, T: 'static + Send>(path: Vec<String>, decoder: Decoder<E, T>) -> Decoder<E, T> {
    Box::new(move |v| {
        let mut cur = v;
        for key in &path { match cur.get(key) { Some(n) => cur = n, None => return json_dec_err_str(format!("missing path: {}", key)) } }
        decoder(cur)
    })
}
pub fn json_dec_list<E: From<String> + 'static, T: 'static + Send>(decoder: impl Fn() -> Decoder<E, T> + Send + 'static) -> Decoder<E, Vec<T>> {
    Box::new(move |v| match v.as_array() {
        Some(arr) => {
            let mut out = Vec::with_capacity(arr.len());
            for item in arr { let d = decoder(); match d(item) { SkyResult::Ok(t) => out.push(t), SkyResult::Err(_) => return json_dec_err_str("decode error".into()) } }
            json_dec_ok(out)
        },
        None => json_dec_err_str("expected array".into())
    })
}
pub fn json_dec_map<E: From<String> + 'static, A: 'static + Send, B: 'static + Send>(f: impl Fn(A) -> B + Send + 'static, decoder: Decoder<E, A>) -> Decoder<E, B> {
    Box::new(move |v| match decoder(v) { SkyResult::Ok(a) => json_dec_ok(f(a)), SkyResult::Err(e) => SkyResult::Err(e) })
}
// `map2`/`map3`/`map4` — combine 2/3/4 decoders over the SAME JSON value with an
// N-ary function. Each runs against `v`; the first Err short-circuits (real
// error propagated, not collapsed to a generic string). Total, no panic.
pub fn json_dec_map2<E: From<String> + 'static, A: 'static + Send, B: 'static + Send, C: 'static + Send>(
    f: impl Fn(A, B) -> C + Send + 'static, da: Decoder<E, A>, db: Decoder<E, B>,
) -> Decoder<E, C> {
    Box::new(move |v| {
        let a = match da(v) { SkyResult::Ok(a) => a, SkyResult::Err(e) => return SkyResult::Err(e) };
        let b = match db(v) { SkyResult::Ok(b) => b, SkyResult::Err(e) => return SkyResult::Err(e) };
        json_dec_ok(f(a, b))
    })
}
pub fn json_dec_map3<E: From<String> + 'static, A: 'static + Send, B: 'static + Send, C: 'static + Send, D: 'static + Send>(
    f: impl Fn(A, B, C) -> D + Send + 'static, da: Decoder<E, A>, db: Decoder<E, B>, dc: Decoder<E, C>,
) -> Decoder<E, D> {
    Box::new(move |v| {
        let a = match da(v) { SkyResult::Ok(a) => a, SkyResult::Err(e) => return SkyResult::Err(e) };
        let b = match db(v) { SkyResult::Ok(b) => b, SkyResult::Err(e) => return SkyResult::Err(e) };
        let c = match dc(v) { SkyResult::Ok(c) => c, SkyResult::Err(e) => return SkyResult::Err(e) };
        json_dec_ok(f(a, b, c))
    })
}
pub fn json_dec_map4<E: From<String> + 'static, A: 'static + Send, B: 'static + Send, C: 'static + Send, D: 'static + Send, G: 'static + Send>(
    f: impl Fn(A, B, C, D) -> G + Send + 'static, da: Decoder<E, A>, db: Decoder<E, B>, dc: Decoder<E, C>, dd: Decoder<E, D>,
) -> Decoder<E, G> {
    Box::new(move |v| {
        let a = match da(v) { SkyResult::Ok(a) => a, SkyResult::Err(e) => return SkyResult::Err(e) };
        let b = match db(v) { SkyResult::Ok(b) => b, SkyResult::Err(e) => return SkyResult::Err(e) };
        let c = match dc(v) { SkyResult::Ok(c) => c, SkyResult::Err(e) => return SkyResult::Err(e) };
        let d = match dd(v) { SkyResult::Ok(d) => d, SkyResult::Err(e) => return SkyResult::Err(e) };
        json_dec_ok(f(a, b, c, d))
    })
}
pub fn json_dec_and_then<E: From<String> + 'static, A: 'static + Send, B: 'static + Send>(
    decoder: Decoder<E, A>, f: impl Fn(A) -> Decoder<E, B> + Send + 'static
) -> Decoder<E, B> {
    Box::new(move |val| match decoder(val) { SkyResult::Ok(a) => f(a)(val), SkyResult::Err(e) => SkyResult::Err(e) })
}

// --- Succeed / Fail / OneOf ---
pub fn json_dec_succeed<E: From<String> + 'static, A: 'static + Send>(a: A) -> Decoder<E, A> {
    let cell = std::cell::RefCell::new(Some(a));
    Box::new(move |_| {
        cell.borrow_mut().take().map(SkyResult::Ok).unwrap_or_else(|| {
            SkyResult::Err(str_err("Internal compiler error: a Decode.succeed value was consumed twice. This should not happen — please file a bug report."))
        })
    })
}
pub fn json_dec_fail<E: From<String> + 'static, A: 'static + Send>(msg: String) -> Decoder<E, A> {
    let m = msg; Box::new(move |_| json_dec_err_str(m.clone()))
}
pub fn json_dec_one_of<E: From<String> + 'static, T: 'static + Send>(decoders: Vec<Decoder<E, T>>) -> Decoder<E, T> {
    Box::new(move |v| { for d in &decoders { let r = d(v); if r.is_ok() { return r; } } json_dec_err_str("oneOf: no match".into()) })
}
pub fn json_dec_decode_string<E: From<String> + 'static, T>(decoder: Decoder<E, T>, json: String) -> SkyResult<E, T> {
    match serde_json::from_str(&json) {
        Ok(val) => decoder(&val),
        Err(e) => json_dec_err_str(format!("json parse: {}", e))
    }
}

// --- Currying helpers (for pipeline decoder composition) ---
pub fn curry1<A, R, F: FnOnce(A) -> R + Send + 'static>(f: F) -> Box<dyn FnOnce(A) -> R + Send> {
    Box::new(f)
}
pub fn curry2<A1: 'static + Send, A2: 'static + Send, R: 'static, F: FnOnce(A1, A2) -> R + Send + 'static>(
    f: F,
) -> Box<dyn FnOnce(A1) -> Box<dyn FnOnce(A2) -> R + Send> + Send> {
    Box::new(move |a1| Box::new(move |a2| f(a1, a2)))
}
pub fn curry3<A1: 'static + Send, A2: 'static + Send, A3: 'static + Send, R: 'static, F: FnOnce(A1, A2, A3) -> R + Send + 'static>(
    f: F,
) -> Box<dyn FnOnce(A1) -> Box<dyn FnOnce(A2) -> Box<dyn FnOnce(A3) -> R + Send> + Send> + Send> {
    Box::new(move |a1| Box::new(move |a2| Box::new(move |a3| f(a1, a2, a3))))
}
pub fn curry4<A1: 'static + Send, A2: 'static + Send, A3: 'static + Send, A4: 'static + Send, R: 'static, F: FnOnce(A1, A2, A3, A4) -> R + Send + 'static>(
    f: F,
) -> Box<dyn FnOnce(A1) -> Box<dyn FnOnce(A2) -> Box<dyn FnOnce(A3) -> Box<dyn FnOnce(A4) -> R + Send> + Send> + Send> + Send> {
    Box::new(move |a1| Box::new(move |a2| Box::new(move |a3| Box::new(move |a4| f(a1, a2, a3, a4)))))
}
pub fn curry5<A1: 'static + Send, A2: 'static + Send, A3: 'static + Send, A4: 'static + Send, A5: 'static + Send, R: 'static, F: FnOnce(A1, A2, A3, A4, A5) -> R + Send + 'static>(
    f: F,
) -> Box<dyn FnOnce(A1) -> Box<dyn FnOnce(A2) -> Box<dyn FnOnce(A3) -> Box<dyn FnOnce(A4) -> Box<dyn FnOnce(A5) -> R + Send> + Send> + Send> + Send> + Send> {
    Box::new(move |a1| Box::new(move |a2| Box::new(move |a3| Box::new(move |a4| Box::new(move |a5| f(a1, a2, a3, a4, a5))))))
}
pub fn curry6<A1: 'static + Send, A2: 'static + Send, A3: 'static + Send, A4: 'static + Send, A5: 'static + Send, A6: 'static + Send, R: 'static, F: FnOnce(A1, A2, A3, A4, A5, A6) -> R + Send + 'static>(
    f: F,
) -> Box<dyn FnOnce(A1) -> Box<dyn FnOnce(A2) -> Box<dyn FnOnce(A3) -> Box<dyn FnOnce(A4) -> Box<dyn FnOnce(A5) -> Box<dyn FnOnce(A6) -> R + Send> + Send> + Send> + Send> + Send> + Send> {
    Box::new(move |a1| Box::new(move |a2| Box::new(move |a3| Box::new(move |a4| Box::new(move |a5| Box::new(move |a6| f(a1, a2, a3, a4, a5, a6)))))))
}
pub fn curry7<A1: 'static + Send, A2: 'static + Send, A3: 'static + Send, A4: 'static + Send, A5: 'static + Send, A6: 'static + Send, A7: 'static + Send, R: 'static, F: FnOnce(A1, A2, A3, A4, A5, A6, A7) -> R + Send + 'static>(
    f: F,
) -> Box<dyn FnOnce(A1) -> Box<dyn FnOnce(A2) -> Box<dyn FnOnce(A3) -> Box<dyn FnOnce(A4) -> Box<dyn FnOnce(A5) -> Box<dyn FnOnce(A6) -> Box<dyn FnOnce(A7) -> R + Send> + Send> + Send> + Send> + Send> + Send> + Send> {
    Box::new(move |a1| Box::new(move |a2| Box::new(move |a3| Box::new(move |a4| Box::new(move |a5| Box::new(move |a6| Box::new(move |a7| f(a1, a2, a3, a4, a5, a6, a7))))))))
}
pub fn curry8<A1: 'static + Send, A2: 'static + Send, A3: 'static + Send, A4: 'static + Send, A5: 'static + Send, A6: 'static + Send, A7: 'static + Send, A8: 'static + Send, R: 'static, F: FnOnce(A1, A2, A3, A4, A5, A6, A7, A8) -> R + Send + 'static>(
    f: F,
) -> Box<dyn FnOnce(A1) -> Box<dyn FnOnce(A2) -> Box<dyn FnOnce(A3) -> Box<dyn FnOnce(A4) -> Box<dyn FnOnce(A5) -> Box<dyn FnOnce(A6) -> Box<dyn FnOnce(A7) -> Box<dyn FnOnce(A8) -> R + Send> + Send> + Send> + Send> + Send> + Send> + Send> + Send> {
    Box::new(move |a1| Box::new(move |a2| Box::new(move |a3| Box::new(move |a4| Box::new(move |a5| Box::new(move |a6| Box::new(move |a7| Box::new(move |a8| f(a1, a2, a3, a4, a5, a6, a7, a8)))))))))
}
#[allow(clippy::type_complexity)]
pub fn curry9<A1: 'static + Send, A2: 'static + Send, A3: 'static + Send, A4: 'static + Send, A5: 'static + Send, A6: 'static + Send, A7: 'static + Send, A8: 'static + Send, A9: 'static + Send, R: 'static, F: FnOnce(A1, A2, A3, A4, A5, A6, A7, A8, A9) -> R + Send + 'static>(
    f: F,
) -> Box<dyn FnOnce(A1) -> Box<dyn FnOnce(A2) -> Box<dyn FnOnce(A3) -> Box<dyn FnOnce(A4) -> Box<dyn FnOnce(A5) -> Box<dyn FnOnce(A6) -> Box<dyn FnOnce(A7) -> Box<dyn FnOnce(A8) -> Box<dyn FnOnce(A9) -> R + Send> + Send> + Send> + Send> + Send> + Send> + Send> + Send> {
    Box::new(move |a1| Box::new(move |a2| Box::new(move |a3| Box::new(move |a4| Box::new(move |a5| Box::new(move |a6| Box::new(move |a7| Box::new(move |a8| Box::new(move |a9| f(a1, a2, a3, a4, a5, a6, a7, a8, a9))))))))))
}
#[allow(clippy::type_complexity)]
pub fn curry10<A1: 'static + Send, A2: 'static + Send, A3: 'static + Send, A4: 'static + Send, A5: 'static + Send, A6: 'static + Send, A7: 'static + Send, A8: 'static + Send, A9: 'static + Send, A10: 'static + Send, R: 'static, F: FnOnce(A1, A2, A3, A4, A5, A6, A7, A8, A9, A10) -> R + Send + 'static>(
    f: F,
) -> Box<dyn FnOnce(A1) -> Box<dyn FnOnce(A2) -> Box<dyn FnOnce(A3) -> Box<dyn FnOnce(A4) -> Box<dyn FnOnce(A5) -> Box<dyn FnOnce(A6) -> Box<dyn FnOnce(A7) -> Box<dyn FnOnce(A8) -> Box<dyn FnOnce(A9) -> Box<dyn FnOnce(A10) -> R + Send> + Send> + Send> + Send> + Send> + Send> + Send> + Send> + Send> {
    Box::new(move |a1| Box::new(move |a2| Box::new(move |a3| Box::new(move |a4| Box::new(move |a5| Box::new(move |a6| Box::new(move |a7| Box::new(move |a8| Box::new(move |a9| Box::new(move |a10| f(a1, a2, a3, a4, a5, a6, a7, a8, a9, a10)))))))))))
}

// --- Pipeline (curried decoder combinators) ---
// Curried by design — see README section A0. Pipeline-decoder helpers
// thread Box<dyn FnOnce> chains that Rust's static trait system can't
// express in tupled form. These are the ONLY functions in the runtime
// that intentionally return impl FnOnce.
// UNCURRIED: the codegen lowers `decode |> Pipeline.required "x" dec` to a
// direct 3-arg call `json_dec_p_required("x", dec, decode)` (the accumulator
// decoder is the pipe's left side, threaded as the last arg). Taking
// next_decoder as a normal parameter — rather than returning a closure over it
// — matches that shape (35-composite-generics; was a 2-arg curried fn → E0061).
pub fn json_dec_p_required<E: From<String> + 'static, T: 'static, F: 'static>(name: String, decoder: Decoder<E, T>, next_decoder: Decoder<E, Box<dyn FnOnce(T) -> F + Send>>) -> Decoder<E, F> {
    let n = name; let d = decoder; let nd = next_decoder;
    Box::new(move |v| {
        let field_val = match v.get(&n) { Some(f) => match d(f) { SkyResult::Ok(t) => t, _ => return json_dec_err_str("required decode error".into()) }, None => return json_dec_err_str(format!("missing required: {}", n)) };
        match nd(v) { SkyResult::Ok(f) => ok_res(f(field_val)), _ => json_dec_err_str("next decode error".into()) }
    })
}
pub fn json_dec_p_optional<E: From<String> + 'static, T: Clone + 'static + Send, F: 'static>(name: String, decoder: Decoder<E, T>, default: T, next_decoder: Decoder<E, Box<dyn FnOnce(T) -> F + Send>>) -> Decoder<E, F> {
    let n = name; let d = decoder; let nd = next_decoder; let def = default;
    Box::new(move |v| {
        let field_val = match v.get(&n) { Some(val) => match d(val) { SkyResult::Ok(t) => t, _ => def.clone() }, None => def.clone() };
        match nd(v) { SkyResult::Ok(f) => SkyResult::Ok(f(field_val)), _ => json_dec_err_str("opt next error".into()) }
    })
}

/// `JsonDec.Pipeline.custom decoder next` — like `required`, but the custom
/// `decoder` runs on the WHOLE value (not a single field) and supplies the next
/// pipeline argument. A custom decode failure aborts the pipeline.
pub fn json_dec_p_custom<E: From<String> + 'static, T: 'static, F: 'static>(decoder: Decoder<E, T>, next_decoder: Decoder<E, Box<dyn FnOnce(T) -> F + Send>>) -> Decoder<E, F> {
    let d = decoder; let nd = next_decoder;
    Box::new(move |v| {
        let t = match d(v) { SkyResult::Ok(t) => t, _ => return json_dec_err_str("custom decode error".into()) };
        match nd(v) { SkyResult::Ok(f) => SkyResult::Ok(f(t)), _ => json_dec_err_str("custom next error".into()) }
    })
}
