// Ignored by default (needs a release build + the full repo); run explicitly in CI / by hand.
#[test]
#[ignore]
fn indexes_full_repo_under_memory_cap() {
    let status = std::process::Command::new("bash")
        .arg(concat!(env!("CARGO_MANIFEST_DIR"), "/scripts/mem-test.sh"))
        .status().unwrap();
    assert!(status.success(), "skydex exceeded the memory cap or failed to index the full repo");
}
