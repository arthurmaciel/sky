# Sky `--target rust` full-static binaries — design

## Goal

Give `sky build --target rust` an **opt-in** path to produce **fully static**
binaries, so that (a) the Rust-vs-Go binary-size comparison is fair (Go is
fully static by default; Rust today is glibc/libgcc-dynamic) and (b) Sky apps
ship as genuinely dependency-free artifacts that run on scratch/distroless
containers with no glibc on the target.

## Locked decisions

| # | Decision | Choice |
|---|---|---|
| 1 | Driver | **Both** — fair perf number AND deployable static artifact |
| 2 | Activation | **Opt-in** via `sky.toml [rust] static = true` + `--static`/`--no-static` CLI override; default build unchanged (glibc-dynamic, stock rustup) |
| 3 | Linux mechanism | **musl target + mimalloc** global allocator |
| 4 | Perf sweep | Measure binsize **static-vs-static** for the fair number, **keep the dynamic numbers** (labeled) so the allocator/throughput trade stays visible |

## Per-OS behaviour matrix

When `static` is requested:

| OS | Mechanism | Result |
|---|---|---|
| **Linux** | `--target x86_64-unknown-linux-musl` + `mimalloc` as `#[global_allocator]` | true full-static (zero `ldd` deps); mimalloc neutralizes musl malloc's multithread-contention slowdown on DB/live servers |
| **Windows** | `-C target-feature=+crt-static` (static MSVC CRT) | static CRT; standard + safe; no allocator change needed |
| **macOS** | *impossible* — Apple ships no static libc | build **dynamic** (libSystem) + emit a clear warning; NEVER silently claim static |
| **any webview project** (`usesWebview`) | n/a — links system WebKit/WebView2/WebKitGTK | **refuse** with a clear error: webview apps cannot be static |

### Why not crt-static + glibc on Linux

`+crt-static` on the gnu target statically links glibc, which upstream glibc
**officially discourages**: NSS / `getaddrinfo` are designed around `dlopen`, so
a static-glibc binary can **fail DNS resolution at runtime**. That is
unacceptable for a server runtime (Sky.Live / Sky.Http via reqwest/sqlx). musl
is static-clean by design. Rejected.

### Why mimalloc

musl's default allocator is slower than glibc's under multithreaded contention —
exactly the DB/live server workloads that currently win 2–5× on the Rust
backend. Setting `mimalloc` (or jemalloc) as the global allocator recovers, and
usually beats, glibc malloc. Without it, going musl-static would partially undo
those server wins. The allocator is gated on the `static` build so non-static
builds are byte-identical to today.

## Architecture

In-boundary touchpoints only (`runtime-rust/`, `src/Sky/Generate/Rust/`, the
Rust-target parts of `app/Main.hs`, `sky.toml` Rust fields, the sweep scripts):

```
sky.toml [rust] static=true  ──┐
--static / --no-static  ───────┼──> staticRequested : Bool
                               │
app/Main.hs (Rust-target)  ────┴──> per-OS decision (matrix above)
   ├─ Linux  : cargo build --target x86_64-unknown-linux-musl
   │            (binary path → target/x86_64-unknown-linux-musl/<profile>/sky-app)
   ├─ Windows: RUSTFLAGS=-C target-feature=+crt-static cargo build
   ├─ macOS  : cargo build (dynamic) + warn "static unsupported on macOS"
   └─ webview: refuse before cargo with a clear error
                               │
Project.hs / Emitter.hs  ──────┴──> emit `#[global_allocator]` mimalloc shim
                                     in main.rs under cfg(static) when Linux-static;
                                     add mimalloc to generated Cargo.toml deps (gated)
```

### Components

1. **`sky.toml` parse** — add a `static : Bool` field to the `[rust]` section
   (default `False`). Lives wherever the existing `[rust]` / `["rust.dependencies"]`
   keys are parsed.
2. **CLI flag** — `--static` / `--no-static` on `sky build`/`sky run --target rust`,
   overriding the toml value (process-arg precedence).
3. **Build orchestration** (`app/Main.hs`, Rust-target arms at the three
   `callProcess "cargo" ["build", …]` sites) — compute `staticRequested`, apply
   the per-OS matrix: choose `--target` (Linux musl), `RUSTFLAGS` (Windows
   crt-static), or dynamic+warn (macOS); **resolve the binary path** for the
   chosen target triple (musl changes `target/<triple>/<profile>/`); refuse on
   webview projects.
4. **mimalloc allocator shim** — a small `#[cfg(...)] #[global_allocator]` block
   emitted into `main.rs` only for the Linux-static build; `mimalloc` added to
   the generated `Cargo.toml` (gated dep, like the existing feature-gated deps).
   Non-static build: not emitted → byte-identical output.
5. **Toolchain probe** — before a Linux-static build, check the musl target is
   installed (`rustup target list --installed`); if missing, emit an actionable
   error (`rustup target add x86_64-unknown-linux-musl`) rather than a raw cargo
   failure. (Opt-in, so this only fires when the user asked for static.)
6. **Perf sweep** (`runtime-rust/scripts/rust-perf.sh` + `examples-perf-sweep.sh`)
   — add a static-built binsize probe (and optionally a static throughput probe
   to expose the allocator trade); report Rust-static-vs-Go-static binsize as the
   fair ratio, keep the existing dynamic binsize labeled.

## Risks / cons

- **musl C-dependency builds.** Bundled-sqlite (`libsqlite3-sys`), ring/aws-lc,
  and any C-linking crate must compile under the musl target. Mitigation: the
  musl target + a musl C toolchain (`musl-gcc`); verify on the DB examples
  (15/18/19/27/36) which pull sqlx+sqlite.
- **Throughput regression if mimalloc is omitted or insufficient.** Must verify
  the static DB/live servers don't lose throughput vs the dynamic build (the
  perf sweep's static throughput probe is the gate).
- **macOS asymmetry.** macOS can never be fully static, so the "static" promise
  is Linux+Windows only. The matrix degrades macOS to dynamic+warn — honest, but
  means cross-OS artifacts aren't uniformly static.
- **Bigger source of truth.** Adds a build-mode dimension (static × per-OS) to
  the codegen + sweep; must not regress the default dynamic path (gate every
  static branch behind `staticRequested`).
- **CI toolchain.** The sweep runner needs the musl target installed on the
  Linux runner to exercise the static path (in-boundary: the sweep workflow).

## Testing / verification

- **Unit/codegen:** a non-static build is byte-identical to today (no mimalloc
  shim, no `--target`) — diff `main.rs` + `Cargo.toml` for a sample example with
  `static=false`.
- **Static build proof (Linux):** build a cli (01), a server (15), and a DB+live
  (27) static; assert `ldd` reports "not a dynamic executable" (zero deps) and
  the binary runs headless per shape.
- **DNS proof:** the static server (15/27) must resolve + serve (guards against
  any NSS/resolver breakage even on musl).
- **Perf:** static binsize ratio vs Go (the fair number); static throughput on
  27/19 must not regress vs dynamic (mimalloc gate).
- **Webview refusal:** `static=true` on 29/31 errors clearly, doesn't silently
  produce a dynamic binary.
- **macOS degrade:** `static=true` on macOS warns + builds dynamic, exit 0.

## Out of scope

- Making macOS static (physically impossible without an unofficial libc).
- Static webview apps (link system WebKit).
- Changing the **default** build to static (decision #2: opt-in only).
- musl as a cross-compilation-from-any-host story (assume native-arch musl).
