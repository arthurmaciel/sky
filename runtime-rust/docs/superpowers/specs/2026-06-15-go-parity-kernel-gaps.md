# Go-Parity Kernel Gaps — Verified Worklist

**Date:** 2026-06-15  
**Branch:** feat/runtime-rust  
**Trigger:** `skydex parity --gaps | grep '^go-only'` reported 81 candidates.  
**Status after Step 2:** 75 remain (6 Math kernels shipped as commit b33d6081).

---

## Methodology

All candidates were ground-truth tested: a minimal Sky program calling each flagged function was built with `sky build --target rust`. Build failures (`E0425 cannot find function/value`) confirm REAL gaps; clean builds are skydex over-reports.

---

## Over-reports found (skydex mis-flags)

| Kernel | Reason |
|---|---|
| `System.cwd` | Already implemented as `system_cwd` in `runtime-rust/src/sky_runtime/system.rs`. Skydex reports `System.getcwd` as the gap — which is a REAL gap (see below). The ground-truth test inadvertently tested `System.cwd` (not `getcwd`), confirming `cwd` works. |

**Net: 0 genuine over-reports.** All 81 original flags — minus the 6 Math kernels now shipped — are genuine build failures.

---

## Math (DONE — commit b33d6081)

| Kernel | Sky sig | Rust fn | Files changed |
|---|---|---|---|
| `Math.phi` | `Float` | `math_phi() -> f64` | Kernel.hs + Types.hs + math.rs |
| `Math.sqrt2` | `Float` | `math_sqrt2() -> f64` | Kernel.hs + Types.hs + math.rs |
| `Math.inf` | `Float` | `math_inf() -> f64` | Kernel.hs + Types.hs + math.rs |
| `Math.nan` | `Float` | `math_nan() -> f64` | Kernel.hs + Types.hs + math.rs |
| `Math.mod` | `Float -> Float -> Float` | `math_mod(x: f64, y: f64) -> f64` | Kernel.hs + math.rs |
| `Math.remainder` | `Float -> Float -> Float` | `math_remainder(x: f64, y: f64) -> f64` | Kernel.hs + math.rs |

**Pattern proven:** zero-arg constant kernels need THREE changes:
1. Routing entry in `Kernel.hs` (so codegen emits fn name)
2. Entry in `kernelsZeroArg` in `Types.hs` (so codegen emits `name()` not bare `name`)
3. `pub fn name() -> f64` in `math.rs`

Two-arg functions need only 1 + 3 (the default `_ -> toSnakeCase` fallthrough works IF the snake-cased name exists in the runtime — `math_mod` / `math_remainder` didn't, so both routing + runtime were needed). Cabal rebuild required for `.hs` changes.

---

## Verified real-gap worklist (75 remaining)

### Module: String — 13 gaps
**Rust file:** `runtime-rust/src/sky_runtime/string.rs`  
**Needs codegen?** No — all route via default snake_case fallthrough. Runtime-only.  
**Effort:** Small (all pure string ops, no deps)

| Kernel | Sky sig | Target Rust fn |
|---|---|---|
| `String.casefold` | `String -> String` | `string_casefold(s: String) -> String` |
| `String.equalFold` | `String -> String -> Bool` | `string_equal_fold(a: String, b: String) -> bool` |
| `String.trimStart` | `String -> String` | `string_trim_start(s: String) -> String` |
| `String.trimEnd` | `String -> String` | `string_trim_end(s: String) -> String` |
| `String.dropLeft` | `Int -> String -> String` | `string_drop_left(n: i64, s: String) -> String` |
| `String.dropRight` | `Int -> String -> String` | `string_drop_right(n: i64, s: String) -> String` |
| `String.padLeft` | `Int -> Char -> String -> String` | `string_pad_left(n: i64, ch: String, s: String) -> String` |
| `String.padRight` | `Int -> Char -> String -> String` | `string_pad_right(n: i64, ch: String, s: String) -> String` |
| `String.toList` | `String -> List Char` | `string_to_list(s: String) -> Vec<String>` |
| `String.fromList` | `List Char -> String` | `string_from_list(chars: Vec<String>) -> String` |
| `String.concat` | `List String -> String` | `string_concat(parts: Vec<String>) -> String` |
| `String.isEmail` | `String -> Bool` | `string_is_email(s: String) -> bool` |
| `String.isUrl` | `String -> Bool` | `string_is_url(s: String) -> bool` |

Notes:
- `casefold` = Unicode case folding for case-insensitive compare (Go uses `golang.org/x/text/unicode/norm`; Rust: `unicode-normalization` crate or just `.to_lowercase()` for the common case — check Go impl for exact semantics).
- `toList` / `fromList`: chars are Sky `Char` = single UTF-8 character as `String`. Go iterates Unicode runes; Rust: `s.chars().map(|c| c.to_string()).collect()`.
- `padLeft` / `padRight`: pad character is a `Char` (single-rune string). Rune-aware padding (count grapheme clusters, not bytes).
- `isEmail` / `isUrl`: Go uses a simple regex. A lightweight pure-Rust regex is sufficient (no external crate needed beyond `regex` which is already in the runtime).
- `dropLeft` / `dropRight`: rune-based (Sky chars = Unicode codepoints, not bytes).

---

### Module: File — 10 gaps
**Rust file:** `runtime-rust/src/sky_runtime/file.rs`  
**Needs codegen?** No — routes via default snake_case.  
**Effort:** Small (all `std::fs` ops, no external deps)

| Kernel | Sky sig | Target Rust fn |
|---|---|---|
| `File.readFileLimit` | `String -> Int -> Task Error String` | `file_read_file_limit<E>(path: String, limit: i64) -> SkyTask<E, String>` |
| `File.readFileBytes` | `String -> Task Error String` | `file_read_file_bytes<E>(path: String) -> SkyTask<E, String>` |
| `File.append` | `String -> String -> Task Error ()` | `file_append<E>(path: String, content: String) -> SkyTask<E, ()>` |
| `File.remove` | `String -> Task Error ()` | `file_remove<E>(path: String) -> SkyTask<E, ()>` |
| `File.readDir` | `String -> Task Error (List String)` | `file_read_dir<E>(path: String) -> SkyTask<E, Vec<String>>` |
| `File.isDir` | `String -> Task Error Bool` | `file_is_dir<E>(path: String) -> SkyTask<E, bool>` |
| `File.tempFile` | `String -> Task Error String` | `file_temp_file<E>(prefix: String) -> SkyTask<E, String>` |
| `File.tempDir` | `String -> Task Error String` | `file_temp_dir<E>(prefix: String) -> SkyTask<E, String>` |
| `File.copy` | `String -> String -> Task Error ()` | `file_copy<E>(src: String, dst: String) -> SkyTask<E, ()>` |
| `File.rename` | `String -> String -> Task Error ()` | `file_rename<E>(src: String, dst: String) -> SkyTask<E, ()>` |

Notes:
- `readFileBytes` returns the raw bytes as a `String` (byte-string, like Go returns `string(bytes)`). Use `String::from_utf8_lossy` to match Go behavior.
- `readFileLimit` reads up to `limit` bytes.
- `tempFile` / `tempDir`: Go uses `os.CreateTemp` / `os.MkdirTemp`. Rust: `tempfile` crate or `std::env::temp_dir()` + manual prefix. Check if `tempfile` crate is already in Cargo.toml.
- All return `SkyTask<E, _>` — follow the pattern in existing `file.rs` (`file_read_file`, `file_write_file`).

---

### Module: Dict — 5 gaps
**Rust file:** `runtime-rust/src/sky_runtime/dict.rs`  
**Needs codegen?** Likely yes for `Dict.map` (higher-order fn arg) and `Dict.foldl` (three-arg HOF).  
**Effort:** Small-medium (HOF arg passing needs care)

| Kernel | Sky sig | Target Rust fn |
|---|---|---|
| `Dict.size` | `Dict k v -> Int` | `dict_size<K, V>(d: HashMap<K, V>) -> i64` |
| `Dict.isEmpty` | `Dict k v -> Bool` | `dict_is_empty<K, V>(d: HashMap<K, V>) -> bool` |
| `Dict.union` | `Dict k v -> Dict k v -> Dict k v` | `dict_union<K: Hash+Eq, V>(a: HashMap<K,V>, b: HashMap<K,V>) -> HashMap<K,V>` |
| `Dict.map` | `(k -> v -> w) -> Dict k v -> Dict k w` | `dict_map<K: Hash+Eq+Clone, V, W>(f: impl Fn(K,V)->W, d: HashMap<K,V>) -> HashMap<K,W>` |
| `Dict.foldl` | `(k -> v -> a -> a) -> a -> Dict k v -> a` | `dict_foldl<K: Ord+Clone, V, A>(f: impl Fn(K,V,A)->A, acc: A, d: HashMap<K,V>) -> A` |

Notes:
- `dict_size` / `dict_is_empty`: trivial one-liners. Runtime-only.
- `dict_union`: `a` wins on conflict (matches Go). Clone `b` and extend with `a`. Runtime-only.
- `dict_map` / `dict_foldl`: HOF args. Codegen already handles HOF for `list_map_consume` etc. — follow that pattern. `dict_foldl` iterates in sorted-key order (matches Go's deterministic Sky contract).
- Routing: `dict_size` / `dict_is_empty` / `dict_union` fall through cleanly via default snake_case. `dict_map` and `dict_foldl` should too — but verify after adding runtime fns, since HOF codegen can be sensitive.

---

### Module: Path — 4 gaps
**Rust file:** Create `runtime-rust/src/sky_runtime/path.rs` (none exists yet)  
**Needs codegen?** No — all route via default snake_case.  
**Effort:** Tiny (4 one-liner `std::path` wrappers)

| Kernel | Sky sig | Target Rust fn |
|---|---|---|
| `Path.base` | `String -> String` | `path_base(p: String) -> String` |
| `Path.dir` | `String -> String` | `path_dir(p: String) -> String` |
| `Path.ext` | `String -> String` | `path_ext(p: String) -> String` |
| `Path.isAbsolute` | `String -> Bool` | `path_is_absolute(p: String) -> bool` |

Notes:
- All are pure (no `Task`), matching Go's pure helpers.
- Use `std::path::Path` — no external crate.
- Must add `mod path;` to `mod.rs` and `pub use path::*;`.
- `path_ext` returns the extension WITH the leading dot (e.g. `.txt`) — match Go's `filepath.Ext`.

---

### Module: Time — 5 gaps
**Rust file:** `runtime-rust/src/sky_runtime/time.rs`  
**Needs codegen?** Yes for `format` / `formatRFC3339` / `formatHTTP` — **acronym mangling bug**.  
**Effort:** Small-medium (mangling fix needs Kernel.hs routing entries + runtime fns)

| Kernel | Sky sig | Target Rust fn | Codegen note |
|---|---|---|---|
| `Time.format` | `String -> Int -> String` | `time_format(layout: String, ms: i64) -> String` | Route via default |
| `Time.formatRFC3339` | `Int -> String` | `time_format_rfc3339(ms: i64) -> String` | **MUST add Kernel.hs routing** — default produces `time_format_r_f_c3339` (letter-by-letter) |
| `Time.formatHTTP` | `Int -> String` | `time_format_http(ms: i64) -> String` | **MUST add Kernel.hs routing** — default produces `time_format_h_t_t_p` |
| `Time.addMillis` | `Int -> Int -> Int` | `time_add_millis(delta: i64, ms: i64) -> i64` | Route via default |
| `Time.diffMillis` | `Int -> Int -> Int` | `time_diff_millis(later: i64, earlier: i64) -> i64` | Route via default |

Notes:
- `formatRFC3339` and `formatHTTP` MUST have explicit routing entries in `Kernel.hs` (both abbreviation-mangling and the mis-cased `time_format_r_f_c3339` / `time_format_h_t_t_p` are build-fatal).
- `format`: layout string uses Go's reference time `"2006-01-02T15:04:05Z07:00"` style. Rust: use `chrono::DateTime::format_with_items` with a mapping of Go tokens to `chrono` strftime.  This is the most complex of the 5. Consider a small mapping table from Go format → `chrono::format::StrftimeItems`.
- `addMillis` / `diffMillis`: simple arithmetic on Unix-ms timestamps. Pure, no crate.
- `formatRFC3339` / `formatHTTP`: fixed-format strings. Use `chrono` (already a dep) for correct UTC formatting.
- Need cabal rebuild for Kernel.hs additions.

---

### Module: Random — 3 gaps
**Rust file:** `runtime-rust/src/sky_runtime/random.rs`  
**Needs codegen?** No — all route via default snake_case (verified: `Random_shuffle` → `random_shuffle`).  
**Effort:** Small (`rand` crate already in runtime)

| Kernel | Sky sig | Target Rust fn |
|---|---|---|
| `Random.shuffle` | `List a -> Task Error (List a)` | `random_shuffle<E, A>(xs: Vec<A>) -> SkyTask<E, Vec<A>>` |
| `Random.weighted` | `List (Float, a) -> Task Error (Maybe a)` | `random_weighted<E, A>(weights: Vec<(f64, A)>) -> SkyTask<E, SkyMaybe<A>>` |
| `Random.choiceMaybe` | `List a -> Task Error (Maybe a)` | `random_choice_maybe<E, A>(xs: Vec<A>) -> SkyTask<E, SkyMaybe<A>>` |

Notes:
- Go's `Random_choiceMaybe` (what Sky calls `choice` in the stdlib — `choice = Ffi.kernel "Random_choiceMaybe"`) returns `Maybe a` vs `Random.choice` which returns `a` (panics on empty). The Rust version should return `SkyMaybe<A>` — total, no panic.
- `weighted`: takes `List (Float, a)` — a list of (weight, value) pairs. Go uses Fisher-Yates for shuffle + a cumulative-weight scan for weighted. Use `rand::Rng::gen::<f64>()` for entropy.
- All return `Task Error` (entropy is effectful). Follow `random_int` / `random_float` pattern in `random.rs`.

---

### Module: System — 1 gap
**Rust file:** `runtime-rust/src/sky_runtime/system.rs`  
**Needs codegen?** No.  
**Effort:** Tiny (1-line alias)

| Kernel | Sky sig | Target Rust fn |
|---|---|---|
| `System.getcwd` | `() -> Task Error String` | `system_getcwd<E>(_: ()) -> SkyTask<E, String>` |

Note: Just calls `system_cwd(())` internally. Sky exposes both `cwd` and `getcwd` as aliases. The Rust runtime only has `system_cwd`; add `system_getcwd` as a thin wrapper.

---

### Module: JsonDec — 1 gap
**Rust file:** `runtime-rust/src/sky_runtime/json.rs`  
**Needs codegen?** Yes — add routing entry to Kernel.hs.  
**Effort:** Small (mirror existing `json_dec_field` / `json_dec_at`)

| Kernel | Sky sig | Target Rust fn |
|---|---|---|
| `JsonDec.index` | `Int -> Decoder a -> Decoder a` | `json_dec_index<E, A>(i: i64, dec: Decoder<A>) -> Decoder<A>` |

Note: Go's `JsonDec_index` accesses an array element by index. Rust: deserialize as `serde_json::Value::Array`, extract element `i`, run `dec` on it. Pattern matches `json_dec_field` exactly but with numeric indexing. Needs Kernel.hs routing entry.

---

### Module: JsonDecP — 1 gap
**Rust file:** `runtime-rust/src/sky_runtime/json.rs`  
**Needs codegen?** Yes — add routing entry to Kernel.hs.  
**Effort:** Small (mirror `json_dec_p_required` / `json_dec_p_optional`)

| Kernel | Sky sig | Target Rust fn |
|---|---|---|
| `JsonDecP.requiredAt` | `List String -> Decoder a -> Decoder (a -> b) -> Decoder b` | `json_dec_p_required_at<E, A, B>(path: Vec<String>, dec: Decoder<A>, cont: Decoder<impl Fn(A)->B>) -> Decoder<B>` |

Note: Like `json_dec_p_required` but navigates a nested path (like `JsonDec.at`). Needs Kernel.hs routing entry.

---

### Module: Sub — 1 gap
**Rust file:** `runtime-rust/src/sky_runtime/ws_client.rs`  
**Needs codegen?** Yes — WebSocket subscription types are missing.  
**Effort:** Medium (needs `WsCloseCode`, `WsClientMessage`, `WsClientCfg` types + subscription fn)

| Kernel | Sky sig | Target Rust fn |
|---|---|---|
| `Sub.subscribeWebSocket` | `WsClientCfg msg -> Sub msg` | Blocked on WebSocket type infrastructure |

Note: This gap requires the full WebSocket client subscription infrastructure. The types `WsCloseCode`, `WsClientMessage`, `WsClientCfg` are unresolved imports — they need to be defined in the runtime and exported. This is a larger effort tracked separately. See #62 (Input/focus model, WebSocket client subscriptions).

---

## SUBSYSTEM 1: Set — 10 gaps (separate effort, larger scope)

**Why separate:** `Set a` in Go is backed by `SkySet{items map[string]any}` — a custom struct stringifying every value for key equality. The Rust runtime has **no `SkySet` type** and no `set.rs` module. Implementing this requires:

1. A new `SkySet<A>` type in the runtime (or use `IndexSet<String>` with the value stored alongside, mirroring Go's design).
2. A new `runtime-rust/src/sky_runtime/set.rs` module (10 public fns).
3. A `mod set;` entry in `mod.rs`.
4. Likely codegen additions for Set type annotation (TypeRenderer must emit `SkySet<A>` for `Set a` types).
5. Routing entries in Kernel.hs (all 10 Set kernels fall through to default snake_case — verify they don't mangle).

**Gaps:**

| Kernel | Sky sig |
|---|---|
| `Set.empty` | `Set a` |
| `Set.fromList` | `List a -> Set a` |
| `Set.insert` | `a -> Set a -> Set a` |
| `Set.remove` | `a -> Set a -> Set a` |
| `Set.member` | `a -> Set a -> Bool` |
| `Set.toList` | `Set a -> List a` |
| `Set.size` | `Set a -> Int` |
| `Set.union` | `Set a -> Set a -> Set a` |
| `Set.intersect` | `Set a -> Set a -> Set a` |
| `Set.diff` | `Set a -> Set a -> Set a` |

**Design decision for executor:** Go's `SkySet{items map[string]any}` stringifies elements for equality (allows heterogeneous sets but loses type info). Rust recommendation: use `IndexSet<String>` (from `indexmap` crate — ordered, string-keyed, elements stored as `String` via `format!("{:?}", v)` or a `SkyToKey` trait). Keep parity with Go's stringification semantics. The `SkySet<A>` type wrapper holds `IndexSet<String>` + optionally a `Vec<A>` for `toList`. Precise design is at executor discretion but must be total (no panics).

---

## SUBSYSTEM 2: Db — 4 gaps + DbDec — 17 gaps (separate effort, larger scope)

**Why separate:** This is the full `Std.Db.Decode` typed-decoder family (17 functions) plus 4 new `Std.Db` kernel variations. Both require:
- Understanding the existing `Db` runtime in `db.rs` and the `Decoder` type in `json.rs`.
- The `DbDec.*` decoders mirror `JsonDec.*` but decode from database rows (a `HashMap<String, serde_json::Value>` or SQLite row type).
- Some functions (`Db.insertFields`, `Db.updateFields`, `Db.getByIdDecode`) require new SQL-generation logic.

**Db gaps (4):**

| Kernel | Sky sig | Notes |
|---|---|---|
| `Db.getByIdDecode` | `Conn -> String -> Int -> Decoder a -> Task Error (Maybe a)` | SELECT by id + decode result |
| `Db.insertFields` | `Conn -> String -> List SqlField -> Task Error ()` | Dynamic INSERT with OmitField support |
| `Db.insertFieldsReturning` | `Conn -> String -> List SqlField -> String -> Decoder a -> Task Error (List a)` | INSERT … RETURNING |
| `Db.updateFields` | `Conn -> String -> List (String, SqlValue) -> List SqlField -> Task Error ()` | Dynamic UPDATE with OmitField |

**DbDec gaps (17):**

| Kernel | Sky sig |
|---|---|
| `DbDec.string` | `String -> DbDecoder String` |
| `DbDec.int` | `String -> DbDecoder Int` |
| `DbDec.float` | `String -> DbDecoder Float` |
| `DbDec.bool` | `String -> DbDecoder Bool` |
| `DbDec.money` | `String -> DbDecoder Money` |
| `DbDec.nullable` | `DbDecoder a -> DbDecoder (Maybe a)` |
| `DbDec.succeed` | `a -> DbDecoder a` |
| `DbDec.fail` | `String -> DbDecoder a` |
| `DbDec.map` | `(a -> b) -> DbDecoder a -> DbDecoder b` |
| `DbDec.andThen` | `(a -> DbDecoder b) -> DbDecoder a -> DbDecoder b` |
| `DbDec.andMap` | `DbDecoder a -> DbDecoder (a -> b) -> DbDecoder b` |
| `DbDec.map2` | `(a -> b -> c) -> DbDecoder a -> DbDecoder b -> DbDecoder c` |
| `DbDec.map3` | `(a -> b -> c -> d) -> DbDecoder a -> DbDecoder b -> DbDecoder c -> DbDecoder d` |
| `DbDec.map4` | 4-arg variant |
| `DbDec.map5` | 5-arg variant |
| `DbDec.required` | `String -> DbDecoder a -> DbDecoder (a -> b) -> DbDecoder b` |
| `DbDec.optional` | `String -> DbDecoder a -> a -> DbDecoder (a -> b) -> DbDecoder b` |

**Executor guidance:** Model `DbDecoder<A>` as a function `Box<dyn Fn(&DbRow) -> Result<A, SkyError>>` where `DbRow = HashMap<String, serde_json::Value>`. This mirrors the Go `DbDecoder` pattern exactly. The 17 combinators are small functional wrappers — the pattern is identical to `JsonDec` in `json.rs`, just reading from a row map instead of a JSON value. The `money` decoder needs the `"ISO_CODE AMOUNT"` TEXT round-trip.

---

## Priority order for fan-out executors

| Priority | Module | Gap count | Effort | Blocker |
|---|---|---|---|---|
| 1 | Path | 4 | Tiny | None — new `path.rs`, pure |
| 1 | System.getcwd | 1 | Tiny | None — 1-line alias |
| 2 | String | 13 | Small | None — existing `string.rs` |
| 2 | File | 10 | Small | None — existing `file.rs` |
| 2 | Dict | 5 | Small | HOF codegen — verify after runtime add |
| 2 | Random | 3 | Small | None — existing `random.rs`, `rand` already in deps |
| 3 | Time | 5 | Small-medium | Kernel.hs change (RFC3339/HTTP mangling) + `chrono` Go-format mapping |
| 3 | JsonDec | 1 | Small | Kernel.hs routing entry |
| 3 | JsonDecP | 1 | Small | Kernel.hs routing entry |
| 4 | Set | 10 | Medium | New `SkySet<A>` type + `set.rs` + TypeRenderer codegen |
| 4 | Db | 4 | Medium | SQL-generation + `SqlField`/`SqlValue` types |
| 5 | DbDec | 17 | Medium-large | `DbDecoder<A>` type + 17 combinators |
| 5 | Sub.subscribeWebSocket | 1 | Large | Full WS client subscription infrastructure (#62) |

---

## Pattern guide for executors

### Runtime-only change (most modules)

Only edit `runtime-rust/src/sky_runtime/<module>.rs`. The runtime is **copied** into `sky-out/Rust/` at `sky build` time — NO cabal rebuild needed. Steps:

1. Add `pub fn` implementations to the appropriate `.rs` file.
2. Verify `sky build src/Main.sky --target rust` on a test program that calls the new functions.
3. Done.

### Codegen change required (Time RFC3339/HTTP, JsonDec.index, JsonDecP.requiredAt)

Edit both `src/Sky/Generate/Rust/Builder/Kernel.hs` AND the runtime `.rs` file. Cabal rebuild is mandatory:
```bash
cabal build -w ghc-9.6.7 exe:sky
```

The sky binary is a symlink — it auto-updates after `cabal build`.

### New module (Path, Set)

1. Create `runtime-rust/src/sky_runtime/new_module.rs`.
2. Add `pub mod new_module;` to `runtime-rust/src/sky_runtime/mod.rs`.
3. Verify the default snake_case routing works (no Kernel.hs change needed if function names are unambiguous). Run `sky build --target rust` on a test.

### Zero-arg constant kernel (like `Set.empty`, `Dict.empty`)

Needs THREE places:
1. `Kernel.hs` routing entry.
2. `kernelsZeroArg` in `Types.hs`.
3. Runtime fn.
Cabal rebuild required.

---

## Wrinkles ledger for executors

- **Acronym mangling:** `toSnakeCase` in `Naming.hs` snake-cases letter-by-letter. `RFC3339` → `r_f_c3339`, `HTTP` → `h_t_t_p`. Any kernel with an acronym abbreviation in the name MUST have an explicit route entry in `Kernel.hs`.
- **HOF args in Dict.map / Dict.foldl:** The codegen wraps HOF args via `SkyCall` / trait objects. Follow the pattern in `list_map_consume` / `list_foldl` in `list.rs`. Don't use `fn` pointers — use `impl Fn(...)` bounds, which the codegen correctly emits at call sites.
- **Task return type:** Every effectful kernel returns `SkyTask<E, A>` where `E: Send + From<String> + 'static`. Follow `file_read_file` in `file.rs` as the canonical pattern. Use `SkyTask::new(async move { ... })`.
- **No panics:** `unwrap()` / `expect()` / `[i]` indexing are forbidden. Use `get()`, `ok_or_else()`, `map_err()`. The total-by-construction rule is existential.
- **`pub use` re-exports:** Every new module added to `mod.rs` should use `pub mod` + the functions become available via `pub use sky_runtime::*` in `main.rs`.
- **`system_getcwd` is a 1-line alias:** Don't implement CWD twice. Call `system_cwd(())` from `system_getcwd`.
- **`String.casefold` vs `String.toLower`:** Casefold is Unicode-aware case folding (not just ASCII lowercase). Go uses `golang.org/x/text/unicode/norm`. Rust: `unicode-normalization` crate or `caseless` crate. Check if Rust `String::to_lowercase()` (which is Unicode-aware) is sufficient.
- **`Random.choiceMaybe` Ffi.kernel name mismatch:** The Sky stdlib exposes `choice` but routes to `Ffi.kernel "Random_choiceMaybe"`. The Rust fn must be named `random_choice_maybe` (snake_case of `Random_choiceMaybe`). Confirmed via `E0425: cannot find function 'random_choice_maybe'`.
