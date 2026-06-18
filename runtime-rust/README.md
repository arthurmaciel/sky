# Sky Rust Runtime

I learned about Sky in the middle of April 2026 and quickly started to admire the language 
project. As I have studied Rust in the last year, I had the idea to implement a new **experimental** 
backend with it. 

The Sky author shared his initial thought of using Rust as a target language, but choose Go 
due to Rust type system, that would block 'universal' and automatic FFI.

In fact, that is the case. But when I faced the FFI limits, I decided to pursue the following
goals:

- Have a Rust backend for real use
- Test the limits of Sky FFI to Rust (complex lifetimes, generics, traits etc)
- Learn more about Rust itself
- Learn more about compilers
- See the limits of AI tooling on a practical and complex project


## Contract

The Rust backend is **experimental**. Don't use it for production yet.

Its principles declaration is:

> **Principles — applied to every change, in this strict priority order:**
> **1. Security · 2. Correctness · 3. Soundness · 4. Efficiency · 5. Completeness · 6. Readability.**
> A lower principle never justifies compromising a higher one (a readable name
> that breaks correctness is rejected; an efficient path that opens a soundness
> hole is rejected).

Code changes must not hurt any of these principles. If at a specific decision those principles conflict, 
the priority order should guide the choices for human and artificial agents. 

The Rust backend must **mirror** Go backend functionality and look for byte-equality results. If not 
possible, the divergence must be logged here.
There is no commitment about implementation parity - Rust should be idiomatic.

The backend must have the smallest footprint at Sky project code base as possible, changing
only necessary files.


### Limitations to the contract

**Expect a one-month parity delay**.

Sky is heavily and quickly developed by its author. It provides industrial-grade source 
code and utilities ("batteries included" -> I read it as "power plant included"). 

So keeping the Rust backend up-to-date is difficult and demands careful orchestration. 

Anyway, at the moment the backend reaches full behavioral parity with the Go reference, 
holding four hard rules: no panic vector, no runtime error from well-typed Sky, as few `Any`
as possible in generated code (fully-typed codegen), no change to Sky/Go source or 
the upstream examples. 

Fixes are root-cause only. Where Rust implements a mechanism differently from Go to hold
those guarantees, that *mechanism* divergence is recorded in **Rust vs Go backend
— divergent implementation strategies**.


---

## Getting started

The Rust backend compiles Sky source to a Rust program, then to a native binary
via `cargo`. This guide takes you from a clean machine to **running every example
in this repo** (except the Go-FFI ones — those need the default Go backend). You
pick the Rust backend by adding `--backend rust` to any `sky` command; that's the
only flag a newcomer needs. (Cross-compiling to another platform uses
`--target <triple>` — covered in *Static & cross compilation* below; ignore it for
now.)

Running the examples is **identical on every OS** — only the one-time setup
differs. Read the subsection for your OS, then jump to *Running the examples*.

### Linux

#### 1. Prerequisites

```bash
# Rust (rustup) — stable for building, nightly for the FFI inspector
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
source "$HOME/.cargo/env"
rustup toolchain install nightly      # the FFI inspector runs `cargo +nightly rustdoc`

# Haskell — the Sky compiler is written in Haskell (GHC 9.6.7 + cabal 3.10)
curl --proto '=https' --tlsv1.2 -sSf https://get-ghcup.haskell.org | sh
ghcup install ghc 9.6.7 && ghcup set ghc 9.6.7
ghcup install cabal 3.10.3.0

# ripgrep — used by the build tooling
sudo apt install -y ripgrep

# Go — OPTIONAL: only needed to build the Go reference or Go-FFI examples.
# Skip it for a Rust-only setup.
# sudo apt install -y golang-go     # or install from https://go.dev/dl/
```

System libraries for the UI app shapes:

```bash
# Sky.Webview (desktop) — WebKitGTK + GTK3 + libsoup3 stack
sudo apt install -y libwebkit2gtk-4.1-dev libgtk-3-dev librsvg2-dev \
                    libsoup-3.0-dev libjavascriptcoregtk-4.1-dev

# Only if you run a webview example with no display attached (e.g. over SSH):
sudo apt install -y xvfb

# Only if you later want fully-static binaries (see Static & cross compilation):
# sudo apt install -y musl-tools
```

Sky.Tui (terminal UI) needs no extra package — just a real terminal.

Now continue with **Clone, Fast-build env, and Build the compiler** below.

### macOS

#### 1. Prerequisites

```bash
# Rust (rustup) — stable + nightly (the FFI inspector needs nightly)
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
source "$HOME/.cargo/env"
rustup toolchain install nightly

# Haskell — GHC 9.6.7 + cabal via ghcup
curl --proto '=https' --tlsv1.2 -sSf https://get-ghcup.haskell.org | sh
ghcup install ghc 9.6.7 && ghcup set ghc 9.6.7
ghcup install cabal 3.10.3.0

# ripgrep + GNU coreutils (the helper scripts use GNU `timeout`)
brew install ripgrep coreutils

# Go — OPTIONAL: only for the Go reference / Go-FFI examples.
# brew install go
```

System libraries:

- **Sky.Webview** works natively — WKWebView is built into macOS, nothing to
  install.
- **Sky.Tui** needs only a real terminal (Terminal.app / iTerm2).
- `musl-cross` (`brew install FiloSottile/musl-cross/musl-cross`) is only needed
  for static *cross*-builds to Linux — see *Static & cross compilation*.

Now continue with **Clone, Fast-build env, and Build the compiler** below.

### Windows

Run everything in a **Git Bash / MSYS** shell — the helper scripts are bash. The
`cabal`, `cargo`, and `go` toolchains themselves build natively; only the scripts
need bash.

#### 1. Prerequisites

```bash
# Rust (rustup) — install from https://rustup.rs (run the installer), then:
rustup toolchain install nightly      # FFI inspector needs nightly

# Haskell — install GHC 9.6.7 + cabal via GHCup: https://www.haskell.org/ghcup/
#   (the GHCup Windows installer walks you through it)

# ripgrep
choco install ripgrep -y              # or: winget install BurntSushi.ripgrep.MSVC

# Go — OPTIONAL: only for the Go reference / Go-FFI examples.
#   https://go.dev/dl/
```

System runtimes for the UI shapes:

- **Sky.Webview** needs the **WebView2 Runtime**. It is preinstalled on Windows
  11; on Windows 10 install the Evergreen runtime from
  <https://developer.microsoft.com/microsoft-edge/webview2/> (the "Evergreen
  Standalone Installer").
- **Sky.Tui caveat** — a TUI needs a real interactive console to allocate a pty.
  Run TUI (and webview) examples from **Windows Terminal, PowerShell, or cmd**,
  **not** from a piped or headless shell. Under Git Bash the `winpty` shim can't
  allocate a pty headlessly, so launch the interactive shapes from Windows
  Terminal.

Now continue with **Clone, Fast-build env, and Build the compiler** below.

### Clone the repo (all OSes)

```bash
git clone -b feat/runtime-rust https://github.com/arthurmaciel/sky.git
cd sky
```

### Fast-build env (all OSes)

Install `sccache` once, then export the fast-build environment in **every shell**
you build from (shell state does not persist between sessions):

```bash
cargo install sccache    # one-time

# Compilers + a SHARED cargo target dir + sccache + non-incremental cargo:
export PATH="$HOME/.cargo/bin:/usr/local/go/bin:/usr/local/bin:/usr/bin:/bin:$HOME/.ghcup/bin"
export CARGO_TARGET_DIR="$HOME/.cache/sky-rust-target"
export RUSTC_WRAPPER=sccache
export CARGO_INCREMENTAL=0
```

Why: the **shared `CARGO_TARGET_DIR`** compiles the heavy dependency tree
(tokio / axum / serde / sqlx) **once** and reuses it across every example;
**sccache** caches compiled crate objects across builds; **`CARGO_INCREMENTAL=0`**
is mandatory with sccache (sccache silently skips caching when incremental builds
are on). On macOS/Windows adapt the `PATH` to where your tools actually live
(e.g. drop `/usr/local/go/bin` if Go isn't installed); the three `export` lines
for the cargo/sccache env are the load-bearing ones.

### Build the Sky compiler (all OSes)

```bash
cabal build -w ghc-9.6.7 exe:sky
mkdir -p sky-out
ln -sf "$(cabal list-bin -w ghc-9.6.7 exe:sky)" sky-out/sky
./sky-out/sky --version
```

The `ln -sf` makes `sky-out/sky` point at the freshly-built compiler binary; a
later `cabal build` updates it in place. **Never** use
`cabal install --install-method=copy` — it pays a large copy on every rebuild for
no benefit, and the symlink is what the tooling expects.

### Running the examples

This is the **same on every OS**. Each example is a self-contained Sky project; you
`cd` into it and run it with `--backend rust`. `sky run` builds and runs in one
step — exactly what you want to *see* a result.

```bash
# Make sure the fast-build env above is exported in this shell first.
SKY="$PWD/sky-out/sky"     # absolute path to the compiler you just built
```

Five shapes to try:

```bash
# 1. CLI — prints to stdout and exits
cd examples/01-hello-world
"$SKY" run src/Main.sky --backend rust            # try 07-todo-cli too

# 2. HTTP server — boots and serves; curl it from a second terminal
cd ../15-http-server
"$SKY" run src/Main.sky --backend rust            # leave it running…
#   …in another terminal:
#   curl localhost:8000/

# 3. Sky.Live web app — open it in a browser
cd ../18-job-queue
"$SKY" run src/Main.sky --backend rust            # try 09-live-counter too
#   then open http://localhost:8000 in your browser

# 4. Sky.Tui — terminal UI; run in a REAL terminal
cd ../21-tui-stopwatch
"$SKY" run src/Main.sky --backend rust            # Windows: Windows Terminal, not Git Bash

# 5. Sky.Webview — opens a native desktop window
cd ../31-webview-stopwatch-ui
"$SKY" run src/Main.sky --backend rust
#   Linux needs the webkit deps above; macOS works out of the box;
#   Windows needs the WebView2 Runtime.
```

**Go-FFI examples** (e.g. `02-go-stdlib`, `13-skyshop`) bind Go libraries and can
only build on the **Go backend** — run them **without** `--backend rust` (Go is
the default), or skip them for a Rust-only setup.

### CLI reference

```bash
$ sky build src/Main.sky --backend rust
$ sky run   src/Main.sky --backend rust
$ sky check src/Main.sky --backend rust    # full emit + cargo build
$ sky test  tests/MyTest.sky --backend rust
$ sky add uuid --features="v4" --backend rust   # fully automatic, no shims
$ sky install                                  # regen FFI after rm -rf .skycache

# Static / cross / allocator flags (see "Static & cross compilation" below)
$ sky build src/Main.sky --backend rust --static                 # fully-static binary (musl Linux / crt-static Windows)
$ sky build src/Main.sky --backend rust --target x86_64-unknown-linux-musl  # cross-compile to a target triple
$ sky build src/Main.sky --backend rust --mimalloc               # mimalloc global allocator (faster; +RSS)
$ sky build src/Main.sky --backend rust --static --system-alloc  # static WITHOUT mimalloc (lean RSS; ~11x slower — warns)
```

Precedence **CLI > env > `sky.toml`**; the env mirrors are `SKY_RUST_STATIC` /
`SKY_RUST_TARGET` / `SKY_RUST_ALLOC`. `--static` / `--target` / `--mimalloc`
compose with the backend selector `--backend rust` (they never clash with it).

---

## Project status

**examples-sweep = 37 green · 0 red — full Go≡Rust behavioral parity.** Every
example **builds**, **runs** headless per shape, and **matches the Go reference**
under its equivalence mode.

### Sweep summary (by equivalence mode)

| Shape | Mode | N | Proves |
|---|---|---|---|
| cli | `equiv-stdout` | 8 | Go & Rust byte-identical stdout + exit code |
| server | `equiv-body` | 4 | byte-identical HTTP response bodies over each comparable GET route |
| live | `equiv-scenario` | 13 | same headless-browser round-trip passes on **both** backends (app behaviour, not a DOM diff) |
| tui | `equiv-pty` | 5 | both drive the Sky.Tui runtime without panic (NOT cell-identical) |
| server | `equiv-serve` | 1 | both boot + serve (no comparable GET route to byte-compare) |
| webview/cli | `n/a` | 6 | no Go comparison possible (native webview window / nondeterministic / Rust-FFI) |

The sweep is the `sky-rust-backend:examples-sweep` skill — one pass that BUILDS,
RUNS, and asserts EQUIV per example. `sky-rust-backend:examples-perf-sweep`
measures Rust-vs-Go throughput separately (informational, never blocks).

### Examples

**Build** / **Run** are per-row (✅ pass · ❌ fail). "Round-trip" = how RUN is
exercised: `cli` = stdout · `server` = curl boot/serve · `live` = headless browser
scenario · `tui` = pty smoke · `webview` = xvfb smoke. The four **Perf** columns
are Rust/Go ratios from the perf sweep: **Thru** (request throughput, **↑** higher
= Rust faster) · **RSS** (resident memory, **↓** lower = Rust leaner) · **Cold**
(cold-start ms, **↓**) · **Bin** (binary size, **↓**). `—` = the shape has no such
measurement; `n/a` = measured but the probe couldn't compare.

| Build | Run | Example | Shape | Round-trip | Equiv | Thru ↑ | RSS ↓ | Cold ↓ | Bin ↓ |
|:-:|:-:|---|---|---|---|:-:|:-:|:-:|:-:|
| ✅ | ✅ | 00-standard-libs | cli | stdout | ✅ | — | 0.18 | 0.65 | 0.054 |
| ✅ | ✅ | 01-hello-world | cli | stdout | ✅ | — | 0.16 | 0.45 | 0.026 |
| ✅ | ✅ | 02-go-stdlib | cli | stdout | n/a — non-deterministic (wall-clock time + live HTTP); Go-stdlib-FFI demo, no stable comparable stdout | — | 0.23 | 0.82 | 0.149 |
| ✅ | ✅ | 04-local-pkg | cli | stdout | ✅ | — | 0.17 | 0.45 | 0.026 |
| ✅ | ✅ | 06-json | cli | stdout | ✅ | — | 0.17 | 3.69 | 0.032 |
| ✅ | ✅ | 07-todo-cli | cli | stdout | n/a — non-deterministic RFC3339Nano banner timestamp (Std.Log format itself matches Go) | — | 0.27 | 1.54 | 0.139 |
| ✅ | ✅ | 09-live-counter | live | browser (live-counter) | ✅ | n/a | 0.05 | 0.85 | 0.016 |
| ✅ | ✅ | 10-live-component | live | browser (live-component) | ✅ | **2.74×** | 0.31 | 0.97 | 0.017 |
| ✅ | ✅ | 12-skyvote | live | browser (skyvote) | ✅ | — | — | — | — |
| ✅ | ✅ | 14-task-demo | cli | stdout | ✅ | — | 0.16 | 0.74 | 0.026 |
| ✅ | ✅ | 15-http-server | server | curl 4 routes | ✅ | 0.99× | 0.11 | 0.18 | 0.006 |
| ✅ | ✅ | 16-skychess | live | browser (skychess) | ✅ | 1.34× | 0.25 | 0.96 | 0.030 |
| ✅ | ✅ | 17-skymon | live | browser (skymon) | ✅ | — | — | — | — |
| ✅ | ✅ | 18-job-queue | live | browser (job-queue) | ✅ | **2.36×** | 0.62 | 0.88 | 0.029 |
| ✅ | ✅ | 19-skyforum | live | browser (skyforum) | ✅ | **5.35×** | 0.31 | 0.75 | 0.017 |
| ✅ | ✅ | 20-cli-counter | cli | stdout | ✅ | — | 0.15 | 0.43 | 0.029 |
| ✅ | ✅ | 21-tui-stopwatch | tui | pty | ✅ | — | — | — | — |
| ✅ | ✅ | 22-tui-stopwatch-ui | tui | pty | ✅ | — | — | — | — |
| ✅ | ✅ | 23-tui-todo | tui | pty | ✅ | — | — | — | — |
| ✅ | ✅ | 24-tui-kitchen-sink | tui | pty | ✅ | — | — | — | — |
| ✅ | ✅ | 25-sky-console | live | browser (smoke) | ✅ | **5.74×** | 0.28 | 0.78 | 0.017 |
| ✅ | ✅ | 26-ui-showcase | live | browser (smoke) | ✅ | — | — | — | — |
| ✅ | ✅ | 27-multi-session-chat | live | browser (smoke) | ✅ | **4.20×** | 0.53 | 0.98 | 0.029 |
| ✅ | ✅ | 28-streaming-chat | live | browser (smoke) | ✅ | **2.10×** | 0.51 | 0.88 | 0.017 |
| ✅ | ✅ | 29-webview-threejs-spike | webview | xvfb | n/a — native wry window, no comparable output | — | — | — | — |
| ✅ | ✅ | 30-sse-server-demo | server | curl `/` | ✅ | 0.98× | 0.11 | 0.18 | 0.006 |
| ✅ | ✅ | 31-webview-stopwatch-ui | webview | xvfb | n/a | — | — | — | — |
| ✅ | ✅ | 32-sse-relay | server | curl `/` | ✅ | 0.98× | 0.17 | 0.18 | 0.015 |
| ✅ | ✅ | 33-websocket-echo | server | curl `/` | ✅ | 1.00× | 0.14 | 0.18 | 0.007 |
| ✅ | ✅ | 34-multi-tier-console | live | browser (smoke) | ✅ | **2.79×** | 0.32 | 0.97 | 0.017 |
| ✅ | ✅ | 35-composite-generics | cli | stdout | n/a — non-deterministic (Time.now + Dict.toList order) | — | 0.21 | 0.72 | 0.111 |
| ✅ | ✅ | 36-composite-server | server | curl | ✅ | n/a | n/a | n/a | 0.017 |
| ✅ | ✅ | 37-composite-live-shop | live | browser (smoke) | ✅ | — | — | — | — |
| ✅ | ✅ | 38-composite-ui-multibackend | tui | pty | ✅ | — | — | — | — |
| ✅ | ✅ | simple | cli | stdout | ✅ | — | 0.15 | 0.70 | 0.028 |
| ✅ | ✅ | test_pkg | cli | stdout | ✅ | — | 0.19 | 0.45 | 0.026 |
| ✅ | ✅ | examples/rust/skyshop-rs | live/FFI | curl | n/a — Rust-FFI app (stripe/firebase/firestore); does not build on Go — Rust-only | — | — | — | — |

**Equiv modes:** `stdout` = byte-identical stdout + exit · `body N` = N GET-route
response bodies byte-identical · `scenario` = same headless-browser round-trip
passes on both backends · `pty` = both drive the Tui runtime, no panic · `serve`
= both boot + serve · `n/a` = no Go comparison possible.

**Perf** ratios are Rust/Go; the arrow marks the good direction (Thru higher,
RSS/Cold/Bin lower). Headlines:

- **Throughput splits by workload.** Stateful live apps (DB / session / broadcast)
  win **2.1–5.7×** Go (25-sky-console 5.74×, 19-skyforum 5.35×, 27-multi-session-chat
  4.20×, 34-multi-tier-console 2.79×, 10-live-component 2.74×, 18-job-queue 2.36×,
  28-streaming-chat 2.10×, 16-skychess 1.34×). Thin http/sse/ws **echo** servers sit
  at **parity ~0.98–1.00×** (15/30/32/33) — there is almost no per-request work to
  win on. 27's prior 0.78× loss is gone: a process-global pool cache made its
  per-session `Db.connect` cheap.
- **Binaries 0.6–15%** of Go's static binaries; **RSS 5–62%** of Go's resident set
  — Rust wins both on every measured example.
- **Cold-start** is faster on http/sse (~0.18×) and par-to-slightly-slower on live
  (0.75–0.98×); on cli it is mixed (most faster, but 06-json 3.69× and 07-todo-cli
  1.54× are slower — small absolute deltas, see the TSV).

Live-only latency metrics (`live_event` ≈ par, `live_warm` 3–6× Go,
`sse_eps`/`ws_eps` ≥ par) and the perf thresholds live in `examples-perf-sweep`'s
output (informational, never blocks).

---

## Architecture

```
Sky Source → Haskell Parser → Type-Check → Canonical AST → Rust Codegen (Builder.hs)
                                                                    ↓
                                            sky_runtime/ modules (this directory)
                                                                    ↓
                                          sky-out/Rust/src/main.rs + sky_runtime/
                                                                    ↓
                                                       cargo build → binary
```

All runtime logic lives in `sky_runtime/`; `Builder.hs` emits thin wrappers that
instantiate `E = SkyError` for the generated project. No inline Rust
implementation strings in the Haskell codegen.

The `sky_runtime` crate is the **single source of truth** for all Rust code
emitted by the Sky compiler's `--backend rust` path. Every generated project
copies this crate's modules into `sky-out/Rust/src/sky_runtime/` at build time.

---

### Rust vs Go backend — divergent implementation strategies

Where the Rust backend deliberately implements something **differently** from Go,
the **why** is recorded here. The Go backend is the reference, but parity is about
*observable behaviour*, not internal mechanism — and Rust's no-`Any` /
no-panic-vector constraints (plus the absence of reflection) sometimes make a
different mechanism the *correct* one, not a shortcut.

> **Before scoping any "Go-parity" work, re-verify what Go *currently* does**
> (read `runtime-go/rt/` + `docs/` + the latest refactor commit). Go evolves; a
> stale parity premise wastes work.

### Console serving — pre-built separate process

The console runs as a **pre-built** separate process behind a reverse-proxy. The
console binary is compiled at the user's `sky build` time (a sibling binary); at
runtime the parent `exec`s it and proxies `/_sky/console/*` — no runtime build, no
toolchain on the VM, ~5 MB RSS. Go runs its console **in-process** (links the
bundled console into the user's binary). Two Sky programs in one Rust crate would
collide on every generated type (`StateModel`/`StateMsg`/…), needing codegen
type-namespacing Rust has no reflection to shortcut; separate binaries have zero
type collision and full fault isolation.

- **Proxy convention — STRIP.** The browser reaches the console child only through
  the parent proxy (the child binds `127.0.0.1`), so the parent **strips**
  `/_sky/console` before forwarding and the child's router stays byte-identical to
  a standalone Live app. `SKY_LIVE_BASE_PATH` affects rendered **output** URLs only
  (via `<meta sky-base>`/`__SKY_BASE`, which `client.js` prefixes onto
  `/_sky/event` + `/_sky/sse`), never routing. The session cookie is de-collided
  per sub-app — a base-derived **distinct name** (`sky_sid__sky_console`) +
  base-scoped `Path` — so the proxied child can't clobber the parent's `sky_sid`.
- **Child lifecycle.** The parent traps SIGTERM/SIGINT, reaps the child, then exits
  `128+signum` (trapping alone would make the parent unkillable-by-SIGTERM). On
  Linux the child additionally gets `PR_SET_PDEATHSIG=SIGTERM` (via `pre_exec` +
  `libc`) so it dies even when the parent is SIGKILL'd / OOM'd.
- **reqwest is a Std.Live dependency.** The live runtime's reverse-proxy forwards
  via reqwest, so codegen declares reqwest for **every** Live app (`usesHttp ||
  usesEmail || usesLive`).
- **Console pre-build is fingerprint-validated.** The Rust backend is dev-only (the
  runtime is sourced from disk, never embedded), so `SKY_VERSION` is always
  `"dev"` and a version-only cache would never invalidate. `Sky.Build.Rust.Console`
  validates the cache by a content fingerprint (sha256 of the console source + the
  runtime `.rs`), rebuilding on any change.
- **`--backend rust` ignores `[go.dependencies]`.** Go FFI bindings are inert on the
  Rust backend (it can't link Go), so `regenMissingBindings` short-circuits — a
  pure-Rust build needs no `go` toolchain even when the project declares Go deps.
- **Observability export is OTLP/JSON, env-gated, inert by default.** Federation
  push (`SKY_PARENT_URL` → parent ingest) and the remote HubExporter
  (`SKY_CONSOLE_HUB` → `/v1/{logs,traces}` OTLP/**JSON** + bearer + bounded retry
  spool) mirror Go's behaviour; OTLP's JSON encoding means no protobuf dep.
- **Console telemetry data flow — push-to-local-collector.** Rust's console is a
  SEPARATE process and can't read the app's in-RAM rings, so the data path is the
  industrial push-to-collector model applied locally: the app auto-instruments each
  HTTP request into its in-RAM rings (a span + an access log via
  `observability::track`); a **lean** app (no sqlx) **pushes** that telemetry to the
  console child — the *local collector* — which ingests, writes its SQLite store,
  reads it back through the hub read kernels, and serves the UI; a **db** app instead
  writes the spill directly and the child only reads it (`parent_spill_active()`
  selects the path). Every Live app stays lean (no SQLite embedded just to get a
  console). The console shows the PARENT's telemetry; a sub-app does not
  self-instrument.

### Hub read kernels (console data plane) — generic-over-return-type

Each `hub_read_*<A: DeserializeOwned>(…) -> SkyTask<E, A>` is **generic over its
return type**: it builds a `serde_json::Value` matching the record's camelCase
serde shape and `from_value::<A>`s it. The project-generated `State*` records are
named only at the **call site**, where `A` is inferred from the concrete
`StateStore` field types — no turbofish, no `Any`, no downcast. (Go's `Hub_read*`
return `any` narrowed by `rt.Coerce` reflectively.) The value travels as its real
type `A`; the one `serde` decode is provably-shaped because the kernel owns both
the SELECT and the `Value`. (`live/hub.rs`.)

### Telemetry spill — one schema end-to-end · WAL + `mode=rw` reader

The embedded console uses **one** schema end-to-end (the hub
`service_name/time/trace_id/…` schema) for both the writer
(`telemetry_spill.rs`) and the reader (`live/hub.rs`). Go uses two (a leaner
per-app spill plus the hub schema); the Rust spill is an internal writer↔reader
contract, so a single source of truth is the richer one the console records need.
The spill is WAL (concurrent parent-writer + console-reader without livelock), and
the console reader opens `mode=rw`, not `mode=ro`: a `mode=ro` connection can't
attach `-wal`/`-shm` shared memory and silently reads stale/empty data; `mode=rw`
participates in WAL and sees all committed writes (the console only ever `SELECT`s).

### Pub/Sub broker — per-type `Broker<T>` keyed by `TypeId`

One `Broker<T>` per payload type, keyed by `TypeId`. The payload travels as its
real `T` and is **never downcast**; a publisher/subscriber type mismatch can't
construct. (Go passes payloads as `any`, type-asserted on receive.) Mirroring Go's
reflect/`any` risk surface would be a defect, not parity. (`live/pubsub.rs`.)

### Sky.Live `init` request — typed-record `LiveReq`

`req` is a typed-record `LiveReq` (`path`/`query`/`method`/`params`/`headers`/
`cookies`); the kernel type stays free so it's Go-safe on the shared seam. Go uses
a heterogeneous `Dict`/`any` map. A typed record keeps the no-`Any` invariant on
the request path. (`live/req.rs`.)

### Closure-holding Model serialization — compile-error guard

A Model field that is a callback-record (fn fields lowered to `Arc<dyn Fn>`)
derives `Clone` + a generated `Default` (disconnected error closures) and
`#[serde(skip)]`s the field; persisting such a Model to a real store is designed to
be a **compile error**. (Go reflectively serializes a session Model, skipping func
fields at runtime.) An un-restorable closure can't silently round-trip through a
session store; the type system rejects it instead of a runtime surprise.


### Multibackend program-entry model

A `main` may pick its UI backend at runtime and run it, sharing one
`init`/`update`/`subscriptions` across backends:

```elm
main =
    case List.head argsList of
        Just "live" -> Live.app { …, view = viewLive, routes, notFound } |> Task.run
        _           -> Tui.app  { …, view, onKey } |> Task.run
```

The codegen treats *any* backend driver future as the program entry, uniformly.
Three rules:

1. **`Task.run` on a backend-entry app-future is dropped.** `Live.app {…}` /
   `Tui.app {…}` / `Tui.program {…}` / `Webview.app {…}` each lower to a
   `SkyTask<()>` driver future. `App {…} |> Task.run` (or `Task.run (App {…})`)
   drops the `Task.run` *anywhere* — top-level OR inside a `case` arm — so the
   future is returned as a `SkyTask` (the entry `block_on`s it / a dispatching
   `case` unifies as `SkyTask<()>`), never executed inline via `task_run`.
2. **`mainIsTask` derives from `usesBackendApp`** (`usesLive || usesTui ||
   usesWebview`), not `usesLive` alone — so a pure-Tui / pure-Webview `App {…} |>
   Task.run` main returns `SkyTask` and is `block_on`'d.
3. **`init`'s param is derived from its Sky type, adapted per call site.** Only a
   *req-reading* init (`init req = … req.path …`, detected by
   `collectLiveReqInitFns`: param 0 binds a var used in the body) pins param 0 to
   `sky_runtime::LiveReq`. A *non-req* init (`init _`) is forced to `()` and adapted
   at the `Live.app` call site via `move |_r: LiveReq| init(())` — so the SAME init
   can also feed `Tui.app` (bound `Fn(())`). No global pin; no Tui-side change;
   every Live example's `init` body is byte-identical so the rendered HTML is
   unchanged.

`Cli.program` is intentionally excluded from the backend-entry set: it runs inline
via `task_run` (not in `usesBackendApp`), so its `Task.run` is kept.


### Std.Ui parity (byte-identical render)

`Std.Ui` is pure Sky source that builds a `Std.Html` ADT, serialised by `html.rs`
`render_html` — so parity is a **codegen-lowering + serializer** problem, not a
renderer port. Each corpus fixture runs `main = Io.writeStdout (Html.toString
(Ui.layout [] view))` and the stdout is byte-diffed Go-vs-Rust (Go is the golden).
All corpus cases are byte-identical:

| Covers | Primitives |
|---|---|
| text | `layout` + `text` |
| layout | `row`/`column`/`spacing`/`padding`/`align` |
| styling | `Background`/`Border`/`Font` |
| sized | `button`/`link`/`image` (static) |
| advanced | nearby overlays · aspect-ratio · grid |
| semantic | `Region` tag + aria mapping |

The load-bearing mechanisms (all Rust-target only, Go untouched):

- **`any`-carrier resolution** — Std.Ui's wildcard `any` slots (and a user
  `view : Model -> any`) resolve to the concrete `Html<msg>` / `Attribute<msg>`
  carrier; no `dyn Any`.
- **Whole-program DCE** — dep modules prune to the reachable-from-`main` set, so a
  one-line render emits 60 Std.Ui fns not 205.
- **Injective fn-name mangling** — `Std.Ui.borderRounded` vs `Std.Ui.Border.rounded`
  don't collide under `toSnakeCase`.
- **Serializer alignment** — `render_html` sorts attrs, renders `BoolAttr` as
  `k="true"`, and self-closes void elements with ` />`, matching Go `renderVNode`.
- **`onSubmit` form-event peephole** — `Ui.onSubmit DoSignIn` inlines to a typed
  `decode_form::<T>` dispatch.

Event *dispatch* (onPress/onSubmit) and the style-injection features (pseudo-class
/ media-query / transition / animation) render through Sky.Live's VNode path,
covered by the integration apps rather than the static corpus.

### Modification boundaries

Only modify these when working on the Rust backend:

| Directory / file | Purpose |
|---|---|
| `runtime-rust/` | runtime crate (`sky_runtime` modules, tests) |
| `src/Sky/Generate/Rust/Builder.hs` + `Builder/` | Rust codegen — `Emitter` / `ExprEmitter` / `TypeEmitter` / `Pattern` / `Kernel` / `ModuleEmitter` / `Walker` / `Naming` / `CrateSpecs` (`crate-specs.toml`) |
| `src/Sky/Generate/Rust/Project.hs` | project orchestration — `main.rs` + `Cargo.toml`, copies runtime + FFI bindings |
| `src/Sky/Build/Rust/Ffi.hs` | Rust FFI — inspector, `.skyi` / `.kernel.json` / `_bindings.rs`, coercion |
| `src/Sky/Build/Rust/Console.hs` | separate-process console pre-build (fingerprint-validated) |
| `src/Sky/Sky/Toml/Rust.hs` | Rust dependency-spec parsing (`["rust.dependencies"]`) |
| `tools/sky-ffi-inspect-rs/` | Rust crate inspector (rustdoc JSON) |

Shared compiler files keep only a minimal `case Toml._target of { TargetRust -> …;
TargetGo -> … }` dispatch seam. Dependencies are one-way (shared → Rust-only), so
the Go path stays byte-identical and upstream merges stay small.

**One shared file carries Rust-only inspector fields: `src/Sky/Build/FfiGen.hs`.**
The inspector-JSON decode type `FnInfo` (and its single Aeson `FromJSON`) lives
there and is used by both backends, so a Rust-only field can only be *decoded*
there. Every such field defaults (`""` / `False`), the Go inspector never emits it,
and no `src/Sky/Generate/Go/` code reads it → Go output byte-identical. Adding a
Rust-only `FnInfo` field is the one sanctioned shared-file touch; new *behaviour*
still goes behind `TargetRust ->` seams.


### Cross-backend rules (load-bearing)

Go is the **production backend**; Rust is second-tier.

1. **Go FFI artifacts stay at the root of `.skycache/ffi/`** —
   `<slug>.{kernel.json,skyi}`.
2. **Each non-Go backend gets its own subdir** — Rust at `.skycache/ffi/rust/`.
3. **`loadAndSeedFfiRegistry` reads target-appropriate paths** — go = root, rust =
   `rust/` subdir.
4. **Never touch Go-generated files** — `runtime-go/`, root `.skycache/ffi/*`,
   `src/Sky/Generate/Go/`.
5. **Never change shared compiler code in a way that could break Go** — new Rust
   functionality goes behind explicit `TargetRust ->` branches.
6. **`sky add` routing:** URL → `[rust.dependencies]` as `{ git = … }`; bare name →
   crates.io via `cargo fetch`.

**T1 guard.** The Go reference for `00-standard-libs` builds via a fork-local guard
in `src/Sky/Build/Compile.hs`: the synced tag carries an `undefined: T1` Go-codegen
regression (a callee-bound type var leaking into emitted Go); the guard erases the
unbound token to `any`. Without it `00`'s Go reference is broken (an upstream bug),
never a Rust failure. Reconcile the surgical guard against the upstream typed-codegen
rewrite when that lands.


### sky.toml Rust fields

```toml
[project]
backend = "rust"                   # default "go"; overridden by --backend

["rust.dependencies"]
uuid  = "1.16.0"                  # crates.io — version string
serde = { version = "1", features = ["derive"] }
mylib = { git = "https://github.com/org/mylib", rev = "abc123" }

[rust]
sqlx_tls  = "rustls"             # default; alt: "native-tls"
static    = true                 # opt-in full-static binary (musl Linux / crt-static Windows). Default false.
target    = "x86_64-unknown-linux-musl"  # cross-compile target triple. "" = host. Orthogonal to static/backend.
allocator = "mimalloc"           # "" auto (mimalloc on musl/static, system on dynamic) | "system" | "mimalloc"

[live]                            # Sky.Live apps
store     = "memory"             # memory | sqlite | postgres | redis
storePath = "sessions.db"        # file path / postgres:// URL / redis:// URL
```

Rust FFI is fully automatic (`rustdoc --output-format json`) — no hand-written
glue, even for proc-macro/derive crates. There is no `[rust.shims]` section.

**Reaching async / framework crates** (which auto-FFI can't bind directly — see the
FFI Reach section): wrap the crate in a thin fork-local crate exposing plain
`&str`→`Result`/`Dict`-shaped fns over a dedicated-thread async→sync bridge, then
reference it as a local **`file://` git** dep:

```toml
["rust.dependencies"]
my-shim = { git = "file:///abs/path/to/wrapper-repo", branch = "master" }
```

`examples/rust/skyshop-rs` is the worked example (firestore / async-stripe /
rs-firebase-admin-sdk). Use the **literal** absolute path (Cargo does not expand
`$HOME`); the wrapper must be a real git repo at that URL.

The codegen wires Cargo features from `[live] store`: `sqlite`/`postgres` enable
`db` (sqlx, both drivers — `store.rs` compiles `SqliteStore` + `PostgresStore`
together); `redis` enables a `redis_store` feature + the redis crate; `memory`
pulls neither. A non-live `Std.Db` app keeps its single driver.

---

## Verification state

### `runtime-rust/tests/sky/` — FFI + framework fixtures

The FFI / framework fixture set is 50+ Sky projects under
`runtime-rust/tests/sky/`, each building + running from a wiped slate. They cover:

- **Leaf FFI crates** (rand, num_cpus, chrono, uuid, roman, semver, bytesize, …) —
  free fns, static/instance methods, Display/FromStr, Option/Result, byte ⇄ `List
  Int`, generic-bound monomorphisation.
- **FFI reach** — `Option<&str>` param coercion, csv/regex/bytes name-collision
  handling, recovered builder setters, unsized-receiver gating.
- **Stdlib runtime** — `Std.Db` CRUD (sqlite/mysql/postgres), `Std.Auth`,
  `Std.Config`, `Std.Email`, `Std.Cache`, `Sky.Core.Char`/`Bytes`/`Task`, the
  streaming/relay surfaces.
- **App frameworks** — Sky.Live (static render, TEA-over-SSE, typed forms, URL
  routing, typed `LiveReq`, sessions, PubSub), Sky.Tui (Element → cells, key/focus
  input), Sky.Webview, Sky.Http.Server + WebSocket.
- **Codegen shapes** — Task-valued `if`/`case` branches at `main`, discard-Task
  effect ordering, curried function-valued returns, event-handler `Arc` capture,
  `List.sort`/`sortBy`/`sortWith`, bare-`any` record-field codegen rejection,
  static `Ffi.callTask` resolution, unannotated `Result` Ok-payload recovery,
  `errorToString` String/record parity, `Task.retryWith` transient-retry, and
  single-use non-`Clone` `SkyTask` capture-move.

`examples/rust/skyshop-rs` is the one real end-to-end Rust-FFI app (a 1:1 port of
`examples/13-skyshop` binding `firestore` 0.49 + `async-stripe` 1.0-rc.6 +
`rs-firebase-admin-sdk` 4.3 via fork-local wrapper crates; `verify.sh` is its
committed one-command check).

### Runtime unit tests

`cargo test --features full` passes, including the soundness suites
(`core_soundness`, `kernel_soundness`, `dict_determinism`) that assert no-panic +
sorted-iteration invariants under proptest, the Sky.Live diff/dispatch/form/store
tests (memory/sqlite + env-gated pg/redis restart-survival), and the pub/sub broker
fan-out / echo / SkipOrigin / per-type-isolation tests. The faithful view-diff and
the postgres/redis stores are covered here; generated postgres + redis live apps
are cargo-build-verified.

The per-example Go≡Rust parity table is the **Project status** sweep above.


## Error type

All runtime functions are generic over `E`; `Builder.hs` emits thin wrappers that
fix `E = SkyError`:

```rust
// sky_runtime/task.rs (generic):
pub fn task_map<E, A, B>(f: impl FnOnce(A) -> B + Send + 'static, t: SkyTask<E, A>) -> SkyTask<E, B>
// generated main.rs (wrapper):
pub fn task_map<A, B>(f: impl FnOnce(A) -> B + Send + 'static, t: SkyTask<A>) -> SkyTask<B> {
    sky_runtime::task::task_map::<SkyError, _, _>(f, t)
}
```

The effect model: every effect kernel defers its I/O into the returned Task body,
so constructing a Task is pure and the side effect fires only on `.await`. Codegen
`task_run`s (block_on) a discarded Task-typed `let _ = <task>` in program order; a
non-Task discard (`_ = List.map …`, `_ = someVar`) keeps bind/drop. So a built-but-
discarded `List (Task ())` never runs — matching Go's deferred-Task semantics.

---

## Soundness, correctness and security

Every accepted compromise is recorded here with its rationale, and mirrored at the
exact site by an inline `// SKY-RUST-AUDIT:ACCEPTED — <why>` marker. The codegen
itself emits **no** `dyn Any`; all accepted sites are irreducible-by-design.
`grep -rn 'SKY-RUST-AUDIT' runtime-rust/src` lists every settled decision.

### Accepted compromises

| Problem (location) | Disposition | Why |
|---|---|---|
| `crypto.rs` HMAC `expect_used` (`crypto_hmac_sha256` / `crypto_hmac_sha512`) | Accepted | `Hmac::new_from_slice` is infallible (accepts any key length); the pure Sky kernel `hmacSha256 : String -> String -> String` has no `Result` channel, and a fallback MAC would be a silently-wrong hash (security defect) |
| `email.rs` `hmac_bytes` `expect_used` | Accepted | same — a fallback MAC is a wrong SES signature |
| `ffi_polyfills.rs` `panic` (×2: `ffi_call_pure_polyfill` / `ffi_call_task_polyfill`) | Accepted | statically dead for valid Sky (the codegen peephole resolves the static-dispatch shape); the dynamic fallback returns an unconstrained generic `T` with no total value to synthesise |
| `dyn Any` sites (pubsub broker, cache store/value) | Accepted | each `TypeId`-/`K`-keyed and correct-by-construction; the payload travels as its real type and is never erased — see the register below |
| `unsafe` `pre_exec` (`PR_SET_PDEATHSIG`, `live/console_proxy.rs`) | Accepted | `cfg(linux)` orphan-guard; the closure only calls `prctl` (async-signal-safe) between fork and exec, off any Sky value path; failure non-fatal. No safe stdlib API delivers a parent-death signal |

The clippy gate denies the panic-prone lint family (`unwrap_used` / `expect_used`
via `Cargo.toml [lints.clippy]` + `clippy.toml`; `indexing_slicing` / `panic` /
`unreachable` via `src/lib.rs` `#![cfg_attr(not(test), deny(…))]`). The
`#[allow]`d exceptions are exactly the irreducible sites above. Everything else is
panic-vector-free: lock-family unwraps use `unwrap_or_else(|e| e.into_inner())`
(poison-tolerant); AES/ChaCha propagate `new_from_slice` errors into their
`SkyResult` channel; the cookie-sid lookup degrades an impossible `None` to a fresh
session; the SSE response builder falls back to a 500 rather than `unwrap`; every
slice/array access uses `.get(...)` / iterators / a checked total form rather than
`[i]`.

### `dyn Any` register

Each `dyn Any` site is irreducible-by-design (forced by a Sky kernel signature that
erases a type the runtime must round-trip), and each downcast is correct by
construction:

| Site | Shape | Verdict |
|---|---|---|
| `live/pubsub.rs` broker registry | `Box<dyn Any + Send + Sync>` → `Arc<Broker<T>>`, keyed by `TypeId` | only an `Arc<Broker<T>>` is ever stored under `TypeId::of::<T>()`; the payload travels as its real `T`, never erased — only the broker *container* is. The single `downcast_ref` is `TypeId`-gated; its structurally-impossible `None` degrades gracefully (logs + fresh broker) |
| `cache.rs` per-handle store | `Box<dyn Any + Send>` → `Vec<CacheEntry<K>>` | the Sky `Cache_size`/`Cache_clear` kernels carry no `V`, so the per-handle store can't be fully `(K,V)`-typed. Downcast by `K` (every op on a handle uses the same `K`, per Sky's `Cache k v`) can't fail; mismatch → no-op. Keys matched by `PartialEq` (linear) |
| `cache.rs` cache value | `Box<dyn Any + Send>` (one per entry) → `V` | `Cache_remove` carries no `V`, so values are erased and downcast to `V` only on `get` (where the kernel return makes `V` available). Per-handle `V`-consistency makes the cast total; on the impossible miss it returns `Nothing` |

`html.rs` `OnRaw(String, Arc<dyn Any + Send + Sync>)` is an opaque event payload
**only ever passed through**, never `downcast` in Rust — no cast, no failure mode.


### Rust FFI

`sky add <crate> --backend rust` invokes `sky-ffi-inspect-rs`, which runs
`cargo +nightly rustdoc --output-format json` (so derive/proc-macro impls are
visible), maps Rust types → Sky types (`Vec→List`, `Option→Maybe`, `HashMap→Dict`,
`Result→Result E A`), and writes
`.skycache/ffi/rust/<slug>.{kernel.json,skyi,_bindings.rs}`.

- **Opaque types** are emitted fully-qualified by public re-export path
  (`chrono::NaiveDate`), so wrappers need only one root `use <crate>::*;`.
- **Nameability filter:** generic fns, lifetime-parameterised types, borrowed
  results, non-byte slices/arrays, `unsafe fn`, and private/std types are dropped so
  `_bindings.rs` always compiles. Byte sequences (`&[u8]`, `[u8; N]`, …) are kept
  and bridged to `List Int`.
- **Display/FromStr bridge:** opaque types implementing them get synthetic
  `to_string`/`from_string` bindings.
- **Method bindings disambiguate by receiver:** `Utc::now` → `now_from_utc`.
- **Inspector resolution:** `$SKY_FFI_INSPECTOR_RS` → `./bin/sky-ffi-inspect-rs`
  (ancestors) → TH-embedded binary at `~/.cache/sky/tools/`.

### Reach (what auto-FFI can/can't cover)

The boundary is type-theoretic, not a maturity gap: only `rustc` resolves Rust's
generics (monomorphised — no callable symbol until concrete), traits (open), and
lifetimes. So **leaf/data crates** (hashing, codecs, parsing, math, time, regex,
many client SDKs) auto-bind well; **frameworks** (axum, bevy, diesel, tokio) are
generic+trait+`Stream` at the core and auto-bind almost nothing usable. The
Sky-Rust strategy is **automatic FFI over the leaf universe + Sky-native modules
over frameworks** (the `Sky.Live` / `Sky.Http.Server` model — built on axum/hyper
internally, exposing a Sky-idiomatic surface). "Verbatim FFI to any framework" is a
deliberate non-goal.

The widenings that extend leaf-crate reach:

- **Generic-bound monomorphisation** — monomorphises generic fns whose bound maps to
  a Sky type (`AsRef<[u8]>`/`Into<Vec<u8>>` → `List Int`; `AsRef<str>`/`Display` →
  `String`); a recursive extension resolves nested `AsRef`/`Into`/`IntoIterator`
  inner types (soundness-gated: primitive-numeric `Into`/`From` resolve at identity
  only).
- **Builder setters** — `&mut self -> &mut Self` and in-place `&mut self -> ()`
  methods are exposed as owned-threading wrappers (`fn(recv, args) -> recv`),
  recovering the *configuration* surface of builder-pattern crates; a by-value
  `-> Self` is left on the normal path.
- **Lifetime-elided copies** — `&'a str`/`&'a [u8]`/`&'a OsStr`/`&'a Path` are kept
  as owned copies (the lifetime token is an elision artifact).
- **`Option<T>` params** — `SkyMaybe<T>` bridges to `Option<&str>` (`.as_deref()`),
  `Option<u16>` (`.map`), `Option<&T>` (`.as_ref()`), else identity.
- **Absolute `::<crate>` paths** — every extern-crate reference is emitted
  `::csv::…` (no `use crate::*` glob shadowing) so a crate named like an unsuffixed
  kernel module (`csv`/`time`/`log`/`json`/`config`/`email`/`html`) no longer
  collides.
- **Glob-re-export qualification** — types defined in a private submodule and
  glob-re-exported at the crate root (regex's `RegexBuilder` in private
  `builders::string`) are recorded at the usable public path.
- **Submodule name disambiguation** — same-named types in different submodules get
  distinct Sky names (`regex::Regex` → `Regex`, `regex::bytes::Regex` →
  `BytesRegex`).
- **Builtin name disambiguation** — a crate root type whose bare name equals a Sky
  builtin (`bytes::Bytes`) is crate-prefixed (`BytesBytes`).
- **Sized gate** — an instance method whose receiver type is never produced by value
  anywhere (a DST like `bytes::buf::UninitSlice`) is dropped.

Measure constructable surface per crate with the `sky-rust-backend:ffi-audit` skill.
The inspector's `--audit` flag tags every tail-filter drop with reason +
constructable-or-not for diagnostics.


### FFI codegen type-coercion rules

`Sky.Build.Rust.Ffi` (`emitRustFnSimple`).

**Param type (`resolveRustType`).** Sky-mapped for known types; raw qualified type
for opaque:

| Sky param type | Wrapper param type |
|---|---|
| `String` | `String` (borrowed `&argN` internally) |
| `Int` / `Float` / `Bool` / `Bytes` | `i64` / `f64` / `bool` / `Vec<u8>` |
| `List a` / `Maybe a` / `Dict String v` | `Vec<…>` / `SkyMaybe<…>` / `HashMap<…>` |
| opaque | fully-qualified raw type |

**Param coercion (`argCall`).**

| Wrapper type | Raw param | Emitted arg |
|---|---|---|
| `String` | `&str` | `&argN` |
| `i64`/`f64` | narrower numeric | `argN as <raw>` |
| `Vec<i64>` | `&[u8]` / `Vec<u8>` | `&to_u8_vec(&argN)` / `to_u8_vec(&argN)` |
| `Vec<i64>` | `[u8; N]` / `&[u8; N]` | prelude `let bN = to_u8_array::<_,N>(…)?;` then `bN`/`&bN` |
| anything | same/absent | `argN` |

`[u8; N]` length mismatch returns `Err`, never panics.

**Return coercion (`translateRustRet`)** — driven by the raw Rust return:

| Raw return | Wrapper return | Lift |
|---|---|---|
| `&[u8]` / `Vec<u8>` / `[u8; N]` | `Vec<i64>` | `from_u8_slice(…)` |
| `Option<T>` | `SkyMaybe<T'>` | `Some→Just`, `None→Nothing` |
| `Vec<T>` | `Vec<T'>` | per-element map only if `T` needs coercion |
| `iN`/`uN` / `f32`/`f64` | `i64` / `f64` | `as i64` / `as f64` |
| `&str`/`&String` | `String` | `.to_string()` |
| opaque `T` | `T` (qualified) | identity |

Effect drives the body: `pure` → `ok_res(lift(call))`; `fallible` → `match` on
`Result`; `effectful` → the same inside `Box::pin(async move { … })`.

---

## Build performance & DX

Sky→Rust compiles the generated project with `cargo`, so the first build of an app
with heavy deps (tokio / axum / sqlx / a framework FFI crate) is a real Rust
compile. These strategies cut the *second* build to seconds — they change the build
*mechanism*, never the output:

| Strategy | What it buys |
|---|---|
| **sccache** (`RUSTC_WRAPPER=sccache`) | a shared compilation cache — each crate object is cached across projects + rebuilds, so the heavy dep tree compiles once machine-wide |
| **Shared `CARGO_TARGET_DIR`** | one target dir for every example → tokio/serde/sqlx/axum built once and reused, not recompiled per app |
| **Lean dev profile** | the generated `Cargo.toml [profile.dev]` already sets `debug = 0` + `incremental = true` (via `emitCargoToml`) |
| **Cached FFI bindings** | `.skycache/ffi/rust/*.{skyi,kernel.json,_bindings.rs}` are generated once; only `sky add` / `sky install` (or a wiped `.skycache`) re-runs the nightly-rustdoc inspector |
| **Compiler dev loop** | only codegen (`.hs`) edits need a `cabal build`; edits under `runtime-rust/src/` are copied into the generated project at `sky build` time → rebuild only the example |

Standalone runtime compile-check (fastest gate for `.rs` edits): `cargo check
--manifest-path runtime-rust/Cargo.toml --features full` (~1.2 s warm); `cargo build
--manifest-path runtime-rust/Cargo.toml --features full` (~2.4 s warm) when link
errors matter. `sky check` always runs the **Go** pipeline; it does not validate the
Rust codegen path — use `sky build --backend rust` for that.

The canonical inner loop (Sky source or runtime `.rs` change, no `.hs` edit): `sky
run --backend rust src/Main.sky` rebuilds + runs — ~0.3 s warm, ~1-2 s on first
change. A runtime-only `.rs` edit is re-copied into the generated project on the next
`sky run` (no wipe needed). Detailed env setup and the disk-hygiene recipe live in
`runtime-rust/CLAUDE.md`.

**Readable output.** The generated `sky-out/Rust/src/*.rs` is run through `rustfmt`
(per-file, `--edition 2021`, best-effort) before the `cargo build` — so the emitted
Rust reads like hand-written code when inspected. `SKY_RUST_FMT=0` skips it.

---

## Static & cross compilation

Opt-in. The default build is unchanged (glibc-dynamic, host platform, system
allocator). `--static` / `--target` / `[rust] static` / `[rust] target` /
`[rust] allocator` turn on the modes below; non-opt-in builds are byte-identical
to before.

### Static compilation

`--static` (or `[rust] static = true` / `SKY_RUST_STATIC=1`) per-OS matrix:

| Host | Mechanism | Result |
|---|---|---|
| **Linux** | `--target x86_64-unknown-linux-musl` + mimalloc (`static_alloc`) | true static-pie; zero `ldd` deps |
| **Windows** | `-C target-feature=+crt-static` | static MSVC CRT |
| **macOS** | — (Apple ships no static libc) | **degrades** to a native dynamic binary + a warning showing the cross-compile recipe |
| **webview app** | — (links system WebKit/WebView2) | **refused** with an actionable error |

Toolchain: the Linux musl path needs `rustup target add
x86_64-unknown-linux-musl` + a musl C toolchain (`musl-tools`); `sky` checks both
and errors with the exact install command if either is missing.

#### Global allocator (mimalloc)

The static build swaps the Rust `#[global_allocator]` for **mimalloc**
(feature-gated `static_alloc`, compiled only when enabled). It's a **separate
knob** from static (`[rust] allocator` / `--mimalloc` / `--system-alloc`):
**auto** default → mimalloc on musl/static, system on dynamic.

| Pros | Cons | Risks |
|---|---|---|
| Drop-in malloc — frees per-allocation, so RSS stays bounded on a long-running server | Adds a C dep (cc-built; needs the musl C toolchain for the static target) | **Why not a bump/arena allocator:** it can't free per-object, so as a *global* allocator it grows unbounded → OOM (violates the no-OOM floor). mimalloc frees normally. |
| Per-thread heaps + low fragmentation — built for the multithreaded server hot path | ~2× baseline RSS vs the system allocator (its segment reservation) | The **default dynamic** build uses the system allocator = **glibc `malloc` (ptmalloc2, per-thread arenas)** — "arena-based malloc" in the glibc sense, but **not** a bump/arena (`bumpalo`-style) allocator, which Sky uses nowhere. |
| Feature-gated → dynamic default builds are byte-identical | One more build dimension | musl static + `system` allocator is a throughput cliff (below) — gated behind a loud warning. |

**Measured** (alloc-stress fixture: allocation-heavy `Sky.Http.Server`, `ab -c50`;
2×2 linking × allocator):

| variant | throughput | peak RSS |
|---|--:|--:|
| A dynamic + glibc malloc | 1457/s | 8.5 MB |
| B dynamic + mimalloc | 2511/s (**1.72× A**) | 16.3 MB |
| C static(musl) + mimalloc | 2149/s (**1.48× A**) | 14.7 MB |
| D static(musl) + musl malloc | ~192/s (**0.14× A**) | 7.8 MB |

mimalloc is **1.72×** glibc on dynamic; **musl's own malloc is ~7× slower** than
glibc (~11× vs mimalloc) and it's **not** contention-driven (≈same at `-c4` and
`-c50` — musl malloc is just slow for high-volume small allocations). So
`--static` keeps mimalloc **default-on**; `--system-alloc` is an opt-out only for
RSS-constrained deploys (D is the leanest at 7.8 MB) and emits a loud cliff
warning. RSS stays bounded under sustained churn (C growth 1.024×).

#### Size: static vs dynamic vs Go

**Local sweep** — every statically-compilable example, release binary sizes (KiB),
*measured 2026-06-18 on an x86_64 Linux host (native musl)*:

| Example | Shape | Dynamic | Static (musl) | Go | Static/Dyn | Static/Go | Cold dyn→static |
|---|---|--:|--:|--:|--:|--:|--:|
| 00-standard-libs | cli | 1393K | 1622K | 31605K | 1.16 | 0.051 | 590→97 ms |
| 01-hello-world | cli | 575K | 822K | 30381K | 1.43 | 0.027 | 7→109 ms |
| 02-go-stdlib | cli | 3617K | 3880K | 31500K | 1.07 | 0.123 | 504→113 ms |
| 04-local-pkg | cli | 576K | 822K | 30383K | 1.43 | 0.027 | 4→93 ms |
| 06-json | cli | 756K | 994K | 30994K | 1.32 | 0.032 | 13→161 ms |
| 07-todo-cli | cli | 3334K | 3634K | 30759K | 1.09 | 0.118 | 9→104 ms |
| 09-live-counter | live | 4959K | 5180K | 397574K | 1.04 | 0.013 | — |
| 10-live-component | live | 4951K | 5168K | 397546K | 1.04 | 0.013 | — |
| 12-skyvote | live | 9505K | 9696K | 399679K | 1.02 | 0.024 | — |
| 14-task-demo | cli | 599K | 842K | 30601K | 1.41 | 0.028 | 4→127 ms |
| 15-http-server | server | 1825K | 2031K | 397536K | 1.11 | 0.005 | — |
| 16-skychess | live | 9272K | 9500K | 399080K | 1.02 | 0.024 | — |
| 17-skymon | live | 9693K | 9904K | 398871K | 1.02 | 0.025 | — |
| 18-job-queue | live | 8991K | 9232K | 397798K | 1.03 | 0.023 | — |
| 19-skyforum | live | 5195K | 5408K | 398045K | 1.04 | 0.014 | — |
| 20-cli-counter | cli | 654K | 894K | 30568K | 1.37 | 0.029 | 4→123 ms |
| 21-tui-stopwatch | tui | 688K | 922K | 30598K | 1.34 | 0.030 | — |
| 22-tui-stopwatch-ui | tui | 856K | 1090K | 33121K | 1.27 | 0.033 | — |
| 23-tui-todo | tui | 885K | 1118K | 33208K | 1.26 | 0.034 | — |
| 24-tui-kitchen-sink | tui | 5354K | 5532K | 398426K | 1.03 | 0.014 | — |
| 25-sky-console | live | 5151K | 5360K | 397827K | 1.04 | 0.013 | — |
| 26-ui-showcase | live | 5348K | 5556K | 398498K | 1.04 | 0.014 | — |
| 27-multi-session-chat | live | 9046K | 9288K | 397703K | 1.03 | 0.023 | — |
| 28-streaming-chat | live | 5027K | 5252K | 397575K | 1.04 | 0.013 | — |
| 30-sse-server-demo | server | 1836K | 2043K | 397559K | 1.11 | 0.005 | — |
| 32-sse-relay | server | 4579K | 4804K | 397614K | 1.05 | 0.012 | — |
| 33-websocket-echo | server | 2041K | 2239K | 397665K | 1.10 | 0.006 | — |
| 34-multi-tier-console | live | 4984K | 5208K | n/a | 1.05 | — | — |
| 35-composite-generics | cli | 2696K | 2922K | 31366K | 1.08 | 0.093 | 10→130 ms |
| 36-composite-server | server | 5054K | 5190K | n/a | 1.03 | — | — |
| 37-composite-live-shop | live | 5488K | 5676K | n/a | 1.03 | — | — |
| 38-composite-ui-multibackend | tui | 6125K | build-fail | n/a | — | — | — |
| simple | cli | 618K | 862K | 30516K | 1.40 | 0.028 | 4→105 ms |
| test_pkg | cli | 575K | 822K | 30381K | 1.43 | 0.027 | 4→93 ms |

- **Static/Dyn 1.02–1.43× (mean 1.15×)** — the static overhead is proportionally
  bigger on tiny CLIs, ~1.02–1.05× on real apps.
- **Static is 0.5–12.3% of Go's binary** — even static-vs-static, Rust wins
  decisively. (Go Live binaries are ~390 MB because they embed the bundled
  console; Rust static live binaries are ~5–9 MB.)
- **Cold-start caveat:** static binaries start slower (~95–160 ms vs ~4–13 ms
  dynamic) from musl + mimalloc init — amortized on long-running servers, but it
  matters for frequently-invoked CLIs.
- Anomalies: `34/36/37` Go build failed (Go size `n/a`; the Rust static built
  fine); `38-composite-ui-multibackend` static `build-fail` — it includes a
  webview backend, which can't link static (expected).

**CI cross-OS static build** — 5 shape-diverse examples, the `static-perf`
workflow_dispatch job, *measured 2026-06-18 on GitHub runners*. Per-OS static
target: **Linux** `x86_64-unknown-linux-musl` (native) · **Windows**
`-C target-feature=+crt-static` (native MSVC) · **macOS** `x86_64-unknown-linux-musl`
(cross — a Linux ELF). **What's measured where, and why:** `Build` + `Bin` on all
three OS; `Thru`/`RSS`/`Cold` (static-vs-dynamic) on **Linux only** — a macOS
cross-build produces a *Linux* binary that can't run on the macOS host, and the
Windows runner has no `ab`/RSS harness. Webview examples are excluded — they link
the system WebKit/WebView2 and cannot statically link. (macOS `Bin` is blank: the
size probe used GNU `stat -c%s`, unavailable on macOS — but the cross artifact *is*
the `linux-musl` binary, so its size ≈ the Linux `Bin` column.)

| OS | Example | Shape | Build | Bin (static) | Static/Dyn | Thru s/d | RSS s/d (MB) | Cold d→s (ms) |
|---|---|---|:-:|--:|--:|--:|--:|--:|
| Linux | 01-hello-world | cli | ✅ | 810K | 1.45 | — | — | 4→4 |
| Linux | 15-http-server | server | ✅ | 1991K | 1.15 | 11727→11977 | 4→12 | — |
| Linux | 18-job-queue | live | ✅ | 9152K | 1.01 | 9347→9158 | 106→130 | — |
| Linux | 21-tui-stopwatch | tui | ✅ | 910K | 1.38 | — | — | 4→4 |
| Linux | 33-websocket-echo | server | ✅ | 2191K | 1.13 | 11618→11804 | 4→12 | — |
| Windows | 01-hello-world | cli | ✅ | 461K | 1.31 | — | — | — |
| Windows | 15-http-server | server | ✅ | 1687K | 1.07 | — | — | — |
| Windows | 18-job-queue | live | ✅ | 9242K | 1.01 | — | — | — |
| Windows | 21-tui-stopwatch | tui | ✅ | 588K | 1.23 | — | — | — |
| Windows | 33-websocket-echo | server | ✅ | 1888K | 1.06 | — | — | — |
| macOS | 01-hello-world | cli | ✅ | — | — | — | — | — |
| macOS | 15-http-server | server | ✅ | — | — | — | — | — |
| macOS | 18-job-queue | live | ✅ | — | — | — | — | — |
| macOS | 21-tui-stopwatch | tui | ✅ | — | — | — | — | — |
| macOS | 33-websocket-echo | server | ✅ | — | — | — | — | — |

All 5 shapes **build static on every OS** — including the **macOS → Linux cross**
(the previously-unverified leg) and `tui`. On Linux all 5 also **run** static (the
local `15-http-server` SIGSEGV was environment-specific, not reproduced on CI);
mimalloc-on-musl holds throughput within noise of dynamic (servers ~1.0–1.02×) at
~2–3× RSS — consistent with the allocator 2×2 above.

### Cross compilation

`--target <triple>` / `[rust] target` selects the **output platform** as a raw
Rust target triple (no aliases — it matches `cargo --target` exactly), orthogonal
to `--static`: `--target x86_64-unknown-linux-gnu` alone is a dynamic Linux
cross-build; `--static --target x86_64-unknown-linux-musl` is a static Linux
artifact from any host. (`--target` is distinct from `--backend`, which selects
the codegen backend go/rust.) Common triples:

| Triple | Platform |
|---|---|
| `x86_64-unknown-linux-musl` | Linux x86_64, static-capable |
| `aarch64-unknown-linux-musl` | Linux arm64, static-capable |
| `x86_64-unknown-linux-gnu` | Linux x86_64, glibc |
| `aarch64-unknown-linux-gnu` | Linux arm64, glibc |

Toolchain: `rustup target add <triple>` + a musl C cross-linker (`musl-tools` on
Linux x86_64; `brew install FiloSottile/musl-cross/musl-cross` on macOS). `sky`
sets `CARGO_TARGET_<T>_LINKER` automatically and errors with the exact install
command if the target/linker is missing. The macOS-host → Linux cross leg is
implemented, pending macOS verification.

---

## Known limitations

| Limitation | Description | Workaround |
|---|---|---|
| `any` in record fields | A bare-wildcard `any` record field is rejected at codegen with a structured `error[Rust]: any-typed record field …` (no heterogeneous `Box<dyn Any>` field, by the no-`Any` floor). A declared alias type-param `any` works as a normal generic | Encode the payload as an ADT upstream, or use a concrete type |
| composite ADT stringification (`errorToString` / `Basics.toString`) | String, scalars, lists, maps and **records** are Go-`%v`-identical (records via `SkyStringify`, `{f0 f1}` in `_fieldIndex` order). An **ADT** value renders best-effort `Ctor p0 p1`, NOT Go's reflected flattened-struct `{tag payload}` layout (a Rust sum type can't reproduce Go's zero-init inactive fields without fabrication) | Stringify the ADT's fields explicitly when exact Go parity is required |
| `Task.retryWith` bound-value task | An **inline-expression** task retries per policy (the headline flaky-API case). A task passed as a **bound local** (`let t = … in retryWith p t`) is a one-shot `SkyTask` (`Pin<Box<dyn Future>>`, not re-runnable) → it runs once and ignores the attempt count | Pass the task inline: `retryWith p (Http.get url)` |
| non-`Clone` capture (multi-use / opaque handle) | A **single-use** bound `SkyTask` captured into a closure is moved (not cloned). A **multi-use** non-`Clone` capture, or a non-`Clone` opaque FFI handle captured into a closure, still hits the clone prelude → `cargo build` fails. The general fix is an ownership-model change (no-clone set from region types) | Restructure to a single use, or inline the value rather than capturing it |
| `withTransaction` nested scope | BEGIN/body/COMMIT/ROLLBACK now run on one dedicated connection (rollback is real on any pool size). A **nested** `withTransaction` is flattened onto the outer transaction — no per-nesting SAVEPOINT, so an inner `Err` doesn't roll back independently | Use a single transaction scope; split into separate transactions for independent rollback |
| Bytes non-ASCII *text* base64/hex | Lossless on ASCII / hex / binary (byte-identical to Go); differs from Go only when a `Bytes` value holds literal non-ASCII *text bytes* compared against a Go-/externally-computed encoded string | Compare decoded values rather than encoded strings |
| `Ffi.callTask` / `Ffi.callPure` dynamic dispatch | static-shape calls (literal kernel name + literal args) are peephole-resolved to the direct kernel call; the genuinely-dynamic path (non-literal name/args) is unsupported by design (no reflection / no `Box<dyn Any>`) | Use a string-literal kernel name + list-literal args, or `Ffi.kernel "<name>"` for value-level selection |
| `rustdoc` needs nightly | Inspector runs `cargo +nightly rustdoc` — rustdoc-JSON output is unstable upstream | `rustup install nightly` |
| Un-nameable FFI bindings dropped | Generics, borrowed-view returns, lifetime-bound handles, std types, unsafe fns skipped (builder setters / `Option<T>` params / glob re-exports are recovered) — a soundness filter, not a maturity gap | Use a wrapper crate with owned/primitive signatures |
| WASM target | Not yet supported — needs a `Send`-free, threads/`tokio`-free runtime rewrite (`SkyTask` is `Send`-everywhere; `block_on` builds a multi-thread runtime + OS thread) | — |

---

## Glossary

**Sky language**

| Term | Meaning |
|---|---|
| **Sky** | Elm-family functional language compiling to typed Go (reference) and Rust (this backend), via a Haskell compiler |
| **Sky source** | `.sky` files |
| **stdlib** | `Sky.Core` (pure + kernels), `Std` (effects), `Sky.Http` (server) — shared across both backends |
| **kernel function** | a built-in runtime primitive dispatched by name; surfaced in Sky as `Ffi.kernel "Name"` |
| **TEA** | The Elm Architecture — `init` / `update` / `view` / `subscriptions` |
| **Sky.Live / Sky.Tui / Sky.Webview / Sky.Cli** | the app backends: web (HTTP+SSE), terminal (ANSI cells), desktop (system webview), one-shot/loop CLI |

**Compiler pipeline** (`src/Sky/`)

| Stage | Where |
|---|---|
| **Parse** | lexer + layout filter + parser — `Parse/` |
| **Canonicalise** | name resolution, import validation — `Canonicalise/` |
| **Type check** | HM inference + exhaustiveness — `Type/` |
| **Lower** | canonical AST → IR — `Build/Compile.hs` |
| **Generate** | IR → target language — `Generate/{Go,Rust}/` |
| **TargetGo / TargetRust** | the compile-target selector (`--backend rust`); shared code branches on it at a minimal seam |

**Rust codegen — Haskell side** (`src/Sky/Generate/Rust/`, `src/Sky/Build/Rust/`)

| Term | Meaning |
|---|---|
| **Builder.hs / Emitter / ModuleEmitter / ExprEmitter / TypeEmitter** | the Rust code generators (expr / type / pattern / module / `Cargo.toml` emission) |
| **Walker.hs** | the kernel-usage analyzer — produces `UsedKernels` (the `usesX` flags) |
| **`usesX` flags** | `usesLive` / `usesTui` / `usesWebview` / `usesBackendApp` / `usesTaskRun` / `usesTaskParallel` / `usesDb` / `usesHttp` / `usesHttpServer` / `usesWsClient` / `usesEmail` / `usesTea` / `usesHtml` — gate which runtime modules + crates are emitted |
| **`mainIsTask`** | entry-mode flag — when true the entry `block_on`s `sky_main()` |
| **peephole** | a call-site pattern rewrite in codegen (e.g. `Ev.onSubmit` → typed `decode_form`, `App {…} \| Task.run` → drop the `Task.run`) |
| **monomorphise** | resolve Sky's `any`/generics to a concrete Rust type at the call site, instead of erasing to `Box<dyn Any>` |
| **DCE** | whole-program dead-code elimination — dep modules prune to the reachable-from-`main` set |
| **runtimeOpaqueTypes** | Sky types the runtime must name (Request/Response/LiveReq/Csv…) bridged to concrete Rust structs/enums |
| **CrateSpecs / `crate-specs.toml`** | single source of truth for generated-project crate versions/features; `cargoDependencyFor name` emits a dependency line from it |

**Rust runtime crate** (`runtime-rust/src/sky_runtime/`)

| Type / fn | Meaning |
|---|---|
| **`sky_runtime`** | the runtime crate copied into every generated project |
| **`SkyResult` / `SkyMaybe`** | Rust forms of `Result Error a` / `Maybe a` |
| **`SkyString` / `SkyList` / `SkyDict`** | Sky string / list (`Vec`) / dict (`HashMap`) |
| **`SkyTask` / `SkyCmd` / `SkySub`** | async task (`Pin<Box<dyn Future>>`) / TEA command / TEA subscription |
| **`SkyError`** | the project error type the generated wrappers fix `E` to (`String`) |
| **`SkyRow`** | trait a `Db.get*` row is decoded through (no `Any`) |
| **`SubManager` / `spawn_subs`** | the two Sub drivers (Cli/Tui loop · Sky.Live) — both spawn `SkySub::Source` subscriptions and abort+respawn per model update |
| **`Broker<T>`** | per-payload-type pub/sub broker keyed by `TypeId` — the payload travels as its real `T`, never downcast |
| **`SessionStore`** | the Sky.Live session-store trait — `Memory` / `Sqlite` / `Postgres` / `Redis` impls |
| **`LiveReq`** | the typed `init` request record (`path`/`query`/`method`/`params`/`headers`/`cookies`) |

**FFI** (`src/Sky/Build/Rust/Ffi.hs`, `tools/sky-ffi-inspect-rs/`)

| Term | Meaning |
|---|---|
| **FFI binding** | generated Rust wrapping an external crate function |
| **FFI inspector** | `sky-ffi-inspect-rs` — scans a crate's public API via `cargo +nightly rustdoc --output-format json` |
| **FFI registry** | cached inspection results at `.skycache/ffi/rust/` |
| **nameability filter** | drops un-bindable items (generics, borrows, non-byte slices, `unsafe fn`, std/private types) so `_bindings.rs` always compiles |
| **generic-bound monomorphisation** | the widening that monomorphises generic fns whose bound maps to a Sky type (`AsRef<[u8]>` → `List Int`, `Display` → `String`) |
| **opaque type** | an FFI type emitted by its fully-qualified path (`chrono::NaiveDate`), passed through without inspection |

**Build artifacts + conventions**

| Term | Meaning |
|---|---|
| **`sky-out/` · `sky-out/Rust/`** | compiler output · Rust codegen output (capital `R` by convention) |
| **`.skycache/` · `.skycache/ffi/rust/`** | build cache (source hashes, lowered IR) · Rust FFI registry |
| **`SKY-RUST-AUDIT:` marker** | an in-code decision marker (ACCEPTED) mirroring the soundness ledger |
| **no-`Any` invariant** | generated code + Sky-reachable runtime paths use the static type system end-to-end; the one `unsafe` is the console orphan-guard |
