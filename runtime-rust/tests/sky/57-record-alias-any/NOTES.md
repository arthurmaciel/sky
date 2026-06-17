# record-alias `any` — soundness gate

This fixture exercises the record-alias `any` field lowering in the Rust backend.

## Positive (this fixture builds + runs)

`src/Main.sky` declares `type alias Box a = { value : a, label : String }` and
uses it through a function parameter. `a` is a **declared generic type var**, so
it lowers to a generic Rust struct `MainBox<a>` and compiles cleanly:

```
$ sky build src/Main.sky --target rust   # -> Build complete
$ ./sky-app                              # -> answer
```

## Negative (a SHOULD-FAIL case — NOT a build fixture)

A record alias with a **bare-wildcard `any`** field — `any` that is NOT one of
the alias's declared type vars:

```elm
type alias Carrier =
    { payload : any        -- bare wildcard, no generic slot to carry it
    , label : String
    }
```

Before the fix this emitted the literal undefined Rust type `any` (a non-generic
`struct Carrier { payload: any }` plus usages referencing a phantom
`Carrier<any>`), so `cargo build` failed with a cryptic cascade — E0412
("cannot find type `any`") + E0107 ("struct takes 0 generic arguments but 1 was
supplied"). That is a `type-checks ⇒ cargo-fails` soundness-floor breach.

The Rust backend forbids `Box<dyn Any>` type erasure, and a record field —
unlike the ADT pub/sub-Msg carrier — has no convention guaranteeing the value is
a `Dict String String`, so silently resolving it to `HashMap<String, String>`
would mis-type it (in the wild `payload = "hi"` is a `String`). Correctness/
soundness outranks completeness: the backend now **fails loud at codegen** with
a structured, actionable error instead of leaking an undefined `any` to cargo:

```
$ sky build src/Main.sky --target rust
sky: error[Rust]: any-typed record field 'payload' in 'Carrier' — encode it as an ADT upstream, or use a concrete type
$ echo $?
1
```

No `main.rs` is written; cargo is never invoked. The author resolves it by
encoding the payload as an ADT (so the carried type is known per variant) or by
naming a concrete type.

The fix lives in `src/Sky/Generate/Rust/Builder/TypeEmitter.hs`
(`guardBareAny` / `typeHasBareAny` on the record-alias struct-emission path).
