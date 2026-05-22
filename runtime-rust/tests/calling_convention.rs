//! Integration test: assert that no unintended curried helpers are added
//! to the runtime. The only functions that should return `impl FnOnce` /
//! `impl FnMut` are the pipeline-decoder helpers (json_dec_p_required,
//! json_dec_p_optional) per README section A0.

use std::path::PathBuf;

#[test]
fn no_unintended_curried_helpers() {
    let runtime_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("src")
        .join("sky_runtime");

    let mut curried: Vec<String> = Vec::new();
    let re = regex::Regex::new(r"fn ([a-z_]+).*-> impl Fn(Once|Mut)?\(").unwrap();

    for entry in std::fs::read_dir(&runtime_dir).unwrap() {
        let path = entry.unwrap().path();
        if path.extension().and_then(|e| e.to_str()) != Some("rs") {
            continue;
        }
        let content = std::fs::read_to_string(&path).unwrap();
        for cap in re.captures_iter(&content) {
            curried.push(cap.get(1).unwrap().as_str().to_string());
        }
    }

    curried.sort();
    assert_eq!(
        curried,
        vec!["json_dec_p_optional", "json_dec_p_required"],
        "Unexpected curried helper(s) found — see README section A0 (tupled convention). \
         Only Json.Decode.Pipeline decoders should be curried."
    );
}
