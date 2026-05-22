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
pub fn json_enc_null(_: ()) -> JsonVal { JsonVal::Null }
pub fn json_enc_list<A>(f: impl Fn(A) -> JsonVal, items: Vec<A>) -> JsonVal {
    JsonVal::Array(items.into_iter().map(|x| f(x)).collect())
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
    Box::new(move |v| match decoder(v) { SkyResult::Ok(a) => json_dec_ok(f(a)), SkyResult::Err(_) => json_dec_err_str("map error".into()) })
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

// --- Pipeline (curried decoder combinators) ---
// Curried by design — see README section A0. Pipeline-decoder helpers
// thread Box<dyn FnOnce> chains that Rust's static trait system can't
// express in tupled form. These are the ONLY functions in the runtime
// that intentionally return impl FnOnce.
pub fn json_dec_p_required<E: From<String> + 'static, T: 'static, F: 'static>(name: String, decoder: Decoder<E, T>) -> impl FnOnce(Decoder<E, Box<dyn FnOnce(T) -> F + Send>>) -> Decoder<E, F> {
    move |next_decoder| {
        let n = name; let d = decoder; let nd = next_decoder;
        Box::new(move |v| {
            let field_val = match v.get(&n) { Some(f) => match d(f) { SkyResult::Ok(t) => t, _ => return json_dec_err_str("required decode error".into()) }, None => return json_dec_err_str(format!("missing required: {}", n)) };
            match nd(v) { SkyResult::Ok(f) => ok_res(f(field_val)), _ => json_dec_err_str("next decode error".into()) }
        })
    }
}
pub fn json_dec_p_optional<E: From<String> + 'static, T: Clone + 'static + Send, F: 'static>(name: String, decoder: Decoder<E, T>, default: T) -> impl FnOnce(Decoder<E, Box<dyn FnOnce(T) -> F + Send>>) -> Decoder<E, F> {
    move |next_decoder| {
        let n = name; let d = decoder; let nd = next_decoder; let def = default;
        Box::new(move |v| {
            let field_val = match v.get(&n) { Some(val) => match d(val) { SkyResult::Ok(t) => t, _ => def.clone() }, None => def.clone() };
            match nd(v) { SkyResult::Ok(f) => SkyResult::Ok(f(field_val)), _ => json_dec_err_str("opt next error".into()) }
        })
    }
}
