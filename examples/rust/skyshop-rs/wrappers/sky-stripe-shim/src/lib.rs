//! sky-stripe-shim — STUB surface for the skyshop-rs Sky→Rust port (Stage 1).
//!
//! Full FFI surface the app's `Lib/Stripe.sky` needs, canned bodies, ZERO heavy
//! deps. Each public fn is a TOTAL `fn(..) -> Result<_, String>` binding as a
//! sync Sky `Result` (D1), flat D3 shape. All `&str` params.
//!
//! Stage 3 swaps these for the real `async-stripe` 1.0-rc.6 D2-bridge.

use std::collections::HashMap;

/// `stripe_create_checkout_session(cart_id, customer_email, line_items_json, success_url, cancel_url)
///   -> Result<HashMap<String,String>, String>`
/// Sky: `Result String (Dict String String)`. Returns `{ "id": ..., "url": ... }`.
/// `line_items_json` is a flat JSON array of `{title,amount,quantity,currency}`
/// objects (D3); the stub only validates it parses.
pub fn stripe_create_checkout_session(
    cart_id: &str,
    customer_email: &str,
    line_items_json: &str,
    success_url: &str,
    cancel_url: &str,
) -> Result<HashMap<String, String>, String> {
    let _email = customer_email.to_string();
    let _cancel = cancel_url.to_string();
    let _items: serde_json::Value =
        serde_json::from_str(line_items_json).map_err(|e| format!("bad line_items_json: {e}"))?;
    let session_id = format!("cs_test_stub_{cart_id}");
    let mut m = HashMap::new();
    m.insert("_status".to_string(), "ok".to_string());
    m.insert("id".to_string(), session_id.clone());
    // The success_url already encodes the order id; the stub URL points at it
    // so the Sky app's "redirect to Stripe" flow has a real same-origin target.
    m.insert("url".to_string(), success_url.to_string());
    Ok(m)
}

/// `stripe_create_customer(email, name) -> Result<String, String>`
/// Sky: `Result String String`. Returns the (stub) customer id.
pub fn stripe_create_customer(email: &str, name: &str) -> Result<String, String> {
    let _name = name.to_string();
    let slug: String = email
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '_' })
        .collect();
    Ok(format!("cus_test_stub_{slug}"))
}

/// `stripe_retrieve_session(session_id) -> Result<HashMap<String,String>, String>`
/// Sky: `Result String (Dict String String)`. Returns the flat PaymentStatus
/// shape the Sky app reads (status / payment_status / customer_* / shipping_*).
/// The stub always reports a PAID, COMPLETE session so the verify-payment flow
/// exercises end-to-end without Stripe.
pub fn stripe_retrieve_session(session_id: &str) -> Result<HashMap<String, String>, String> {
    let _sid = session_id.to_string();
    let mut m = HashMap::new();
    m.insert("_status".to_string(), "ok".to_string());
    m.insert("status".to_string(), "complete".to_string());
    m.insert("payment_status".to_string(), "paid".to_string());
    m.insert("customer_name".to_string(), "Test Buyer".to_string());
    m.insert("customer_email".to_string(), "buyer@example.com".to_string());
    m.insert("customer_phone".to_string(), "+440000000000".to_string());
    m.insert("shipping_line1".to_string(), "1 Test Street".to_string());
    m.insert("shipping_line2".to_string(), "".to_string());
    m.insert("shipping_city".to_string(), "London".to_string());
    m.insert("shipping_country".to_string(), "GB".to_string());
    m.insert("shipping_postal_code".to_string(), "EC1A 1BB".to_string());
    Ok(m)
}
