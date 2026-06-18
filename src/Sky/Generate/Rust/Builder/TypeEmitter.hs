module Sky.Generate.Rust.Builder.TypeEmitter
  ( unionsToRustTypes
  , unionToRustTypeDef
  , substPlaceholder
  , aliasesToRustTypes
  , sortFieldsByIndex
  , aliasToRustTypeDef
  , fieldTypeToRust
  , paramTypeToRust
  ) where

import Data.List (intercalate, sortBy, stripPrefix)
import qualified Data.Map.Strict as Map
import qualified Sky.AST.Canonical as Can
import Sky.Generate.Rust.Builder.Types (RustTypeDef(..), runtimeOpaqueTypes)
import Sky.Generate.Rust.Builder.Naming (toCamelCase, mangleTVar, rustVariantName)
import Sky.Generate.Rust.Builder.TypeRenderer (typeToRustString, flattenArrowType, resultIsTaskTy)

unionsToRustTypes :: Map.Map String String -> String -> String -> Map.Map String Can.Union -> [RustTypeDef]
unionsToRustTypes recordMap skyModName modPrefix unions =
    -- The opaque `Decoder a` from Sky.Core.Json.Decode AND Std.Config is the
    -- runtime json::Decoder (rendered via the global `Decoder<T>` alias by
    -- typeToRustString). Its Sky def is a phantom (`type Decoder a` with a unit
    -- placeholder), so emitting it as a Rust enum yields `pub enum Decoder<a> {
    -- Decoder }` — an unused type param a (E0392). Skip it; the alias covers all
    -- references and the combinators route to decode_* / json_decode_* / config_* kernels.
    map (\(name, u) -> unionToRustTypeDef recordMap skyModName modPrefix name u)
        (filter (\(name, _) -> name /= "Decoder") (Map.toList unions))

unionToRustTypeDef :: Map.Map String String -> String -> String -> String -> Can.Union -> RustTypeDef
unionToRustTypeDef recordMap skyModName modPrefix typeName (Can.Union uvars alts _ _) =
    let codegenName = toCamelCase (modPrefix ++ "_" ++ typeName)
        -- Sub-D step 4: a generic ADT (`type Retry e = ...`) lowers to a generic
        -- enum (`pub enum MainRetry<e> { ... }`). Without this the enum body
        -- references `e` undeclared (E0107/E0091/E0412). Type vars are kept
        -- verbatim (lowercase) to match typeToRustString's TVar rendering and
        -- the generic params already emitted on functions.
        gens = if null uvars then ""
               else "<" ++ intercalate ", " (map mangleTVar uvars) ++ ">"
    in case Map.lookup (skyModName, typeName) runtimeOpaqueTypes of
        -- Registry hit, PLAIN path (`sky_runtime::EmailProvider`):
        -- `pub use sky_runtime::X as <codegenName>;`. The runtime newtype IS the
        -- canonical representation; the Sky-side placeholder constructor (e.g.
        -- `Decimal__Internal Float`) is a phantom-shape that only reserves a slot.
        Just rustPath
          | '{' `elem` rustPath ->
              -- Generic alias carrying the union's own type vars (Html msg ->
              -- pub type StdHtmlHtml<msg> = sky_runtime::Html<msg>;). Substitute
              -- the single Sky uvar for the {M} placeholder; the alias IS generic.
              -- [] is dead in practice: a {M} registry entry only pairs with a parametric Sky type.
              let m = case uvars of (v:_) -> mangleTVar v; [] -> "M"
                  path = substPlaceholder "{M}" m rustPath
              in RAliasDefGen codegenName gens path
          | '<' `notElem` rustPath -> RPubUseAlias codegenName rustPath
        -- Registry hit, INSTANTIATED-generic path (`sky_runtime::ChunkEvent<SkyError>`):
        -- `pub use` can't carry an instantiation, so emit a non-generic type alias
        -- (`pub type SkyCoreHttpStreamChunkEvent = sky_runtime::ChunkEvent<SkyError>;`).
        -- The runtime enum is generic over the error slot; the bridge pins it to
        -- the project's SkyError so a matched `Errored e` binds the real Error.
        -- Variant access (`<alias>::Chunk`) resolves through the alias. Mirrors
        -- the parametric-record-alias arm in aliasToRustTypeDef. (Independent of
        -- the Sky-side `uvars` — ChunkEvent is non-generic in Sky yet bridges to
        -- an instantiated runtime generic.)
          | otherwise              -> RAliasDef codegenName rustPath
        -- No registry entry: emit the regular enum/ADT (one constructor per alt).
        Nothing       -> REnumDef codegenName gens (map ctorToRust alts)
  where
    -- A constructor field whose type IS the enum being defined (direct
    -- self-recursion, e.g. `Length = … | Minimum Int Length`) makes the Rust
    -- enum infinite-sized (E0072). Box that back-edge. `Vec<Self>` / `SkyMaybe<Self>`
    -- fields render to a different head and are already heap/finite, so they
    -- are NOT boxed. Construction wraps the arg in Box::new and matches deref it
    -- (ecBoxedCtorFields, consumed by the expr + pattern emitters).
    selfRustName = toCamelCase (modPrefix ++ "_" ++ typeName)
    firstUVar = case uvars of (v:_) -> mangleTVar v; [] -> "M"
    -- An `any`-typed ADT variant field is Sky's source-level type-erasure escape
    -- hatch, but in these Std.Ui carriers the value is ALWAYS a concrete type
    -- (every construction wraps it). The Rust backend forbids type erasure
    -- (no `dyn Any` in generated code), so render the field as that concrete
    -- type — `AttrEvent any` always carries `Std.Html.Attributes.Attribute msg`,
    -- `Raw any` always an `Std.Html.Html msg`. (`Event.OnRaw`'s `any` is in the
    -- runtime's opaque Event enum — the one sanctioned Arc<dyn Any> seam — and
    -- is not codegen-emitted, so it's not here.) Rust-only; the shared .sky keeps
    -- `any` (load-bearing for onSubmit's permissive `a -> Attribute b`).
    anyCarrierField ctorName = case (skyModName, typeName, ctorName) of
        ("Std.Ui", "Attribute", "AttrEvent") -> Just ("StdHtmlAttributesAttribute<" ++ firstUVar ++ ">")
        ("Std.Ui", "Element",   "Raw")       -> Just ("StdHtmlHtml<" ++ firstUVar ++ ">")
        -- A bare `any` constructor field on a non-generic ADT (the union has no
        -- declared type vars to carry it) is a pub/sub payload carrier. The
        -- upstream pub/sub guidance names `Dict String String` as the portable
        -- payload, so resolve it to that concrete carrier (= HashMap<String,
        -- String>). This keeps the ADT (e.g. a TEA `Msg`) monomorphic so the
        -- per-type Broker keyed on `TypeId` connects publisher and subscriber.
        -- (A concrete-typed payload field — e.g. `Received String` — never
        -- reaches here; only a bare `TVar "any"` field does.) Resolving rather
        -- than emitting a verbatim `any` also fixes the pre-existing E0412 a
        -- bare `any` field produced on a non-generic enum.
        _ | null uvars                       -> Just "HashMap<String, String>"
          | otherwise                        -> Nothing
    boxIfRecursive t =
        let r = typeToRustString recordMap t
        in if r == selfRustName then "Box<" ++ r ++ ">" else r
    renderField ctorName t = case t of
        Can.TVar "any" | Just concrete <- anyCarrierField ctorName -> concrete
        _                                                          -> boxIfRecursive t
    ctorToRust (Can.Ctor name _idx _arity argTypes) =
        (rustVariantName name, if null argTypes then Nothing
               else Just (intercalate ", " (map (renderField name) argTypes)))

-- | Substitute all occurrences of `needle` with `replacement` in `haystack`.
-- Used to expand {M} placeholders in runtimeOpaqueTypes registry values.
substPlaceholder :: String -> String -> String -> String
substPlaceholder needle replacement haystack = go haystack
  where
    go [] = []
    go s@(c:cs) = case stripPrefix needle s of
        Just rest -> replacement ++ go rest
        Nothing   -> c : go cs

aliasesToRustTypes :: Map.Map String String -> String -> String -> Map.Map String Can.Alias -> [RustTypeDef]
aliasesToRustTypes recordMap skyModName modPrefix aliases = concatMap (\(name, alias) -> aliasToRustTypeDef recordMap skyModName modPrefix name alias) (Map.toList aliases)

-- | Sort record fields by their declaration index (_fieldIndex)
sortFieldsByIndex :: [(String, Can.FieldType)] -> [(String, Can.FieldType)]
sortFieldsByIndex = sortBy (\(_, Can.FieldType i _) (_, Can.FieldType j _) -> compare i j)

-- | Render a RECORD FIELD's type. A function-typed field (`onConnect :
-- WebSocketServer -> Task Error ()`) holds a STORED effectful callback that may
-- capture app state, so it renders as `Arc<dyn Fn(..) -> .. + Send + Sync>` —
-- NOT a bare `fn` pointer (which forbids captures). The record literal / update
-- emitters wrap the assigned value in `Arc::new(..)` to match. Non-function
-- fields delegate to typeToRustString unchanged.
fieldTypeToRust :: Map.Map String String -> Can.Type -> String
fieldTypeToRust recordMap ft = case ft of
    Can.TLambda _ _ ->
        let (ps, ret) = flattenArrowType ft
        in "std::sync::Arc<dyn Fn(" ++ intercalate ", " (map (typeToRustString recordMap) ps)
           ++ ") -> " ++ typeToRustString recordMap ret ++ " + Send + Sync>"
    _ -> typeToRustString recordMap ft

aliasToRustTypeDef :: Map.Map String String -> String -> String -> String -> Can.Alias -> [RustTypeDef]
-- Sub-D: a record alias registered in runtimeOpaqueTypes (e.g. Std.Csv.Csv)
-- emits a `pub use <runtime type> as <codegenName>;` alias instead of a fresh
-- struct, so the runtime kernels can return/take the record by its real type.
aliasToRustTypeDef _recordMap skyModName modPrefix name (Can.Alias vars (Can.TRecord _ _))
    | Just rustPath <- Map.lookup (skyModName, name) runtimeOpaqueTypes =
        let codegenName = toCamelCase (modPrefix ++ "_" ++ name)
        in if null vars
           -- Non-parametric (Csv, HttpResponse): plain re-export.
           then [RPubUseAlias codegenName rustPath]
           -- Parametric (WebSocketServerCfg msg): the runtime type's generics are
           -- already pinned in rustPath (…<SkyError>), and the Sky var (`msg`) is
           -- phantom. Emit a NON-generic alias and render usages without args
           -- (see typeToRustString) — Rust forbids unused type-alias params, so
           -- we drop `msg` entirely. `pub type Cfg = WsServerCfg<SkyError>;`.
           else [RAliasDef codegenName rustPath]
aliasToRustTypeDef recordMap _skyModName modPrefix name (Can.Alias vars ty) = case ty of
    Can.TRecord fields _ ->
        let sortedFields = sortFieldsByIndex (Map.toList fields)
            -- Sub-D step 4: a parametric record alias (`RetryPolicy e = { ...,
            -- shouldRetry : ShouldRetry e }`) must emit a generic struct so its
            -- fields can reference the var. Type vars kept verbatim to match
            -- typeToRustString's TVar/TAlias-arg rendering.
            gens = if null vars then "" else "<" ++ intercalate ", " (map mangleTVar vars) ++ ">"
        in [RStructDef (toCamelCase (modPrefix ++ "_" ++ name)) gens
              (map (\(n, Can.FieldType _ ft) ->
                       (n, guardBareAny name vars n ft (fieldTypeToRust recordMap ft)))
                   sortedFields)]
    _ ->
        [RAliasDef (toCamelCase (modPrefix ++ "_" ++ name)) (typeToRustString recordMap ty)]

-- | Soundness gate for a bare-wildcard `any` in a record-alias field.
--
-- A field whose type is `Can.TVar "any"` (or contains one) where `any` is NOT
-- one of the alias's declared type vars is Sky's source-level type-erasure
-- escape hatch. The declared-var case (`type alias Box a = { value : a }`) is
-- fine — `any` becomes a generic struct param `<any>` (TypeRenderer renders
-- `TVar v -> v`). But a BARE wildcard (`type alias Carrier = { payload : any }`)
-- has no generic slot to carry it and would render the literal identifier `any`
-- — an undefined Rust type (E0412 at cargo) plus a non-generic struct that
-- later usages reference with a phantom `<any>` arg (E0107). That is a
-- `type-checks ⇒ cargo-fails` soundness-floor breach.
--
-- Unlike the ADT pub/sub-Msg carrier (`anyCarrierField`, where the variant
-- ALWAYS wraps a `Dict String String` by convention so resolving to
-- HashMap<String,String> is correct), a record field carries an arbitrary value
-- — in the wild `payload = "hi"` is a String, not a Dict — so silently
-- resolving it to HashMap<String,String> would mis-type it. Correctness/
-- soundness outranks completeness: FAIL LOUD at codegen with a structured,
-- actionable error rather than guess a carrier type or leak an undefined `any`
-- to cargo. The author encodes the payload as an ADT (so the type is known per
-- variant) or names a concrete type.
guardBareAny :: String -> [String] -> String -> Can.Type -> String -> String
guardBareAny typeName vars fieldName fieldTy rendered
    | typeHasBareAny vars fieldTy =
        error $ "error[Rust]: any-typed record field '" ++ fieldName ++ "' in '"
             ++ typeName ++ "' — encode it as an ADT upstream, or use a concrete type"
    | otherwise = rendered

-- | Does this type contain a `TVar "any"` that is NOT a declared alias var?
-- Declared-var `any` (rare but legal) is a generic param and renders fine.
typeHasBareAny :: [String] -> Can.Type -> Bool
typeHasBareAny vars = go
  where
    bareAny v = v == "any" && ("any" `notElem` vars)
    go t = case t of
        Can.TVar v          -> bareAny v
        Can.TType _ _ args  -> any go args
        Can.TLambda a b     -> go a || go b
        Can.TTuple a b rest -> any go (a : b : rest)
        Can.TRecord fs ext  -> any (go . Can._fieldType) (Map.elems fs)
                                 || maybe False bareAny ext
        Can.TAlias _ _ args _ -> any (go . snd) args
        Can.TUnit           -> False


-- | Render a FUNCTION PARAMETER's type. An EFFECTFUL function-typed parameter
-- (one whose result is a `Task`) renders as `impl Fn(args) -> ret + Send + Sync
-- + 'static` (argument-position impl Trait) rather than the fn-pointer
-- typeToRustString would produce. fn pointers reject closures that capture
-- environment — e.g. Sky.Core.Http.Stream.forEachChunk's `\chunk -> emit chunk
-- writer` captures `writer`; `impl Fn` accepts capturing (move) closures, plain
-- closures, AND fn items, so it's a strict widening of what the slot holds. An
-- `Arc<dyn Fn>` (the `Handler` VALUE form) flowing into such a param is wrapped
-- back to a plain closure at the call site (see the Arc→impl-Fn adapter in
-- ExprEmitter's supplied-arg renderer) so this stays `impl Fn`.
--
-- The Task-result gate is deliberate: a pure callback (`e -> bool`, `a -> b`) is
-- frequently STORED in an ADT variant or record field — which render as fn
-- pointers (e.g. ShouldRetry's `RetryWhen (fn(e) -> bool)`, result concrete
-- `Bool` not a Task) — so the gate can never catch them. Non-function params
-- render normally. The arrow chain flattens uncurried (`\a b ->` → `|a, b|`).
paramTypeToRust :: Map.Map String String -> Can.Type -> String
paramTypeToRust rm t = case t of
    Can.TLambda _ _ | resultIsTaskTy (snd (flattenArrowType t)) ->
        let (ps, ret) = flattenArrowType t
        in "impl Fn(" ++ intercalate ", " (map (typeToRustString rm) ps) ++ ") -> "
           ++ typeToRustString rm ret ++ " + Send + Sync + 'static"
    _ -> typeToRustString rm t
