use std::process::Command;

#[test]
fn parity_gaps_runs() {
    let bin = env!("CARGO_BIN_EXE_skydex");
    let repo = concat!(env!("CARGO_MANIFEST_DIR"), "/../..");
    let db = std::env::temp_dir().join(format!("skydex-q-{}.db", std::process::id()));
    let _ = std::fs::remove_file(&db);
    assert!(Command::new(bin)
        .args(["index", "--repo", repo, "--db"])
        .arg(&db)
        .status()
        .unwrap()
        .success());
    let out = Command::new(bin)
        .args(["parity", "--gaps", "--db"])
        .arg(&db)
        .output()
        .unwrap();
    assert!(out.status.success());
    // Dict.union is a known go-only gap on this repo (Go has rt.Dict_union; the
    // Rust backend has no dict_union kernel — the gap class skydex exists to catch).
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(
        stdout.contains("Dict.union"),
        "expected Dict.union in parity --gaps output, got:\n{stdout}"
    );
    let _ = std::fs::remove_file(&db);
    let _ = std::fs::remove_file(format!("{}-wal", db.display()));
    let _ = std::fs::remove_file(format!("{}-shm", db.display()));
}
