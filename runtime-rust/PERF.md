# Rust target performance (Session 23 measurement)

## Build time (cold Sky compilation, excludes first `cargo build` dependency download)

| Example | Go (cold) | Rust (warm cargo) | Rust dependencies |
|---------|-----------|-------------------|-------------------|
| 01-hello-world | 2.3s | 0.09s | none |
| 04-local-pkg | 1.5s | 0.28s | none |
| 06-json | 2.8s | 1.16s | serde_json |
| 14-task-demo | 1.9s | 2.18s | tokio |
| simple | 3.9s | 2.23s | tokio |
| test_pkg | 5.5s | 0.26s | none |

Rust warm `cargo build` times are competitive with or faster than cold
Go build times. First-time `cargo build` is much slower (30s–2min)
because it compiles all transitive crate dependencies.

## Binary size (debug mode)

| Example | Go (stripped) | Rust (debug) | Rust target/ dir |
|---------|--------------|--------------|-------------------|
| 01-hello-world | 12M | ~4M | 6.4M |
| 06-json | 13M | ~7M | 56M |

Rust debug binaries are smaller than Go binaries. Rust `target/`
directory is large (caches compiled dependencies). Release mode
(`cargo build --release`) produces smaller binaries (~2-4M).

## Observations

- **Incremental builds**: Rust `cargo build` on cached artifacts is
  near-instant (0.1-1s). Go rebuilds run `go build` from scratch each
  time (no incremental compilation across Sky invocations).
- **First-time build**: Rust is slower due to crate compilation.
  Mitigation: pre-built sky-runtime-rust crate (once, not per project).
- **Binary size**: Rust debug includes full stdlib debuginfo. Release
  mode with LTO produces smaller binaries than Go.
- **Target directory bloat**: `target/` caches every dependency.
  Clean with `rm -rf sky-out/Rust/target` between builds if space is
  constrained.
