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
// Type-directed coercion via serde_urlencoded: a numeric/bool record field
// decodes `"42"`/`"true"` (the deserializer parses by the TARGET type), while a
// String field keeps the raw string. The old all-String serde_json path rejected
// any non-String field. We re-encode the `{name: value}` map to an x-www-form-
// urlencoded string (round-tripped through the same crate so values are escaped),
// then deserialize into `T`. A missing required field → `Err` → no Msg dispatched
// (the `OnForm` closure maps `Err` to `None`), unchanged.
pub fn decode_form<T: serde::de::DeserializeOwned>(fd: FormData) -> Result<T, String> {
    let pairs: Vec<(String, String)> = fd.into_iter().collect();
    let encoded = serde_urlencoded::to_string(&pairs).map_err(|e| e.to_string())?;
    serde_urlencoded::from_str::<T>(&encoded).map_err(|e| e.to_string())
}

/// `decode_form` + a warn on failure. The `OnForm` closure is synchronous and
/// returns `Option<M>`, so a decode failure must surface here (not via the
/// async logger) — we `eprintln!` a warn line (same plain style as the runtime
/// logger's error path) and return `None` so the live loop dispatches no Msg.
/// The codegen-emitted `onSubmit` closure calls this.
pub fn decode_form_or_warn<T: serde::de::DeserializeOwned>(fd: FormData) -> Option<T> {
    match decode_form::<T>(fd) {
        Ok(t) => Some(t),
        Err(e) => {
            eprintln!("[sky.live] form decode failed, dispatching no Msg: {e}");
            None
        }
    }
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
    fn decode_form_or_warn_some_and_none() {
        let mut fd = FormData::new();
        fd.insert("email".to_string(), "a@b.c".to_string());
        fd.insert("password".to_string(), "pw".to_string());
        let r: Option<Creds> = decode_form_or_warn(fd);
        assert_eq!(r, Some(Creds { email: "a@b.c".into(), password: "pw".into() }));

        let bad = FormData::new(); // missing both fields
        let r2: Option<Creds> = decode_form_or_warn(bad);
        assert_eq!(r2, None);
    }

    #[derive(serde::Deserialize, PartialEq, Debug)]
    struct Order {
        item: String,
        qty: i64,
        express: bool,
        price: f64,
    }

    #[test]
    fn decode_form_coerces_numeric_and_bool_fields() {
        // The old all-String serde_json path rejected these non-String fields.
        let mut fd = FormData::new();
        fd.insert("item".to_string(), "widget".to_string());
        fd.insert("qty".to_string(), "42".to_string());
        fd.insert("express".to_string(), "true".to_string());
        fd.insert("price".to_string(), "9.99".to_string());
        let r: Result<Order, String> = decode_form(fd);
        assert_eq!(r, Ok(Order { item: "widget".into(), qty: 42, express: true, price: 9.99 }));
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
