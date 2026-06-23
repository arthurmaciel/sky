# serde-bound generic FFI (`T: Serialize/DeserializeOwned`) + meta-crate re-export (#47) — design

**Goal (a):** bind a foreign generic fn/method bounded by serde (`<T: Serialize>` param,
`<T: DeserializeOwned>` return) by monomorphizing `T = serde_json::Value` and surfacing it to Sky
as a JSON **String** — the firestore/stripe typed-object API shape. **Goal (b):** make
`sky add <facade-crate>` (which yields 0 bindings because the real API is `pub use`-re-exported from
sub-crates) actionable.

Empirical (skyshop-rs no-shim, 2026-06-23): `unmodellable-bound` = 91 (firestore) + 6 (firebase) — the
serde-bound typed-doc API; and `sky add async-stripe` = 0 bindings (facade re-export).

**Status:** GUARDIAN-CLEARED — APPROVE-WITH-CONSTRAINTS (2026-06-23). The make-or-break is **C-G3**:
`subst_generic_json` substitutes a `{generic:T}` node POSITION-BLIND (it will emit `&Value` /
`(Value,Value)` / `HashMap<K,Value>` which type-check but have NO Sky JSON-String coercion → latent
cargo-fail / mis-surface). The reduction MUST be gated by a NEW **positive occurrence-census walk**:
admit `T = Value` ONLY when every occurrence of `T` is an admissible position (a by-value param, the
owned return, or directly inside `Result<T,_>` / `Vec<T>` / `Option<T>`); ANY occurrence as `&T` /
`&mut T` / a tuple element / a map value / behind another generic / an assoc-projection → DROP
(`unmodellable-bound`, sound over-drop). `subst_generic_json` will NOT refuse — the CALLER census-gates.

### Guardian constraints (the plan MUST honor)
- **C-G3 [make-or-break]** positive occurrence-census walk over the fn signature; reduce only if EVERY
  `T` occurrence is admissible (by-value param / owned return / `Result/Vec/Option<T>`); else drop. Add
  NEGATIVE fixtures: `&T`, `(T,T)`, `HashMap<K,T>`, `T` behind another bound → all DROP.
- **C-G2** the wrapper's `serde_json::Value` must use the RUNTIME's `serde_json` (share the dep); gate
  `usesSerdeJson` so it lands in the generated Cargo.toml. serde version-skew (a crate pinning a
  non-1.x / future-serde) → a LOUD cargo-fail (E0277), acceptable for v1, never a runtime fault; no
  inspect-time version check is possible — document it.
- **C-G1** recognize serde traits by RESOLVED canonical path (`serde::Serialize`/`serde::de::DeserializeOwned`
  via the #25 `EXTERNAL_TRAIT_PATH_BY_ID`, serde is `crate_id>0`), NOT last-segment. NEGATIVE fixture: a
  crate's OWN `trait Serialize` must NOT trigger the reduction.
- **C-G4** total coercion (input `from_str`→Err, output `to_string` total, NO `.unwrap()` — clippy HARD-DENY).
- **C-G6** per-param independent reduction (`<T: Serialize, U: DeserializeOwned>` → each → Value).
- **G5** Go-byte-identity (additive arm, gated on a serde-bound generic Go never emits).
- Mandatory guardian-final on the diff before commit.
- Add a comment at `subst_generic_json` (~main.rs:6191): admissibility MUST be position-gated by the
  caller (it substitutes position-blind).

NOTE: #47 is necessary-not-sufficient for the firestore
typed surface — those ops are ALSO async (#44 ✓) and generic-Self builders (#45, not done). #47 binds
the serde-generic shape wherever it's otherwise bindable (non-async-or-#44, non-generic-Self).

## (a) serde-T → `serde_json::Value` monomorphization → Sky JSON String

The reduction (mirrors the iterators `Vec<Item>` reduction + closures monomorphization): a generic param
`T` whose ONLY bounds are serde (`Serialize` and/or `DeserializeOwned`/`Deserialize`) + auto-traits
(Send/Sync/Sized) is monomorphized to **`serde_json::Value`** — which IS `Serialize + DeserializeOwned`
by construction, so the monomorphization always type-checks. Surfaced to Sky as a **JSON `String`**:

| Foreign shape | Monomorphize | Sky surface | Wrapper |
|---|---|---|---|
| `fn put<T: Serialize>(x: T)` | `T = Value` | param `String` (JSON) | deserialize the Sky JSON string → `Value` → call `put::<Value>(v)` |
| `fn get<T: DeserializeOwned>() -> T` | `T = Value` | return `String` (JSON) | call `get::<Value>()` → `serde_json::to_string(&v)` → Sky String |
| `… -> Result<T, E>` | `T = Value` | `Result Error String` (flatten, #32/#44 path) | flatten + to_string |

- **Input coercion:** Sky String (a JSON document) → `serde_json::from_str::<Value>(&s)` → `Value`. Fallible
  → the wrapper returns `Err` on malformed JSON (total, no panic).
- **Output coercion:** `Value` → `serde_json::to_string(&v)` → Sky String. `to_string` on a `Value` is
  total (never fails for a valid Value).
- **Sky side:** the user encodes/decodes with `Sky.Core.Json.Encode`/`Decode` — the param/return is a
  JSON string, exactly how the shims surfaced `fields_json: &str` today.

### Recognition (inspector)
A generic param `T` is serde-reducible when its bound set (method + trait-def union, the #21 Q2-A path)
is a subset of `{Serialize, Deserialize, DeserializeOwned, Send, Sync, Sized, lifetime}` AND `T` appears
only in admissible positions (by-value param, return, or inside a `Result`/`Vec`/`Option` of those).
Reuse the #25 external-trait-id machinery to identify the serde traits by canonical path
(`serde::Serialize` / `serde::de::DeserializeOwned`) — NOT last-segment (a crate's own `Serialize`
must not match). If `T` has ANY non-serde-non-auto bound → NOT reducible → keep the existing
`unmodellable-bound` drop (sound over-drop).

### Soundness gates (for the guardian)
- **G1 — serde trait identity by canonical path** (not last segment) — reuse #25; a non-serde
  look-alike must NOT trigger the reduction.
- **G2 — `serde_json` availability.** The monomorphization references `serde_json::Value` + the foreign
  crate must depend on a COMPATIBLE serde. `serde_json` must be in the generated Cargo.toml when a
  serde-reduced binding is reached (gate like `usesJson`). The foreign crate's serde version must unify
  with ours (serde is near-universally `1.x` — low risk, but a version-skew → cargo-fail; confirm cargo
  unifies, else drop).
- **G3 — `T` position.** `T` must appear ONLY where `Value` is a drop-in: by-value param, owned return,
  or in `Result/Vec/Option<T>`. `T` as `&T` / `&mut T` / behind another generic / as an assoc-type
  projection → drop (the owned-clone/borrow hazards). Conservative.
- **G4 — totality.** input `from_str` fallible → `Err` (no panic/unwrap); output `to_string` total.
  No `.unwrap()`.
- **G5 — Go-byte-identity.** gated on a serde-bound generic the Go inspector never emits.
- **G6 — multiple type-params.** `fn f<T: Serialize, U: DeserializeOwned>(...)` → reduce EACH
  independently to `Value`. A type-param used in MULTIPLE positions reduces consistently.

## (b) meta-crate re-export (async-stripe = 0 bindings)

`sky add async-stripe` introspects the FACADE crate's rustdoc; the real items are `pub use`-re-exported
from `async-stripe-core`/`-checkout`/`-types` (different crate_ids) — rustdoc represents these as `use`
import items pointing at IDs in OTHER crates, whose DEFINITIONS aren't in the facade's rustdoc JSON.
Following them requires the sub-crate's rustdoc (separate `cargo doc`) — heavy + out of scope here.

**v1 (this epic) = ACTIONABLE GUIDANCE, not cross-crate traversal:** when `sky add <crate>` yields 0 (or
near-0) bindings AND the crate's rustdoc has `pub use` re-exports to EXTERNAL crates, the `sky add`
output names the re-export target crates and tells the user to `sky add` the sub-crate(s) directly
(`sky add async-stripe-core`, `async-stripe-checkout`). The sub-crates DO have their items in their own
rustdoc → introspectable (subject to #44/#45/#47a). This is a UX/diagnostic fix, no codegen risk.
(Cross-crate re-export following is a separate, larger task — file it.)

## Proof bar
1. Hand-stub fixture `NN-ffi-serde`: a dep-free crate (with `serde`+`serde_json`) exposing
   `fn put<T: Serialize>(x: T) -> String` (returns a tag), `fn roundtrip<T: Serialize + DeserializeOwned>(x: T) -> T`,
   `fn get_default<T: DeserializeOwned>() -> T`, + a NEGATIVE row (`<T: SomeOtherTrait>` → must DROP). Main.sky
   passes/receives JSON strings via `Json.Encode`/`Decode`, asserts round-trip.
2. Inspector unit tests: serde-bound → reduced-to-Value binding; non-serde bound → drop; serde by
   canonical path (not last-segment); `&T` position → drop.
3. (b): a unit test that a facade with an external `pub use` emits the guidance.
4. Real-crate (CI): re-add firestore, confirm the `unmodellable-bound` count drops for the serde-doc fns
   that are otherwise bindable.

## Non-goals
Cross-crate rustdoc re-export traversal (file separately). Binding `T` to a SPECIFIC Sky record type
(only `Value`/JSON-string in v1). serde with `#[serde(...)]` attr semantics (the JSON is opaque to Sky;
the user decodes). Generic-Self serde methods (need #45 first).
