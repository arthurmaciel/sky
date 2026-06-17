module Sky.Generate.Rust.Builder.ModuleEmitter
  ( buildModule
  , declsToRustItems
  , defToRustItem
  , returnTypeWithGenerics
  , inferCtorReturnType
  , isCanTypeCopy
  , tailExpr
  , needsTaskWrap
  , buildProgram
  ) where

import Data.List (isSuffixOf, isPrefixOf, isInfixOf, stripPrefix, sortBy, nub, intercalate)
import Data.Maybe (fromMaybe, isJust)
import Data.Char (toLower, toUpper, isUpper, isDigit, isLower)
import Numeric (showHex)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Sky.AST.Canonical as Can
import qualified Sky.Sky.ModuleName as ModuleName
import qualified Sky.Reporting.Annotation as Ann

import Sky.Generate.Rust.Builder.Types
    ( RustBuilder(..), RustModule(..), RustItem(..), RustTypeDef(..)
    , EmitCtx(..), UsedKernels(..), runtimeOpaqueTypes
    , kernelsNeedingErrorPin, kernelsZeroArg, topLevelErrorPin
    )
import Sky.Generate.Rust.Builder.Naming
    ( toCamelCase, toSnakeCase, moduleNameToRust, rustSafeIdent, kernelCtorToRust
    , anonStructName, rustFnName, disambiguateUserFnName
    )
import Sky.Generate.Rust.Builder.Kernel (kernelToRust, kernelSigPrefix, splitKernelName)
import Sky.Generate.Rust.Builder.Pattern
    ( bodyUsesList, patBindingVars, patternToRustParam, patternToRustArg
    )
import Sky.Generate.Rust.Builder.SigRegistry
    ( knownDefSig, sigTVars
    )
import Sky.Generate.Rust.Builder.ExprEmitter
    ( exprToRustString, collectVarLocalsMulti, taskExprInnerType, mainEntryTailReturnsTask, solveArgType
    , inferParamRustType, canDefBody, collectClosureDefs
    , collectLambdaCapturedVars, isClosureParamStr, isBackendEntryApp
    )
import Sky.Generate.Rust.Builder.TypeRenderer
    ( extractReturnType, extractParamTypes, hasTypeVars, typeToRustString
    , collectRenderedTVars
    )
import Sky.Generate.Rust.Builder.TypeEmitter
    ( unionsToRustTypes, aliasesToRustTypes, sortFieldsByIndex, paramTypeToRust
    , fieldTypeToRust
    )
import Sky.Generate.Rust.Builder.Walker
    ( analyzeKernelUsage, collectZeroArgDefs, collectAnonRecordTypes
    , collectFormTargets, collectLiveInitFns, collectLiveReqInitFns, collectLiveSerdeTypes, buildRecordMap
    , detectAppMsg, detectAppModel
    )

-- ============================================================
-- buildModule (lines 858-899 of Builder.hs)
-- ============================================================

buildModule :: EmitCtx -> Can.Module -> RustModule
buildModule ctx0 mod =
    let modPrefix = moduleNameToRust (Can._name mod)
        -- Seed sibling top-level fn defs so inferParamRustType can resolve a
        -- param flowing into a sibling call (17-skymon's exec/query wrappers).
        ctx = ctx0 { ecSiblingFns = collectSiblingFns (Can._decls mod)
                   , ecCurrentModule = ModuleName._name (Can._name mod) }
        items = declsToRustItems ctx modPrefix (Can._decls mod)
        -- Existing function names after prefixing (to avoid double-emit)
        prefixed = map (\(RustFunction n g p r b) -> rustFnName (ecNameRenames ctx) modPrefix n)
                    [ f | f@(RustFunction _ _ _ _ _) <- items ]
        existingNames = Set.fromList prefixed
        -- Synthesize record alias constructors
        synCtorItems = concat [synCtor aliasName vars fields | (aliasName, Can.Alias vars (Can.TRecord fields _)) <- Map.toList (Can._aliases mod)]
        -- Record aliases that map to a ZERO-FIELD runtime marker because the
        -- kernel destructures them at the call site (Std.Webview.AppCfg →
        -- WebviewAppCfg). A synthesized constructor would assign into a fieldless
        -- struct AND reference the erased `any`/Fn field types, so skip it. This
        -- is NOT every opaque cfg: WebSocketServerCfg → WsServerCfg maps to a real
        -- runtime struct WITH its fn-pointer fields, so that constructor stays.
        markerCfgAliases = Set.fromList [("Std.Webview", "AppCfg")]
        skipOpaqueCfgCtor aliasName =
            Set.member (ModuleName._name (Can._name mod), aliasName) markerCfgAliases
        synCtor aliasName vars0 fields
            | skipOpaqueCfgCtor aliasName = []
            | otherwise =
            let rm = ecRecordMap ctx
                ctorName = toSnakeCase (modPrefix ++ "_" ++ aliasName)
                structName = toCamelCase (modPrefix ++ "_" ++ aliasName)
                -- A runtimeOpaque alias renders non-generic (its generics are
                -- pinned in the registry value, e.g. WsServerCfg<SkyError>), so
                -- its constructor must not declare the Sky vars or return
                -- `Struct<vars>` (E0107 / unused param).
                vars = if Map.member (ModuleName._name (Can._name mod), aliasName) runtimeOpaqueTypes
                       then [] else vars0
                sortedFields = sortFieldsByIndex (Map.toList fields)
                -- A function-typed field is a STORED callback → Arc<dyn Fn..>
                -- (see fieldTypeToRust + the struct field renderer). The
                -- constructor's matching param must be Arc-typed too, so its
                -- body `Struct { onConnect: onConnect }` assigns Arc-param into
                -- the Arc-field without a mismatch (33-websocket-echo ctor).
                rustFlds = [(n, fieldTypeToRust rm ft) | (n, Can.FieldType _ ft) <- sortedFields]
                body = structName ++ " { " ++ intercalate ", " (map (\(n, _) -> n ++ ": " ++ n) sortedFields) ++ " }"
                -- Sub-D step 4: a parametric record alias's constructor must
                -- declare the type vars (its field params reference them, e.g.
                -- shouldRetry : ShouldRetry e) and return the generic struct.
                gens = if null vars then ""
                       else "<" ++ intercalate ", " (map (\v -> v ++ ": Clone + PartialEq + std::fmt::Debug + Send + 'static") vars) ++ ">"
                retTy = structName ++ (if null vars then "" else "<" ++ intercalate ", " vars ++ ">")
            in if Set.member ctorName existingNames then []
               else [RustFunction ctorName gens (map (\(n, t) -> n ++ ": " ++ t) rustFlds) retTy body]
        prefixItem (RustFunction n g p r b)
            -- Only the entry module's main is the unprefixed program entry
            -- (`sky_main`). A non-entry module's `main` (e.g. Std.Html.main,
            -- the `<main>` builder) module-prefixes like any other def so its
            -- call site `Html.main` → `std_html_main` resolves.
            | n == "sky_main" = RustFunction n g p r b
            | otherwise = RustFunction (rustFnName (ecNameRenames ctx) modPrefix n) g p r b
        prefixItem (RustStruct n f) = RustStruct (toCamelCase (modPrefix ++ "_" ++ n)) f
        prefixItem (RustEnum n v) = RustEnum (toCamelCase (modPrefix ++ "_" ++ n)) v
        prefixItem (RustTypeAlias n t) = RustTypeAlias (toCamelCase (modPrefix ++ "_" ++ n)) t
        prefixItem other = other
    in RustModule
        { modName = modPrefix
        , modItems = map prefixItem items ++ synCtorItems
        }

-- ============================================================
-- declsToRustItems (lines 905-909 of Builder.hs)
-- ============================================================

-- | Collect a module's top-level function definitions as bare-name ->
-- (params, body), for sibling-call param inference (ecSiblingFns). Both Def and
-- TypedDef arms; TypedDef's params are the pattern halves of its annotated pairs.
-- | Bare names of every top-level Def / TypedDef in a module's decls (used to
-- build the collision-rename map). DestructDef has no single name → skipped.
topLevelDefNames :: Can.Decls -> [String]
topLevelDefNames = go
  where
    go (Can.Declare def rest)         = nameOf def ++ go rest
    go (Can.DeclareRec def defs rest) = concatMap nameOf (def : defs) ++ go rest
    go Can.SaveTheEnvironment         = []
    nameOf (Can.Def (Ann.At _ n) _ _)          = [n]
    nameOf (Can.TypedDef (Ann.At _ n) _ _ _ _) = [n]
    nameOf _                                    = []

collectSiblingFns :: Can.Decls -> Map.Map String ([Can.Pattern], Can.Expr)
collectSiblingFns = go
  where
    go (Can.Declare def rest)        = ins def (go rest)
    go (Can.DeclareRec def defs rest) = foldr ins (go rest) (def : defs)
    go Can.SaveTheEnvironment        = Map.empty
    ins (Can.Def (Ann.At _ name) params body) m  = Map.insert name (params, body) m
    ins (Can.TypedDef (Ann.At _ name) _ pats body _) m = Map.insert name (map fst pats, body) m
    ins _ m = m

-- | Extract the generic param NAMES from a rendered Rust `<…>` decl string
-- (`<msg: Clone + …, a: Clone + …>` -> ["msg","a"]). The name is the leading
-- identifier of each comma-separated segment. The codegen's param bounds carry
-- no `>` or top-level `,` (just `Clone + PartialEq + … + 'static`), so the
-- simple split is exact here. Used to guard the ctor-turbofish to declared
-- generics only.
extractGenDeclNames :: String -> [String]
extractGenDeclNames s = case dropWhile (/= '<') s of
    ('<':rest) -> [ nm | seg <- splitOnComma (takeWhile (/= '>') rest)
                       , let nm = takeWhile isIdent (dropWhile (not . isIdent) seg)
                       , not (null nm) ]
    _ -> []
  where
    isIdent c = isUpper c || isLower c || isDigit c || c == '_'
    splitOnComma str = case break (== ',') str of
        (a, ',':b) -> a : splitOnComma b
        (a, _)     -> [a]

declsToRustItems :: EmitCtx -> String -> Can.Decls -> [RustItem]
declsToRustItems _ctx _mod Can.SaveTheEnvironment = []
declsToRustItems ctx modPrefix (Can.Declare def rest) = defToRustItem ctx modPrefix def : declsToRustItems ctx modPrefix rest
declsToRustItems ctx modPrefix (Can.DeclareRec def defs rest) = 
    map (defToRustItem ctx modPrefix) (def : defs) ++ declsToRustItems ctx modPrefix rest

-- ============================================================
-- defToRustItem (lines 1176-1344 of Builder.hs)
-- ============================================================

-- Resolve the DEFINED function's OWN signature: consult the home module's
-- per-module env (ecModuleEnv) first, then the flat ecSolvedTypes. This is the
-- mass-E0308 keystone (a dep module's binding is absent from the flat map).
-- Used ONLY for the defined function's param/return types — NOT for body
-- expression lookups, which must stay on the flat map so cross-module calls to
-- same-named functions resolve to the right module's binding.
lookupOwnSig :: EmitCtx -> String -> Maybe Can.Type
lookupOwnSig ctx name = case Map.lookup name (ecModuleEnv ctx) of
    Just t  -> Just t
    Nothing -> Map.lookup name (ecSolvedTypes ctx)

-- | Monomorphise a TEA function's polymorphic-in-msg RETURN to the app's
-- concrete Msg — but ONLY for the exact TEA return shapes, substituting ONLY the
-- msg position. Returns Nothing for everything else, so stdlib generics
-- (`Task.map : … -> Task e b`, `Cmd.map : … -> Cmd b`) are NOT corrupted (an
-- earlier blanket "replace every TVar" version turned `Task e b` into
-- `Task StateMsg StateMsg` → `expected StateMsg, found StateModel`).
--   * view:    `Html msg`            → `Html <AppMsg>`
--   * handler: `(Model, Cmd msg)` / `(Model, Sub msg)` → msg slot only
-- The Model slot is left untouched (typeToRustString resolves it as usual).
teaReturnSubst :: Can.Type -> Maybe Can.Type -> Can.Type -> Maybe Can.Type
teaReturnSubst msgT mModelT ret = case ret of
    Can.TType m "Html" [Can.TVar _] -> Just (Can.TType m "Html" [msgT])
    Can.TTuple a (Can.TType m c [Can.TVar _]) []
        | c `elem` ["Cmd", "Sub"] ->
            -- The Model slot `a` is often left a bare TVar by the solver; pin it
            -- to the app's concrete Model when we have it (else leave as-is).
            let a' = case (a, mModelT) of (Can.TVar _, Just mt) -> mt; _ -> a
            in Just (Can.TTuple a' (Can.TType m c [msgT]) [])
    _ -> Nothing

-- | Resolve a ROW-POLYMORPHIC (open) record param to its concrete struct by
-- field-NAME superset match. HM narrows a record-update handler's `model` param
-- to only the fields it touches AND can leave a spurious TVar in a field type
-- (`{ model | currentUser = Nothing }` infers `currentUser : Maybe a`), so the
-- concrete-only gate rejects it → it defaulted to `String` → `model.page` etc.
-- failed (E0609/E0308). typeToRustString already does this superset match, but
-- only after the gate lets the type through; this lets a field-TVar-carrying
-- open record through by matching on field NAMES alone and emitting the bare
-- (non-parametric) struct name — the struct's real field types are concrete.
resolveOpenRecordParam :: Map.Map String String -> Can.Type -> Maybe String
resolveOpenRecordParam recordMap t = case t of
    Can.TRecord fields _ -> matchStructByFields recordMap (Set.fromList (Map.keys fields))
    _ -> Nothing

-- | Find the struct with the FEWEST extra fields whose field set is a SUPERSET
-- of `fieldSet`. Shared by resolveOpenRecordParam (param is an open record) and
-- inferRecordParamFromUpdate (param is a bare TVar but record-updated in the
-- body). Skips Anon structs (generic — need the typeToRustString gens path).
matchStructByFields :: Map.Map String String -> Set.Set String -> Maybe String
matchStructByFields recordMap fieldSet
    | Set.null fieldSet = Nothing
    | otherwise =
        let best = foldr (\(k, nm) acc ->
                     let kSet   = Set.fromList (words (map (\c -> if c == ',' then ' ' else c) k))
                         extras = Set.size kSet - Set.size fieldSet
                     in if fieldSet `Set.isSubsetOf` kSet && extras >= 0
                        then case acc of
                               Nothing                  -> Just (extras, nm)
                               Just (e, _) | extras < e -> Just (extras, nm)
                               _                        -> acc
                        else acc) Nothing (Map.toList recordMap)
        in case best of
             Just (_, nm) | not ("Anon" `isPrefixOf` nm) -> Just nm
             _ -> Nothing

-- | Resolve a bare-TVar param to its struct by scanning the body for a record
-- update `{ param | f1 = …, f2 = … }` and superset-matching the struct from the
-- updated field names. Closes the `handleSignOut model = let _ = … in
-- ({ model | … }, Cmd.none)` case, where the solver leaves `model` a bare TVar
-- (no `model.field` access to constrain it to an open record), so
-- resolveOpenRecordParam (which needs a TRecord) misses.
inferRecordParamFromUpdate :: Map.Map String String -> String -> Can.Expr -> Maybe String
inferRecordParamFromUpdate recordMap pname = go
  where
    go (Ann.At _ e) = case e of
      Can.Update _ (Ann.At _ (Can.VarLocal v)) updates | v == pname ->
          matchStructByFields recordMap (Map.keysSet updates)
      Can.Update _ r updates -> fj (go r) (firstJustL [ go x | (_, Can.FieldUpdate _ x) <- Map.toList updates ])
      Can.Call fn args        -> firstJustL (map go (fn : args))
      Can.Lambda _ b          -> go b
      Can.Let d b             -> fj (go (canDefBody d)) (go b)
      Can.LetRec ds b         -> fj (firstJustL (map (go . canDefBody) ds)) (go b)
      Can.LetDestruct _ x b   -> fj (go x) (go b)
      Can.Case s bs           -> fj (go s) (firstJustL [ go b | Can.CaseBranch _ b <- bs ])
      Can.If brs el           -> firstJustL ([ fj (go c) (go t) | (c, t) <- brs ] ++ [go el])
      Can.Binop _ _ _ _ a b   -> fj (go a) (go b)
      Can.Access r _          -> go r
      Can.Record fs           -> firstJustL [ go x | (_, x) <- Map.toList fs ]
      Can.List es             -> firstJustL (map go es)
      Can.Tuple a b rest      -> firstJustL (map go (a : b : rest))
      Can.Negate x            -> go x
      _                       -> Nothing
    fj (Just x) _ = Just x
    fj Nothing  y = y
    firstJustL = foldr fj Nothing

-- | Memoise a top-level NULLARY value binding whose body executes a Task.
--
-- A Sky top-level binding like @dbConn = Task.run (Db.connect ())@ or
-- @initSchema = let _ = Db.execRaw … in ()@ lowers as a per-reference function,
-- so every call re-runs the effect. On a Sky.Live cookie-less request that meant
-- a @CREATE TABLE IF NOT EXISTS@ executed per request — the ex27 throughput
-- regression (Rust paid a 6.6x init penalty vs Go's 1.2x; the per-statement sqlx
-- DDL cost dominated because Rust's baseline request is ~4x cheaper than Go's).
--
-- Fix: run the body ONCE behind a function-local 'OnceLock' and return a clone on
-- later calls. This is a deliberate Rust-only divergence from Go (which re-runs
-- per reference) — sound for the idempotent connect / schema-init CAFs it targets,
-- and the conventional run-once CAF semantics of an Elm/Haskell-family language.
--
-- Gated tightly so it cannot regress unrelated code: it fires ONLY for a nullary,
-- monomorphic, Task-executing binding whose return type is a concrete owned value
-- (no @SkyTask@ future — not 'Clone'; no @fn@/@dyn@/@impl@/reference types). Every
-- pure constant stays byte-identical, and no non-@Send + Sync@ type reaches the
-- @static OnceLock@. The post-@task_run@ return types this targets (@Db@, @()@,
-- @String@, records) are all @Send + Sync + Clone@.
maybeMemoiseNullary
    :: Int     -- ^ arity (param count)
    -> String  -- ^ source name
    -> String  -- ^ rust name
    -> String  -- ^ rendered generics decl ("" when monomorphic)
    -> String  -- ^ rendered return type
    -> String  -- ^ rendered body
    -> String
maybeMemoiseNullary nParams name rustName gens retTy body
    | nParams == 0
    , null gens
    , rustName /= "sky_main", name /= "main"
    , not ("SkyTask<" `isPrefixOf` retTy)
    , not (any (`isInfixOf` retTy) ["fn(", "dyn ", "impl ", "&", "'"])
    , "task_run" `isInfixOf` body
    = let cell = "static __SKY_MEMO: ::std::sync::OnceLock<" ++ retTy
                 ++ "> = ::std::sync::OnceLock::new(); "
          got  = "__SKY_MEMO.get_or_init(|| { " ++ body ++ " })"
      in if retTy == "()"
         then "{ " ++ cell ++ "let _ = " ++ got ++ "; }"
         else "{ " ++ cell ++ got ++ ".clone() }"
    | otherwise = body

-- Peel @n@ leading arrows off a function type, returning the @n@ argument types
-- and the residual result. Used to uncurry a lambda-bodied def (the absorbed
-- lambda params take their types from the peeled arrows).
peelArrows :: Int -> Can.Type -> ([Can.Type], Can.Type)
peelArrows 0 ty = ([], ty)
peelArrows n (Can.TLambda src res) = let (ss, r) = peelArrows (n - 1) res in (src : ss, r)
peelArrows _ ty = ([], ty)

defToRustItem :: EmitCtx -> String -> Can.Def -> RustItem
defToRustItem ctx modPrefix (Can.Def (Ann.At _ name) params body) =
    let rustName = if name == "main" && ecCurrentModule ctx == "Main" then "sky_main" else name
        n = length params
        (paramStrs, genVars) =
            -- Try solvedTypes FIRST (HM-inferred types, most accurate).
            -- Falls through to knownDefSig (stdlib overrides) then body analysis.
            let solvedParamTys = case lookupOwnSig ctx name of
                    Just ty -> extractParamTypes ty
                    Nothing -> []
            -- Use solved types when every param is renderable: either fully
            -- concrete (no TVars), OR a row-polymorphic open record that
            -- resolves to a concrete struct by field name (TEA handler `model`
            -- params). Genuinely polymorphic functions still fall through to
            -- knownDefSig for proper generic bounds like `T0: Clone`.
            in let rmG = ecRecordMap ctx
                   monoTy t = if hasTypeVars t
                              then resolveOpenRecordParam rmG t
                              else Just (paramTypeToRust rmG t)
                   monoTys = map monoTy solvedParamTys
               in if length solvedParamTys == length params && all isJust monoTys
               then let pStrs = zipWith3
                            (\i p mt -> fst (patternToRustArg i p) ++ ": " ++ fromMaybe "String" mt)
                            [0..] params monoTys
                    in (pStrs, "")
               else case knownDefSig modPrefix name n of
                   Just (paramTypes, retType) ->
                        let argTriples = zipWith3
                                (\i p t -> let (nm, pre) = patternToRustArg i p
                                           in (nm ++ ": " ++ t, pre))
                                [0..] params paramTypes
                            safeParams = map fst argTriples
                            tvars = sigTVars paramTypes retType
                            extraBound tv = if name == "member" && tv == "T0" then " + PartialEq" else ""
                            genList = map (\tv -> tv ++ ": Clone" ++ extraBound tv) tvars
                            gens = if null genList then "" else "<" ++ intercalate ", " genList ++ ">"
                       in (safeParams, gens)
                   Nothing ->
                       -- Fallback: body analysis, with body-driven param
                       -- monomorphisation. A param that is polymorphic in the
                       -- solved sig (TVar) but flows into a monomorphic kernel
                       -- (Db.exec's args -> Vec<String>, Dict.get's row ->
                       -- HashMap) recovers that concrete type via
                       -- inferParamRustType. Inferred params drop out of the
                       -- generic list (their T_i is no longer used → would be
                       -- E0392). Non-inferred params keep the legacy String /
                       -- Vec<T_i> default, byte-identical to before.
                       let counts = collectVarLocalsMulti body
                           paramNames = [ n | Ann.At _ (Can.PVar n) <- params ]
                           anyCloneNeeded = any (\n -> Map.lookup n counts >= Just 2) paramNames
                               || bodyUsesList body
                           useVec = bodyUsesList body
                           pnOf p = case p of Ann.At _ (Can.PVar v) -> v; _ -> ""
                           -- (rendered "name: type", was-inferred?)
                           solvedAt i = if i < length solvedParamTys then Just (solvedParamTys !! i) else Nothing
                           isWild p = case p of Ann.At _ Can.PAnything -> True; _ -> False
                           -- (rendered "name: type", was-inferred?, Maybe generic-decl)
                           renderP i p =
                               let tn = "T" ++ show i
                                   (nm, _pre) = patternToRustArg i p
                                   pn = pnOf p
                                   -- open-record (TEA model) param → concrete struct
                                   openRec = solvedAt i >>= resolveOpenRecordParam (ecRecordMap ctx)
                                   -- bare-TVar param record-updated in the body
                                   -- (`{ param | … }`) → struct from update fields
                                   recUpd = if null pn then Nothing
                                            else inferRecordParamFromUpdate (ecRecordMap ctx) pn body
                                   inferred = if null pn then Nothing
                                              else inferParamRustType ctx pn body
                               in case (openRec, recUpd, inferred) of
                                    (Just s, _, _) -> (nm ++ ": " ++ s, True, Nothing)
                                    (_, Just s, _) -> (nm ++ ": " ++ s, True, Nothing)
                                    (_, _, Just t) -> (nm ++ ": " ++ t, True, Nothing)
                                    -- An IGNORED wildcard (`_`) param with no
                                    -- inferable type renders GENERIC, so a call
                                    -- passing any type (e.g. `()` for a `() -> X`
                                    -- thunk like `getConn _ = dbConn`) type-checks
                                    -- — the String default mismatched a unit call
                                    -- (16-skychess). Safe: the value is discarded.
                                    _ | isWild p -> (nm ++ ": " ++ tn, True, Just (tn ++ ": Clone"))
                                    _ -> (nm ++ ": " ++ (if useVec then "Vec<" ++ tn ++ ">" else "String"), False, Nothing)
                           rendered = zipWith renderP [0..] params
                           pStrs = [ s | (s, _, _) <- rendered ]
                           inferredIdx = [ i | (i, (_, True, _)) <- zip [0..] rendered ]
                           wildGens = [ g | (_, _, Just g) <- rendered ]
                           genList = (if anyCloneNeeded
                                      then [ "T" ++ show i ++ ": Clone"
                                           | i <- [0..length params - 1], i `notElem` inferredIdx ]
                                      else []) ++ wildGens
                           gs = if null genList then "" else "<" ++ intercalate ", " genList ++ ">"
                       in (pStrs, gs)
        -- P4-T3 / #24 tenet 4: force param 0 of a `Live.app` init.
        --   * READS the request (`init req = … req.path …`, ∈ ecLiveReqInitFns)
        --     → `sky_runtime::LiveReq` (the field access needs a concrete record;
        --     live_app passes it straight through).
        --   * otherwise (`init _`, an IGNORED slot — `{}` / `a` / `()` all mean
        --     the same) → `()`. The natural render is unreliable here (an empty
        --     `{}` annotation resolves to the MODEL struct; a free `a` renders
        --     generic), so force `()` and adapt at the call site: `Tui.app` passes
        --     it directly (`Fn(())`); `Live.app` wraps `move |_r| init(())`.
        -- Param NAME comes from patternToRustArg so `init req` -> `req: ...`.
        paramStrs' = case (params, paramStrs) of
            ((p0 : _), (_ : rest))
                | Set.member name (ecLiveReqInitFns ctx) ->
                    (fst (patternToRustArg 0 p0) ++ ": sky_runtime::LiveReq") : rest
                | Set.member name (ecLiveInitFns ctx) ->
                    (fst (patternToRustArg 0 p0) ++ ": ()") : rest
            _ -> paramStrs
        -- Whether this is the program's entry `main` (used by `entryMainNeedsLift`
        -- below to reconcile a unit-tailed `main` against its forced `SkyTask<()>`
        -- signature). The signature itself is left to the normal inference + the
        -- `retTyFinal` rule — keying the RETURN on `usesTaskRun` is unsound (14's
        -- `main` calls `Task.run` inline yet its TAIL is still a Task, so it must
        -- keep `SkyTask<()>`; only the body TAIL's task-ness is a sound signal).
        isEntryMain = name == "main" && ecCurrentModule ctx == "Main"
        retTy = case lookupOwnSig ctx name of
                    Just ty ->
                        let ret = extractReturnType ty
                        in if not (hasTypeVars ret)
                           then typeToRustString (ecRecordMap ctx) ret
                            else case knownDefSig modPrefix name n of
                                Just (_, knownRetType) -> knownRetType
                                Nothing ->
                                    -- Return type has TVars: try constructor-shape inference (Q1a)
                                    let ctorTy = inferCtorReturnType (ecRecordMap ctx) (ecSolvedTypes ctx) body
                                    in if null ctorTy
                                       then -- Fallback: body inference for Task returns
                                            let bodyInner = taskExprInnerType (ecSolvedTypes ctx) body
                                            in if null bodyInner
                                               then case knownDefSig modPrefix name n of
                                                   Just (_, knownRetType2) -> knownRetType2
                                                   Nothing -> "()"
                                               else "SkyTask<" ++ bodyInner ++ ">"
                                       else ctorTy
                    Nothing ->
                         -- No solved type available — use knownDefSig, body inference,
                         -- or (for main) the hardcoded Task/unit convention.
                         let bodyInner = taskExprInnerType (ecSolvedTypes ctx) body
                         in if null bodyInner
                            then case knownDefSig modPrefix name n of
                                Just (_, knownRetType) -> knownRetType
                                -- `name == "main"` alone is not enough: only the
                                -- entry module's `main` is the program entry. A
                                -- stdlib `<main>` element helper (`Std.Html.main`)
                                -- also lands here and must keep its real return
                                -- type, not the entry-point unit convention.
                                Nothing -> if name == "main" && ecCurrentModule ctx == "Main"
                                           then if ecUsesTaskRun ctx then "()" else "SkyTask<()>"
                                           else "()"
                            else "SkyTask<" ++ bodyInner ++ ">"
        -- Track multi-use variables in the function body so they get
        -- cloned at each function-call argument site (ownership safety).
        multiBody = collectVarLocalsMulti body
        multiVars = [ v | (v, c) <- Map.toList multiBody, c >= 2 ]
        -- Step 4: skip .clone() for params whose type is Rust Copy (i64, f64, bool, ...)
        paramNames = [ n | Ann.At _ (Can.PVar n) <- params ]
        paramTys = case lookupOwnSig ctx name of
            Just ty -> extractParamTypes ty
            Nothing -> []
        copyVars = Set.fromList
            [ n | (n, t) <- zip paramNames paramTys
            , not (hasTypeVars t) && isCanTypeCopy t ]
        -- A Sky.Live init's param 0 is ALWAYS forced to a concrete type (#24
        -- tenet 4: LiveReq for a req-reader, else `()`), so the param's original
        -- type var (`init : a -> …`) is orphaned — drop the generics (an unused
        -- type param is uninferrable at the call site — E0283).
        genVars' = if Set.member name (ecLiveInitFns ctx) then "" else genVars
        -- TEA msg-monomorphisation (Live.app boundary). A handler/view whose
        -- return is polymorphic in msg (`(Model, Cmd msg)` via `Cmd.none`,
        -- `Html msg`) collapses to a `()` return — then the real body mismatches
        -- at every call site (the Sky.Live cascade). Substitute the app's
        -- CONCRETE Msg (detected from `update`/`view`) for the free TVars and
        -- render concretely. Only fires when return-inference already gave `()`
        -- AND the solved return carries TVars AND this is a Live app (ecAppMsg
        -- = Just), so non-Live programs and concrete-return fns are untouched.
        -- The Sky.Live entry `main = Live.app {…}` lowers its body to a
        -- `live_app`/`live_app_routed` call, which returns `SkyTask<E, ()>`
        -- (a `Box::pin(async move { serve_live(…).await })` future). Return
        -- inference otherwise lands this on `()` (Live.app's solved type is
        -- unit-shaped), so sky_main would emit the call as a discarded
        -- statement and the future would be dropped — the binary exits before
        -- axum binds a port. Force the Task return so the printer returns the
        -- future as the tail expression and `block_on(sky_main())` awaits it.
        -- #24 tenet 3: ANY backend-entry main (Live.app / Tui.app / Tui.program /
        -- Webview.app) yields a `SkyTask<()>` driver future the entry block_on's,
        -- so force the Task return regardless of which backend (was Live-only).
        isBackendEntryMain = name == "main" && ecCurrentModule ctx == "Main"
                          && ecUsesBackendApp ctx
        retTyFinal
            | isBackendEntryMain = "SkyTask<()>"
            | otherwise = case (retTy == "()", ecAppMsg ctx, extractReturnType <$> lookupOwnSig ctx name) of
                (True, Just msgT, Just ret)
                    | Just sub <- teaReturnSubst msgT (ecAppModel ctx) ret -> typeToRustString (ecRecordMap ctx) sub
                _ -> retTy
        ctx' = ctx { ecCloneVars = Set.fromList multiVars
                   , ecCopyVars = copyVars
                   , ecInGenericFn = not (null genVars')  -- Sub-A.13
                   , ecClosureDefs = collectClosureDefs body
                   , ecReturnElem = taskElemOf retTyFinal
                   , ecEnclosingRet = extractReturnType <$> lookupOwnSig ctx name
                   -- The DECL names from the rendered `<…>` (genVars' may rename
                   -- to T0/T1 via knownDefSig); the ctor turbofish guards on
                   -- these exact names so `::<msg>` is only emitted when `msg` is
                   -- actually declared. Mismatched names just skip the turbofish.
                   , ecGenParams = extractGenDeclNames genVars' }
        bodyStr = exprToRustString ctx' body
        -- Collect destructure preludes for non-trivial pattern args. The
        -- prelude is `let <Pattern> = __pN else { unreachable!() };` per
        -- patternToRustArg. Empty for PVar/PAnything/PTuple params.
        preludes = concat [ snd (patternToRustArg i p) | (i, p) <- zip [0..] params ]
        -- S6: When the function returns SkyTask<T> but the body tail is a
        -- bare value (not already a Task expression), wrap in task_succeed({...}).
        -- Walk through let chains to find the tail expression, then check
        -- whether the tail is already a Task expression. Keyed on `retTy` (NOT
        -- `retTyFinal`): a backend-entry `main` (Live/Tui/Webview) has
        -- `retTyFinal` FORCED to `SkyTask<()>` but its body tail IS already a Task
        -- (`live_app_routed(…)`) that `needsTaskWrap` doesn't recognise — keying
        -- on `retTyFinal` would double-wrap it (`task_succeed(SkyTask<()>)`,
        -- E0308). `retTy` (pre-force) already carries `SkyTask<()>` for the unit-
        -- tail server `main` (`main = let _ = Task.run run in ()`), so the
        -- composite-server unit-tail lift still fires off `retTy`.
        bodyStr0 = if "SkyTask<" `isPrefixOf` retTy && needsTaskWrap (ecSolvedTypes ctx) body
                   then "task_succeed({ " ++ bodyStr ++ " })"
                   else bodyStr
        -- Entry-`main` unit-tail lift. A server / Task.run-inline `main` (`main =
        -- let _ = Task.run run in ()`) has a `()` TAIL but its emitted signature
        -- stays `SkyTask<()>` (the entry block_on's it — see `entryPointSection`'s
        -- `mainIsTask`). The normal `bodyWrapped` keys on `retTy`, which here can
        -- be `()` (when `usesTaskRun` is set) — so it skips the lift and the body
        -- returns `()` against a `SkyTask<()>` signature (E0308 — composite-
        -- server). Lift the unit tail to `task_succeed(())` whenever the FINAL
        -- signature is a Task BUT the body tail is a genuine non-Task value AND
        -- this is NOT a backend-entry app (those already return their driver Task
        -- as the tail — wrapping would double-box). The inline `task_run` already
        -- fired the real effect; the outer succeed is a no-op.
        entryMainNeedsLift = isEntryMain
                          && "SkyTask<" `isPrefixOf` retTyFinal
                          && not (isBackendEntryApp body)
                          && needsTaskWrap (ecSolvedTypes ctx) body
        bodyWrapped = if entryMainNeedsLift && not ("task_succeed" `isPrefixOf` bodyStr0)
                      then "task_succeed({ " ++ bodyStr ++ " })"
                      else bodyStr0
        -- Non-Clone capture fix (#52): an `impl Fn(..)` HOF parameter is NOT
        -- `Clone`, so when it's captured into a closure the per-closure
        -- `.clone()` capture-prelude (needed so SIBLING closures each own a
        -- copy) fails E0599. Arc-wrap the param at function entry: `Arc<F>` IS
        -- `Clone` (cheap ref-count bump), so the existing prelude's `.clone()`
        -- becomes a sound `Arc::clone`, and a call site `p.clone()(args)` still
        -- dispatches through `Arc`'s `Deref` to the inner `Fn`. Only fires for
        -- params that (a) render as `impl Fn` AND (b) are actually captured by a
        -- closure in the body — a non-captured fn param is left byte-identical.
        arcFnParamPrelude = arcFnParamPreludeFor ctx body paramStrs' params
     in RustFunction rustName genVars' paramStrs' retTyFinal
            (maybeMemoiseNullary n name rustName genVars' retTyFinal (arcFnParamPrelude ++ preludes ++ bodyWrapped))
-- Uncurry a lambda-bodied def: `f a = \b -> e` is eta-equivalent to `f a b = e`,
-- but the codegen would otherwise render the first as a 1-arg fn RETURNING a
-- `fn`-pointer closure — which can't hold a capturing closure. Absorb the body
-- lambda's params into the signature (their types come from peeling the return
-- type's arrows), so it lowers as a flat N-arg fn. Partial application of the
-- flattened fn is already closure-wrapped by the call-site emitter, so every use
-- shape keeps working. Only fires when the return type actually has the arrows.
defToRustItem ctx _modPrefix (Can.TypedDef nameAt fvs pats0 body retTy0)
    | Ann.At _ (Can.Lambda lamPats lamBody) <- body
    , not (null lamPats)
    , (argTys, residual) <- peelArrows (length lamPats) retTy0
    , length argTys == length lamPats =
        defToRustItem ctx _modPrefix
            (Can.TypedDef nameAt fvs (pats0 ++ zip lamPats argTys) lamBody residual)
defToRustItem ctx _modPrefix (Can.TypedDef (Ann.At _ name) _ pats0 body retTy0) =
    let rm = ecRecordMap ctx
        rustName = if name == "main" && ecCurrentModule ctx == "Main" then "sky_main" else name
        -- Std.Ui `any`-carrier resolution. Several Std.Ui helpers are declared
        -- `-> any` / `any ->` where `any` is a wildcard the Go backend renders
        -- as interface{}. In Rust the slot carries one concrete type — `Html
        -- msg` (layout / layoutWith / render* / html) or `Attribute msg`
        -- (kernelAttr / collectHtmlAttrs / toAttrAttribute / ariaForDescription)
        -- — so resolve `any` to that carrier. Otherwise the fn is generic over
        -- an unbound `any` whose body returns a concrete carrier (E0308), and
        -- `msg` flows into the generic list automatically (collectRenderedTVars
        -- recurses into the carrier's args). Mirrors the ctor-field carrier
        -- table in TypeEmitter.hs (anyCarrierField).
        -- Fallback for a user-written `-> any` (e.g. `view : Model -> any` in a
        -- Sky.Live app): when the body's tail is a Call to an Html-returning
        -- Std.Ui entry (layout / render* — i.e. stdUiAnyCarrier resolves the
        -- CALLEE to Html) and the app's Msg type is known, the function returns
        -- `Html appMsg`. Closes the E0308 where `view<any>` returns Html<Msg>.
        bodyAnyCarrier = case tailExpr body of
            Ann.At _ (Can.Call (Ann.At _ (Can.VarTopLevel m n)) _)
                | Just (Can.TType _ "Html" _) <- stdUiAnyCarrier (moduleNameToRust m) n
                , Just msgTy <- ecAppMsg ctx
                -> Just (Can.TType (ModuleName.Canonical "Std.Html") "Html" [msgTy])
            -- Direct `Std.Html` constructor in the tail (`view _ = Html.node …`):
            -- the callee produces `Html msg` itself (no Std.Ui entry wrapping it),
            -- so a `-> any` view returning it would compile to a generic `<any>`
            -- whose body is a concrete `Html<_>` (E0308). Pin `any` → `Html<msg>`
            -- from the app's known Msg. Covers the Sky.Webview/Live raw-Html view
            -- shape (example 29). Module-gated to Std.Html so no blast radius.
            Ann.At region (Can.Call (Ann.At _ (Can.VarTopLevel m n)) _)
                | ModuleName._name m == "Std.Html"
                , Just msgTy <- ecAppMsg ctx
                , htmlResultRegion region n
                -> Just (Can.TType (ModuleName.Canonical "Std.Html") "Html" [msgTy])
            _ -> Nothing
        -- The solver pins the body's region to its concrete type. Confirm it's
        -- actually `Html …` before substituting (a non-Html `Std.Html` helper —
        -- e.g. `toString : Html msg -> String` — must not be coerced to Html).
        htmlResultRegion region n = case Map.lookup region (ecRegionTypes ctx) of
            Just (Can.TType _ "Html" _) -> True
            -- The solver leaves the call's region a bare TVar when only the
            -- `Html msg`'s `msg` slot is unresolved (the `c` in `Html c`); that
            -- is exactly the view-returns-Html shape we want to pin. A concrete
            -- NON-Html type (e.g. `String` from `Html.toString`) rejects.
            Just (Can.TVar _)           -> n `notElem` htmlStringHelpers
            Just _                      -> False
            -- Region not recorded (cross-module / alias): fall back to the callee
            -- name — every node-producing Std.Html ctor returns `Html msg`; the
            -- String-shaped helpers are the only exclusions.
            Nothing                     -> n `notElem` htmlStringHelpers
        htmlStringHelpers = ["toString", "toStringIndent"]
        applyAny ty = case stdUiAnyCarrier _modPrefix name of
                          Just c  -> substTVarAny c ty
                          Nothing -> case bodyAnyCarrier of
                                         Just c  -> substTVarAny c ty
                                         Nothing -> ty
        pats  = map (\(p, t) -> (p, applyAny t)) pats0
        retTy = applyAny retTy0
        argTriples = zipWith
            (\i (pat, ty) -> let (nm, pre) = patternToRustArg i pat
                             in (nm ++ ": " ++ paramTypeToRust rm ty, pre))
            [0..] pats
        params0 = map fst argTriples
        -- P4-T3 / #24 tenet 4 (annotated TypedDef path; same rule as the Def
        -- path above): force param 0 of a `Live.app` init to `sky_runtime::LiveReq`
        -- when it reads the request (∈ ecLiveReqInitFns), else to `()` (ignored
        -- slot — declared `()` / `{}` / free var all collapse here). The Live.app
        -- call site wraps the `()` form via `move |_r| init(())`.
        params = case (pats, params0) of
            (((p0, _) : _), (_ : rest))
                | Set.member name (ecLiveReqInitFns ctx) ->
                    (fst (patternToRustArg 0 p0) ++ ": sky_runtime::LiveReq") : rest
                | Set.member name (ecLiveInitFns ctx) ->
                    (fst (patternToRustArg 0 p0) ++ ": ()") : rest
            _ -> params0
        preludes = concatMap snd argTriples
        -- `main : Task Error ()` lowers to `sky_main() -> SkyTask<()>` so the
        -- entry can `block_on` it. Only when the program calls `Task.run` itself
        -- (main returns ()) does sky_main return unit. Hardcoding "()" here
        -- dropped the task — composed (`andThen`) mains never ran.
        -- #56 / #24 tenet 3: a backend-entry program (Live.app / Tui.app /
        -- Tui.program / Webview.app) keeps the SkyTask<()> return even when it
        -- ALSO uses Task.run — its driver future is the real entry and must be
        -- block_on'd (mirrors `mainIsTask` in Emitter.hs). Only a program that
        -- uses Task.run AND has no backend app collapses main to () (it runs the
        -- task inline). Without this the app future is discarded and never binds.
        ret = if name == "main" && ecCurrentModule ctx == "Main"
              then if ecUsesTaskRun ctx && not (ecUsesBackendApp ctx)
                   then "()"
                   else typeToRustString rm retTy
              else typeToRustString rm retTy
        -- Collect type variable names from annotation types, emit as generic params.
        -- A Sky.Live init fn's first param is pinned to LiveReq (above), so any
        -- type var that appeared only in its annotation (e.g. `a` in
        -- `init : a -> …`) is orphaned — exclude the first param's types or the
        -- live_app call site can't infer the unused generic (E0283).
        annotPatTys = if Set.member name (ecLiveInitFns ctx) then map snd (drop 1 pats) else map snd pats
        allAnnotTys = annotPatTys ++ [retTy | not (name == "main" && ecCurrentModule ctx == "Main")]
        -- collectRenderedTVars (not collectTVars): a var that appears only inside
        -- a runtimeOpaque type's dropped args (e.g. `msg` in WebSocketServerCfg
        -- msg) must NOT become a function generic — it'd be unused in the Rust
        -- sig (E0107 on the return type / E0283 at call sites).
        tvarNames = nub [ v | t <- allAnnotTys, v <- collectRenderedTVars t ]
        -- `+ Sync`: generic values flow across the multi-threaded tokio TEA
        -- boundary (Cmd.perform goroutines, SSE driver tasks). Sky values are
        -- immutable, so Sync is sound; it's also required for the Std.Live
        -- Event::OnRaw type-erased payload (Arc<dyn Any + Send + Sync>).
        -- #52 Part B: a wildcard `any` generic that flows into a `Db.get*`
        -- accessor (e.g. a pub/sub decoder `decode : any -> _` reading fields
        -- with `Db.getString`) gains the `SkyRow` bound, so the generic body
        -- type-checks and monomorphises per call site (the payload's real
        -- `Dict String String`). `db_get_*` is generic over `SkyRow` in the
        -- runtime; the bound is added ONLY to the `any` var and ONLY when the
        -- body actually calls a `db_get_*` (no blast radius on other generics).
        -- `SkyRow` is in scope via the generated module's `pub use sky_runtime::*`.
        bodyHasDbGet = "db_get_" `isInfixOf` tdBody
        genBound v = v ++ ": Clone + PartialEq + std::fmt::Debug + Send + Sync + 'static"
                       ++ (if v == "any" && bodyHasDbGet then " + SkyRow" else "")
        genDecl = if null tvarNames then ""
                  else "<" ++ intercalate ", " (map genBound tvarNames) ++ ">"
        multiBody = collectVarLocalsMulti body
        multiVars = [ v | (v, c) <- Map.toList multiBody, c >= 2 ]
        -- Seed the body's solved-type env with this function's OWN parameter
        -- types. `solveArgType` resolves a bare `VarLocal` by env lookup; a
        -- function parameter is local (never in the flat `_stEnv`), so without
        -- this it defaulted to "String" — making a polymorphic `++` over two
        -- `List (Attribute msg)` params (`extraAttrs ++ attrs` in Std.Ui's
        -- renderNodeAs) mis-emit `format!` (string concat) instead of a Vec
        -- extend (E0277/E0308). The annotation already gives us each param's
        -- concrete type; only simple `PVar` binders are mapped (compound
        -- patterns don't name a single value to type-direct on).
        paramTypeEnv = Map.fromList
            [ (pn, ty) | (Ann.At _ (Can.PVar pn), ty) <- pats ]
        ctx' = ctx { ecCloneVars = Set.fromList multiVars, ecCopyVars = ecCopyVars ctx
                   , ecInGenericFn = not (null tvarNames)  -- Sub-A.13
                   , ecClosureDefs = collectClosureDefs body
                   , ecReturnElem = taskElemOf ret
                   , ecEnclosingRet = Just retTy
                   , ecSolvedTypes = Map.union paramTypeEnv (ecSolvedTypes ctx)
                   , ecGenParams = tvarNames }
        -- NARROW task-wrap: an annotated `() -> Task Error X` whose body resolves
        -- to a kernel that is STRING-shaped in the Rust runtime but Task-shaped in
        -- Go. Per Sky.Core.Pure's note, `uuidV4Kernel : Task = Ffi.kernel "Uuid_v4"`
        -- (Go's Uuid_v4 is a Task closure; Rust's uuid_v4 is pure String —
        -- Uuid.v4 : String), so the pure body needs a task_succeed wrap. Restricted
        -- to those two kernels ONLY — the general needsTaskWrap mis-classifies
        -- genuinely-Task kernel calls (System.args, Db.*) as pure here, so it
        -- can't be reused on the broad annotated-fn surface. 35-composite-generics.
        tdBody = exprToRustString ctx' body
        isRustPureGoTaskKernel = case tailExpr body of
            Ann.At _ (Can.VarTopLevel m kn)
                | Just (kMod, kFn) <- Map.lookup (ModuleName._name m, kn) (ecKernelAliases ctx)
                  -> kernelToRust kMod kFn `elem` ["uuid_v4", "uuid_v7"]
            _ -> False
        -- Std.Ui.onSubmit's `a -> Attribute b` body (a constant-`a` closure into
        -- a `b` form slot) is not expressible in Rust's static types — but every
        -- applied call site is peepholed to an inline form-decode, so the body is
        -- dead. Emit `unreachable!()`; the signature stays for any value-use.
        tdWrapped
            | ecCurrentModule ctx == "Std.Ui" && name == "onSubmit" = "unreachable!()"
            | "SkyTask<" `isPrefixOf` ret && isRustPureGoTaskKernel
                    = "task_succeed({ " ++ tdBody ++ " })"
            | otherwise = tdBody
        -- Non-Clone capture fix (#52): Arc-wrap a captured `impl Fn(..)` HOF
        -- parameter so its per-closure `.clone()` capture-prelude becomes a
        -- sound `Arc::clone`. See the matching note in the Can.Def arm above.
        arcFnParamPrelude = arcFnParamPreludeFor ctx body params (map fst pats)
    in RustFunction rustName genDecl params ret
           (maybeMemoiseNullary (length params) name rustName genDecl ret (arcFnParamPrelude ++ preludes ++ tdWrapped))
defToRustItem ctx modPrefix (Can.DestructDef pat expr) =
    let vars = intercalate "_" (patBindingVars pat)
        fnName = if null vars then "__destruct" else "__destruct_" ++ vars
    in RustFunction fnName "" [patternToRustParam pat] "()" (exprToRustString ctx expr)

-- | Non-Clone capture fix (#52): emit `let p = Arc::new(p);` shadowing
-- preludes for every NON-`Clone` `impl Fn(..)` HOF parameter that is captured
-- into a closure in the function body. `Arc<F>` IS `Clone` (a ref-count bump),
-- so the per-closure capture-prelude's `.clone()` becomes a sound `Arc::clone`,
-- and a call site `p.clone()(args)` still dispatches through `Arc`'s `Deref` to
-- the inner `Fn`. Three gates keep it surgical:
--   * `isClosureParamStr pStr` — the param renders as `impl Fn(..)`.
--   * NOT `+ Clone` in the rendered type — a `Clone`-able fn param (the
--     stdlib recursion helpers `list_map`/`list_foldl` take `impl Fn + Clone`)
--     already clones AND is often passed POSITIONALLY to a sibling that wants a
--     bare `Fn` (an `Arc<Fn>` there would be E0277). Only a genuinely non-Clone
--     fn param (a user HOF like `withTempDir`'s `action`) needs the wrap, and
--     such params are CALLED, not passed positionally.
--   * captured BY A CLOSURE in the body (via `collectLambdaCapturedVars`) — a
--     param that's only STORED into a struct/enum (a `Std.Html.Events.onInput`
--     handler → `OnString(.., handler)`) is NOT lambda-captured and must keep
--     its bare type so the existing `Arc::new(handler)` storage path is intact.
-- Param names route through `rustSafeIdent` so a Rust-keyword name (`fn`) gets
-- its raw-ident form on BOTH sides of the `let` (matching the use sites).
arcFnParamPreludeFor :: EmitCtx -> Can.Expr -> [String] -> [Can.Pattern] -> String
arcFnParamPreludeFor _ctx body paramStrs pats =
    let captured = collectLambdaCapturedVars body
    in concat
         [ "let " ++ pn' ++ " = std::sync::Arc::new(" ++ pn' ++ "); "
         | (pStr, Ann.At _ (Can.PVar pn)) <- zip paramStrs pats
         , isClosureParamStr pStr
         , not ("Clone" `isInfixOf` pStr)
         , pn `Set.member` captured
         , let pn' = rustSafeIdent pn ]

-- | The concrete carrier type a Std.Ui helper's wildcard `any` resolves to.
-- `any` in these signatures is a Sky wildcard (Go = interface{}); in Rust it
-- always carries exactly one concrete type. See the call site in the TypedDef
-- branch of defToRustItem for the rationale.
stdUiAnyCarrier :: String -> String -> Maybe Can.Type
stdUiAnyCarrier modPrefix fnName
    | modPrefix /= "Std_Ui" = Nothing
    | fnName `elem` [ "html", "layout", "layoutWith"
                    , "renderElement", "renderNodeAs", "renderNearby" ]
        = Just (Can.TType (ModuleName.Canonical "Std.Html") "Html" [Can.TVar "msg"])
    | fnName `elem` [ "kernelAttr", "collectHtmlAttrs"
                    , "toAttrAttribute", "ariaForDescription" ]
        = Just (Can.TType (ModuleName.Canonical "Std.Html.Attributes") "Attribute" [Can.TVar "msg"])
    | otherwise = Nothing

-- | Substitute the wildcard `TVar "any"` with a concrete carrier type
-- everywhere it appears in a type (including inside List/Maybe/Tuple wrappers).
substTVarAny :: Can.Type -> Can.Type -> Can.Type
substTVarAny carrier = go
  where
    go t = case t of
        Can.TVar "any"          -> carrier
        Can.TVar _              -> t
        Can.TType m n args      -> Can.TType m n (map go args)
        Can.TLambda a b         -> Can.TLambda (go a) (go b)
        Can.TTuple a b rest     -> Can.TTuple (go a) (go b) (map go rest)
        Can.TRecord fs ext      -> Can.TRecord (Map.map (\f -> f { Can._fieldType = go (Can._fieldType f) }) fs) ext
        Can.TAlias m n ps inner -> Can.TAlias m n (map (\(k, v) -> (k, go v)) ps) inner
        Can.TUnit               -> Can.TUnit

-- | Extract the element-type string `T` from a rendered `SkyTask<T>` return
-- type. Returns Nothing for non-Task or unparenthesised shapes. Used to seed
-- `ecReturnElem` so a polymorphic-helper `Task.fail` in the function's tail
-- chain pins the turbofish to the resolved element (not the i64 default).
taskElemOf :: String -> Maybe String
taskElemOf s
    | "SkyTask<" `isPrefixOf` s && not (null s) && last s == '>' =
        Just (drop (length ("SkyTask<" :: String)) (init s))
    | otherwise = Nothing

-- ============================================================
-- returnTypeWithGenerics (lines 1346-1370 of Builder.hs)
-- ============================================================

returnTypeWithGenerics
    :: Map.Map String String         -- record map
    -> Can.Type                      -- Sky return type (may have TVars)
    -> Map.Map String Can.Type       -- solved types (for inference)
    -> (String, [String])            -- (Rust type, generic params to add)
returnTypeWithGenerics recMap ty solved = case ty of
    Can.TType _ "Task" [_e, a] ->
        let (innerStr, gens) = returnTypeWithGenerics recMap a solved
        in ("SkyTask<" ++ innerStr ++ ">", gens)
    Can.TType _ "Result" [e, a] ->
        let (errStr, gs1) = returnTypeWithGenerics recMap e solved
            (okStr,  gs2) = returnTypeWithGenerics recMap a solved
        in ("SkyResult<" ++ errStr ++ ", " ++ okStr ++ ">", gs1 ++ gs2)
    Can.TType _ "Maybe" [a] ->
        let (s, gs) = returnTypeWithGenerics recMap a solved
        in ("SkyMaybe<" ++ s ++ ">", gs)
    Can.TVar n ->
        let g = if "_" `isPrefixOf` n
                then "__T" ++ drop 1 n   -- private generic for Skolems
                else "T_" ++ n           -- user-facing generic
        in (g, [g])
    _ ->
        (typeToRustString recMap ty, [])

-- ============================================================
-- inferCtorReturnType (lines 1372-1401 of Builder.hs)
-- ============================================================

inferCtorReturnType :: Map.Map String String -> Map.Map String Can.Type -> Can.Expr -> String
inferCtorReturnType recMap solved (Ann.At _ expr) = case expr of
    Can.Call (Ann.At _ (Can.VarCtor _ _ tyName ctorName _)) args ->
        case (tyName, ctorName, args) of
            -- Result: Ok x / Err e
            ("Result", "Ok", [arg]) ->
                let okT = solveArgType solved arg
                in "SkyResult<SkyError, " ++ okT ++ ">"
            ("Result", "Err", [arg]) ->
                let errT = solveArgType solved arg
                in "SkyResult<" ++ errT ++ ", String>"
            -- Maybe: Just y / Nothing
            ("Maybe", "Just", [arg]) ->
                let valT = solveArgType solved arg
                in "SkyMaybe<" ++ valT ++ ">"
            ("Maybe", "Nothing", []) -> "SkyMaybe<String>"
            -- List: cons (::) / empty
            ("List", "::", [arg, _]) ->
                let elT = solveArgType solved arg
                in "Vec<" ++ elT ++ ">"
            ("List", "[]", []) -> "Vec<String>"
            _ -> ""
    -- For a plain local variable, look up its solved type
    Can.VarLocal name -> case Map.lookup name solved of
        Just ty -> typeToRustString recMap ty
        Nothing -> ""
    _ -> ""

-- ============================================================
-- isCanTypeCopy (lines 1403-1413 of Builder.hs)
-- ============================================================

isCanTypeCopy :: Can.Type -> Bool
isCanTypeCopy Can.TUnit                          = True
isCanTypeCopy (Can.TType _ "Int" [])             = True
isCanTypeCopy (Can.TType _ "Float" [])           = True
isCanTypeCopy (Can.TType _ "Bool" [])            = True
isCanTypeCopy (Can.TType _ "Char" [])            = True
isCanTypeCopy _                                   = False

-- ============================================================
-- tailExpr (lines 1415-1420 of Builder.hs)
-- ============================================================

tailExpr :: Can.Expr -> Can.Expr
tailExpr (Ann.At _ (Can.Let _ b))         = tailExpr b
tailExpr (Ann.At _ (Can.LetRec _ b))      = tailExpr b
tailExpr (Ann.At _ (Can.LetDestruct _ _ b)) = tailExpr b
tailExpr e                                = e

-- ============================================================
-- needsTaskWrap (lines 1422-1444 of Builder.hs)
-- ============================================================

needsTaskWrap :: Map.Map String Can.Type -> Can.Expr -> Bool
needsTaskWrap solved body =
    case tailExpr body of
        Ann.At _ Can.Unit          -> True
        Ann.At _ (Can.Int _)       -> True
        Ann.At _ (Can.Float _)     -> True
        Ann.At _ (Can.Str _)       -> True
        Ann.At _ (Can.Chr _)       -> True
        tail                      -> not (isTaskExpr tail)
  where
    isTaskExpr e =
        -- Use taskExprInnerType: if it returns non-empty, e is a Task expression
        let inner = taskExprInnerType solved e
        in not (null inner)

-- ============================================================
-- buildProgram (lines 3082-3138 of Builder.hs)
-- ============================================================

buildProgram :: [Can.Module] -> Map.Map String Can.Type -> Map.Map String (Map.Map String Can.Type) -> Map.Map Ann.Region Can.Type -> Map.Map (String, String) (String, String) -> String -> String -> RustBuilder
buildProgram mods solvedTypes perModuleEnv regionTypes kernelAliases liveStore liveStorePath =
    let aliasMap = buildRecordMap mods
        rawAnon = collectAnonRecordTypes mods
        -- Only include anonymous record keys NOT already covered by a type alias
        anonEntries = Map.filterWithKey (\k _ -> not (Map.member k aliasMap)) rawAnon
        
        -- Generate RStructDef entries with generic type params per field.
        -- Each field gets a distinct type param T0..Tn so the struct works
        -- with heterogeneous decoder pipelines (String, i64, bool, ...).
        (anonDefs, anonKeyMap) =
            foldr (\(key, flds) (defs, km) ->
                let name = anonStructName key
                    n = length flds
                    typeParams = ["T" ++ show i | i <- [0..n-1]]
                    gens = if null typeParams then "" else "<" ++ intercalate ", " typeParams ++ ">"
                    rustFlds = zipWith (\f t -> (f, t)) flds typeParams
                in if null rustFlds then (defs, km)
                   else (RStructDef name gens rustFlds : defs, Map.insert key name km)
                ) ([], Map.empty) (Map.toList anonEntries)
        
        -- Cross-module ADT name resolution. A reusable module can reference a
        -- type defined elsewhere WITHOUT importing it (`Ui.Charts` sig
        -- `… -> Html Msg` where `Msg` lives in `State`), so the canonicaliser
        -- leaves that TType's modName EMPTY and the renderer would emit a bare,
        -- undefined `Msg` instead of `StateMsg` (17-skymon E0412). Build a
        -- bareName -> Rust-type-name map over EVERY module's unions + aliases,
        -- keyed by a `@adt@` sentinel so it can't collide with the record
        -- field-key entries above; typeToRustString consults it for empty-modName
        -- TTypes. Same-module refs already carry their modName, so this only
        -- fires on the genuinely-unresolved cross-module case.
        adtNameMap = Map.fromList $ concatMap
            (\m ->
                let modStr = ModuleName._name (Can._name m)
                    mangled = map (\c -> if c == '.' then '_' else c) modStr
                    rustName nm = toCamelCase (mangled ++ "_" ++ nm)
                in [ ("@adt@" ++ nm, rustName nm)
                   | nm <- Map.keys (Can._unions m) ++ Map.keys (Can._aliases m) ])
            mods
        recordMap = Map.unions [aliasMap, anonKeyMap, adtNameMap]

        -- structName -> (field -> declared type), over every record alias, for
        -- record-UPDATE field-value expected-type seeding (see ecStructFields).
        structFields = Map.fromList $ concatMap
            (\m ->
                let modStr = ModuleName._name (Can._name m)
                    mangled = map (\c -> if c == '.' then '_' else c) modStr
                in [ ( toCamelCase (mangled ++ "_" ++ nm)
                     , Map.fromList [ (fn, ft) | (fn, Can.FieldType _ ft) <- Map.toList flds ] )
                   | (nm, Can.Alias _ (Can.TRecord flds _)) <- Map.toList (Can._aliases m) ])
            mods

        ctorArity = Map.fromList
            [ (name, Map.size fields)
            | mod <- mods
            , (name, Can.Alias _ (Can.TRecord fields _)) <- Map.toList (Can._aliases mod)
            ]

        -- Sub-A.13: ctor name -> declared field types, harvested from every
        -- module's unions (Ctor name tag arity fieldTypes).
        ctorFieldTypes = Map.fromList
            [ (ctorName, fieldTys)
            | mod <- mods
            , union <- Map.elems (Can._unions mod)
            , Can.Ctor ctorName _ _ fieldTys <- Can._u_alts union
            ]

        ctx = EmitCtx { ecRecordMap = recordMap, ecSolvedTypes = solvedTypes, ecRegionTypes = regionTypes, ecExpectedType = Nothing, ecInGenericFn = False, ecCloneVars = Set.empty, ecCopyVars = Set.empty, ecPipeInnerType = Nothing, ecUsesTaskRun = usesTaskRun usage, ecZeroArgDefs = zeroArgDefs, ecNoCloneVars = noCloneVars, ecCtorArity = ctorArity, ecCtorFieldTypes = ctorFieldTypes, ecKernelAliases = kernelAliases, ecLiveInitFns = liveInitFns, ecLiveReqInitFns = liveReqInitFns, ecUsesBackendApp = usesBackendApp, ecLiveStore = (liveStore, liveStorePath), ecModuleEnv = Map.empty, ecAppMsg = appMsg, ecAppModel = appModel, ecClosureDefs = Map.empty, ecReturnElem = Nothing, ecSiblingFns = Map.empty, ecCurrentModule = "", ecStructFields = structFields, ecForcedClosureParam = Nothing, ecEnclosingRet = Nothing, ecGenParams = [], ecNameRenames = nameRenames, ecIndexedHofClosure = False, ecBinaryHofClosure = False, ecInResultCtorArg = False }
        -- Multi-module signature scoping. The flat `ecSolvedTypes` (`_stEnv`)
        -- collides on bare names across modules, so a DEP module's function
        -- (e.g. `Lib.Db.exec : String -> List String -> Task Error ()`) whose
        -- name isn't the entry's was looked up and missed — codegen then fell
        -- back to body-analysis defaults (`args: String`, return `()`) instead
        -- of the real `Vec<String>` / `SkyTask`. The result: a cascade of E0308
        -- at every call site (the keystone of the mass-mismatch class). Per
        -- module M, layer M's OWN per-module env (`_stPerModuleEnv[M]`) ON TOP
        -- of the flat map so M's bindings win; cross-module refs still fall back
        -- to flat. Mirrors collectLiveSerdeTypes' scoped lookup.
        scopeCtxToModule m =
            let modEnv = Map.findWithDefault Map.empty
                             (ModuleName.toString (Can._name m)) perModuleEnv
            in ctx { ecModuleEnv = modEnv }
        liveInitFns = collectLiveInitFns mods
        liveReqInitFns = collectLiveReqInitFns mods
        -- #24 tenet 3: does `main` yield a backend-entry app-future? Any of these
        -- drivers returns a `SkyTask<()>` the entry must block_on.
        usesBackendApp = usesLive usage || usesTui usage || usesWebview usage
        -- Does the entry `main`'s emitted `sky_main` RETURN a `SkyTask<…>`? The
        -- entry must `block_on` it iff so. The SOUND signal is the body TAIL's
        -- task-ness (see the `retTy` note at `isEntryMain`: keying on
        -- `usesTaskRun` is unsound — 14-task-demo calls `Task.run` inline yet its
        -- TAIL is a Task, so `sky_main` keeps `SkyTask<()>` and MUST be
        -- block_on'd). Pre-deferral this was masked: effect kernels fired eagerly,
        -- so even a dropped tail future printed. With deferred effects a dropped
        -- tail Task never runs → the tail effect is silently lost. Mirror the
        -- emitter's `retTy` decision: backend-entry app OR a Task-typed body tail.
        mainBodyTailIsTask =
            usesBackendApp ||
            (case lookup "main" mainModuleDefs of
                 Just body -> mainEntryTailReturnsTask solvedTypes body
                 Nothing   -> False)
        -- `main`'s body, looked up ONLY in the entry module (`module Main`), so a
        -- stdlib `<main>` helper (Std.Html.main) never shadows the program entry.
        mainModuleDefs =
            [ (n, b)
            | m <- mods
            , ModuleName._name (Can._name m) == "Main"
            , (n, b) <- collectTopDefBodies (Can._decls m)
            ]
        appMsg = detectAppMsg mods solvedTypes perModuleEnv
        appModel = detectAppModel mods solvedTypes perModuleEnv
        usage = analyzeKernelUsage mods
        zeroArgDefs = collectZeroArgDefs mods
        noCloneVars = Set.empty
        -- Collision-rename map for non-injective name mangling. Two distinct
        -- Sky functions can snake_case to the same Rust name (e.g.
        -- `Std.Ui.borderRounded` and `Std.Ui.Border.rounded` → both
        -- `std_ui_border_rounded`). For every default name produced by >1
        -- distinct (modPrefix, bareName), rename each member to
        -- `toSnakeCase modPrefix ++ "_" ++ bareName` (bareName verbatim, so the
        -- preserved camelCase keeps them apart, mirroring the Go backend).
        allDefNames = nub
            [ (moduleNameToRust (Can._name m), dn)
            | m <- mods, dn <- topLevelDefNames (Can._decls m), not (null dn) ]
        nameRenames =
            let grouped = Map.fromListWith (++)
                    [ (toSnakeCase (mp ++ "_" ++ n), [(mp, n)]) | (mp, n) <- allDefNames ]
                collisions = [ ks | ks <- Map.elems grouped, length ks >= 2 ]
                userVsUser = Map.fromList
                    [ ((mp, n), toSnakeCase mp ++ "_" ++ n) | ks <- collisions, (mp, n) <- ks ]
                -- A user module whose function lowers to a runtime-kernel name
                -- (e.g. user `module Auth` → `auth_hash_password`, identical to
                -- the `Std.Auth` kernel) is ambiguous at the crate root once both
                -- glob re-exports land. Disambiguate the USER side with a `user_`
                -- prefix; the kernel name is untouched, so every other example's
                -- kernel calls stay byte-identical. Takes precedence over the
                -- user-vs-user rename above (which could itself re-collide with
                -- the kernel) on the rare double-collision.
                kernelVsUser = Map.fromList
                    [ ((mp, n), nn)
                    | (mp, n) <- allDefNames
                    , Just nn <- [disambiguateUserFnName mp n] ]
            in Map.union kernelVsUser userVsUser
        existingTypes = concatMap (\m ->
            let skyModName = ModuleName._name (Can._name m)         -- "Std.Decimal" — un-mangled, for runtimeOpaqueTypes lookup
                prefix     = moduleNameToRust (Can._name m)          -- "Std_Decimal" — mangled, for codegen names
            in unionsToRustTypes recordMap skyModName prefix (Can._unions m)
            ++ aliasesToRustTypes recordMap skyModName prefix (Can._aliases m)) mods
    in RustBuilder
        { builderModules = map (\m -> buildModule (scopeCtxToModule m) m) mods
        , builderTypes = existingTypes ++ anonDefs
        , builderKernels = usage
        , builderFfiOpaques = Set.empty  -- populated by generateRust via passed FFI types
        , builderFormTargets = collectFormTargets recordMap regionTypes mods
        , builderLiveInitFns = liveInitFns
        , builderLiveReqInitFns = liveReqInitFns
        , builderLiveSerdeTypes = collectLiveSerdeTypes recordMap mods solvedTypes perModuleEnv
        , builderMainReturnsTask = mainBodyTailIsTask
        }

-- | Top-level def names + bodies of a module's declaration block (entry-`main`
-- detection). Mirrors `collectLiveReqInitFns`'s local `collectDefBodies` but
-- keyed name → body (params dropped). Only top-level Declare/DeclareRec defs.
collectTopDefBodies :: Can.Decls -> [(String, Can.Expr)]
collectTopDefBodies = goD
  where
    goD (Can.Declare def rest)          = ins def ++ goD rest
    goD (Can.DeclareRec def defs0 rest) = concatMap ins (def : defs0) ++ goD rest
    goD Can.SaveTheEnvironment          = []
    ins (Can.Def (Ann.At _ n) _ b)          = [(n, b)]
    ins (Can.TypedDef (Ann.At _ n) _ _ b _) = [(n, b)]
    ins _                                   = []

