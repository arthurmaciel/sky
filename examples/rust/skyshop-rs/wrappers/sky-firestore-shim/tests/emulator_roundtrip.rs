//! Real round-trip against the Firestore emulator (Stage-2 run-verify).
//!
//! Requires `FIRESTORE_EMULATOR_HOST` to point at a running emulator, e.g.:
//!   gcloud emulators firestore start --host-port=127.0.0.1:8412
//!   FIRESTORE_EMULATOR_HOST=127.0.0.1:8412 \
//!   FIRESTORE_PROJECT_ID=sky-skyshop-dev cargo test --test emulator_roundtrip -- --nocapture
//!
//! The test is a no-op (passes trivially) when the emulator env var is unset, so
//! it never fails a plain `cargo test` without an emulator.

use std::collections::HashMap;

use sky_firestore_shim::{
    fs_delete_doc, fs_get_doc, fs_query, fs_query_where, fs_query_where_order, fs_set_doc,
};

fn fields(pairs: &[(&str, &str)]) -> String {
    let m: HashMap<String, String> = pairs
        .iter()
        .map(|(k, v)| (k.to_string(), v.to_string()))
        .collect();
    serde_json::to_string(&m).unwrap()
}

#[test]
fn emulator_roundtrip() {
    if std::env::var("FIRESTORE_EMULATOR_HOST").is_err() {
        eprintln!("FIRESTORE_EMULATOR_HOST unset — skipping emulator round-trip");
        return;
    }

    let coll = "skyshop_test_products";

    // Clean slate for the three ids we use.
    for id in ["p1", "p2", "p3"] {
        let _ = fs_delete_doc(coll, id);
    }

    // 1. set three docs
    assert_eq!(
        fs_set_doc(coll, "p1", &fields(&[("id", "p1"), ("title", "Wallet"), ("category", "bags"), ("price", "4500"), ("published", "true")])).unwrap(),
        "p1"
    );
    assert_eq!(
        fs_set_doc(coll, "p2", &fields(&[("id", "p2"), ("title", "Tote"), ("category", "bags"), ("price", "2900"), ("published", "true")])).unwrap(),
        "p2"
    );
    assert_eq!(
        fs_set_doc(coll, "p3", &fields(&[("id", "p3"), ("title", "Scarf"), ("category", "fashion"), ("price", "6200"), ("published", "false")])).unwrap(),
        "p3"
    );

    // 2. get_doc — present
    let p1 = fs_get_doc(coll, "p1").unwrap();
    assert_eq!(p1.get("_status").map(String::as_str), Some("ok"));
    assert_eq!(p1.get("title").map(String::as_str), Some("Wallet"));
    assert_eq!(p1.get("price").map(String::as_str), Some("4500"));

    // 2b. get_doc — absent → _status=not_found in the Ok payload
    let missing = fs_get_doc(coll, "does-not-exist").unwrap();
    assert_eq!(missing.get("_status").map(String::as_str), Some("not_found"));

    // 3. query — all three
    let all = fs_query(coll).unwrap();
    assert_eq!(all.len(), 3, "expected 3 docs, got {}", all.len());
    assert!(all.iter().all(|r| r.get("_status").map(String::as_str) == Some("ok")));

    // 4. query_where — category == bags → p1, p2
    let bags = fs_query_where(coll, "category", "==", "bags").unwrap();
    assert_eq!(bags.len(), 2, "expected 2 bags, got {}", bags.len());

    // 4b. query_where — published == true → p1, p2
    let pub_true = fs_query_where(coll, "published", "==", "true").unwrap();
    assert_eq!(pub_true.len(), 2, "expected 2 published, got {}", pub_true.len());

    // 5. query_where_order — category == bags ordered by price desc → p1(4500), p2(2900)
    let ordered = fs_query_where_order(coll, "category", "==", "bags", "price", "desc").unwrap();
    assert_eq!(ordered.len(), 2);
    assert_eq!(ordered[0].get("id").map(String::as_str), Some("p1"));
    assert_eq!(ordered[1].get("id").map(String::as_str), Some("p2"));

    // 5b. ascending
    let ordered_asc = fs_query_where_order(coll, "category", "==", "bags", "price", "asc").unwrap();
    assert_eq!(ordered_asc[0].get("id").map(String::as_str), Some("p2"));
    assert_eq!(ordered_asc[1].get("id").map(String::as_str), Some("p1"));

    // 6. delete + confirm gone
    assert_eq!(fs_delete_doc(coll, "p3").unwrap(), "p3");
    let after = fs_get_doc(coll, "p3").unwrap();
    assert_eq!(after.get("_status").map(String::as_str), Some("not_found"));

    // cleanup
    let _ = fs_delete_doc(coll, "p1");
    let _ = fs_delete_doc(coll, "p2");

    eprintln!("EMULATOR ROUND-TRIP OK: set→get→query→where→where_order→delete all verified");
}
