# Sky→Rust Domain Glossary

## Sky Language

- **Sky** — Elm-family functional language compiling to typed Go (and now Rust) via a Haskell compiler (GHC 9.4.8)
- **Sky source** — `.sky` files written in Sky syntax
- **Stdlib** — standard library split into Sky.Core (pure + kernel), Std (effects), Sky.Http (server)
- **Kernel function** — built-in runtime primitive dispatched by name (`Ffi.kernel "Name"`)
- **Sky.Live** — TEA-based web framework (HTTP-first, SSE patches, sessions, routing)
- **Sky.Tui** — terminal UI backend rendering Std.Ui to ANSI cells
- **Sky.Webview** — desktop backend via system webview (WKWebView/WebView2/WebKitGTK)

## Compiler Pipeline

- **Parse** — lexer + layout filter + parser (`src/Sky/Parse/`)
- **Canonicalise** — name resolution, import validation (`src/Sky/Canonicalise/`)
- **Type check** — HM inference, exhaustiveness (`src/Sky/Type/`)
- **Lower** — AST → IR (`src/Sky/Build/Compile.hs`)
- **Generate** — IR → target language (`src/Sky/Generate/{Go,Rust}/`)

## Rust Backend

- **Builder.hs** — Rust codegen module (`src/Sky/Generate/Rust/Builder.hs`)
- **TargetRust** — compile target selector (via `--target rust`)
- **sky_runtime** — Rust runtime crate providing Sky primitives in Rust
- **SkyResult** — Rust equivalent of `Result Error a`
- **SkyMaybe** — Rust equivalent of `Maybe a`
- **SkyString** — Rust string type for Sky strings
- **SkyList** — Rust vector type for Sky lists
- **SkyDict** — Rust map type for Sky dicts
- **SkyTask** — Rust async task type for Sky tasks

## FFI

- **FFI binding** — generated Rust code wrapping external Rust crate functions
- **FFI inspector** — tool scanning Rust crate public API (`tools/sky-ffi-inspect-rs/`)
- **FFI registry** — cached inspection results (`.skycache/ffi/rust/`)
- **Tier 1** — auto-bindable functions (50-60% of real-world crates)
- **Tier 2** — generated glue needed (25-35%)
- **Tier 3** — lossy binding possible (5-10%)
- **Tier 4+5** — impossible to bind automatically (5-10%)

## Build Artifacts

- **sky-out/** — compiler output directory
- **sky-out/Rust/** — Rust codegen output (capital R by convention)
- **.skycache/** — build cache (source hashes, lowered IR, FFI registries)
- **.skycache/ffi/rust/** — Rust FFI registry files

## Safety Invariant

Zero `Any` types, zero `unsafe` blocks in generated code. Type safety guaranteed at compile time.
