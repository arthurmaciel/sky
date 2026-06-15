# skyshop-rs wrapper crates

Three Rust shim crates the Sky→Rust `examples/rust/skyshop-rs` port consumes via
the auto-FFI. Stage 1 = STUB bodies (canned data, zero heavy deps) so the whole
app builds + boots fast on `--target rust`. Later stages swap each stub for the
real backend (firestore / async-stripe / rs-firebase-admin-sdk).

## Conventions (shared by all three)

- Every public fn is a TOTAL `fn(..) -> Result<_, String>` → the Sky auto-FFI
  classifies it `fallible` and binds it as a SYNC Sky `Result` (D1), not a Task.
- All `&str` params (Sky passes `&arg`); owned internally.
- D3 flat shapes: single doc → `HashMap<String,String>` (Sky `Dict String String`);
  query rows → `Vec<HashMap<String,String>>` (Sky `List (Dict String String)`).
- ERROR-SLOT WRINKLE: the Sky FFI `Err` payload is unusable, so the Sky side
  discards it (`Err _ ->`). Any status the app needs is encoded in the `Ok`
  payload under a `"_status"` key (`"ok"` | `"not_found"`), NOT the error string.
  Genuine backend failures still return `Err(String)` with the backend's
  `Display` embedded verbatim (so `wrapDbError` string-matching works later).

## Import names (Sky side)

| Crate | Sky module |
|-------|-----------|
| `sky-firestore-shim` | `Rust.Sky_firestore_shim` |
| `sky-stripe-shim` | `Rust.Sky_stripe_shim` |
| `sky-firebase-auth-shim` | `Rust.Sky_firebase_auth_shim` |

## `sky-firestore-shim`

| Fn | Sky signature | Stub returns |
|----|---------------|--------------|
| `fs_get_doc(collection, id)` | `String -> String -> Result String (Dict String String)` | `products` → matching canned product row (`_status=ok`) or `_status=not_found`; other collections → `{_status:ok, id}` |
| `fs_set_doc(collection, id, fields_json)` | `String -> String -> String -> Result String String` | echoes `id` (validates `fields_json` parses) |
| `fs_delete_doc(collection, id)` | `String -> String -> Result String String` | echoes `id` |
| `fs_query(collection)` | `String -> Result String (List (Dict String String))` | `products` → 6 canned rows; else `[]` |
| `fs_query_where(collection, field, op, value)` | `String -> String -> String -> String -> Result String (List (Dict String String))` | `products` filtered by exact-match on `field` (`published` always passes); else `[]` |
| `fs_query_where_order(collection, field, op, value, order_field, dir)` | `String -> String -> String -> String -> String -> String -> Result String (List (Dict String String))` | as `fs_query_where` + numeric-aware sort on `order_field`, `dir=desc` reverses |

Canned product row keys: `_status, id, title, summary, category, price_amount,
price_currency (GBP), price_discount (0), price_tax (0), stock, published (true)`.

## `sky-stripe-shim`

| Fn | Sky signature | Stub returns |
|----|---------------|--------------|
| `stripe_create_checkout_session(cart_id, customer_email, line_items_json, success_url, cancel_url)` | `String -> String -> String -> String -> String -> Result String (Dict String String)` | `{_status:ok, id: cs_test_stub_<cart>, url: <success_url>}` |
| `stripe_create_customer(email, name)` | `String -> String -> Result String String` | `cus_test_stub_<email-slug>` |
| `stripe_retrieve_session(session_id)` | `String -> Result String (Dict String String)` | always PAID+complete: `{_status, status=complete, payment_status=paid, customer_name, customer_email, customer_phone, shipping_line1, shipping_line2, shipping_city, shipping_country, shipping_postal_code}` |

`line_items_json` = flat JSON array of `{title,amount,quantity,currency}`.

## `sky-firebase-auth-shim`

| Fn | Sky signature | Stub returns |
|----|---------------|--------------|
| `fb_verify_id_token(id_token)` | `String -> Result String (Dict String String)` | empty token → `Err`; else `{_status:ok, uid: uid_stub_<hash>, email, name}` |
