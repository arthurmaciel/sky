//! Integration test: assert that no unintended curried helpers are added
//! to the runtime. Under the tupled calling convention (README section A0) a
//! multi-arg Sky function lowers to ONE tupled Rust fn `f(a, b)`, never a
//! curried `f(a)(b)`. Two legitimate shapes return `impl Fn…`:
//!
//!   1. Pipeline-decoder builders (`json_dec_p_required` / `_optional`) — they
//!      return `impl FnOnce(Decoder<…>) -> Decoder<…>`; the deferred arg is a
//!      Sky-domain `Decoder`, so this IS the curried exception (allowlisted).
//!   2. Handler producers (the `middleware_with_*` family) — they take all
//!      their Sky args tupled and return a **Handler**, which is the runtime
//!      type `Fn(ServerRequest) -> SkyTask<E, Response>`. The returned closure
//!      takes a runtime `ServerRequest`, NOT a deferred Sky arg, so this is not
//!      currying — it's a function that returns a function-typed value. These
//!      are recognised structurally (return-Fn arg == `ServerRequest`) so new
//!      middleware don't need allowlisting.

use std::path::PathBuf;

#[test]
fn no_unintended_curried_helpers() {
    let runtime_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("src")
        .join("sky_runtime");

    let mut curried: Vec<String> = Vec::new();
    // Capture the helper name AND the first parameter type of the returned
    // `Fn`, so Handler producers (returned `Fn(ServerRequest) -> …`) can be
    // distinguished from genuine curried builders.
    let re = regex::Regex::new(
        r"fn ([a-z_]+).*-> impl Fn(?:Once|Mut)?\(\s*([A-Za-z_][A-Za-z0-9_]*)",
    )
    .unwrap();

    for entry in std::fs::read_dir(&runtime_dir).unwrap() {
        let path = entry.unwrap().path();
        if path.extension().and_then(|e| e.to_str()) != Some("rs") {
            continue;
        }
        let content = std::fs::read_to_string(&path).unwrap();
        for cap in re.captures_iter(&content) {
            let returned_arg = cap.get(2).unwrap().as_str();
            // A function returning a Handler (`Fn(ServerRequest) -> SkyTask`)
            // is a handler producer, not a curried helper — skip it.
            if returned_arg == "ServerRequest" {
                continue;
            }
            curried.push(cap.get(1).unwrap().as_str().to_string());
        }
    }

    curried.sort();
    assert_eq!(
        curried,
        vec!["json_dec_p_optional", "json_dec_p_required"],
        "Unexpected curried helper(s) found — see README section A0 (tupled convention). \
         Only Json.Decode.Pipeline decoders should be curried; middleware that return \
         a Handler (Fn(ServerRequest) -> …) are recognised structurally and exempt."
    );
}
