//! sky-stripe-shim — REAL `async-stripe` 1.0.0-rc.6-backed surface for the
//! skyshop-rs Sky→Rust port (Stage 3).
//!
//! This is the FULL FFI surface the app's `Lib/Stripe.sky` needs. Each public fn
//! is a TOTAL `fn(..) -> Result<_, String>` the Sky auto-FFI binds as a
//! synchronous Sky `Result` (D1), with the D3 flat shape:
//!
//!   * checkout session → `Result<HashMap<String,String>, String>` ({id,url,...})
//!   * customer         → `Result<String, String>`                  (the cus_ id)
//!   * retrieve session → `Result<HashMap<String,String>, String>` (status/...)
//!
//! ERROR-SLOT WRINKLE: the Sky side discards the `Err` payload (`Err _ ->`), so
//! any status the Sky code inspects is encoded IN the Ok payload via a
//! `"_status"` key (`"ok"`), the same convention the Stage-1 stub used and the
//! Stage-2 firestore shim mirrors. Real Stripe failures still go through
//! `Err(String)` with the `StripeError` `Display` embedded verbatim — but the
//! Sky side only string-matches the Ok-payload keys, never the Err slot.
//!
//! All `&str` params (Sky passes `&arg`); owned internally. Returned rows are
//! flat `HashMap<String,String>` — exactly the D3 flat-row shape the Sky
//! `Db.getField` accessor reads.
//!
//! ASYNC BRIDGE: async-stripe is async (tokio). Each op builds a future and
//! drives it to completion on a dedicated current-thread tokio runtime that
//! lives on a spawned OS thread — the same pattern as
//! `runtime-rust/src/sky_runtime/task.rs::block_on` and the Stage-2 firestore
//! shim. `.join()` converts any internal panic into an `Err(String)` so NO
//! panic escapes the FFI boundary.
//!
//! NO panic / NO unwrap reachable: every `.await?` / parse maps to `Err(String)`.
//!
//! CONFIG: secret key from `STRIPE_API_KEY` (test key `sk_test_…`). Base URL
//! overridable via `STRIPE_API_BASE` (point at stripe-mock, e.g.
//! `http://127.0.0.1:12111`) — wired through `ClientBuilder::url`.

use std::collections::HashMap;
use std::future::Future;
use std::str::FromStr;

use stripe::{Client, ClientBuilder, StripeError};
use stripe_checkout::checkout_session::{
    CreateCheckoutSession, CreateCheckoutSessionLineItems,
    CreateCheckoutSessionLineItemsPriceData, ProductData, RetrieveCheckoutSession,
};
use stripe_checkout::CheckoutSessionMode;
use stripe_core::customer::CreateCustomer;
use stripe_types::Currency;

/// One inline line item, as the Sky side serialises it
/// (`Lib/Stripe.sky::lineItemValue`): a flat object with a title, an integer
/// amount in the smallest currency unit (cents), an integer quantity, and a
/// lowercase ISO currency code.
#[derive(serde::Deserialize)]
struct LineItem {
    #[serde(default)]
    title: String,
    #[serde(default)]
    amount: i64,
    #[serde(default)]
    quantity: u64,
    #[serde(default)]
    currency: String,
}

/// Build a Stripe `Client` from the environment. Secret key from
/// `STRIPE_API_KEY`; optional `STRIPE_API_BASE` overrides the API base URL
/// (stripe-mock). A missing key is mapped to `Err(String)` — never a panic.
fn client() -> Result<Client, String> {
    let secret = std::env::var("STRIPE_API_KEY")
        .map_err(|_| "stripe shim: STRIPE_API_KEY is not set".to_string())?;
    let mut builder = ClientBuilder::new(secret);
    if let Ok(base) = std::env::var("STRIPE_API_BASE") {
        if !base.is_empty() {
            builder = builder.url(base);
        }
    }
    builder
        .build()
        .map_err(|e| format!("stripe shim: client build failed: {e}"))
}

/// Drive an async Stripe future to completion on a dedicated current-thread
/// tokio runtime, off the calling thread. A panic inside the future (or runtime)
/// is caught by `.join()` and mapped to `Err(String)` — nothing escapes.
///
/// Pattern mirrors `runtime-rust/src/sky_runtime/task.rs::block_on` and the
/// Stage-2 firestore shim.
fn block_on<T, F>(fut: F) -> Result<T, String>
where
    T: Send + 'static,
    F: Future<Output = Result<T, String>> + Send + 'static,
{
    let join = std::thread::spawn(move || {
        let rt = match tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
        {
            Ok(r) => r,
            Err(e) => return Err(format!("tokio runtime init failed: {e}")),
        };
        rt.block_on(fut)
    })
    .join();

    match join {
        Ok(r) => r,
        Err(_) => Err("stripe shim: async task panicked".to_string()),
    }
}

/// Embed a `StripeError` `Display` verbatim behind a labelled context, the same
/// way the firestore shim surfaces the firestore error `Display`.
fn stripe_err(ctx: &str, e: StripeError) -> String {
    format!("stripe shim: {ctx} failed: {e}")
}

// ──────────────────────────────────────────────────────────────────────────
// PUBLIC FFI SURFACE — signatures byte-identical to the Stage-1 stub.
// ──────────────────────────────────────────────────────────────────────────

/// `stripe_create_checkout_session(cart_id, customer_email, line_items_json, success_url, cancel_url)
///   -> Result<HashMap<String,String>, String>`
/// Sky: `Result String (Dict String String)`. Returns `{ "id": ..., "url": ... }`.
/// `line_items_json` is a flat JSON array of `{title,amount,quantity,currency}`
/// objects (D3); each becomes an inline `price_data` + `product_data` line item
/// (no pre-created Stripe Price needed).
pub fn stripe_create_checkout_session(
    cart_id: &str,
    customer_email: &str,
    line_items_json: &str,
    success_url: &str,
    cancel_url: &str,
) -> Result<HashMap<String, String>, String> {
    let cart_id = cart_id.to_string();
    let customer_email = customer_email.to_string();
    let success_url = success_url.to_string();
    let cancel_url = cancel_url.to_string();

    let parsed: Vec<LineItem> = serde_json::from_str(line_items_json)
        .map_err(|e| format!("stripe shim: bad line_items_json: {e}"))?;
    if parsed.is_empty() {
        return Err("stripe shim: line_items_json contained no items".to_string());
    }

    // Build inline line items: price_data carries the currency + unit_amount,
    // product_data carries the product name. `Currency::from_str` is infallible
    // (an unrecognised code falls through to `Currency::Unknown`, which Stripe
    // then rejects with a readable API error → mapped to Err, no panic).
    let line_items: Vec<CreateCheckoutSessionLineItems> = parsed
        .into_iter()
        .map(|li| {
            let currency = Currency::from_str(&li.currency)
                .unwrap_or(Currency::USD);
            let mut price_data = CreateCheckoutSessionLineItemsPriceData::new(currency);
            price_data.unit_amount = Some(li.amount);
            price_data.product_data = Some(ProductData::new(li.title));
            CreateCheckoutSessionLineItems {
                price_data: Some(price_data),
                quantity: Some(if li.quantity == 0 { 1 } else { li.quantity }),
                ..Default::default()
            }
        })
        .collect();

    block_on(async move {
        let client = client()?;
        let session = CreateCheckoutSession::new()
            .mode(CheckoutSessionMode::Payment)
            .customer_email(customer_email)
            .line_items(line_items)
            .success_url(success_url)
            .cancel_url(cancel_url)
            .send(&client)
            .await
            .map_err(|e| stripe_err(&format!("create_checkout_session for cart {cart_id}"), e))?;

        let mut m = HashMap::new();
        m.insert("_status".to_string(), "ok".to_string());
        m.insert("id".to_string(), session.id.to_string());
        // `url` is Option in the API (None for non-hosted ui_modes). For a
        // hosted Payment-mode session it is always populated; default to ""
        // rather than failing so the Sky `Db.getField "url"` accessor is total.
        m.insert("url".to_string(), session.url.unwrap_or_default());
        Ok(m)
    })
}

/// `stripe_create_customer(email, name) -> Result<String, String>`
/// Sky: `Result String String`. Returns the created customer id.
pub fn stripe_create_customer(email: &str, name: &str) -> Result<String, String> {
    let email = email.to_string();
    let name = name.to_string();
    block_on(async move {
        let client = client()?;
        let customer = CreateCustomer::new()
            .email(email)
            .name(name)
            .send(&client)
            .await
            .map_err(|e| stripe_err("create_customer", e))?;
        Ok(customer.id.to_string())
    })
}

/// `stripe_retrieve_session(session_id) -> Result<HashMap<String,String>, String>`
/// Sky: `Result String (Dict String String)`. Returns the flat PaymentStatus
/// shape the Sky app reads (status / payment_status / customer_* / shipping_*).
/// `status`/`payment_status` map to the lowercase Stripe strings the Sky side
/// compares against (`"complete"` / `"paid"`). Customer + shipping detail come
/// from the expanded `customer_details` block; absent fields default to "" so
/// every `Db.getField` accessor stays total.
pub fn stripe_retrieve_session(session_id: &str) -> Result<HashMap<String, String>, String> {
    let session_id = session_id.to_string();
    block_on(async move {
        let client = client()?;
        // `RetrieveCheckoutSession::new` takes `impl Into<CheckoutSessionId>`;
        // `String` satisfies it via the def_id `From<String>` impl.
        let session = RetrieveCheckoutSession::new(session_id.clone())
            .expand([String::from("customer_details")])
            .send(&client)
            .await
            .map_err(|e| stripe_err(&format!("retrieve_session {session_id}"), e))?;

        let mut m = HashMap::new();
        m.insert("_status".to_string(), "ok".to_string());

        // status: Option<CheckoutSessionStatus> → "complete" / "open" / "expired" / "".
        m.insert(
            "status".to_string(),
            session
                .status
                .as_ref()
                .map(|s| s.as_str().to_string())
                .unwrap_or_default(),
        );
        // payment_status: CheckoutSessionPaymentStatus → "paid" / "unpaid" / ...
        m.insert(
            "payment_status".to_string(),
            session.payment_status.as_str().to_string(),
        );

        // Customer + shipping details from the expanded customer_details block.
        let (name, custom_email, phone, line1, line2, city, country, postal) =
            match session.customer_details.as_ref() {
                Some(cd) => {
                    let (l1, l2, ci, co, pc) = match cd.address.as_ref() {
                        Some(a) => (
                            a.line1.clone().unwrap_or_default(),
                            a.line2.clone().unwrap_or_default(),
                            a.city.clone().unwrap_or_default(),
                            a.country.clone().unwrap_or_default(),
                            a.postal_code.clone().unwrap_or_default(),
                        ),
                        None => Default::default(),
                    };
                    (
                        cd.name.clone().unwrap_or_default(),
                        cd.email.clone().unwrap_or_default(),
                        cd.phone.clone().unwrap_or_default(),
                        l1,
                        l2,
                        ci,
                        co,
                        pc,
                    )
                }
                None => Default::default(),
            };

        // Fall back to the session-level customer_email when customer_details
        // has none (e.g. before the customer fills the hosted form).
        let final_email = if custom_email.is_empty() {
            session.customer_email.clone().unwrap_or_default()
        } else {
            custom_email
        };

        m.insert("customer_name".to_string(), name);
        m.insert("customer_email".to_string(), final_email);
        m.insert("customer_phone".to_string(), phone);
        m.insert("shipping_line1".to_string(), line1);
        m.insert("shipping_line2".to_string(), line2);
        m.insert("shipping_city".to_string(), city);
        m.insert("shipping_country".to_string(), country);
        m.insert("shipping_postal_code".to_string(), postal);
        Ok(m)
    })
}
