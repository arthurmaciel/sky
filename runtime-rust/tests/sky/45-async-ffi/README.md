# 45-async-ffi — Sky→Rust auto-FFI ASYNC foreign fn (task #15 probe + regression)

Rust-backend FFI test fixture (NOT an author example — lives under
`runtime-rust/tests/sky/` per the boundary rule). Probes whether a REAL
`async fn` backed by tokio auto-binds and drives end-to-end through Sky's Task
runtime.

**STATUS: RED-by-design.** This fixture FAILS to build today — it is the
regression artifact for task #15. Three compile-time codegen bugs in the
effectful-FFI path (below) must be fixed before it goes GREEN. It is NOT in the
green fixture set / sweep until then.

## Layout
- `asyncffi-crate/` — tiny local Rust crate. One `pub async fn delay_echo(x: i64,
  ms: i64) -> Result<i64, String>` that `tokio::time::sleep`s `ms` then returns
  `x*2`. Total / no-panic (`ms.max(0)`, `saturating_mul`). `tokio` with `time` +
  `rt` features.
- `setup.sh` — git-inits `asyncffi-crate/` into the cache path the `sky.toml`
  `file://` dep points at.
- `src/Main.sky` — drives `delay_echo` via the Task path
  (`main : Task Error ()`, `Task.andThen`), asserts `delay_echo 21 5 == 42`.

## Run
```sh
bash setup.sh
# build the source inspector + pin it (avoids a stale embedded inspector)
cargo build --release --manifest-path ../../../../tools/sky-ffi-inspect-rs/Cargo.toml
export SKY_FFI_INSPECTOR_RS="$(pwd)/../../../../tools/sky-ffi-inspect-rs/target/release/sky-ffi-inspect-rs"
sky build --backend rust src/Main.sky          # FAILS today (see below)
# after the fix → ./sky-out/rust/target/debug/sky-app → delay_echo(21, 5)=42  [ALL OK]
```

## What the probe found (2026-06-22)
The inspector correctly classifies `async fn … -> Result<T,String>` as
`effect="effectful"` (`classify_effect`, `is_async` → effectful). But three
downstream codegen bugs make the bound async fn impossible to use:

1. **`.skyi` / kernel.json TYPE ignores effect.** `wrapperSkyType`
   (`src/Sky/Build/FfiGen.hs`) never consults `_fnEffect`; it emits
   `delay_echo : Int -> Int -> Result String Int` (sync `Result`) for an
   effectful fn instead of `… -> Task Error Int`. This is the HM type source,
   so driving it as a Task is a Sky-side E2001 (`expected Result String Int,
   actual Task Error Int`), and driving it as a `Result` then hits cargo (#2/#3).

2. **Wrapper return double-wraps the Result.** The `effectful` branch in
   `src/Sky/Build/Rust/Ffi.hs` (~L701, `retInner`) runs `translateRustRet` on the
   RAW `Result<i64,String>` (the `fallible` branch unwraps via `okTypeOfResult`
   first; effectful doesn't). It emits
   `SkyTask<SkyError, Result<i64, String>>` while the body's `ok_res(v)` puts
   `i64` in the Ok slot → **E0271** (future resolves to the wrong type).

3. **`SkyTask<A>` alias arity.** Generated `main.rs` declares
   `pub type SkyTask<A> = sky_runtime::SkyTask<SkyError, A>;` (1 param), but the
   wrapper writes `SkyTask<SkyError, …>` (2 params) → **E0107**. The wrapper
   should use the 1-arg project alias (`SkyTask<i64>`) or the 2-arg runtime path.

All three are COMPILE-TIME (the Rust backend's "type-checks ⇒ cargo-builds"
floor catches this before runtime — no false success). The reactor question
(does the future actually drive?) is unanswerable until they're fixed.
