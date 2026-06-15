use std::path::Path;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Lang { Haskell, Go, Rust, Bash, Ts, Sky, Other }

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Role { CompilerHs, RuntimeGo, RuntimeRust, StdlibSky, ScriptSh, ConsoleTs, Example, Fixture, Other }

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Stage { Parse, Canonicalise, Type, Build, Generate }

pub fn lang_of(path: &str) -> Lang {
    match Path::new(path).extension().and_then(|e| e.to_str()) {
        Some("hs") => Lang::Haskell,
        Some("go") => Lang::Go,
        Some("rs") => Lang::Rust,
        Some("sh") => Lang::Bash,
        Some("ts") | Some("tsx") | Some("mjs") | Some("js") => Lang::Ts,
        Some("sky") => Lang::Sky,
        _ => Lang::Other,
    }
}

pub fn role_of(path: &str) -> Role {
    if path.starts_with("runtime-rust/tests/sky/") { Role::Fixture }
    else if path.starts_with("examples/") { Role::Example }
    else if path.starts_with("src/Sky/") || path.starts_with("app/") { Role::CompilerHs }
    else if path.starts_with("runtime-go/") { Role::RuntimeGo }
    else if path.starts_with("runtime-rust/src/") { Role::RuntimeRust }
    else if path.starts_with("sky-stdlib/") { Role::StdlibSky }
    else if path.starts_with("sky-bundled/") { Role::ConsoleTs }
    else if path.ends_with(".sh") { Role::ScriptSh }
    else if matches!(lang_of(path), Lang::Ts) { Role::ConsoleTs } // any .ts/.tsx/.js/.mjs (incl. scripts)
    else { Role::Other }
}

pub fn stage_of(path: &str) -> Option<Stage> {
    if path.starts_with("src/Sky/Parse/") { Some(Stage::Parse) }
    else if path.starts_with("src/Sky/Canonicalise/") { Some(Stage::Canonicalise) }
    else if path.starts_with("src/Sky/Type/") { Some(Stage::Type) }
    else if path.starts_with("src/Sky/Build/") { Some(Stage::Build) }
    else if path.starts_with("src/Sky/Generate/") { Some(Stage::Generate) }
    else { None }
}

impl Lang { pub fn as_str(&self) -> &'static str { use Lang::*; match self { Haskell=>"hs",Go=>"go",Rust=>"rs",Bash=>"sh",Ts=>"ts",Sky=>"sky",Other=>"other" } } }
impl Role { pub fn as_str(&self) -> &'static str { use Role::*; match self { CompilerHs=>"compiler-hs",RuntimeGo=>"runtime-go",RuntimeRust=>"runtime-rust",StdlibSky=>"stdlib-sky",ScriptSh=>"script-sh",ConsoleTs=>"console-ts",Example=>"example",Fixture=>"fixture",Other=>"other" } } }
impl Stage { pub fn as_str(&self) -> &'static str { use Stage::*; match self { Parse=>"parse",Canonicalise=>"canonicalise",Type=>"type",Build=>"build",Generate=>"generate" } } }

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn classifies_paths() {
        assert_eq!(lang_of("src/Sky/Build/Compile.hs"), Lang::Haskell);
        assert_eq!(lang_of("runtime-rust/src/sky_runtime/list.rs"), Lang::Rust);
        assert_eq!(lang_of("a.sky"), Lang::Sky);
        assert_eq!(role_of("runtime-rust/tests/sky/49-x/src/Main.sky"), Role::Fixture);
        assert_eq!(role_of("examples/13-skyshop/src/Main.sky"), Role::Example);
        assert_eq!(role_of("src/Sky/Parse/Lexer.hs"), Role::CompilerHs);
        assert_eq!(role_of("runtime-go/rt/rt.go"), Role::RuntimeGo);
        assert_eq!(role_of("sky-stdlib/Sky/Core/List.sky"), Role::StdlibSky);
        assert_eq!(role_of("scripts/web-verify.mjs"), Role::ConsoleTs); // JS/TS/MJS not Other
        assert_eq!(lang_of("scripts/x.mjs"), Lang::Ts);
        assert_eq!(stage_of("src/Sky/Canonicalise/Module.hs"), Some(Stage::Canonicalise));
        assert_eq!(stage_of("src/Sky/Generate/Rust/Builder.hs"), Some(Stage::Generate));
    }
}
