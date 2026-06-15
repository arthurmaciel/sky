//! Integration smoke test against `stripe-mock` (the official Stripe mock
//! server). Run with the mock listening on `STRIPE_API_BASE` and any
//! `sk_test_…` key in `STRIPE_API_KEY`:
//!
//!   stripe-mock -http-port 12111 &
//!   STRIPE_API_BASE=http://127.0.0.1:12111 STRIPE_API_KEY=sk_test_123 \
//!       cargo test --test mock -- --nocapture
//!
//! Skips itself (passes trivially) when `STRIPE_API_BASE` is unset so the
//! crate's `cargo test` stays green in a mock-free CI.

use sky_stripe_shim::{
    stripe_create_checkout_session, stripe_create_customer, stripe_retrieve_session,
};

fn mock_configured() -> bool {
    std::env::var("STRIPE_API_BASE").map(|v| !v.is_empty()).unwrap_or(false)
}

#[test]
fn create_customer_against_mock() {
    if !mock_configured() {
        eprintln!("STRIPE_API_BASE unset — skipping create_customer_against_mock");
        return;
    }
    let id = stripe_create_customer("buyer@example.com", "Test Buyer")
        .expect("create_customer should return Ok against stripe-mock");
    eprintln!("customer id = {id}");
    assert!(id.starts_with("cus_"), "expected a cus_ id, got {id:?}");
}

#[test]
fn create_checkout_session_against_mock() {
    if !mock_configured() {
        eprintln!("STRIPE_API_BASE unset — skipping create_checkout_session_against_mock");
        return;
    }
    let line_items = r#"[{"title":"Widget","amount":1999,"quantity":2,"currency":"usd"},
                         {"title":"Gadget","amount":500,"quantity":1,"currency":"usd"}]"#;
    let m = stripe_create_checkout_session(
        "cart_42",
        "buyer@example.com",
        line_items,
        "http://localhost:8000/order/cart_42/success",
        "http://localhost:8000/cart",
    )
    .expect("create_checkout_session should return Ok against stripe-mock");
    eprintln!("session = {m:?}");
    assert_eq!(m.get("_status").map(String::as_str), Some("ok"));
    let id = m.get("id").expect("id key present");
    assert!(id.starts_with("cs_"), "expected a cs_ id, got {id:?}");
    assert!(m.contains_key("url"), "url key present");
}

#[test]
fn retrieve_session_against_mock() {
    if !mock_configured() {
        eprintln!("STRIPE_API_BASE unset — skipping retrieve_session_against_mock");
        return;
    }
    // stripe-mock accepts any well-formed id and returns a canned session.
    let m = stripe_retrieve_session("cs_test_mocksession")
        .expect("retrieve_session should return Ok against stripe-mock");
    eprintln!("retrieved = {m:?}");
    assert_eq!(m.get("_status").map(String::as_str), Some("ok"));
    // The flat PaymentStatus shape the Sky side reads must all be present.
    for k in [
        "status",
        "payment_status",
        "customer_name",
        "customer_email",
        "customer_phone",
        "shipping_line1",
        "shipping_line2",
        "shipping_city",
        "shipping_country",
        "shipping_postal_code",
    ] {
        assert!(m.contains_key(k), "missing key {k} in {m:?}");
    }
}
