// Indexes the skydex crate's own dir as a tiny tracked tree and checks rows land.
use std::process::Command;

#[test]
fn index_builds_a_db() {
    let bin = env!("CARGO_BIN_EXE_skydex");
    let db = std::env::temp_dir().join(format!("skydex-test-{}.db", std::process::id()));
    let _ = std::fs::remove_file(&db);
    let repo = env!("CARGO_MANIFEST_DIR"); // tools/skydex
    let status = Command::new(bin)
        .args(["index", "--repo", repo, "--db"])
        .arg(&db)
        .status()
        .unwrap();
    assert!(status.success());
    // The store has files + at least one rust symbol from our own src.
    let out = Command::new(bin)
        .args(["roles", "--db"])
        .arg(&db)
        .output()
        .unwrap();
    assert!(out.status.success());
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.contains("runtime-rust") || stdout.contains("other"));
    let _ = std::fs::remove_file(&db);
    let _ = std::fs::remove_file(format!("{}-wal", db.display()));
    let _ = std::fs::remove_file(format!("{}-shm", db.display()));
}
