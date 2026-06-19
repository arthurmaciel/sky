# DbDec + Db decoder subsystem — Rust backend (Go-parity)

**Goal.** Close the last 21 go-parity kernel gaps (skydex `parity --gaps`): the
`Std.Db.Decode` family (17: DbDec.string/int/float/bool/money/nullable/succeed/
fail/map/andThen/andMap/map2-5/required/optional) + 4 `Std.Db` SQL-gen kernels
(getByIdDecode/insertFields/insertFieldsReturning/updateFields).

**Boundary.** Rust backend only: `runtime-rust/`, `src/Sky/Generate/Rust/`,
`examples/rust/`. NEVER touch `sky-stdlib/`, `runtime-go/`, `src/Sky/Generate/Go/`.

**Principles order:** security > correctness > soundness > efficiency > parity.

---

## Validated design decision — share the `Decoder` type (answers "specialize per source?")

Sky has ONE `Decoder a` type (kernel-implicit Prelude type) shared by JsonDec,
DbDec, Config. A source-parameterized `Decoder<Src,E,T>` is the type-theoretic
ideal but is **NOT expressible in the Rust backend alone**: Sky's `Decoder a`
carries no source parameter, so codegen renders every `Decoder a` identically
(`Decoder<T>`) and cannot tell a DB decoder from a JSON decoder. True
specialization would need a Sky-level `Decoder source a` — out of boundary.

**In-boundary design (consistent + correct-by-construction):**

| Layer | Decision |
|---|---|
| Type | ONE shared `Decoder<E,T> = Box<dyn Fn(&JsonVal) -> SkyResult<E,T> + Send>` (json.rs:7). Matches Sky's single `Decoder a`. |
| Combinators | `DbDec.{map,andThen,andMap,map2..5,succeed,fail}` route to the SAME `json_dec_*` runtime fns — they only transform the decoded value, never touch the source. Pure DRY, zero correctness risk. |
| Source | Unify on `JsonVal`. A DB row is a `JsonVal::Object` of string-valued (or `Null`) fields. |
| Primitives | DB-specific + TOTAL: `db_dec_int(col)` reads the named field as a string and PARSES it (DB columns arrive as strings — distinct from `json_dec_int` which expects a JSON number). Never panic; missing/ill-typed field → `Err`. |

Cross-application (DbDec decoder on JSON or vice-versa) can't happen by
construction — the runner functions fix the source. Sky's types can't prevent it
(same type), but neither can Go's (uses `any`); JsonVal is strictly safer.

---

## CORRECTNESS BLOCKER — NULL preservation

`row_to_map` (db.rs:18) collapses SQL `NULL` → `String::new()`. NULL and
empty-string become indistinguishable → `DbDec.nullable` would be WRONG off the
stringified HashMap. **Fix:** `db_query_decode`/`db_get_by_id_decode` must build
the `JsonVal` from the raw `sqlx::Row`, NOT the lossy HashMap:

```
row_to_json(row: &DbRow) -> JsonVal:
  for each column i:
    try_get::<Option<String>>(i):
      Ok(None)    -> JsonVal::Null            // SQL NULL preserved
      Ok(Some(s)) -> JsonVal::String(s)
      else try Option<i64>/Option<f64> -> JsonVal::String(v.to_string())
                                            (or Null when None)
  -> JsonVal::Object{ col -> val }
```

`db_query` (the untyped path) keeps its current HashMap shape — unchanged.

---

## Work plan (de-risk spine first, then fill)

### Phase A — spine (prove the approach, SQLite-backed)
1. `json.rs`: add `json_dec_map5` + `json_dec_and_map` (mirror map2-4). Needed
   for DbDec.map5/andMap routing.
2. `row_to_json(&DbRow) -> JsonVal` in db.rs (NULL-preserving, above).
3. `db.rs` new section (or `db_decoder.rs`): DB primitives reusing
   `json_dec_field` + json_dec_ok/err:
   - `db_dec_string(col)` = field → expect JsonVal::String.
   - `db_dec_int(col)`    = field → parse string → i64 (accept JSON number too).
   - `db_dec_float/bool/money(col)` = parse string.
   - `db_dec_nullable(inner)` = field absent or JsonVal::Null → Nothing; else Just(inner).
   - `db_dec_required(col, inner, accum)` / `db_dec_optional` = pipeline (mirror json_dec_p_*).
4. Change `db_query_decode` to take `decoder: Decoder<E,A>` (was `impl Fn(HashMap)`);
   run `decoder(&row_to_json(&raw_row))` per row. Update its internal test.
5. `db_get_by_id_decode(conn, table, id, decoder: Decoder<E,A>) -> SkyTask<E, SkyMaybe<A>>`.
6. Kernel.hs routing: DbDec.{string,int,float,bool,money,nullable,succeed,fail,
   map,andThen,andMap,map2..5,required,optional} (succeed/fail/map/andThen/andMap/
   map2..5 → json_dec_*; string/int/.../required/optional → db_dec_*); Db.getByIdDecode.
7. Probe `runtime-rust/tests/sky/kernel-parity-probe-dbdec`: SQLite create+insert+queryDecode
   a 2-field record with int+string+nullable; verify decoded values + NULL→Nothing.

### Phase B — Db SQL-gen kernels (mirror Go db_auth.go; column-name validated)
- `db_insert_fields(conn, table, fields: List SqlField)` — dynamic INSERT, OmitField
  drops the column (DEFAULT). Validate identifiers `[A-Za-z0-9_.]` (injection gate).
- `db_insert_fields_returning(conn, table, fields, projection, decoder)` — append
  RETURNING, decode via row_to_json.
- `db_update_fields(conn, table, whereCols, setFields)` — dynamic UPDATE; all-Omit → 0 rows.
- SqlField/SqlValue already modeled? check runtime; reuse the existing SqlValue path.

### Verify
- `cargo build --features full` (runtime) green.
- probe builds (`sky build --target rust`) + runs (SQLite) with correct decoded output.
- build-sweep PASS (no regression — db_query_decode sig change + json additions).
- skydex `parity --gaps`: DbDec + Db gaps → 0 (only Sub.subscribeWebSocket false-positive remains).
- pre-final gate: every primitive TOTAL (no unwrap/panic); SQL identifiers validated.

## Open checks before coding
- [ ] Does `Db.queryDecode`'s Sky sig pass params as `List SqlValue` or `List String`? match it.
- [ ] `SqlField`/`SqlValue` runtime representation for Phase B (reuse, don't reinvent).
- [ ] `json_dec_p_*` pipeline shape (required/optional accumulator) for db_dec_required.

---

## STATUS (2026-06-16) — core shipped + verified, 7 hard kernels remain

> **Update.** Since this 2026-06-16 snapshot, 6 of the 7 "REMAINING" kernels have
> since been routed in `Kernel.hs` (`DbDec.nullable`/`required`/`optional` via the
> `{run, fields}` Decoder redesign; `Db.insertFields`/`updateFields`/
> `insertFieldsReturning` via the SqlField SQL-gen path). Only `DbDec.money`
> stays UNROUTED (still needs the Money-ADT codegen wrapper). The per-row notes
> below are the original blocker analysis, kept for context.

**CLOSED + probe-verified** (`runtime-rust/tests/sky/kernel-parity-probe-dbdec`, real SQLite —
`rows=…|…  byId1=…  DBDEC PROBE OK`): the shared-Decoder design proven end-to-end.
- Primitives: `db_dec_string/int/float/bool` (read+parse a column; TOTAL).
- Combinators routed to existing json runtime: `succeed/fail/map/andThen/andMap/
  map2/map3/map4/map5` → `json_dec_*` (added `json_dec_map5` + `json_dec_and_map`).
- `db_query_decode` reworked to take `Decoder<E,A>` + run on `row_to_json` (NULL-
  preserving `sqlx::Row → JsonVal`); new `db_get_by_id_decode` (id BOUND param).

**REMAINING (7) — each a real, separable blocker (do NOT ship silently-wrong):**
| Kernel | Blocker | Correct fix |
|---|---|---|
| `DbDec.nullable` | Sky sig `Decoder a -> Decoder (Maybe a)` passes ONLY the inner decoder, but the opaque `Box<dyn Fn(&JsonVal)>` can't expose WHICH column it reads (Go tracks `d.cols`). A 1-arg runtime that catches inner-`Err`→`Nothing` would conflate NULL with a malformed value → silently wrong. | Make `Decoder` carry column metadata (a struct `{ run: Box<dyn Fn>, cols: Vec<String> }`) so nullable checks those cols for NULL. Touches json + db decoders — a Decoder-type redesign. |
| `DbDec.money` | runtime `db_dec_money` returns `(Decimal, String)`; Sky `Money` is a per-project GENERATED ADT (`StdMoneyMoney::Money(Decimal, Currency)`) the runtime can't name. | Codegen wrapper: at a `DbDec.money` call site emit a `json_dec_map` that builds the Money ctor from the pair. (`db_dec_money` runtime is correct + total; UNROUTED until the wrapper exists.) |
| `DbDec.required` / `optional` | pipeline accumulator is `Box<dyn FnOnce(A)->B>`; `FnOnce` can't satisfy the `Fn` that `Decoder` requires (CLAUDE.md Phase-3 limitation #2 — same wall JsonDecP hit). | Resolve the FnOnce/Clone wall (Arc the accumulator, or the Decoder-struct redesign) shared with JsonDecP. |
| `Db.insertFields` / `updateFields` | Phase B SQL-gen — NO decoder dependency. Mirror Go `db_auth.go`: dynamic INSERT/UPDATE from `List SqlField` (`SetField`/`OmitField`), identifier-validated `[A-Za-z0-9_.]` (injection gate), all-Omit → 0 rows. | **Most tractable of the 7** — pure runtime + routing, reuse the existing `SqlValue` path. |
| `Db.insertFieldsReturning` | INSERT … RETURNING + decode → has the same Decoder dependency as queryDecode. | After insertFields: append RETURNING, decode via `row_to_json` + `Decoder`. |

**The remaining 7 cluster into TWO design problems (neither quick — both need
careful codegen design; do in a focused session, not rushed):**

1. **Decoder redesign** — `nullable`, `required`, `optional`. The opaque
   `Box<dyn Fn(&JsonVal)>` can't carry which columns it reads (nullable) nor an
   `FnOnce` accumulator (required/optional). Fix: change `Decoder` to a struct
   `{ run: Box<dyn Fn>, cols: Vec<String> }` (+ Arc the pipeline accumulator).
   Shared with the JsonDecP pipeline wall — fixes both at once.

2. **Generated-ADT boundary marshaling** — `money`, `insertFields`,
   `updateFields`, `insertFieldsReturning`. `SqlValue`/`SqlField`/`Money` are
   per-project GENERATED Sky ADTs; the runtime can't name or destructure them.
   `insertFields : … -> List (String, SqlField) -> …` hands the runtime an
   opaque generated enum. Fix: CODEGEN destructures the ADT at the call site
   into a runtime-friendly form (e.g. lower `List (String, SqlField)` to a
   `Vec<(String, Option<SqlScalar>)>` before the kernel call; lower `DbDec.money`
   to a `json_dec_map` building the Money ctor from `db_dec_money`'s pair).
   `db_dec_money` runtime is already correct + total — only the codegen wrapper
   is missing. NOTE: Rust's `Db.exec` currently uses `Vec<String>` params, so the
   broader SqlValue param path is also unimplemented on Rust — the ADT-marshaling
   work closes that class too.

**skydex caveat:** `parity --gaps` shows only `required/optional` + the 3 `Db.*` +
`Sub.subscribeWebSocket` (false-positive, implemented via ExprEmitter peephole).
It OVER-credits `nullable`/`money` because their runtime fns exist by name even
though unrouted/incorrect — skydex is a presence index, not a type checker. The
**probe is the truth**; nullable/money are NOT usable yet.
