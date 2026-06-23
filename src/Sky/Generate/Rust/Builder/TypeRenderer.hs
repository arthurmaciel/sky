module Sky.Generate.Rust.Builder.TypeRenderer
  ( extractReturnType
  , extractParamTypes
  , formTargetRustType
  , hasTypeVars
  , rustifyExpectedType
  , collectTVars
  , collectRenderedTVars
  , typeToRustString
  , flattenArrowType
  , resultIsTaskTy
  , isEventArgType
  ) where

import Data.List (intercalate, nub, isPrefixOf)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Sky.AST.Canonical as Can
import qualified Sky.Sky.ModuleName as ModuleName
import Sky.Generate.Rust.Builder.Naming (toCamelCase, mangleTVar)
import Sky.Generate.Rust.Builder.Types (runtimeOpaqueTypes)

-- | Flatten a curried arrow type `A -> B -> C` into ([A, B], C) so it renders
-- as an uncurried Rust fn pointer. Mirrors the codegen's uncurried lambda/call
-- convention.
flattenArrowType :: Can.Type -> ([Can.Type], Can.Type)
flattenArrowType (Can.TLambda a b) = let (ps, r) = flattenArrowType b in (a : ps, r)
flattenArrowType ty = ([], ty)

-- | Is this type the `Task _ _` shape? The discriminator for an EFFECTFUL
-- function type (one whose result is a Task) — see the `Can.TLambda` arm of
-- `typeToRustString` (renders such arrows as `Arc<dyn Fn>` so capturing route /
-- middleware handlers register) and `paramTypeToRust`'s identical gate. Kept here
-- so both renderers share one definition.
resultIsTaskTy :: Can.Type -> Bool
resultIsTaskTy (Can.TType _ "Task" _) = True
resultIsTaskTy _                      = False

-- | Is this the ARG type of a Std.Ui/Std.Html event callback — concrete
-- `String` or `Bool` (the wire payload of `OnString`/`OnBool`)? Used to gate
-- the `Arc<dyn Fn>` rendering of a `(String -> msg)` / `(Bool -> msg)` handler
-- so a capturing closure can flow through the event chain. Kept tight (only
-- these two leaf types) so it can't catch unrelated arrow types.
isEventArgType :: Can.Type -> Bool
isEventArgType (Can.TType _ "String" []) = True
isEventArgType (Can.TType _ "Bool"   []) = True
isEventArgType _                         = False


-- | Walk TLambda chain to extract the innermost (return) type
extractReturnType :: Can.Type -> Can.Type
extractReturnType (Can.TLambda _ ret) = extractReturnType ret
extractReturnType ty = ty

-- | Extract parameter types from a function type (TLambda chain), converting
-- each to a Rust type string.  Returns [] for non-function types.
extractParamTypes :: Can.Type -> [Can.Type]
extractParamTypes (Can.TLambda paramTy restTy) = paramTy : extractParamTypes restTy
extractParamTypes _ = []

-- | P2-T4/T5 shared helper. Given the `onSubmit` handler argument's
-- solver-inferred type (looked up from ecRegionTypes at the handler arg's
-- region), determine the form-target record's Rust type string `T`.
--
-- The handler is either:
--   * a `(Creds -> Msg)` function — the FIRST param is the form record `T`;
--     we return `Just (typeToRustString recordMap T)` (the record-handler case).
--   * a bare `Msg` value (`onSubmit SomeMsg`) — non-function type; `Nothing`
--     (the bare-Msg case, no decode).
--
-- Both the call-site peephole (Part A) and the collectFormTargets pre-pass
-- (Part B) route through THIS function so they agree on the rendered name.
formTargetRustType :: Map.Map String String -> Maybe Can.Type -> Maybe String
formTargetRustType recordMap mHandlerTy = case mHandlerTy of
    Just ty -> case extractParamTypes ty of
        (t : _) -> Just (typeToRustString recordMap t)
        []      -> Nothing
    Nothing -> Nothing

-- | Check if a type contains unresolved type variables (should not be emitted)
hasTypeVars :: Can.Type -> Bool
hasTypeVars (Can.TVar _) = True
hasTypeVars (Can.TLambda a b) = hasTypeVars a || hasTypeVars b
hasTypeVars (Can.TType _ _ args) = any hasTypeVars args
hasTypeVars (Can.TTuple a b rest) = any hasTypeVars (a:b:rest)
hasTypeVars (Can.TRecord fields _) = any (hasTypeVars . Can._fieldType) (Map.elems fields)
hasTypeVars (Can.TAlias _ _ pairs _) = any (hasTypeVars . snd) pairs  -- Sub-D step 4
hasTypeVars _ = False

-- | Sub-A.13: convert a solver-inferred Can.Type into a Rust type string,
-- suitable for turbofish at empty-literal emit sites. Returns Nothing when
-- the type still carries unbound type variables (the caller falls back to
-- a safe default with a stderr warning).
rustifyExpectedType :: Map.Map String String -> Can.Type -> Maybe String
rustifyExpectedType recMap ty
    | hasTypeVars ty = Nothing
    | otherwise      = Just (typeToRustString recMap ty)

-- | Collect all type variable names from a type (for generic param declaration).
collectTVars :: Can.Type -> [String]
collectTVars (Can.TVar v) = [v]
collectTVars (Can.TLambda a b) = collectTVars a ++ collectTVars b
collectTVars (Can.TType _ _ args) = concatMap collectTVars args
collectTVars (Can.TTuple a b rest) = concatMap collectTVars (a:b:rest)
collectTVars (Can.TRecord fields _) = concatMap (collectTVars . Can._fieldType) (Map.elems fields)
collectTVars (Can.TAlias _ _ pairs _) = concatMap (collectTVars . snd) pairs  -- Sub-D step 4
collectTVars _ = []

-- | Like collectTVars but mirrors typeToRustString's rendering: a runtimeOpaque
-- type/alias drops its Sky args (its generics are pinned in the registry value,
-- e.g. WsServerCfg<SkyError>), so vars appearing ONLY inside those dropped args
-- must not become function generics — they'd be unused in the Rust sig
-- (E0107/E0283). Exception: {M}-entries (Html, Attribute, Event) ARE generic in
-- the emitted alias, so their Sky args DO appear in the rendered type and must
-- be collected.
collectRenderedTVars :: Can.Type -> [String]
collectRenderedTVars t = case t of
    Can.TVar v -> [v]
    Can.TLambda a b -> collectRenderedTVars a ++ collectRenderedTVars b
    Can.TType modName name args ->
        case Map.lookup (ModuleName._name modName, name) runtimeOpaqueTypes of
            Just rp | '{' `elem` rp -> concatMap collectRenderedTVars args  -- generic alias
            Just _  -> []                                                    -- non-generic opaque; drop args
            Nothing -> concatMap collectRenderedTVars args
    Can.TTuple a b rest -> concatMap collectRenderedTVars (a:b:rest)
    Can.TRecord fields _ -> concatMap (collectRenderedTVars . Can._fieldType) (Map.elems fields)
    Can.TAlias modName name pairs _ ->
        case Map.lookup (ModuleName._name modName, name) runtimeOpaqueTypes of
            Just rp | '{' `elem` rp -> concatMap (collectRenderedTVars . snd) pairs  -- generic alias
            Just _  -> []                                                              -- non-generic opaque
            Nothing -> concatMap (collectRenderedTVars . snd) pairs
    _ -> []

-- | Render a Can.Type as a Rust type string.  `recordMap` maps the canonical
-- comma-separated key of a TRecord's field names to the Rust struct name
-- (either an alias or an anonymous struct name).
typeToRustString :: Map.Map String String -> Can.Type -> String
typeToRustString recordMap t = case t of
    Can.TType _ "Int" [] -> "i64"
    Can.TType _ "Float" [] -> "f64"
    Can.TType _ "Bool" [] -> "bool"
    Can.TType _ "Char" [] -> "char"
    Can.TType _ "String" [] -> "String"
    Can.TType _ "Task" [_, a] -> "SkyTask<" ++ typeToRustString recordMap a ++ ">"
    -- Sub-E: TEA Cmd/Sub are generic over the message type.
    Can.TType _ "Cmd" [m] -> "SkyCmd<" ++ typeToRustString recordMap m ++ ">"
    Can.TType _ "Sub" [m] -> "SkySub<" ++ typeToRustString recordMap m ++ ">"
    -- Json.Decode / Std.Config share one runtime decoder representation. Both
    -- expose an opaque `Decoder a`; render it as the global `Decoder<T>` alias
    -- (= sky_runtime::json::Decoder<SkyError, T>) so an annotated decoder
    -- (`cfgDecoder : Config.Decoder DbCfg`) matches the decode_* / json_decode_* / config_*
    -- kernels its call sites route to. The placeholder enum is skipped at the
    -- def site (see the Decoder guard in the union emitter).
    Can.TType _ "Decoder" [a] -> "Decoder<" ++ typeToRustString recordMap a ++ ">"
    Can.TUnit -> "()"
    Can.TType _ "List" [a] -> "Vec<" ++ typeToRustString recordMap a ++ ">"
    Can.TType _ "Maybe" [a] -> "SkyMaybe<" ++ typeToRustString recordMap a ++ ">"
    Can.TType _ "Dict" [k, v] -> "HashMap<" ++ typeToRustString recordMap k ++ ", " ++ typeToRustString recordMap v ++ ">"
    Can.TType _ "Set" [a] -> "BTreeSet<" ++ typeToRustString recordMap a ++ ">"
    -- #32: normalise the Result ERROR slot to `SkyError` whenever it would
    -- render to `String`. An auto-FFI `.skyi` can advertise a foreign Result as
    -- `Result String a`, but the generated FFI wrapper ALWAYS returns
    -- `SkyResult<SkyError, _>` (the documented design — an FFI Result's error
    -- slot is unusable on the Sky side; codegen forces `SkyError`). A binding
    -- carrying such a Result would otherwise lower its return type to
    -- `SkyResult<String, _>` from the advertised annotation while the value is
    -- `SkyResult<SkyError, _>` → cargo E0308. Sound because `String` is never a
    -- legitimate Result error slot in the Rust backend: Sky bans `Result String a`
    -- in public surfaces, the runtime never constructs a `SkyResult<String, _>`
    -- value, and the only origin is the FFI skyi. `Result Error a` is unchanged.
    Can.TType _ "Result" [e, a] ->
        let errStr = case typeToRustString recordMap e of
                         "String" -> "SkyError"
                         other    -> other
        in "SkyResult<" ++ errStr ++ ", " ++ typeToRustString recordMap a ++ ">"
    Can.TType _ "Error" [] -> "SkyError"
    Can.TRecord fields _ ->
        let key = intercalate "," (Map.keys fields)
            fieldSet = Set.fromList (Map.keys fields)
            -- When exact key misses, find the alias with the FEWEST extra
            -- fields that is a superset of the TRecord's fields.
            -- HM's row polymorphism narrows inferred record types to only
            -- the accessed fields — we widen back to the full alias.
            bestMatch = foldr (\(k, name) best ->
                let kSet = Set.fromList (words (map (\c -> if c == ',' then ' ' else c) k))
                    extras = Set.size kSet - Set.size fieldSet
                in if fieldSet `Set.isSubsetOf` kSet && extras >= 0
                   then case best of
                        Nothing -> Just (extras, name)
                        Just (e, _) | extras < e -> Just (extras, name)
                        _ -> best
                   else best
                ) Nothing (Map.toList recordMap)
            structName = case bestMatch of
                Just (_, n) -> n
                -- Std.Cache's `stats` returns an ANONYMOUS record `{ hits,
                -- misses, evictions }` with no project alias to match — map it to
                -- the runtime `CacheStats` struct (field names match) so the
                -- `Cache_stats` kernel's return type lines up and `st.hits`
                -- resolves. Without this an unmatched anon record falls back to
                -- `String` (E0308 + no fields).
                Nothing
                    | fieldSet == Set.fromList ["hits", "misses", "evictions"] -> "sky_runtime::CacheStats"
                    | otherwise -> "String"
            -- Anonymous record structs have generic type params (T0..Tn).
            -- Fill them from the TRecord's actual field types so references
            -- like `AnonXxx<String, i64, bool>` compile correctly. The struct
            -- DEFINITION assigns T0..Tn to fields in `Map.toList` (alphabetical
            -- key) order — see the anonDefs builder in buildProgram — so the
            -- type args here MUST be ordered the same way. Using declaration
            -- index (sortFieldsByIndex) here transposed the params whenever the
            -- alphabetical and declared orders differed (e.g. `{ from, to,
            -- subject }` → subject/to swapped), mis-typing every field.
            gens
              | "Anon" `isPrefixOf` structName =
                  "<" ++ intercalate ", " [typeToRustString recordMap (Can._fieldType ft) | (_, ft) <- Map.toList fields] ++ ">"
              | structName /= "String" =
                  -- A named record-alias struct that reached us as its EXPANDED
                  -- TRecord form (the `TAlias` wrapper was stripped during lowering
                  -- — happens for a zero-arg def whose annotation is a parametric
                  -- record alias, e.g. `defaultRetryPolicy : RetryPolicy e`). The
                  -- generic struct is `SkyCoreTaskRetryPolicy<e>`; recover its type
                  -- args from the free type vars in the field types (e.g. `e` inside
                  -- `shouldRetry : ShouldRetry e`). Bare name → E0107 "missing
                  -- generics". Non-generic structs have no free TVars → bare, as before.
                  case nub (concatMap (collectRenderedTVars . Can._fieldType . snd) (Map.toList fields)) of
                      []  -> ""
                      tvs -> "<" ++ intercalate ", " (map mangleTVar tvs) ++ ">"
              | otherwise = ""
        in structName ++ gens
    Can.TTuple a b rest -> "(" ++ intercalate ", " (map (typeToRustString recordMap) (a:b:rest)) ++ ")"
    Can.TVar v -> mangleTVar v
    Can.TType modName name [] ->
        let modStr = ModuleName._name modName
            modPrefix = if null modStr then "" else map (\c -> if c == '.' then '_' else c) modStr ++ "_"
        -- Empty modName = an unresolved cross-module ADT ref (`Html Msg` in a
        -- module that doesn't import the type's home). Resolve via the global
        -- @adt@ map (built in buildProgram) so `Msg` -> `StateMsg` rather than a
        -- bare, undefined `Msg` (17-skymon). Same-module refs carry modName and
        -- skip this. Unknown names fall back to the bare camelCase as before.
        in if null modStr
           then case Map.lookup ("@adt@" ++ name) recordMap of
                    Just rn -> rn
                    Nothing -> toCamelCase name
           else toCamelCase (modPrefix ++ name)
    Can.TType modName name args ->
        let modStr = ModuleName._name modName
            modPrefix = if null modStr then "" else map (\c -> if c == '.' then '_' else c) modStr ++ "_"
            baseName = toCamelCase (modPrefix ++ name)
        -- A registered runtimeOpaque type: if the registry value carries {M}
        -- the Sky-side type alias IS generic (e.g. StdHtmlHtml<msg>) — preserve
        -- the Sky type args so `StdHtmlHtml<Msg>` compiles. Non-{M} entries
        -- (plain path like `sky_runtime::EmailProvider`) are non-generic; drop args.
        in case Map.lookup (modStr, name) runtimeOpaqueTypes of
           Just rp | '{' `elem` rp ->
               -- Generic alias: preserve Sky type args
               if null args then baseName
               else baseName ++ "<" ++ intercalate ", " (map (typeToRustString recordMap) args) ++ ">"
           Just _ ->
               -- Non-generic opaque (EmailProvider, ServerRequest, etc.): drop args
               baseName
           Nothing ->
               if null args then baseName
               else baseName ++ "<" ++ intercalate ", " (map (typeToRustString recordMap) args) ++ ">"
    -- A curried Sky arrow chain (A -> B -> C) renders as an UNCURRIED Rust fn
    -- pointer fn(A, B) -> C, matching how the codegen lowers multi-arg lambda
    -- VALUES (`\a b ->` -> |a, b|) and multi-arg CALLS (`f a b` -> f(a, b)).
    -- Rendering it curried (fn(A) -> fn(B) -> C) was latent-broken: any
    -- multi-arg function-typed param/field mismatched its uncurried value.
    --
    -- A `(String -> msg)` / `(Bool -> msg)` callback — single concrete-arg
    -- function returning the polymorphic message var — is exactly the
    -- Std.Ui/Std.Html EVENT handler shape (`onInput`/`onChange`/`onCheck` →
    -- `Event::OnString`/`OnBool`). It MUST render `Arc<dyn Fn>`, not a bare `fn`
    -- pointer, so a CAPTURING closure (`onChange = \s -> toMsg (parse s
    -- default)` in a faithful Sky.Live app — exactly as Go allows) can be
    -- stored and passed through the whole chain (anon-cfg field →
    -- `std_ui_on_input(cb)` → `Event::OnString`). The construction sites Arc-wrap
    -- (`wrapStoredFn` for record fields/lambdas; the `Event::On*` ctor arms).
    -- This scope is deliberately narrow: arg is concrete `String`/`Bool`, result
    -- is a TVar — so it never matches `ShouldRetry e = RetryWhen (e -> Bool)`
    -- (result is concrete `Bool`) nor a HOF param `f : a -> b` (both TVars),
    -- both of which broke under a blanket `Arc<dyn Fn>` switch (derive Debug /
    -- PartialEq on the ADT, bare-fn-item HOF args).
    Can.TLambda arg (Can.TVar _)
        | isEventArgType arg ->
            "std::sync::Arc<dyn Fn(" ++ typeToRustString recordMap arg
                ++ ") -> " ++ typeToRustString recordMap (case t of Can.TLambda _ r -> r; _ -> t)
                ++ " + Send + Sync>"
    -- An EFFECTFUL function type — flattened result is a `Task` — renders as a
    -- shareable `Arc<dyn Fn(..) -> SkyTask<..> + Send + Sync>` rather than a bare
    -- `fn` pointer. This is the `Handler` shape (`Request -> Task Error Response`,
    -- exported by Sky.Http.Server) and any user re-declaration of it (the 36
    -- example's local `Middleware.Handler` alias, and the inline `h : Handler`
    -- param of a middleware-wrapping closure like `guarded h = …`). A real route
    -- handler CAPTURES app state (`handleRegister cfg db` closes over cfg/db), and
    -- a capturing closure cannot coerce to a bare `fn` pointer — so the slot must
    -- be `Arc<dyn Fn>` (Clone, Send, Sync — axum-safe) for it to register. This
    -- matches both `fieldTypeToRust` (which already Arc-wraps Task-returning record
    -- fields, e.g. WsServerCfg.onMessage) and `paramTypeToRust` (which renders
    -- Task-returning top-level HOF params as `impl Fn`); the construction sites
    -- Arc-wrap the assigned closure/fn value (see wrapStoredFn / the partial-app
    -- and lambda arms in ExprEmitter).
    --
    -- The Task-result gate is the SAME discriminator paramTypeToRust uses, so it
    -- can NEVER catch `ShouldRetry e = RetryWhen (e -> Bool)` (result is concrete
    -- `Bool`, not a Task) nor a pure HOF param `f : a -> b` (result TVar) — the
    -- two shapes a blanket Arc switch broke (ADT derive Debug/PartialEq; bare-fn
    -- HOF args). Effectful callbacks are exactly where capturing closures flow.
    Can.TLambda _ _
        | resultIsTaskTy (snd (flattenArrowType t)) ->
            let (ps, ret) = flattenArrowType t
            in "std::sync::Arc<dyn Fn(" ++ intercalate ", " (map (typeToRustString recordMap) ps)
               ++ ") -> " ++ typeToRustString recordMap ret ++ " + Send + Sync>"
    Can.TLambda _ _ ->
        let (ps, ret) = flattenArrowType t
        in "fn(" ++ intercalate ", " (map (typeToRustString recordMap) ps) ++ ") -> " ++ typeToRustString recordMap ret
    Can.TAlias modName name pairs _inner ->
        -- Sub-D step 4: carry the alias's type args so a parametric record alias
        -- (`RetryPolicy e`) renders as SkyCoreTaskRetryPolicy<e>, matching the
        -- generic struct emitted by aliasToRustTypeDef. Non-generic aliases
        -- (empty pairs) render bare as before.
        let modStr = ModuleName._name modName
            modPrefix = if null modStr then "" else map (\c -> if c == '.' then '_' else c) modStr ++ "_"
            base = toCamelCase (modPrefix ++ name)
            args = map snd pairs
        -- runtimeOpaque alias: if the registry value carries {M} the alias IS
        -- generic — preserve Sky args (e.g. StdHtmlHtml<Msg>). Non-{M} entries
        -- are non-generic (generics pinned in the registry value); drop args.
        in case Map.lookup (modStr, name) runtimeOpaqueTypes of
           Just rp | '{' `elem` rp ->
               if null args then base
               else base ++ "<" ++ intercalate ", " (map (typeToRustString recordMap) args) ++ ">"
           Just _ -> base  -- non-generic opaque; drop args
           Nothing ->
               if null args then base
               else base ++ "<" ++ intercalate ", " (map (typeToRustString recordMap) args) ++ ">"
    _ -> "String"
