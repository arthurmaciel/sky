# Lesson — "Parse, don't validate" & "Make invalid states unrepresentable"

Two type-driven design rules, taught from **real fixes in this codebase** (Sky Rust
runtime, `feat/runtime-rust`, commit `64ef1734`). Every Rust example below was found
by a read-only swarm, vetted + designed by the security guardian, implemented, and
verified (`clippy --all-targets --all-features -D warnings` clean · 564 unit tests ·
feature-minimal build · adversarial final review = PASS).

The point of the lesson is not just the wins — it is **discernment**: 15 candidates
were proposed, **8 applied, 7 rejected as forcing**. Knowing when NOT to apply a rule
is half the skill.

---

## The two rules

### 1. Parse, don't validate
*Validate* = check a loose value (`String`, `i32`, `&str`) at a use site, then keep
using the same loose value — so every other use site must check again, and a future
site can forget.
*Parse* = at the boundary, convert the loose value **once** into a **typed** value
(a newtype / enum / smart-constructor result) that *carries the proven invariant in
its type*. Downstream code receives the typed value and **cannot** re-encounter the
invalid case — the check is non-skippable by construction.

> Coined by Alexis King (2019). The slogan: push the check to the edge, return a
> type that makes the checked-ness un-loseable.

**Smells:** the same `if !is_valid(x)` / `.starts_with` / `.contains` / `.parse()`
repeated at multiple sites; a function returning a value callers must re-check; a
sentinel (`""`, `-1`, `0`) standing for "invalid/absent".

### 2. Make invalid states unrepresentable
Model data so an illegal combination **cannot be constructed**. Replace parallel
`Option`s where "exactly one is Some", `bool` pairs encoding a 3+-state machine, a
`kind: String` discriminator over a closed set, or a struct whose two fields must
agree — with a single ADT/enum whose variants are exactly the legal states.

> Yaron Minsky's "make illegal states unrepresentable". The compiler's
> exhaustiveness checker then *forces* you to handle every real state and *forbids*
> the fake ones.

**Smells:** `Option<A>` + `Option<B>` soup; `bool` flags that should be an enum; a
stringly discriminator; a sentinel value substituting for a real variant.

### Why they favor our principle order
`security > correctness > soundness > efficiency > completeness > readability`.
These rules move a guarantee **from runtime discipline into the type system**: a
forgotten re-check (security/correctness regression) becomes a *compile error*. They
are the structural antidote to the **"two checks drift apart"** bug class this
project keeps hitting (e.g. a `==` vs `ct_eq` 10 lines apart; an attribute-name sink
left un-escaped until `SafeAttrName` was introduced). A redesign only qualifies when
it closes such a hole — **never** for cosmetics (readability is the *lowest*
principle; a churny rewrite that only "reads nicer" is a net negative).

---

## The 8 applied fixes (real, verified)

| # | File · symbol | Rule | Smell removed | Principle |
|---|---|---|---|---|
| 1 | `db.rs` · `safe_ident` | parse-don't-validate | `""` sentinel + loose `String` re-checked at 9 SQL-identifier interpolation sites | security/soundness |
| 4 | `live/console.rs` · auth mode | parse-don't-validate | stringly mode + `_ =>` catch-all silently fails a future mode open | **security** |
| 5 | `live/console_proxy.rs` · `gate_allows` | parse-don't-validate | case-sensitive `v == "off"` → mount fail-open for `OFF`/` off ` | **security** |
| 6 | `live/mod.rs` · GET page | invalid-states-unrepresentable | `Option` store-hit + parallel `cookie_sid` masked by `unwrap_or_else(new_sid)` | correctness |
| 7 | `money.rs` · `lookup_currency` | invalid-states-unrepresentable | `-1` minor-units sentinel re-checked at 6 sites | correctness/soundness |
| 9 | `server.rs` · `ServerRoute` | invalid-states-unrepresentable | two parallel `Option`s — both-None route silently dropped | correctness |
| 10 | `telemetry.rs` · `# TYPE` | invalid-states-unrepresentable | Prom type from a name-table could contradict the value variant | correctness |
| 15 | `ws_client.rs` · sub `kind` | invalid-states-unrepresentable | stringly dedup discriminator over a closed 4-set | soundness |

### Worked example — #1 `db.rs` (parse, don't validate)

The sharpest one: a SQL-identifier validator returning a **sentinel** that 9 call
sites had to re-interpret before interpolating the name into SQL.

```rust
// BEFORE — validate: returns "" to mean "invalid"; every caller must remember to re-check.
fn safe_ident(name: &str) -> String {
    if !name.is_empty() && name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_') {
        name.to_string()
    } else {
        String::new() // ← sentinel. A caller that forgets `is_empty()` interpolates "" — or worse.
    }
}
// ...9 sites like:
let qtable = safe_ident(&table);
if qtable.is_empty() { return Err(...); }     // re-validation, repeated 9×, skippable
let sql = format!("SELECT * FROM {} WHERE id = ? LIMIT 1", qtable);
```

```rust
// AFTER — parse: the only constructor runs the policy; the TYPE proves validity.
struct SqlIdent(String);
impl SqlIdent {
    fn parse(name: &str) -> Option<SqlIdent> {
        if !name.is_empty() && name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_') {
            Some(SqlIdent(name.to_string()))
        } else {
            None // no sentinel — invalidity is `None`, impossible to confuse with a value
        }
    }
    fn as_str(&self) -> &str { &self.0 }
}
// ...each site:
let qtable = match SqlIdent::parse(&table) {
    Some(t) => t,
    None => return SkyResult::Err(format!("db.getById: invalid table name {:?}", table).into()),
};
let sql = format!("SELECT * FROM {} WHERE id = ? LIMIT 1", qtable.as_str());
// A new call site PHYSICALLY CANNOT interpolate an unvalidated identifier:
// you only get a `SqlIdent` by passing the gate. The check is non-skippable.
```

Why it favors security: SQL identifiers are *interpolated*, not bound (you can't `?`-bind a table name), so the validation is injection-load-bearing. Moving it into the type means no future site can splice an unvalidated name.

### Worked example — #9 `server.rs` (make invalid states unrepresentable)

```rust
// BEFORE — two parallel Options. (None,None) and (Some,Some) are representable but illegal.
pub struct ServerRoute {
    pub method: String,
    pub path: String,
    pub handler: Option<ErasedHandler>,
    pub static_dir: Option<String>,
}
// server_listen:
if let Some(dir) = r.static_dir { /* serve dir */ }
else if let Some(h) = r.handler { /* route handler */ }
// else: a (None,None) route is SILENTLY DROPPED — no handler, no diagnostic.
```

```rust
// AFTER — one enum. Only the two legal states exist; the match is total.
enum RouteTarget { Handler(ErasedHandler), Static(String) }
pub struct ServerRoute {
    pub method: String,
    pub path: String,
    target: RouteTarget, // private — constructed only via `route()` / `server_static()`
}
// server_listen:
match r.target {
    RouteTarget::Static(dir) => { /* serve dir */ }
    RouteTarget::Handler(h)  => { /* route handler */ }
} // exhaustive: (None,None) is unrepresentable; a new variant is a COMPILE error, not a silent drop.
```

### The security ones (#4, #5) — the highest-value class
A *stringly* security gate plus a `_ => {}` fall-through is **fail-open by default**:

```rust
// #4 BEFORE: a future auth mode silently falls through to the permissive path.
match console_auth_mode_label() {     // returns &'static str
    "off" => return Some(not_found()),
    "app" => return Some(not_impl()),
    _ => {}                            // token / unset-prod / dev-open... AND any future/typo'd mode
}
// #4 AFTER: enum + exhaustive match — a new mode is a compile error, can't fail open.
match resolve_console_auth_mode() {
    ConsoleAuthMode::Off => return Some(not_found()),
    ConsoleAuthMode::App => return Some(not_impl()),
    ConsoleAuthMode::Token | ConsoleAuthMode::UnsetProd | ConsoleAuthMode::DevOpen => {}
}
```
`#5` is the same family at a different layer: `v == "off"` (case-sensitive) let
`SKY_CONSOLE_AUTH=OFF` *spawn* the console child while the request gate 404'd it —
fixed with `v.trim().eq_ignore_ascii_case("off")`. (The one intentionally
behaviour-changing fix in the set — it closes the fail-open.)

---

## The same two rules in three languages

The rules are language-agnostic; the *mechanism* differs. This codebase spans all
three, so here is each idiom.

### Rust — newtype + smart constructor; enum for states
- **Parse:** a tuple/newtype `struct SqlIdent(String)` whose only constructor is
  `fn parse(&str) -> Option<Self>` (or `Result`). Privacy of the field makes the
  constructor the only door. `#[repr(transparent)]` if you need the layout.
- **States:** `enum`, and a `match` with **no `_` arm** so the compiler enforces
  totality. `Option<A> + Option<B>` → `enum { A(..), B(..) }`.

### Haskell — newtype + smart constructor (hide it); ADTs
This is where the rules originated. The Sky **compiler** (Haskell, `src/Sky/...`)
already uses them throughout.
```haskell
-- Parse, don't validate: hide the constructor, export only the smart one.
module Sql (SqlIdent, parseIdent, identText) where
newtype SqlIdent = SqlIdent Text          -- constructor NOT exported
parseIdent :: Text -> Maybe SqlIdent      -- the only way in
parseIdent t
  | not (T.null t) && T.all isIdentChar t = Just (SqlIdent t)
  | otherwise                             = Nothing
identText :: SqlIdent -> Text
identText (SqlIdent t) = t
```
```haskell
-- Make invalid states unrepresentable: a sum type instead of two Maybes.
data RouteTarget = Handler ErasedHandler | Static FilePath  -- exactly two states
-- `case t of { Handler h -> ...; Static d -> ... }` is checked exhaustive by -Wall.
```
The compiler's own code lives this: e.g. `Sky.Generate.Rust.Builder` carries
*typed* IR (`GoExpr`/`GoType` ADTs), not stringly blobs, so an ill-formed emission
is a constructor that doesn't exist. Alexis King's essay is the canonical reference.

### Sky — custom ADTs, typed stdlib surfaces
Sky (the language) gives users the same tools; idiomatic Sky stdlib already applies
them — teach users to reach for these instead of stringly values:
```elm
-- Make invalid states unrepresentable: Std.Db.SqlValue is an ADT, not "stringify everything".
type SqlValue = SqlString String | SqlInt Int | SqlBool Bool | SqlNull SqlValue | ...
-- A heterogeneous param list is `List SqlValue` — each cell's type is proven, no
-- "is this the right type?" re-check at the driver. (Closed the v0.16.26 mixed-param gap.)

-- Parse, don't validate: decoders parse untrusted JSON ONCE into a typed record.
decodeUser : Decoder User                 -- Json.Decode — the boundary parse
-- downstream code holds a `User`, never a re-validated `Value`.

-- Errors are typed, not stringly: `Result Error a` / `Task Error a`, never `Result String a`
-- (a project non-regression rule — the same principle: don't pass a loose String as an error).

-- Make invalid states unrepresentable in your Model: prefer
type Page = LoginPage | DashboardPage | AppDetailPage String
-- over `{ isLogin : Bool, isDashboard : Bool, slug : String }` (which allows two-true / empty-slug).
```

**One slogan across all three:** *make the illegal value impossible to name, and the
forgotten check impossible to forget.*

---

## Discernment — the 7 we REJECTED (and why)

Equally important: a rule is a tool, not a mandate. The guardian rejected 7 of 15
candidates. The user's instruction was explicit — **don't force, don't invent**.

| Candidate | Why REJECTED |
|---|---|
| `jwt.rs` HS256 secret newtype | Two **independent** input boundaries, each a single-condition early-return; the value flows clean (no sentinel). Not re-validation of one value — can't meaningfully drift. Newtype = optional polish → forcing. |
| `html.rs` event-name `SafeEventName` | The policy is a **single predicate** already centralized in `is_safe_html_name`, called directly at both sinks. `SafeAttrName` existed to fix a *compound* (two-predicate) divergence — that class doesn't exist here. Symmetry-only → forcing. |
| `log.rs` `(i32,&str)` level → enum | Private fn, 6 co-located literal-constant call sites, no boundary, no sentinel. Drift risk negligible; enum is **readability-only** (lowest principle). Forcing. |
| `tui/app.rs`+`tea.rs` key dispatch enum | Large **cross-file** refactor of the channel feeding the Go-byte-identical `onKey` wire contract; decode is already total/bounds-checked. Parity-drift risk for no soundness gain. |
| `tui/key.rs` `TuiKey` → enum | `kind`/`value` strings **are** the load-bearing Go-parity wire contract; the two constructors already guarantee consistent pairs (illegal combos unreachable). High churn, parity-risky. |
| `tui/focus.rs` `Focusable` → enum | Cross-file; the producer sets consistent fields so the invalid state is already unreachable; total/no-panic. Readability refactor with drift risk. |
| `tui/layout.rs` `BorderSpec` style | Single-file but **no divergence possible** — both read sites treat unknown→solid identically. Pure cosmetics. Forcing. |

**The rejection heuristics (the real lesson):**
1. **Is there actually a second, *droppable* check?** One boundary validating its own
   input is fine — that *is* parsing. The rule targets a value re-checked at *many*
   sites or a sentinel that can be misread.
2. **Is the illegal state actually reachable?** If the only constructors already
   guarantee consistency, an enum adds churn, not safety.
3. **Does it cross files / a wire contract?** A typed redesign that risks Go≡Rust
   behavioural parity (the project's release gate) needs a *much* higher payoff.
4. **Which principle does it serve?** If the honest answer is "readability" (the
   lowest), and it costs churn or parity risk, **don't** — that's a net regression
   under our ordering.

---

## How this was produced (reproducible method)
Read-only find-swarm (10 agents, 1 per file-bucket) → guardian vet+design (8 approve /
7 reject) → fast implementers (1 per disjoint file, author-only, no build) →
orchestrator gate (clippy `-D` + 564 tests + feature-minimal build) → guardian final
adversarial review (PASS) → this doc. Anti-race: authors touch disjoint files and
never build; the orchestrator runs the single integration build. FFI files
(`ffi_polyfills.rs`, `tools/sky-ffi-inspect-rs`) were excluded — another agent owns them.

**Open follow-up (noted, not done):** `db.rs` `valid_sql_ident` (the `.`-allowing
qualified-name gate) is still a boolean validator re-checked at 6 sites — the exact
smell `SqlIdent` removed elsewhere. A future `QualifiedSqlIdent` smart constructor
would finish the job. Scoped out here because its charset/policy intentionally
differs.
