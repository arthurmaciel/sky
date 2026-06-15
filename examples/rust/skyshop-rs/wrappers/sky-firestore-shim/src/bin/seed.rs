//! seed.rs — committed Firestore-emulator seeder for skyshop-rs.
//!
//! The app's `Lib/Products.sky::listProducts` reads the `products` collection
//! filtered on `published == "true"`. With an empty collection the catalogue
//! page renders blank; with no emulator + no ADC the shim's `connect()` Errs and
//! the app logs `[DB ERROR] Products.listProducts: ... fs_query_where products`.
//! This binary writes a handful of sample products through the SAME public shim
//! entry point the app uses (`fs_set_doc`), so the seeded schema is byte-for-byte
//! what `listProducts` / `Db.getInt` / `Db.getBool` expect.
//!
//! REQUIREMENTS (enforced by the shim's dev-gate, see lib.rs `is_dev`):
//!   * `FIRESTORE_EMULATOR_HOST` MUST be set (e.g. 127.0.0.1:8412).
//!   * `ENV` / `SKY_ENV` MUST be unset / dev / development / local — the emulator
//!     path is refused outside dev (defence-in-depth: an unauthenticated emulator
//!     must never be reachable in production).
//!
//! TOTAL: every write is attempted; per-doc success/failure is printed; the
//! process exits non-zero if ANY write fails.
//!
//! Flat string-field schema (matches `Lib/Db.sky` value wrappers):
//!   id, title, summary, category,
//!   price_amount   — minor units as a decimal string ("8900" = £89.00)
//!   price_currency — ISO 4217 ("GBP")
//!   price_discount — minor-units discount as a string ("0" or e.g. "1000")
//!   price_tax      — minor-units tax as a string ("0")
//!   stock          — integer as a string ("12")
//!   published      — "true" (listProducts filters on this exact value)

use sky_firestore_shim::fs_set_doc;

/// One sample product as the flat (field, value) pairs the app reads.
struct Product {
    id: &'static str,
    title: &'static str,
    summary: &'static str,
    category: &'static str,
    price_amount: &'static str,
    price_currency: &'static str,
    price_discount: &'static str,
    price_tax: &'static str,
    stock: &'static str,
}

impl Product {
    /// Serialise to the flat `{"k":"v",...}` JSON object `fs_set_doc` expects.
    /// `published` is forced to `"true"` so every seeded doc is visible to
    /// `listProducts`.
    fn fields_json(&self) -> String {
        // serde_json on a HashMap would reorder keys; a hand-built object keeps
        // the row readable in logs. All values are plain strings, so manual
        // escaping is unnecessary for this fixed fixture set (no quotes/backslashes).
        format!(
            "{{\"id\":\"{}\",\"title\":\"{}\",\"summary\":\"{}\",\"category\":\"{}\",\
             \"price_amount\":\"{}\",\"price_currency\":\"{}\",\"price_discount\":\"{}\",\
             \"price_tax\":\"{}\",\"stock\":\"{}\",\"published\":\"true\"}}",
            self.id,
            self.title,
            self.summary,
            self.category,
            self.price_amount,
            self.price_currency,
            self.price_discount,
            self.price_tax,
            self.stock,
        )
    }
}

fn sample_products() -> Vec<Product> {
    vec![
        Product {
            id: "prod-aurora-desk-lamp",
            title: "Aurora Desk Lamp",
            summary: "Warm-dimming LED desk lamp with a brushed-aluminium arm.",
            category: "lighting",
            price_amount: "8900",
            price_currency: "GBP",
            price_discount: "0",
            price_tax: "0",
            stock: "12",
        },
        Product {
            id: "prod-meridian-headphones",
            title: "Meridian Wireless Headphones",
            summary: "Over-ear ANC headphones, 40h battery, low-latency mode.",
            category: "audio",
            price_amount: "19900",
            price_currency: "GBP",
            price_discount: "2000",
            price_tax: "0",
            stock: "30",
        },
        Product {
            id: "prod-cedar-notebook",
            title: "Cedar A5 Notebook",
            summary: "Dotted A5 notebook, 200gsm paper, lay-flat binding.",
            category: "stationery",
            price_amount: "1450",
            price_currency: "GBP",
            price_discount: "0",
            price_tax: "0",
            stock: "120",
        },
        Product {
            id: "prod-tidal-water-bottle",
            title: "Tidal Insulated Bottle",
            summary: "750ml vacuum-insulated steel bottle, 24h cold / 12h hot.",
            category: "outdoor",
            price_amount: "2900",
            price_currency: "GBP",
            price_discount: "500",
            price_tax: "0",
            stock: "64",
        },
        Product {
            id: "prod-summit-backpack",
            title: "Summit 28L Backpack",
            summary: "Water-resistant daypack with a padded 16\\\" laptop sleeve.",
            category: "outdoor",
            price_amount: "12500",
            price_currency: "GBP",
            price_discount: "0",
            price_tax: "0",
            stock: "18",
        },
    ]
}

fn main() {
    // Fail fast with a clear message if the emulator host is missing — without it
    // the shim falls through to real GCP and Errs on absent ADC.
    if std::env::var("FIRESTORE_EMULATOR_HOST").is_err() {
        eprintln!(
            "[SEED] FIRESTORE_EMULATOR_HOST is not set. Start the Firestore \
             emulator and export it, e.g.:\n  \
             export FIRESTORE_EMULATOR_HOST=127.0.0.1:8412"
        );
        std::process::exit(2);
    }

    let products = sample_products();
    let total = products.len();
    let mut failures = 0usize;

    println!("[SEED] writing {total} products to collection 'products' ...");
    for p in &products {
        match fs_set_doc("products", p.id, &p.fields_json()) {
            Ok(written_id) => {
                println!("[SEED] ok    products/{written_id}  ({})", p.title);
            }
            Err(e) => {
                failures += 1;
                eprintln!("[SEED] FAIL  products/{}  ({}): {e}", p.id, p.title);
            }
        }
    }

    let ok = total - failures;
    println!("[SEED] done: {ok}/{total} products written, {failures} failure(s).");
    if failures > 0 {
        std::process::exit(1);
    }
}
