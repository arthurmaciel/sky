module Sky.Generate.Rust.Builder.Naming
  ( toCamelCase
  , toSnakeCase
  , anonStructName
  , moduleNameToRust
  , rustSafeIdent
  , kernelCtorToRust
  , rustFnName
  , kernelModulePrefixes
  , disambiguateUserFnName
  , mangleTVar
  , rustVariantName
  ) where

import Data.Char (toLower, toUpper, isUpper)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Sky.Sky.ModuleName as ModuleName

-- | The emitted Rust name for a Sky top-level function, consulting the
-- collision-rename map. `toSnakeCase (modPrefix ++ "_" ++ name)` is NOT
-- injective — `Std.Ui.borderRounded` and `Std.Ui.Border.rounded` both produce
-- `std_ui_border_rounded` (Go keeps them apart via preserved CamelCase). The
-- map (built in buildProgram) holds the de-collided name for exactly those
-- colliders; every other name uses the default snake_case form. Both def and
-- call sites route through here so the renamed names stay consistent.
rustFnName :: Map.Map (String, String) String -> String -> String -> String
rustFnName renames modPrefix name =
    Map.findWithDefault (toSnakeCase (modPrefix ++ "_" ++ name)) (modPrefix, name) renames

-- | The first snake-case segment of every runtime kernel function name —
-- i.e. the short stdlib module names the runtime flattens into the crate
-- root via `pub use sky_runtime::*`. A USER module that mangles to one of
-- these prefixes (e.g. a project module literally named `Auth` →
-- `auth_*`, or `Middleware` → `middleware_*`) collides at the crate root:
-- the user `pub use <usermod>::*` and the kernel `pub use sky_runtime::*`
-- both expose `auth_hash_password` → E0659 ambiguous. This is the Rust
-- analogue of the Go backend's `reservedGoNames` rewriting.
--
-- MUST stay in sync with the kernel name-space in `Kernel.kernelToRust`
-- and the runtime crate's `pub fn` exports: any segment that prefixes a
-- runtime-exported function belongs here so a same-named user module is
-- disambiguated. Over-inclusion is safe (it only renames user fns in a
-- module whose short name matches); under-inclusion re-opens the E0659
-- collision. Derived from the runtime's `pub fn <seg>_…` surface.
kernelModulePrefixes :: Set.Set String
kernelModulePrefixes = Set.fromList
    [ "auth", "middleware", "list", "string", "dict", "set", "maybe"
    , "result", "math", "char", "bytes", "regex", "crypto", "encoding"
    , "json", "jwt", "uuid", "decimal", "money", "task", "cmd", "sub"
    , "pubsub", "time", "random", "http", "file", "io", "system", "process"
    , "db", "log", "trace", "server", "rate", "cache", "email", "compression"
    , "csv", "config", "ffi", "live", "html", "element", "console", "hub"
    , "api", "basics", "path", "webview", "ws", "websocket", "cli"
    , "base64", "url", "decode", "encode", "render"
    ]

-- | Disambiguate a user-module function whose default Rust name would
-- collide with a runtime kernel name. Returns `Just newName` when the
-- default lowering's first snake-segment matches a `kernelModulePrefixes`
-- entry; the new name is `user_` + the default, which can't collide with
-- any kernel (no kernel starts with `user_`) and stays per-module-unique
-- because the default already embeds the user module prefix. Returns
-- `Nothing` for non-colliding user modules so their output is unchanged.
disambiguateUserFnName :: String -> String -> Maybe String
disambiguateUserFnName modPrefix name =
    let def = toSnakeCase (modPrefix ++ "_" ++ name)
        firstSeg = takeWhile (/= '_') def
    in if Set.member firstSeg kernelModulePrefixes
       then Just ("user_" ++ def)
       else Nothing

-- | Convert Sky module-prefixed names to Rust conventions:
--   Types:     Sky_Core_Error_Error  →  SkyCoreErrorError     (CamelCase)
--   Functions: Sky_Core_List_map     →  sky_core_list_map     (snake_case)
toCamelCase :: String -> String
toCamelCase [] = []
toCamelCase (c:cs) = toUpper c : go cs
  where go [] = []
        go ('_':c:cs) = toUpper c : go cs
        go (c:cs) = c : go cs

toSnakeCase :: String -> String
toSnakeCase [] = []
toSnakeCase (c:cs) = toLower c : go cs
  where go [] = []
        go (c:cs) | c == '_' && not (null cs) = '_' : toLower (head cs) : go (tail cs)
                  | isUpper c = '_' : toLower c : go cs
                  | otherwise = c : go cs

-- | Map a Sky type-variable name to a valid UpperCamelCase Rust GENERIC param
-- name. Sky type vars are lowercase-leading identifiers (`msg`, `a`, `e`,
-- `any`, `msg2`); emitting them verbatim as Rust generics
-- (`SkyCmd<msg>`, `pub enum Retry<e>`) trips `non_camel_case_types` (184 occ).
-- Uppercasing the first letter and keeping the tail (digits included) yields a
-- conventional Rust generic (`Msg`, `A`, `E`, `Any`, `Msg2`) while staying
-- injective over the lowercase-leading var space — so two distinct Sky vars
-- never collide after mangling.
--
-- MUST be applied IDENTICALLY at every generic-param DECLARATION site (the
-- `<...>` lists + bounds on functions / structs / enums) AND at the `Can.TVar`
-- USE site in `typeToRustString` — a decl `<Msg>` referenced as `msg` is E0412.
--
-- The wildcard `any` mangles to `Any` only when it is a DECLARED generic param
-- (legal, e.g. `type alias Box any = { value : any }`); the BARE-wildcard `any`
-- record-field case is rejected upstream by `guardBareAny` BEFORE any rendering,
-- so mangling here never masks that soundness error. `Any` is a fresh ident in
-- the generated code (no `use std::any::Any`), so it cannot resolve-clash.
mangleTVar :: String -> String
mangleTVar [] = []
mangleTVar (c:cs) = toUpper c : cs

-- | Normalise a Sky ADT-constructor name to a warning-clean Rust enum variant.
-- The only offender in practice is the stdlib opaque-token convention
-- `type Server = Server_OPAQUE` (Sky.Http.Server's Route/Server/Cookie), whose
-- SCREAMING_SNAKE suffix trips `non_camel_case_types` when emitted verbatim as a
-- Rust variant. These tokens are phantom — never constructed or matched in user
-- code — so rewriting the variant name only needs to stay consistent between the
-- enum DEF and its derived `SkyStringify` match arms (both consume one shared
-- variant list) plus `kernelCtorToRust`. We rewrite a trailing `_OPAQUE` to a
-- camel `Opaque`; every other ctor name is left untouched (so real ctors like
-- `Just` / `Ok` / user variants are byte-identical).
rustVariantName :: String -> String
rustVariantName name = case reverse name of
    'E':'U':'Q':'A':'P':'O':'_':rest -> reverse rest ++ "Opaque"
    _                                -> name

-- | Anonymous record struct name prefix
anonStructName :: String -> String
anonStructName key = toCamelCase ("Anon_" ++ map (\c -> if c == ',' then '_' else c) key)

moduleNameToRust :: ModuleName.Canonical -> String
moduleNameToRust mod =
    map (\c -> if c == '.' then '_' else c) (ModuleName._name mod)

rustSafeIdent :: String -> String
rustSafeIdent "fn" = "r#fn"
rustSafeIdent "match" = "r#match"
rustSafeIdent "let" = "r#let"
rustSafeIdent "mod" = "r#mod"
rustSafeIdent "type" = "r#type"
rustSafeIdent "ref" = "r#ref"
rustSafeIdent "self" = "r#self"
rustSafeIdent "Self" = "r#Self"
rustSafeIdent "static" = "r#static"
rustSafeIdent "mut" = "r#mut"
rustSafeIdent "return" = "r#return"
rustSafeIdent "while" = "r#while"
rustSafeIdent "for" = "r#for"
rustSafeIdent "in" = "r#in"
rustSafeIdent "if" = "r#if"
rustSafeIdent "else" = "r#else"
rustSafeIdent "loop" = "r#loop"
rustSafeIdent "where" = "r#where"
rustSafeIdent "async" = "r#async"
rustSafeIdent "await" = "r#await"
rustSafeIdent "dyn" = "r#dyn"
rustSafeIdent "impl" = "r#impl"
rustSafeIdent "trait" = "r#trait"
rustSafeIdent "enum" = "r#enum"
rustSafeIdent "struct" = "r#struct"
rustSafeIdent "union" = "r#union"
rustSafeIdent "use" = "r#use"
rustSafeIdent "crate" = "r#crate"
rustSafeIdent "super" = "r#super"
rustSafeIdent "pub" = "r#pub"
rustSafeIdent "move" = "r#move"
rustSafeIdent name = name

kernelCtorToRust :: ModuleName.Canonical -> String -> String -> String
kernelCtorToRust modName typeName ctorName =
    let modStr = ModuleName._name modName
    in case (modStr, typeName, ctorName) of
        ("Sky.Core.Basics", "Bool", "True") -> "true"
        ("Sky.Core.Basics", "Bool", "False") -> "false"
        ("Sky.Core.Maybe", "Maybe", c) -> "SkyMaybe::" ++ c
        ("Sky.Core.Result", "Result", c) -> "SkyResult::" ++ c
        _ -> let modPrefix = if null modStr then "" else map (\c -> if c == '.' then '_' else c) modStr ++ "_"
             in toCamelCase (modPrefix ++ typeName) ++ "::" ++ rustVariantName ctorName
