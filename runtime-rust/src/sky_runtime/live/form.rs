//! Form-data decoding for `Event::OnForm`.
//!
//! The browser posts a form submit as a `{name: value, …}` object; the event
//! handler turns it into a `FormData` (`HashMap<String, String>`). `decode_form`
//! narrows that into the typed Sky record `T` the `onSubmit` handler expects.

use crate::sky_runtime::live::html::FormData;

/// Decode browser form data into a typed Sky record `T`.
///
/// Form values are always strings; `T`'s fields are matched by name (Sky record
/// fields are camelCase, matching the HTML `name=` attributes the view emits).
/// A missing required field makes serde return an error → the caller dispatches
/// no Msg (the `OnForm` closure maps `Err` to `None`).
///
// FIXME(P-later): all-String form records only. A `T` with a numeric/bool field
// would reject `"42"`/`"true"` here; multi-value fields and #[serde(rename)] key
// normalisation are also out of P2 scope.
pub fn decode_form<T: serde::de::DeserializeOwned>(fd: FormData) -> Result<T, String> {
    let map: serde_json::Map<String, serde_json::Value> = fd
        .into_iter()
        .map(|(k, v)| (k, serde_json::Value::String(v)))
        .collect();
    serde_json::from_value(serde_json::Value::Object(map)).map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(serde::Deserialize, PartialEq, Debug)]
    struct Creds {
        email: String,
        password: String,
    }

    #[test]
    fn decode_form_ok_and_missing() {
        let mut fd = FormData::new();
        fd.insert("email".to_string(), "a@b.c".to_string());
        fd.insert("password".to_string(), "pw".to_string());
        let r: Result<Creds, String> = decode_form(fd);
        assert_eq!(r, Ok(Creds { email: "a@b.c".into(), password: "pw".into() }));

        let mut bad = FormData::new();
        bad.insert("email".to_string(), "a@b.c".to_string()); // missing password
        let r2: Result<Creds, String> = decode_form(bad);
        assert!(r2.is_err());
    }
}
