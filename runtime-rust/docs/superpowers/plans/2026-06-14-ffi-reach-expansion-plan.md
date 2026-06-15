# FFI reach expansion — prioritized fix plan

Grounded in the 50-crate `--audit` sweep + hands-on builds of csv / url / bytes /
regex / gadget. Goal: **keep more functions from more crates** without violating
the no-panic / no-`Any` / Go-neutral constraints. Ordered by value × tractability.

## Scoreboard of measured blockers

| # | Blocker | Crates hit | Value | Tractability | Status |
|---|---|---|---|---|---|
| P1 | `Option<T>` param coercion (`SkyMaybe<T>` → `Option<&str>`/`Option<u16>`/…) | url, many setters/APIs | **high** | medium | ✅ DONE |
| P2 | Crate-name collision (absolute `::<crate>` paths, no glob) | csv/time/log/json/config/email/html | high | ✅ DONE (A); bytes=future | ✅ |
| P3 | Unqualified receiver dropped by nameability | regex `RegexBuilder` (+48 setters) | med-high | medium | needs investigation |
| P4 | Sized gate on by-value receivers | bytes `UninitSlice` | medium | medium | planned |
| P5 | `&mut [u8]` output-buffer params | hex, tokio I/O | low-med | medium | deferred |

## P1 — `Option<T>` parameter coercion  ★ do first

**Gap.** A param typed `Option<&str>` / `Option<u16>` / `Option<&[u8]>` gets the
wrapper param `SkyMaybe<String>` / `SkyMaybe<i64>` / … but `argCall` passes it
through unchanged → `E0308`. Blocks url `set_fragment`/`set_query`/`set_host`/
`set_port`/`set_password` and every API with an optional borrowed/narrowed arg.

**Fix (Ffi.hs `argCall`).** When `rawTy = Option<inner>`, emit
`arg.map(|x| <coerce x → inner>)` where the inner coercion reuses the existing
scalar rules:
- `Option<&str>` / `Option<&String>` → `arg.as_ref().map(|s| s.as_str())`
- `Option<u16>` / `Option<i32>` … → `arg.map(|n| n as <inner>)`
- `Option<&[u8]>` → `arg.as_ref().map(|v| v.as_slice())` (after `to_u8_vec`)
- `Option<OwnedOpaque>` → `arg` (identity)

Needs a `SkyMaybe<T> → Option<T>` bridge in the runtime (or reuse `dbBindArg`'s
reflect-free shape). Recursive: factor the scalar coercion out of `argCall` so
`Option<_>` (and later `Vec<_>` of the same) can call it on the inner type.

**Soundness.** Pure structural map, no panic, no `Any`.

## P2 — Crate-name collision hardening

**Gap A — csv (`csv` is ambiguous, E0659).** The binding file emits both
`use crate::*;` and `use csv::*;`, and references `csv::ByteRecord`. When the
generated project also exposes a `csv` path, `csv::` is ambiguous.
**Fix:** qualify crate type refs with the **extern-crate-root** prefix `::csv::…`
(leading `::` always resolves to the extern crate, never a local module). One-line
change in the type qualifier; disambiguates every collision of this class.

**Gap B — bytes (`Bytes` vs Sky builtin).** The crate type `bytes::Bytes` shows
up Sky-side as `Bytes`, and `skyTypeToRust "Bytes" = "Vec<u8>"` → the wrapper
references `Vec<u8>::copy_from_slice` (E0599). The collision is in the **Sky type
name**. **Fix (harder):** give opaque crate types whose bare name equals a Sky
builtin (`Bytes`, `String`?, `Error`?) a disambiguated Sky alias (e.g.
`BytesCrate_Bytes`) at binding-gen, OR refuse the bare-`Bytes` mapping when the
inspector qualified it to `bytes::Bytes`. Track separately; lower urgency than A.

## P3 — Unqualified receiver nameability (regex)

**Gap.** regex's `RegexBuilder` receiver arrives **unqualified** (`RegexBuilder`,
not `regex::RegexBuilder`), so `type_is_nameable` drops it (and its 48 setters).
csv/gadget receivers qualify fine — so the reachable-paths collector misses
*some* crate-root/re-exported types.
**Action:** investigate `collect_reachable_paths` / `reachable_local_path` for why
`regex::RegexBuilder` (likely re-exported from a submodule via `pub use`) isn't
mapped to a qualified path. Likely fix: follow `pub use` re-export chains when
building the id→path map. Unlocks the regex/`RegexSetBuilder` builder surface.

## P4 — Sized gate on by-value receivers

**Gap.** Own-threading (and any by-value method) on an **unsized** receiver
(`bytes::buf::UninitSlice` = `[MaybeUninit<u8>]`) emits `arg0: UninitSlice` →
`!Sized` → the whole bindings file fails.
**Fix.** Drop methods whose receiver is a known DST. Heuristic tiers: (1) std DSTs
(`str`, `[T]`, `dyn …`); (2) a crate type that NEVER appears by value in any kept
signature (only behind `&`/`&mut`) — strong "unsized" signal computable in one
pass over the crate's functions. Conservative: when unsure, drop (sound floor).
**Value:** prevents one unsized type from breaking an otherwise-usable crate.

## P5 — `&mut [u8]` output-buffer params (deferred)

`fn(&mut [u8]) -> n` fill-a-buffer APIs (hex `decode_to_slice`, tokio `read`).
Could map to Sky `Bytes -> (Bytes, Int)` (allocate, fill, return). Lower value;
revisit after P1–P4.

## Sequencing

P1 (broad, mechanical) → P2-A (one-line `::` qualify, big csv unlock) → P4 (Sized
gate, prevents regressions from P1/P3 widenings) → P3 (regex investigation) →
P2-B / P5. Each ships with a hermetic-crate end-to-end test + a build-sweep guard.
