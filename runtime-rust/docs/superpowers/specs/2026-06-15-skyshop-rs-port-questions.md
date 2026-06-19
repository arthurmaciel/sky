# skyshop-rs port — open design questions (Planner-Asker)

Target: a NEW fork-local example at `examples/rust/skyshop-rs/`, a faithful 1:1
port of `examples/13-skyshop` (8,200-line Sky.Live e-commerce app) onto the
Sky→Rust backend (`sky build --target rust`), replacing the Go-FFI deps
(`cloud.google.com/go/firestore` + Firebase, `github.com/stripe/stripe-go/v84`)
with Rust crates (`firestore` 0.49, `async-stripe` 1.0.0-rc.6).

These are questions only — to be answered by the reasoner agents. Each cites a
concrete file/symbol and notes why it matters. The two reasoners should treat
the **hard contradictions surfaced in §0** as the first things to resolve,
because several downstream groups are blocked on them.

---

## 0. Blocking contradictions surfaced during investigation (resolve first)

0.1 **`[rust.shims]` does not exist.** The task brief twice references a
   `[rust.shims]` mechanism, but `runtime-rust/README.md` ("sky.toml Rust
   fields") states verbatim: *"There is no `[rust.shims]` section."* and
   `src/Sky/Sky/Toml/Rust.hs` (`RustDepSpec`, `parseRustDepSpec`) parses only
   `["rust.dependencies"]`. Is the brief stale, or is `[rust.shims]` a
   to-be-built mechanism that this port must add? If the latter, it is net-new
   compiler/Toml work — does that belong in this example's scope at all?

0.2 **`["rust.dependencies"]` has no local-path variant.** `RustDepSpec` in
   `src/Sky/Sky/Toml/Rust.hs` is exactly two constructors: `RustVersion`
   (crates.io) and `RustGitDep` (`git`/`rev`/`branch`/`tag`). There is **no
   `path = "..."`** variant. The doctrine answer for un-bindable framework
   crates (README "Known limitations" → *"Use a wrapper crate with
   owned/primitive signatures"*) implies a fork-local wrapper crate — which is a
   *local path* dependency. How does a fork-local wrapper crate get referenced
   from `examples/rust/skyshop-rs/sky.toml` today? Options to evaluate: (a) add a
   `RustPathDep` constructor to `Sky.Sky.Toml.Rust` + emit `path = …` in
   `emitCargoToml` (in-boundary: `src/Sky/Generate/Rust/`); (b) publish the
   wrapper to a git repo and use `RustGitDep`; (c) something else. Which is
   in-doctrine and minimal? This gates §2 and §3 entirely.

0.3 **Every existing `examples/rust`/`runtime-rust/tests/sky` proof binds ONE
   crates.io leaf crate directly** (`01-rand`…`49-bytes-core`; verified — none
   use git deps, none use a local wrapper crate, none bind an async/framework
   crate). There is **zero** precedent for the wrapper-crate pattern in-tree.
   Does the FFI inspector (`tools/sky-ffi-inspect-rs`, `src/Sky/Build/Rust/Ffi.hs`)
   even run against a local-path or git crate, and where does it cache the
   result (`.skycache/ffi/rust/<slug>.{kernel.json,skyi,_bindings.rs}`)? What is
   the `<slug>` for a non-crates.io dep?

0.4 **`13-skyshop` is explicitly classified `out` and Go-package FFI on
   `--target rust` is DOCUMENT_BLOCKED** (see
   `runtime-rust/scripts/equiv-classification.tsv`; the former
   `2026-06-15-go-package-rust-ffi-design.md` was pruned in the 2026-06-18
   docs overhaul — answers are in `2026-06-15-skyshop-rs-port-SYNTHESIS.md`).
   The port is a *new*
   Rust-native example, not a rebuild of the Go one — confirm the boundary rule
   "NEVER edit `examples/13-skyshop`" is understood and that nothing in the port
   re-introduces a `[go.dependencies]` table. Where does `skyshop-rs` get
   classified in `equiv-classification.tsv` (it has no Go counterpart to diff
   against → `out`?), and does the classification-coverage gate in
   `equiv-sweep.sh` require an entry?

0.5 **Is "faithful 1:1" even the right bar given build-only verification?**
   Running needs live GCP/Firestore + Stripe creds. Should the port aim for
   byte-identical behaviour (unverifiable here) or build-green + structurally-
   faithful with documented runtime-only gaps? This frames every fidelity
   decision in §1.

---

## 1. Scope & fidelity — 1:1 vs faithfully approximated/stubbed

1.1 The original is 8,200 lines across 19 `.sky` files. Which files port
   *verbatim* (pure Sky, no FFI: `State.sky`, `Lib/Translation.sky`,
   `Lib/Money.sky`, `Lib/Cart.sky`, `Page/*`, `Ui/Layout.sky`) vs which require
   rewrite of their FFI surface (`Lib/Db.sky`, `Lib/Stripe.sky`, `Lib/Auth.sky`,
   `Lib/OAuth.sky`, `Lib/Notify.sky`)? Why it matters: scoping the rewrite vs the
   copy.

1.2 `Lib/Translation.sky` (781 lines, pure `case` on string keys, EN/中文) and
   `Lib/Money.sky` look fully portable. Confirm they have zero FFI / zero
   Std.Ui dependence and port unchanged. Are there any `Std.*` modules they use
   that the Rust backend doesn't yet surface?

1.3 The view layer uses `Std.Html` + the `Tailwind` package
   (`import Tailwind`, `import Tailwind.Responsive`) from
   `github.com/anzellai/sky-tailwind` declared under `[dependencies]`
   (a *Sky* package, not Go-FFI). Is `sky-tailwind` pure Sky (portable to
   `--target rust` as-is), or does it carry any Go-FFI / kernel that the Rust
   backend lacks? Where is it fetched and how does a `[dependencies]` Sky package
   resolve under `--target rust`? Why it matters: the entire 1,217-line
   `Ui/Layout.sky` + every `Page/*` view depends on it. (Note: `.skydeps` was
   wiped locally, so the package source wasn't inspectable in this pass.)

1.4 The brief's group (9) presumes Std.Ui; but skyshop uses `Std.Html`+Tailwind,
   NOT `Std.Ui`. Does that *help* (raw HTML is simpler) or *hurt* (Tailwind
   package portability is now the risk)? Which Std.Html / Std.Html.Events /
   Std.Css primitives does `Ui/Layout.sky` use, and are all of them rendered
   identically by the Rust Sky.Live renderer (README claims byte-identical VNode
   diff + reuses Go client JS)?

1.5 `Lib/Notify.sky` imports `Net.Http as Http`, `Strings as GoStrings`,
   `Io as Io` (Go stdlib packages) + `Github.Com.Google.Uuid` — but its
   `sendEmailNotification` is a *stub* that only logs "Would send email". Are
   those Go imports actually called anywhere (dead imports), or load-bearing? If
   dead, the port drops them; if live, what replaces them (Sky's `Http.*`
   kernel? `Std.Email`? `Sky.Core.Uuid`)? Why it matters: a dead `[go.dependencies]`
   import still triggers the E1001 refusal on `--target rust`.

1.6 What is the acceptance artifact for "done"? Build-green (`sky build --target
   rust` + `cargo build` exit 0) only, or also a boot-and-curl smoke (the
   run-sweep shape) for the static/non-credentialed pages (Home with no
   products, Privacy, Terms, 404)? Can the home page render with an
   *unconfigured* Firestore (the original logs an error and shows empty
   products) — i.e. is there a credential-free happy path to smoke-test?

1.7 The original ships `static/` (favicons, icons) + `e2e.json` (a single
   `GET /` expecting 200, asserting no `panic:`/`UNIQUE constraint`). Should the
   port carry an analogous `e2e.json`/static set, and does the Rust Sky.Live
   honour `[live] static`?

---

## 2. Wrapper crates — firestore-shim & stripe-shim

2.1 **Crate layout.** Where do the two wrapper crates physically live? Under
   `examples/rust/skyshop-rs/` (e.g. `firestore-shim/`, `stripe-shim/` as
   sibling crates) or somewhere central? The modification boundary allows
   `examples/rust/`. How are they referenced from `sky.toml` given §0.2 (no
   path-dep support)?

2.2 **Async→sync bridging — tokio runtime ownership.** Both `firestore` (0.49)
   and `async-stripe` (1.0) are `async`. Sky FFI binds *synchronous* `fn(...) ->
   Result<String, E>` signatures (the inspector drops async-complex returns).
   The wrapper must own a tokio runtime and `block_on` each call. But the
   generated Sky.Live app *already* runs inside a tokio runtime (axum/hyper) —
   calling `Runtime::block_on` from within an async context **panics**
   ("Cannot start a runtime from within a runtime"), violating the no-panic
   existential. How is this resolved? Candidate approaches to evaluate:
   (a) `tokio::task::block_in_place` + a handle to the ambient runtime;
   (b) a dedicated worker thread + `std::sync::mpsc` to a separate runtime;
   (c) `futures::executor::block_on` on a current-thread runtime off the axum
   threadpool. Which is panic-free under Sky.Live's runtime AND under Sky.Cli
   (no ambient runtime)? Why it matters: this is THE central technical risk.

2.3 **Where does the wrapper get called from in Sky?** `Lib/Db.sky` /
   `Lib/Stripe.sky` are imported by `update`/`init` which the Rust backend runs
   as `SkyTask`/async. Are the wrapper calls `pure`/`fallible`/`effectful` from
   the FFI inspector's POV (drives whether the body is `Box::pin(async move{})`
   per README "Effect drives the body")? Since they do real I/O they must be
   `Task Error a` — but the original `Lib/Db.sky` returns *bare* `Result Error a`
   (e.g. `getDoc : ... -> Result Error (Maybe ...)`), not `Task`. Does the Rust
   FFI surface a blocking call as a non-Task `Result`? Does that even type-check
   against the original Sky call sites which case-match `Result` synchronously
   (e.g. `case Firestore.queryDocuments q ctx of Err e -> …`)?

2.4 **Error mapping.** The original bridges raw gRPC/Stripe error *strings* into
   typed `Error` via `Lib.Db.wrapDbError` (string-matching "PermissionDenied",
   "NotFound", "Unavailable", …) and `Error.network`/`Error.io`. The Rust
   wrapper returns `Result<String, SkyError>` where `SkyError = String` (README
   "Error type"). Does the wrapper preserve enough of the original error text so
   `wrapDbError`'s `String.contains` heuristics still classify correctly? Or do
   those heuristics need re-porting against `firestore`/`async-stripe` error
   shapes?

2.5 **JSON marshalling.** The wrapper must turn `firestore` documents
   (`serde`-deserialized maps) and `async-stripe` objects (Checkout Session,
   Customer) into plain `String`/JSON the Sky side decodes. The original Sky uses
   `Dict String String` rows everywhere (`snapshotToDict` flattens via
   `Fmt.sprint`). Does the wrapper return a JSON string that Sky decodes with
   `Sky.Core.Json.Decode`? CRITICAL: `runtime-rust/CLAUDE.md` flags the JSON
   *pipeline* decoder (`json_dec_p_required`/`optional` + `json_dec_succeed`)
   as a known-unsupported `Box<dyn FnOnce>`/`Clone`/`Send` failure on Rust. Does
   the port's decode path avoid the pipeline combinators, or hit that wall? Or
   does the wrapper instead return a pre-flattened `Dict String String`-shaped
   structure (`HashMap<String,String>` → Sky `Dict String String`) so no Sky-side
   JSON decode is needed?

2.6 **`mergeAll` / `Set with merge` semantics.** `Lib/Db.setDoc` uses Firestore
   `mergeAll` (`Firestore.mergeAll ()`, `documentRefSet docRef ctx goMap
   mergeOpts`) — an upsert-with-merge. Does the `firestore` (0.49) crate's
   builder API (`db.fluent().update().fields(...).merge_all()` or similar)
   expose merge semantics, and what synchronous wrapper signature captures it?
   `Auth.findOrCreateUser` *relies* on merge to preserve phone/address fields.

2.7 **Auth/credentials handling.** `firestore` (0.49) takes a `FirestoreDb`
   constructed from a project id + ADC/service-account; the original reads
   `GOOGLE_CLOUD_PROJECT` and (for Firebase) `GOOGLE_APPLICATION_CREDENTIALS`
   (a `firebaseadminsdk.json`). Does the wrapper construct the `FirestoreDb`
   once (lazily, like the original's `getFirestoreClient`/`ctx =
   Context.background ()`) and cache it, or per-call? Where does the cached
   client live without a `Box<dyn Any>` global (no-Any invariant)? A `OnceCell<FirestoreDb>`?

2.8 **Stripe key + idempotency.** `Lib/Stripe.initStripe` does
   `Stripe.setKey key` (global SDK key) reading `STRIPE_API_KEY`.
   `async-stripe` 1.0 uses a per-`Client` secret key (no global setKey). The
   wrapper must thread a `Client::new(secret)`; where is that constructed/cached?
   Does the port preserve the "apiKey == \"\" → Err invalidInput" early-out
   (`createCheckoutSession`)?

2.9 **Wrapper API granularity.** The original `Lib/Stripe.sky` makes ~30 distinct
   FFI calls (newCustomerParams, customerParamsSetEmail, Customer.list,
   iterNext, iterCustomer, newCheckoutSessionParams, +N setters, Session.new,
   Session.get, checkoutSessionStatus, …). Should the wrapper mirror that
   fine-grained builder surface 1:1 (so `Lib/Stripe.sky` ports near-verbatim),
   or collapse to a few coarse calls (`stripe_create_checkout_session(json) ->
   Result<String,E>`, `stripe_verify_session(id) -> Result<String,E>`) that
   require rewriting `Lib/Stripe.sky`? Trade-off: builder-setter FFI is README-
   supported ("FFI owned-threading builder setters") for *pure-Rust* builders,
   but `async-stripe`'s builders are generic/async — likely NOT auto-bindable,
   forcing the coarse approach. Confirm.

2.10 **Same question for Firestore.** Mirror the ~15 fine-grained
   `Firestore.*` calls (clientCollection, collectionRefDoc, documentRefGet,
   documentSnapshotData, collectionRefWhere, queryOrderBy, asc/desc,
   documentIteratorGetAll, …) or collapse to coarse `firestore_get(collection,
   id) -> Result<Maybe<String>,E>`, `firestore_query_where(...)`,
   `firestore_set(...)`, `firestore_delete(...)`, `firestore_query_where_order(...)`?
   The coarse set maps cleanly onto `Lib/Db.sky`'s 7 exported ops
   (`getDoc`/`setDoc`/`queryDocs`/`queryWhere`/`queryWhereOrder`/`deleteDoc` +
   accessors). Which is less total work AND keeps `Page/*` unchanged?

2.11 **Iterator translation.** `Lib/Db.getAllSnapshots` consumes a Firestore
   *iterator* (`documentIteratorGetAll`), and `Lib/Stripe.getOrCreateCustomer`
   pages a Stripe customer *iterator* (`iterNext`/`iterCustomer`). FFI cannot
   bind borrowed/streaming iterators. Must the wrapper fully materialize each
   query into an owned `Vec`/JSON-array inside the sync boundary? Confirm no
   lazy iterator crosses the FFI line.

---

## 3. FFI binding — how Sky calls the wrapper

3.1 **Module naming.** A Go dep `cloud.google.com/go/firestore` mapped to Sky
   module `Cloud.Google.Com.Go.Firestore`. For a Rust wrapper crate named e.g.
   `firestore_shim`, what Sky module name does the inspector produce, and what is
   the `import` line in the ported `Lib/Db.sky`? (The inspector's naming rules:
   crate → PascalCase module per README's `Naming` notes.) Confirm the ported
   `import` lines.

3.2 **`["rust.dependencies"]` vs the (nonexistent) `[rust.shims]`.** Given §0.1,
   the wrapper is added via `["rust.dependencies"]` only. Write the exact
   `sky.toml` stanza assuming (a) the wrapper is a git dep and (b) a hypothetical
   path dep. Which is buildable today?

3.3 **`.skyi` / `_bindings.rs` path.** Confirm the wrapper's generated artifacts
   land at `.skycache/ffi/rust/<slug>.{kernel.json,skyi,_bindings.rs}` and that
   `sky install` / `sky build --target rust` regenerate them (vs the Go path at
   `.skycache/ffi/` root). What triggers re-inspection when the wrapper's source
   changes (fingerprint? mtime?)?

3.4 **Coercion of `Result`/`String`/`List`/`Maybe`.** Per README "FFI codegen
   type-coercion rules": a wrapper `fn(collection: String, id: String) ->
   Result<Option<String>, String>` should surface in Sky as
   `String -> String -> Result Error (Maybe String)`. Confirm the `Option<T>` →
   `SkyMaybe<T>` return lift and the `Result<_, String>` → `Result Error _`
   mapping hold for the wrapper signatures the port needs. Any signature shape
   that the coercion table does NOT cover (e.g. `Result<Vec<HashMap<String,
   String>>, String>` for a query returning rows)? Is `Vec<HashMap<String,
   String>>` → `List (Dict String String)` a supported return coercion?

3.5 **Effect classification of wrapper fns.** How does the inspector decide
   `pure`/`fallible`/`effectful` for the wrapper functions (it can't see the
   internal `block_on`)? If it marks them non-`effectful`, the call site won't be
   `Box::pin(async)` — is that correct given the wrapper is internally blocking?
   Does the original Sky code's *synchronous* `Result` consumption
   (`case Firestore.queryDocuments q ctx of …`) require the binding be a plain
   `fn -> Result`, NOT a `Task`? Reconcile with 2.3.

3.6 **`ctx`/`Context.background ()` and `js "nil"`.** The original threads a Go
   `context.Context` (`Context.background ()`) and uses `js "nil"` literals
   (`Session.get sessionId (js "nil")`, `Firebase.newApp ctx (js "nil") opts`).
   Neither concept exists in Rust FFI. Confirm these vanish in the port (the
   wrapper owns context internally) and that `js "nil"` has no Rust-backend
   meaning (does the Rust codegen even support the `js` builtin?).

---

## 4. Firestore data model

4.1 **Collections.** Enumerate every Firestore collection the app touches:
   from grep — `products`, `users`, `orders`, `carts`, `cart_items`,
   `order_items`, `notifications`, `product_images` (verify against
   `Lib/Products.sky`, `Lib/Cart.sky`, `Lib/Stripe.sky`, `Lib/Notify.sky`,
   `Lib/Auth.sky`). Does the wrapper need per-collection typed structs (serde),
   or one generic `HashMap<String, Value>` document shape? Why it matters: the
   `firestore` crate is serde-generic — a fully generic document avoids N structs
   but needs `serde_json::Value` ↔ flat-String coercion.

4.2 **Query translation.** The Sky surface is `queryWhere collection field op
   value` (op is a string `"=="`) and `queryWhereOrder ... orderField dir`
   (dir `"asc"`/`"desc"`). The original maps these to
   `collectionRefWhere` + `queryOrderBy` + `asc()/desc()`. How does the
   `firestore` (0.49) fluent query builder express `where field == value` and
   `order_by`? Which `op` strings does the app actually use (grep shows only
   `"=="`)? Does the wrapper need to support other operators, or is `==` + order
   the whole surface?

4.3 **Value typing in queries.** `queryWhere "published" "==" True` passes a
   *Bool*; `queryWhere "order_id" "==" orderId` passes a *String*. The Sky
   binding `collectionRefWhere colRef field op value` takes a polymorphic
   `value`. The Rust wrapper signature must be monomorphic. How is the
   heterogeneous query value typed across the FFI — always-String (and the
   wrapper parses)? A `SqlValue`-style ADT? Why it matters: `published == True`
   (Bool) vs `order_id == "x"` (String) cannot both be `String` params without
   loss.

4.4 **`snapshotToDict` flattening.** The original flattens every field to String
   via `Fmt.sprint [val]` (so an Int field `stock` becomes `"5"`, a Bool becomes
   the Go `%v` form). Does the wrapper replicate this exact stringification
   (e.g. Firestore integer → `"5"`, bool → `"true"`/`"false"`) so downstream
   `Db.getInt`/`Db.getBool` parse identically? Note `Db.getBool` checks
   `val == "1" || val == "true"` — the wrapper's bool stringification must match.

4.5 **Document id injection.** `snapshotToDict` inserts `"id"` = the doc ref id
   (`documentRefID`). Confirm the wrapper returns the doc id alongside each
   row's fields (the Sky code does `Dict.get "id" row` extensively).

4.6 **Writes — `Dict String String` → Firestore.** `setDoc` writes a
   `Dict String String` (all values pre-stringified by `intVal`/`boolVal`/
   `floatVal`). Does the wrapper write everything back as Firestore *strings*
   (losing native int/bool typing in Firestore), matching the Go original's
   behaviour? Or does it re-infer types? Fidelity vs correctness: if the original
   stores `"5"` as a string and queries `published == True` (Bool), there's an
   existing type mismatch in the Go app worth replicating exactly vs fixing.

---

## 5. Auth / Firebase / OAuth

5.1 **No Rust Firebase Admin SDK.** `Lib/Auth.sky` verifies Firebase ID tokens
   via `FirebaseAuth.clientVerifyIDToken` (Firebase Admin SDK, Go). There is no
   mature equivalent in `async-stripe`/`firestore`; Firebase Admin token
   verification in Rust means verifying a Google-signed JWT manually (fetch
   Google's public certs, verify RS256, check `aud`/`iss`/`exp`). Does the port:
   (a) build a third wrapper crate over a JWT+JWKS library; (b) use Sky's own
   `Sky.Core.Jwt` (RS256 supported per stdlib) + an HTTP fetch of Google certs;
   (c) stub auth (build-green, runtime-deferred); (d) something else? Why it
   matters: `verifyToken` is the entire sign-in path; admin gating
   (`isAdmin`, `adminEmails`) depends on the verified email.

5.2 **`Sky.Core.Jwt` RS256 fit.** If 5.1(b): the README "Stdlib runtime" table
   shows Jwt `encode`/`decode` HS256+RS256 *shipped* on Rust. Can it verify a
   Firebase ID token (RS256, key rotation via `kid` → JWKS)? Does `Jwt.decode`
   take a public key, and does the port need to fetch+cache Google's JWKS (an
   HTTP call via Sky's `Http.*` kernel)?

5.3 **Client-side Firebase JS (`Lib/OAuth.sky`).** `firebaseAuthScript`
   injects the Firebase JS SDK (`firebase-app-compat.js` +
   `firebase-auth-compat.js`) and `signInWithPopup`, then posts the ID token via
   `window.__sky_send('FirebaseAuth', [token])`. This is a raw `<script>`
   string injected into `Ui/Layout.sky`. Does the Rust Sky.Live renderer inject
   raw `<script>` identically (README: "`__skyReviveScripts` for late-injected
   `<script>` tags")? Does `window.__sky_send` exist in the Rust backend's
   client JS (it "reuses the Go client JS")? Confirm the wire-event path
   `FirebaseAuth String` Msg round-trips. This is the one piece that needs NO
   Rust change if the client JS is shared — verify.

5.4 **Session identity.** The app stores a `sky_user` cookie (UID) and reloads
   the user on `init` via the cookie. The Rust backend's `init` uses a typed
   `LiveReq` record (path/query/method/params/headers/**cookies**), NOT a
   heterogeneous Dict. The original `init req` does `Dict.get "cookies" req` then
   `Dict.get "sky_user" cookies` — treating `req` as a `Dict`. **This will not
   type-check on the Rust backend** (`LiveReq.cookies : Dict String String`, and
   `req` is a record, not a Dict). How does the port rewrite `init` to read
   `req.cookies` (typed) — and does that diverge from the Go source enough to
   matter for "1:1"? Cite README "Sky.Live `init` request — typed-record
   `LiveReq`". Why it matters: `init` is the first thing that runs; it must
   compile.

5.5 **`getSessionUser` reads Firestore.** It calls `Db.getDoc "users" userId`
   synchronously inside `init`. With the async wrapper (§2.2), can `init` perform
   a blocking Firestore read at session-bootstrap time without deadlocking the
   axum runtime? Same block_in_place question as 2.2, now in `init`.

---

## 6. Stripe checkout

6.1 **Checkout Session creation.** Map `createCheckoutSession` (cartId, items,
   userId, userName, userEmail, remarks) onto `async-stripe` 1.0's
   `CheckoutSession::create` with `CreateCheckoutSession` params: mode=payment,
   success/cancel URLs, customer id, line_items (price_data with product_data
   name + unit_amount + currency), shipping_address_collection,
   phone_number_collection. Does `async-stripe` 1.0.0-rc.6 expose all these, and
   what's the coarse wrapper signature (likely one `stripe_create_checkout(json)
   -> Result<String,E>` returning `{id, url}` JSON, since the fine-grained
   builder setters won't auto-FFI)?

6.2 **Customer get-or-create.** `getOrCreateCustomer` lists customers by email,
   reuses or creates. Map onto `Customer::list` (filter email) + `Customer::create`.
   Coarse wrapper `stripe_get_or_create_customer(name, email) ->
   Result<String,E>` returning the customer id?

6.3 **Session verify / return flow.** `verifyPayment orderId` → `verifyStripeSession`
   retrieves the session (`Session.get`), checks
   `status == "complete" && payment_status == "paid"`, then extracts
   customer_details (name/email/phone) + collected_information shipping address.
   Map onto `CheckoutSession::retrieve`. Which fields does `async-stripe` 1.0
   expose for `customer_details` and `collected_information.shipping_details`?
   The wrapper must surface all 10 `PaymentStatus` fields (status, paymentStatus,
   customerName/Email/Phone, shipping line1/line2/city/country/postalCode). Coarse
   `stripe_verify_session(id) -> Result<String,E>` returning that 10-field JSON?

6.4 **Webhook.** `.env.example` has `STRIPE_WEBHOOK_SECRET` but the success flow
   is *return-URL polling* (`/order/:id/success` → `verifyPayment`), not a
   webhook endpoint (grep confirms no webhook route in `routes`). Confirm the
   port has NO webhook to build — the success-URL verify is the whole flow. Why
   it matters: avoids scoping a webhook handler that doesn't exist.

6.5 **Test mode / dry-run.** Build verification can't hit Stripe. Is there a
   dry-run env (the original early-outs when `STRIPE_API_KEY == ""`) that keeps
   the checkout path build-green and runtime-safe (returns `Err invalidInput`)?
   Should the wrapper itself short-circuit when the key is empty so a creds-less
   boot doesn't panic in `block_on`?

6.6 **`deductStock` / `notifyOrderPlaced`.** Post-payment, `Lib/Stripe.deductStock`
   reads `order_items`/`cart_items` and writes products' `stock` back to
   Firestore (more wrapper calls). `Lib/Notify.notifyOrderPlaced` writes a
   `notifications` doc + (stubbed) email. Confirm these port via the same coarse
   Firestore wrapper and need no new surface.

---

## 7. i18n

7.1 `Lib/Translation.sky` (`t`/`tCategory`/`tCartState`/`tCurrency`/
   `tCurrencySymbol`) is pure `case`-on-string, EN + 中文 (`lang == "zh"`).
   Confirm it ports byte-for-byte. Any non-ASCII (Chinese) string-literal codegen
   concern on the Rust backend (UTF-8 string literals in generated Rust)? Cite
   the README "Bytes non-ASCII *text*" limitation — does that affect *string
   literals* (no, that's Bytes-encoding) or only `Bytes` base64/hex round-trips?
   Likely a non-issue but worth confirming Chinese literals emit correctly.

7.2 Language is held in `Model.lang` and toggled via `SetLang String` Msg — no
   FFI. Confirm nothing i18n-related touches the FFI boundary.

---

## 8. Admin panel

8.1 `Page/Admin.sky` (819 lines) + admin routes (`/admin/products`,
   `/admin/orders`, edit/new). Admin gating is `Auth.isAdmin user`
   (`Db.getBool "is_admin"`). With auth stubbed/deferred (§5.1), does the admin
   panel still *build* (it's pure view + Msg dispatch), and is there a way to
   reach it in a creds-less smoke test, or is it simply build-only?

8.2 Image upload (`UploadImage`, `UpdateImageData String`, `addProductImage`).
   The original stores image data (base64?) in Firestore `product_images`. Does
   this use any Std.Ui file-upload primitive or just a base64 string field +
   Firestore write? Confirm it's pure-Sky + the Firestore wrapper, no new FFI.
   Check `[live] maxBodyBytes` needs (large base64 images).

8.3 Admin order-state transitions (`UpdateOrderState`, `allCartStates`) — pure
   Firestore writes. Confirm no extra surface.

---

## 9. UI / Std.Html + Tailwind rendering parity

9.1 (Supersedes the brief's Std.Ui framing — skyshop uses `Std.Html`+Tailwind.)
   Does the Rust Sky.Live renderer produce byte-identical HTML for the
   `Std.Html`/`Std.Html.Attributes`/`Std.Html.Events`/`Std.Css` primitives that
   `Ui/Layout.sky` + `Page/*` use? README claims "faithful VNode diff" + "byte-
   identical render" but lists Std.Ui parity, not raw Std.Html. Enumerate the
   primitives used (grep `Html.node`, `Attr.*`, `Css.*`, event handlers) and
   flag any the Rust backend doesn't render.

9.2 `Tailwind` + `Tailwind.Responsive` packages: do they emit Sky `Std.Html`
   attribute values (pure, portable) or do they carry runtime/Go-FFI? If pure,
   they ride along under `--target rust` unchanged. If not, this is a blocker.
   (Couldn't inspect — `.skydeps` was wiped.)

9.3 Wire-event arg shapes: the app uses `onClick`, `onSubmit` (forms with typed
   records?), `onInput`, radio/select. Does the Rust backend decode these
   identically (typed form decode, the `decode_form` peephole)? The auth flow
   relies on `__sky_send('FirebaseAuth', [token])` — a *custom* JS-originated Msg,
   not a standard DOM event. Does the Rust client JS support arbitrary
   `__sky_send(MsgName, [args])`?

9.4 `Ui/Layout.sky` injects global `<style>` + the Firebase `<script>`. Confirm
   the Rust renderer's `<head>`/`<script>` injection path matches (the original
   doesn't use `Std.Live.Head` — it inlines via the layout). Any ordering /
   escaping divergence?

---

## 10. Session store / `[live]` config

10.1 The original `[live]` uses `store = "sqlite"`, `storePath =
   "skyshop_sessions.db"`, plus a `static` dir. README confirms Rust supports
   memory/sqlite/postgres/redis session stores. Confirm `sqlite` store +
   `storePath` + `static` all work on `--target rust`. The Cargo feature wiring
   (`sqlite` → `db` feature) — does a Sky.Live sqlite *session store* pull the
   same sqlx as the (now-absent) `Std.Db`? Note: the port replaces `Std.Db`-Firestore
   with the Firestore wrapper, so the ONLY sqlite use is the session store — does
   that still enable the `db`/sqlx feature correctly?

10.2 `init` is per-session; the original pre-loads the user from the `sky_user`
   cookie. Confirm the Rust `LiveReq.cookies` path (§5.4) gives the same
   first-render user load without an extra round-trip.

10.3 Session TTL (`SKY_LIVE_TTL=86400` in `.env.example`) — honoured on Rust?

---

## 11. Env / secrets / config

11.1 Env vars the app reads (grep `System.getenv`): `GOOGLE_CLOUD_PROJECT`,
   `GOOGLE_APPLICATION_CREDENTIALS`, `STRIPE_API_KEY`, `DOMAIN`,
   `SKY_LIVE_PORT`, `ADMIN_EMAILS`, `ENV`, `FIREBASE_API_KEY`, `AUTH_DOMAIN`,
   `SMTP_*`/`NOTIFY_TO`. Confirm `System.getenv` (Task) + `System.getenvOr`
   work on the Rust backend (README "System.* getenv returned bare String" was
   fixed per MEMORY). Does the wrapper read GCP/Stripe creds from the *same* env
   vars, or does it need its own (e.g. `firestore` crate reads
   `GOOGLE_APPLICATION_CREDENTIALS`/ADC natively)?

11.2 `.env` loading: the original relies on Sky.Live runtime loading `.env`
   before `init`. Does the Rust Sky.Live load `.env` at the same point (so a
   lazily-constructed wrapper client sees the vars)? Cite the original's comment
   in `Lib/Auth.getAuthClient` ("after .env has been loaded by the Sky.Live
   runtime").

11.3 Should the port ship its own `.env.example` (dropping SMTP if Notify is
   stubbed, adapting credential vars to the Rust crates' expectations)?

---

## 12. Build & verification strategy

12.1 **Staging order.** What's the incremental build order that keeps it green at
   each step? Proposed: (1) port pure modules (State, Translation, Money, Cart,
   Products-sans-FFI) + a *stub* Db wrapper returning empty/Err → get the full
   app building with no live deps; (2) add the firestore-shim crate + wire real
   reads; (3) add the stripe-shim crate; (4) auth. Confirm or revise.

12.2 **Stub-first viability.** Can the firestore/stripe wrappers ship a
   build-green *stub* implementation first (signatures real, bodies return
   `Err("not configured")` / empty) so the 8,200-line Sky port compiles before
   the async crates are wired? This de-risks the §2.2 block_on problem from the
   Sky-compile problem.

12.3 **What proves "done"?** `sky build src/Main.sky --target rust` exit 0 +
   `cd sky-out/Rust && cargo build` exit 0. Plus optionally: boot the binary,
   `curl localhost:<port>/` → 200 with no panic in stderr (creds-less). Is the
   creds-less boot even reachable (does a lazy wrapper avoid constructing the
   Firestore client until first query)?

12.4 **Disk/build hygiene.** Per `runtime-rust/CLAUDE.md`: shared
   `CARGO_TARGET_DIR`, sccache, symlinked `sky-out/sky`, never
   `cabal install --copy`. The async-stripe + firestore + tokio + tonic(gRPC)
   dependency tree is *large* — will it blow the shared target dir / build time?
   Should skyshop-rs use its OWN target dir to avoid poisoning the leaf-example
   sweep's shared cache?

12.5 **Does this port require any compiler/runtime change at all**, or is it
   purely `examples/rust/` + wrapper crates? §0.2 (path-dep support) and possibly
   §3.4 (new return-coercion shapes like `Vec<HashMap<...>>`) and §5.4 (LiveReq
   cookie typing) may force in-boundary edits to
   `src/Sky/Generate/Rust/` or `src/Sky/Build/Rust/Ffi.hs`. Enumerate the
   minimum compiler/runtime changes, if any, and confirm each stays inside the
   modification boundary.

12.6 **Inspector prerequisites.** The inspector needs `cargo +nightly rustdoc`.
   Can it inspect a wrapper crate that itself depends on async-stripe/firestore
   (heavy transitive deps) without the rustdoc-JSON run timing out or failing on
   the framework crates? Does inspecting the *wrapper* require building its deps?

---

## 13. Risks & unknowns (build-blockers)

13.1 **`block_on`-in-async panic** (§2.2) — the single highest risk; a wrong
   bridge is a guaranteed runtime panic violating the existential no-panic rule.

13.2 **No path-dependency support in `sky.toml`** (§0.2) — may block the entire
   wrapper-crate approach until a `RustPathDep` is added to
   `src/Sky/Sky/Toml/Rust.hs` + `emitCargoToml`. Is that in-scope?

13.3 **JSON pipeline decoder unsupported on Rust** (`runtime-rust/CLAUDE.md`
   Phase-3 #2) — if the port decodes wrapper JSON via
   `Sky.Core.Json.Decode.Pipeline`, it hits a known `Box<dyn FnOnce>` wall. Must
   the wrapper return flat `Dict String String` instead of JSON to dodge it?

13.4 **async-stripe 1.0.0-rc.6 is a release-candidate** — API churn, possible
   builder-API gaps for shipping_address_collection / collected_information.
   Does it compile against the wrapper's tokio version?

13.5 **firestore 0.49 pulls tonic/gRPC + prost + a TLS stack** — heavy, and may
   conflict with the runtime's existing tokio/rustls/hyper versions in the shared
   `sky-app` Cargo graph (feature unification / duplicate-version errors). Does it
   coexist with axum/sqlx's rustls?

13.6 **Firebase Admin token verification has no turnkey Rust crate** (§5.1) —
   the auth path may have to be hand-rolled (JWKS + RS256) or stubbed; either way
   it's the least-precedented piece.

13.7 **`Tailwind` package portability under `--target rust`** (§1.3, §9.2) — if
   it carries any Go-FFI/kernel, the whole view layer is blocked. Unverified
   (deps wiped locally).

13.8 **`init req` typed-LiveReq mismatch** (§5.4) — guaranteed compile error if
   ported verbatim; needs a `req.cookies` rewrite that technically diverges from
   the Go source.

13.9 **Std.Html/Tailwind render parity** (§9.1) — any unrendered primitive →
   visually-broken (build still green) — would only surface in a web-sweep, not
   build-green. Is web-sweep in-scope for "done"?

13.10 **Effect/Task vs bare-Result mismatch** (§2.3, §3.5) — if the wrapper
   binds as `Task` but the original `Lib/Db.sky` consumes `Result`
   synchronously, the port needs a structural rewrite (thread `Task`/`Cmd.perform`
   through every call site in `Page/*`/`update`), which is NOT 1:1 and is large.
   Resolving the bare-`Result`-from-a-blocking-FFI question (can the Rust FFI
   surface a synchronous blocking call as a non-`Task` `Result Error a`?) decides
   how invasive the port is.
