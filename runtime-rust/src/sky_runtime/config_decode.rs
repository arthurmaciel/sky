#![allow(clippy::type_complexity)]
// Std.Config — typed TOML / YAML / JSON config decoders.
//
// Config reuses the JSON Decoder representation (`Decoder<E, T>` over a
// `serde_json::Value`): TOML and YAML are parsed into the same `Value`, then the
// decoder runs unchanged. The combinators (string / int / float / bool / field /
// at / list / map / andThen / succeed / fail) ARE the `json_dec_*` kernels — the
// Sky codegen maps `Config.*` straight onto them. Only the format front-ends,
// `nullable`, and `loadFromFile` live here, because Config's signatures put the
// source `String` FIRST (`decodeToml : String -> Decoder a -> Result Error a`),
// the opposite of `json_dec_decode_string`'s decoder-first argument order.
use super::*;
use super::json::{Decoder, JsonVal};
use std::future::ready;

// Config.nullable : Decoder a -> Decoder (Maybe a)
pub fn config_nullable<E: From<String> + 'static, T: 'static + Send>(
    decoder: Decoder<E, T>,
) -> Decoder<E, Option<T>> {
    Box::new(move |v| match v {
        JsonVal::Null => SkyResult::Ok(None),
        _ => match decoder(v) {
            SkyResult::Ok(t) => SkyResult::Ok(Some(t)),
            SkyResult::Err(e) => SkyResult::Err(e),
        },
    })
}

fn run_decoder<E: From<String> + 'static, T>(
    parsed: Result<JsonVal, String>,
    decoder: Decoder<E, T>,
) -> SkyResult<E, T> {
    match parsed {
        Ok(v) => decoder(&v),
        Err(e) => SkyResult::Err(str_err(&e)),
    }
}

// Config.decodeJson : String -> Decoder a -> Result Error a
pub fn config_decode_json<E: From<String> + 'static, T>(s: String, decoder: Decoder<E, T>) -> SkyResult<E, T> {
    run_decoder(serde_json::from_str(&s).map_err(|e| format!("json parse: {}", e)), decoder)
}

// Config.decodeToml : String -> Decoder a -> Result Error a
pub fn config_decode_toml<E: From<String> + 'static, T>(s: String, decoder: Decoder<E, T>) -> SkyResult<E, T> {
    run_decoder(toml::from_str(&s).map_err(|e| format!("toml parse: {}", e)), decoder)
}

// Config.decodeYaml : String -> Decoder a -> Result Error a
pub fn config_decode_yaml<E: From<String> + 'static, T>(s: String, decoder: Decoder<E, T>) -> SkyResult<E, T> {
    run_decoder(serde_yaml::from_str(&s).map_err(|e| format!("yaml parse: {}", e)), decoder)
}

// Config.loadFromFile : String -> Decoder a -> Task Error a
// Extension dispatch: .toml / .yaml|.yml / .json (default json).
pub fn config_load_from_file<E: From<String> + Send + 'static, T: Send + 'static>(
    path: String,
    decoder: Decoder<E, T>,
) -> SkyTask<E, T> {
    let contents = match std::fs::read_to_string(&path) {
        Ok(s) => s,
        Err(e) => return Box::pin(ready(SkyResult::Err(str_err(&format!("{}", e))))),
    };
    let lower = path.to_ascii_lowercase();
    let res = if lower.ends_with(".toml") {
        config_decode_toml(contents, decoder)
    } else if lower.ends_with(".yaml") || lower.ends_with(".yml") {
        config_decode_yaml(contents, decoder)
    } else {
        config_decode_json(contents, decoder)
    };
    Box::pin(ready(res))
}
