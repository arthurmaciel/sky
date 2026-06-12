module Sky.Generate.Rust.Builder.Walker
  ( analyzeKernelUsage
  , zeroArgKernelDefs
  , isFfiKernelAlias
  , collectZeroArgDefs
  , buildRecordMap
  , collectAnonRecordTypes
  , collectFormTargets
  , collectLiveInitFns
  , collectLiveSerdeTypes
  , detectAppMsg
  , detectAppModel
  ) where

import Data.List (isSuffixOf, isPrefixOf, isInfixOf, nub)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Sky.AST.Canonical as Can
import qualified Sky.Sky.ModuleName as ModuleName
import qualified Sky.Reporting.Annotation as Ann
import Sky.Generate.Rust.Builder.Types (CanonicalModule, UsedKernels(..), runtimeOpaqueTypes, intercalate)
import Sky.Generate.Rust.Builder.Naming (toCamelCase, moduleNameToRust, anonStructName)
import Sky.Generate.Rust.Builder.TypeRenderer (extractReturnType, extractParamTypes, formTargetRustType, flattenArrowType, typeToRustString, collectRenderedTVars, hasTypeVars)

-- | Walk all expressions across all modules to detect kernel usage.
-- Ensures we only emit the runtime stubs and Cargo deps that are actually needed.
analyzeKernelUsage :: [Can.Module] -> UsedKernels
analyzeKernelUsage = foldMap analyzeMod
  where
    analyzeMod mod = walkDecls (Can._decls mod)

    walkDecls Can.SaveTheEnvironment = mempty
    walkDecls (Can.Declare def rest) = walkDef def <> walkDecls rest
    walkDecls (Can.DeclareRec def defs rest) = walkDef def <> foldMap walkDef defs <> walkDecls rest

    walkDef (Can.Def _ _ body) = walkExpr body
    walkDef (Can.TypedDef _ _ _ body _) = walkExpr body
    walkDef (Can.DestructDef _ expr) = walkExpr expr

    walkExpr (Ann.At _ expr) = case expr of
        Can.VarKernel modName fnName ->
            detectKernelUsage modName fnName
        Can.VarTopLevel modName topName ->
            -- Pass the binding name (not ""): Ffi.kernel-aliased stdlib funcs
            -- (e.g. `Task.andThen = Ffi.kernel "Task_andThen"`) reach the usage
            -- walker as VarTopLevel, so fnName-specific arms (Task compose →
            -- executor) need it. Module-only arms are unaffected.
            detectKernelUsage (ModuleName._name modName) topName
        Can.Call fn args -> walkExpr fn <> foldMap walkExpr args
        Can.Lambda _ body -> walkExpr body
        Can.Let def body -> walkDef def <> walkExpr body
        Can.LetRec defs body -> foldMap walkDef defs <> walkExpr body
        Can.LetDestruct _ e body -> walkExpr e <> walkExpr body
        Can.Case scrut branches -> walkExpr scrut <> foldMap (\(Can.CaseBranch _ b) -> walkExpr b) branches
        Can.If branches elseBranch ->
            foldMap (\(c, t) -> walkExpr c <> walkExpr t) branches <> walkExpr elseBranch
        Can.Binop _ _ _ _ a b -> walkExpr a <> walkExpr b
        Can.Access r _ -> walkExpr r
        Can.Update _ r updates -> walkExpr r <> foldMap (\(_, Can.FieldUpdate _ e) -> walkExpr e) (Map.toList updates)
        Can.Record fields -> foldMap (\(_, v) -> walkExpr v) (Map.toList fields)
        Can.List es -> foldMap walkExpr es
        Can.Tuple a b rest -> foldMap walkExpr (a:b:rest)
        Can.Negate e -> walkExpr e
        _ -> mempty

    detectKernelUsage modName fnName =
        mconcat
            [ if "Db" `isSuffixOf` modName || modName == "Db"
              then mempty { usesDb = True } else mempty
            -- Sub-C: Std.Auth needs Db (users table) + Json (JWT serde) + Crypto/bcrypt.
            , if "Auth" `isSuffixOf` modName || modName == "Auth"
              then mempty { usesDb = True, usesJson = True, usesCrypto = True, usesTaskRun = True } else mempty
            , if (modName == "Task" || "Sky.Core.Task" `isSuffixOf` modName)
                  && (fnName == "run" || fnName == "sequence" || fnName == "perform")
              then mempty { usesTaskRun = True } else mempty
            , if (modName == "Task" || "Sky.Core.Task" `isSuffixOf` modName) && fnName == "parallel"
              then mempty { usesTaskParallel = True } else mempty
            -- Task composition combinators build async futures whose
            -- continuations only run when the task is awaited. A `main` shaped
            -- as `t |> Task.andThen …` (no explicit Task.run) must therefore be
            -- block_on'd — the eager-fire "call and drop" entry path would
            -- silently skip every continuation (only the first, eagerly
            -- constructed, side effect leaks). Flag pulls tokio + the block_on
            -- entry while leaving mainIsTask=True. (run/perform/sequence already
            -- set usesTaskRun.)
            , if (modName == "Task" || "Sky.Core.Task" `isSuffixOf` modName)
                  && fnName `elem` ["andThen", "map", "onError", "mapError", "andThenResult"]
              then mempty { usesTaskParallel = True } else mempty
            -- Std.Trace span/event/attr return Tasks (span wraps + awaits the
            -- inner task); a composed main using them needs the block_on entry.
            , if (modName == "Trace" || "Std.Trace" `isSuffixOf` modName)
                  && fnName `elem` ["span", "event", "attr"]
              then mempty { usesTaskParallel = True } else mempty
            , if "System" `isSuffixOf` modName || modName == "System"
              then mempty { usesTaskRun = True } else mempty
            , if "Json" `isPrefixOf` modName || "Sky.Core.Json" `isPrefixOf` modName
              then mempty { usesJson = True } else mempty
            , if "Crypto" `isPrefixOf` modName || "Sky.Core.Crypto" `isPrefixOf` modName
              then mempty { usesCrypto = True } else mempty
            , if modName == "Uuid" || "Sky.Core.Uuid" `isSuffixOf` modName
              then mempty { usesUuid = True } else mempty
            , if modName == "Server" || "Sky.Http.Server" `isInfixOf` modName
                 -- Middleware / RateLimit live in server.rs (need ServerRequest/
                 -- Response + axum), so they pull the server module too.
                 || modName `elem` ["Middleware", "RateLimit"]
                 || "Sky.Http.Middleware" `isSuffixOf` modName
                 || "Sky.Http.RateLimit" `isSuffixOf` modName
              -- isInfixOf so the submodules (Sky.Http.Server.WebSocket / .Stream)
              -- also flip the flag. usesHttpServer alone pulls tokio (via
              -- hasTokio) + the server module; do NOT set usesTaskRun — `main =
              -- Server.listen …` returns a Task, so main must stay task-shaped
              -- (block_on'd), which the usesTaskRun=True path would defeat.
              then mempty { usesHttpServer = True } else mempty
            -- Sky.Core.Http client (distinct from Sky.Http.Server above; the
            -- infix check can't collide — Server is "Sky.Http.Server"). isInfixOf
            -- so the submodule "Sky.Core.Http.Stream" also flips usesHttp — its
            -- kernels live in http_stream.rs (gated with http_client) and it
            -- reuses the bridged HttpRequest struct from http_client.rs.
            , if modName == "Http" || "Sky.Core.Http" `isInfixOf` modName
              then mempty { usesHttp = True } else mempty
            -- Sky.Core.Http.Stream's `chunks` returns `Sub msg` (emitted
            -- wholesale with the module) → needs SkySub from tea.rs. The
            -- Sub-tier itself is a no-op stub on Rust (forEachChunk is the
            -- supported path), but the type must resolve.
            , if "Sky.Core.Http.Stream" `isSuffixOf` modName
              then mempty { usesTea = True } else mempty
            -- Sub-E: TEA — Cmd / Sub / Cli.program → tea module (tokio). Cli's
            -- program returns a Task, so it also needs the tokio runtime.
            , if modName `elem` ["Cmd", "Sub", "Cli"]
                 || "Std.Cmd" `isSuffixOf` modName || "Std.Sub" `isSuffixOf` modName
                 || "Std.Cli" `isSuffixOf` modName || "Sky.Cli" `isSuffixOf` modName
              then mempty { usesTea = True } else mempty
            -- S6: pub/sub kernels live in the broker (live/pubsub.rs), so they
            -- need the live module pulled (usesLive) in addition to the TEA
            -- loop (usesTea). Gated on the FUNCTION name so Cmd.none/batch/
            -- perform + Sub.none/batch/every are unaffected.
            , if (("Std.Cmd" `isSuffixOf` modName || modName == "Cmd") && fnName `elem` ["publish", "publishNoEcho"])
                 || (("Std.Sub" `isSuffixOf` modName || modName == "Sub") && fnName == "subscribeTopic")
                 || modName == "PubSub" || "Std.PubSub" `isSuffixOf` modName
              then mempty { usesTea = True, usesLive = True } else mempty
            -- Sky.Core.WebSocket client (distinct from Sky.Http.Server.WebSocket;
            -- the suffix can't collide). Pulls ws_client + tokio-tungstenite. Its
            -- onMessage Sub also needs the TEA loop.
            , if "Sky.Core.WebSocket" `isSuffixOf` modName
              then mempty { usesWsClient = True, usesTea = True } else mempty
            , if "Time" `isPrefixOf` modName || "Sky.Core.Time" `isPrefixOf` modName
              -- usesTea: the Sky.Core.Time module is emitted wholesale, and
              -- `Time.every : Int -> msg -> Sub msg` references SkySub (tea.rs).
              -- Any Time user therefore needs the TEA module present.
              -- Time.sleep needs the async runtime — pull tokio via
              -- usesTaskParallel (NOT usesTaskRun). usesTaskRun would flip
              -- mainIsTask off, breaking a Task-typed main that awaits sleep but
              -- never calls Task.run (e.g. `main = Server.listen …` with a
              -- streaming handler that sleeps between chunks — it must stay
              -- block_on'd). Same reasoning as the Task-compose combinators.
              then mempty { usesTime = True, usesTea = True } <> (if fnName == "sleep" then mempty { usesTaskParallel = True } else mempty)
              else mempty
            , if "Random" `isPrefixOf` modName || "Sky.Core.Random" `isPrefixOf` modName
              then mempty { usesRandom = True } else mempty
            , if "File" `isPrefixOf` modName || "Sky.Core.File" `isPrefixOf` modName
              then mempty { usesFile = True } else mempty
            -- Std.Email — provider-abstract send. Pulls reqwest (Resend/SendGrid/
            -- SES over HTTPS) + tokio (async) + serde_json (request bodies).
            , if modName == "Email" || "Std.Email" `isSuffixOf` modName
              then mempty { usesEmail = True } else mempty
            -- Std.Live / Live — Html bridge + live_render_static (P0) / live_app
            -- (P1). Pulls tokio (async Task) + the live submodule (html.rs).
            , if modName == "Live" || "Std.Live" `isInfixOf` modName
              then mempty { usesLive = True } else mempty
            -- Std.Tui — terminal TEA backend (tui_app). Pulls the tui module
            -- (cell/diff/key/app) + crossterm (raw mode) + unicode-width + the
            -- tea module (the loop reuses CliEvent/SubManager/cli_run_cmd).
            , if modName == "Tui" || "Std.Tui" `isSuffixOf` modName
              then mempty { usesTui = True, usesTea = True } else mempty
            -- Std.Html / Std.Ui — render to an Html ADT via Html.toString /
            -- Ui.layout. The Html/Attribute/Event types + html_render_ live in the
            -- live submodule, so a NON-Live (CLI / Tui) app that only renders HTML
            -- must still pull that module in (gated below as usesLive || usesHtml).
            , if "Html" `isInfixOf` modName || "Std.Ui" `isInfixOf` modName || modName == "Ui"
              then mempty { usesHtml = True } else mempty
            ]

-- | Known zero-argument kernel stubs that must be called with () when referenced.
-- These emit Rust `fn name() -> T` but are used as value `T` in Sky expressions.
zeroArgKernelDefs :: Set.Set (String, String)
zeroArgKernelDefs = Set.fromList
    [ ("JsonDec", "string")
    , ("JsonDec", "int")
    , ("JsonDec", "float")
    , ("JsonDec", "bool")
    , ("JsonDec", "null")
    -- sub-A.10 C3: zero-arg Sky kernels referenced via Ffi.kernel aliases
    , ("Dict", "empty")
    , ("Sky.Core.Dict", "empty")
    , ("Math", "pi"),  ("Math", "e")
    , ("Sky.Core.Math", "pi"), ("Sky.Core.Math", "e")
    -- Sub-E: Cmd.none / Sub.none are zero-arg values (Cmd msg / Sub msg) but
    -- lower to `cmd_none()` / `sub_none()` (generic fns) on Rust.
    , ("Cmd", "none"), ("Std.Cmd", "none")
    , ("Sub", "none"), ("Std.Sub", "none")
    ]

-- | Collect all zero-argument user-defined definitions across all modules.
-- Every such definition emits `fn name() -> T` in Rust, so VarTopLevel references
-- must emit `name()` instead of bare `name`.
collectZeroArgDefs :: [Can.Module] -> Set.Set (String, String)
collectZeroArgDefs mods = foldMap walkMod mods `Set.union` zeroArgKernelDefs
  where
    walkMod m = walkDecls (moduleNameToRust (Can._name m)) (Can._decls m)
    walkDecls prefix Can.SaveTheEnvironment = mempty
    walkDecls prefix (Can.Declare def rest) = walkDef prefix def <> walkDecls prefix rest
    walkDecls prefix (Can.DeclareRec def defs rest) =
        walkDef prefix def <> foldMap (walkDef prefix) defs <> walkDecls prefix rest
    -- A `Can.Def name [] body` with empty params is zero-arg AT the Sky source
    -- layer — but if the body is `Ffi.kernel "X"` (a Stage-4 alias declaration),
    -- the actual kernel `X` may take multiple args. Treating such an alias as
    -- zero-arg makes callers wrongly emit `string_contains()(args)` (paren-wrap
    -- + args). Exclude these — Stage-4 rewrite resolves call sites directly.
    walkDef prefix (Can.Def (Ann.At _ name) [] body)
        | isFfiKernelAlias body = mempty
        | otherwise             = Set.singleton (prefix, name)
    walkDef prefix (Can.TypedDef (Ann.At _ name) _ [] body _)
        | isFfiKernelAlias body = mempty
        | otherwise             = Set.singleton (prefix, name)
    walkDef _ _ = mempty

-- | True if the body is exactly `Ffi.kernel "X"` (zero or N args don't matter —
-- the alias is a value-level declaration; the kernel itself may take args).
isFfiKernelAlias :: Can.Expr -> Bool
isFfiKernelAlias (Ann.At _ (Can.Call (Ann.At _ (Can.VarKernel "Ffi" "kernel")) _)) = True
isFfiKernelAlias _ = False

-- | Build a map from field-name-signature to struct name
buildRecordMap :: [Can.Module] -> Map.Map String String
buildRecordMap mods = Map.fromList
    [ (intercalate "," (Map.keys fields), toCamelCase (modPrefix ++ "_" ++ name))
    | mod <- mods
    , let modPrefix = moduleNameToRust (Can._name mod)
    , (name, Can.Alias _ (Can.TRecord fields _)) <- Map.toList (Can._aliases mod)
    ]

-- | Generic expression walker over all modules. The handler receives each
-- annotated expression; the default fallthrough recurses into sub-expressions.
-- Eliminates the duplicated walkDecls/walkDef/walkSubExprs boilerplate.
walkExprs :: Monoid m => (Can.Expr -> m) -> [Can.Module] -> m
walkExprs handler = foldMap walkMod
  where
    walkMod m = walkDecls (Can._decls m)
    walkDecls Can.SaveTheEnvironment = mempty
    walkDecls (Can.Declare def rest) = walkDef def <> walkDecls rest
    walkDecls (Can.DeclareRec def defs rest) = walkDef def <> foldMap walkDef defs <> walkDecls rest
    walkDef (Can.Def _ _ body) = walkExpr body
    walkDef (Can.TypedDef _ _ _ body _) = walkExpr body
    walkDef (Can.DestructDef _ expr) = walkExpr expr
    walkExpr e@(Ann.At _ expr) = handler e <> walkSub expr
    walkSub (Can.Call fn args)       = walkExpr fn <> foldMap walkExpr args
    walkSub (Can.Lambda _ body)     = walkExpr body
    walkSub (Can.Let def body)      = walkDef def <> walkExpr body
    walkSub (Can.LetRec defs body)  = foldMap walkDef defs <> walkExpr body
    walkSub (Can.LetDestruct _ a b) = walkExpr a <> walkExpr b
    walkSub (Can.Case s bs)         = walkExpr s <> foldMap (\(Can.CaseBranch _ b) -> walkExpr b) bs
    walkSub (Can.If cs el)          = foldMap (\(c, t) -> walkExpr c <> walkExpr t) cs <> walkExpr el
    walkSub (Can.Binop _ _ _ _ a b) = walkExpr a <> walkExpr b
    walkSub (Can.Access r _)        = walkExpr r
    walkSub (Can.Update _ r ups)    = walkExpr r <> foldMap (\(_, Can.FieldUpdate _ e) -> walkExpr e) (Map.toList ups)
    walkSub (Can.Record fields)     = foldMap (\(_, v) -> walkExpr v) (Map.toList fields)
    walkSub (Can.List es)           = foldMap walkExpr es
    walkSub (Can.Tuple a b rest)    = foldMap walkExpr (a:b:rest)
    walkSub (Can.Negate e)          = walkExpr e
    walkSub _                       = mempty

-- | Walk all expressions collecting anonymous record field signatures.
-- Returns field-key → [(field-name, HM-inferred-type)] for records NOT
-- covered by type-alias-defined structs.  Skips records with unresolved
-- type variables (TVar) to avoid emitting invalid generic struct fields.
collectAnonRecordTypes :: [Can.Module] -> Map.Map String [String]
collectAnonRecordTypes = walkExprs onExpr
  where
    onExpr (Ann.At _ (Can.Record fields)) =
        let key = intercalate "," (Map.keys fields)
            fieldNames = map fst (Map.toList fields)
        in Map.singleton key fieldNames
    onExpr _ = mempty

-- | P2-T5 pre-pass. Walk every expression in every module; for each
-- `Std.Html.Events.onSubmit handler` call, derive the form-target record's Rust
-- type name (via the SAME formTargetRustType helper the call-site peephole uses,
-- so both agree on the rendered name) and collect it. The resulting set drives
-- the serde::Deserialize stamp in typeDefToString.
collectFormTargets :: Map.Map String String -> Map.Map Ann.Region Can.Type -> [Can.Module] -> Set.Set String
collectFormTargets recordMap regionTypes = walkExprs onExpr
  where
    onExpr (Ann.At _ (Can.Call (Ann.At _ (Can.VarTopLevel mdl "onSubmit")) [Ann.At hregion _]))
        -- Both Std.Html.Events.onSubmit AND Std.Ui.onSubmit (which wraps it) are
        -- inlined to a form-decode at their call site, so the handler's form
        -- record type needs `#[derive(Deserialize)]`.
        | ModuleName._name mdl `elem` ["Std.Html.Events", "Std.Ui"] =
            let mTy = Map.lookup hregion regionTypes
            in case formTargetRustType recordMap mTy of
                Just rustT -> Set.singleton rustT
                Nothing    -> mempty
    onExpr _ = mempty

-- | P4-T3 pre-pass. Walk every expression in every module; for each
-- `Live.app { init = <top-level-ref>, ... }` call (the same record-splice form
-- the Live.app call-site peephole matches), collect the Sky BINDING NAME of the
-- init function when the `init` field is a top-level reference (e.g. `init`).
-- Lambda / inline init fields are out of P4 scope and skipped.
--
-- The resulting set drives the param-0 type override in defToRustItem: the
-- runtime now requires `FInit: Fn(LiveReq) -> (Model, SkyCmd<Msg>)`, but the
-- shared HM type checker leaves the init arg a free `req` TVar (must stay free —
-- changing it breaks the Go skyshop example). So the Rust codegen alone pins the
-- init fn's first param to `sky_runtime::LiveReq`.
--
-- Keyed on the Sky binding name (`fname`) to match defToRustItem's `name`.
collectLiveInitFns :: [Can.Module] -> Set.Set String
collectLiveInitFns = walkExprs onExpr
  where
    onExpr (Ann.At _ (Can.Call (Ann.At _ (Can.VarKernel "Live" "app")) [Ann.At _ (Can.Record fields)])) =
        case Map.lookup "init" fields of
            Just (Ann.At _ (Can.VarTopLevel _ fname)) -> Set.singleton fname
            _ -> Set.empty
    onExpr _ = Set.empty

-- | P5-T4b pre-pass. The Rust runtime's `live_app` / `live_app_routed` require
-- `Model: serde::Serialize + serde::de::DeserializeOwned` (it serialises the
-- model to JSON for the SQLite session store). So every user-defined type in the
-- model's TRANSITIVE type closure must derive serde. This pre-pass computes that
-- closure PRECISELY — only types reachable from the model — so we don't over-
-- derive serde on unrelated structs/enums (which would force serde bounds onto
-- function-typed fields and fail with E0277).
--
-- Returns the set of RUST type names (toCamelCase of the mangled module + name)
-- that typeDefToString must stamp with serde::Serialize + serde::Deserialize.
collectLiveSerdeTypes :: Map.Map String String -> [Can.Module] -> Map.Map String Can.Type
                      -> Map.Map String (Map.Map String Can.Type) -> Set.Set String
collectLiveSerdeTypes recordMap mods solvedTypes perModuleEnv =
    case modelType of
        Nothing -> Set.empty
        Just ty -> bfs Set.empty ty
  where
    -- Module-scoped solved-type lookup. The flat `solvedTypes` (`_stEnv`)
    -- collides on bare names across modules: a Sky.Live app with a component
    -- module (e.g. Counter) that also defines `view` / `init` would resolve
    -- the model from the WRONG module's binding — Counter's `view : (Msg ->
    -- parentMsg) -> Counter -> ...` has a function as param 0, not the model,
    -- so the closure came back empty and MainModel never got serde (E0277).
    -- The `view`/`init` reference in the Live.app record carries its home
    -- module (`VarTopLevel modName _`); resolve there first via the per-module
    -- ledger (`_stPerModuleEnv`), mirroring Solve.lookupSolvedVarScoped.
    scopedLookup :: ModuleName.Canonical -> String -> Maybe Can.Type
    scopedLookup modName vname =
        case Map.lookup (ModuleName.toString modName) perModuleEnv of
            Just modEnv -> case Map.lookup vname modEnv of
                Just t  -> Just t
                Nothing -> Map.lookup vname solvedTypes
            Nothing -> Map.lookup vname solvedTypes
    -- Step 1: find the model type. Walk all modules for the first
    -- `Live.app { ... }` call; recover the model from view's solver type
    -- (`view : Model -> Html Msg`) — head of its param types. Fallback:
    -- init's return-tuple first element.
    modelType :: Maybe Can.Type
    modelType =
        case firstLiveAppFields of
            Nothing -> Nothing
            Just fields ->
                let fromView = case Map.lookup "view" fields of
                        Just (Ann.At _ (Can.VarTopLevel vmod vname)) ->
                            case scopedLookup vmod vname of
                                Just t -> case extractParamTypes t of
                                    (m : _) -> Just m
                                    []      -> Nothing
                                Nothing -> Nothing
                        _ -> Nothing
                    fromInit = case Map.lookup "init" fields of
                        Just (Ann.At _ (Can.VarTopLevel imod iname)) ->
                            case scopedLookup imod iname of
                                Just t -> case extractReturnType t of
                                    Can.TTuple a _ _ -> Just a
                                    _                -> Nothing
                                Nothing -> Nothing
                        _ -> Nothing
                in case fromView of
                    Just m  -> Just m
                    Nothing -> fromInit

    firstLiveAppFields :: Maybe (Map.Map String Can.Expr)
    firstLiveAppFields = foldr (\m acc -> case acc of
        Just _  -> acc
        Nothing -> walkDeclsForApp (Can._decls m)) Nothing mods

    walkDeclsForApp Can.SaveTheEnvironment = Nothing
    walkDeclsForApp (Can.Declare def rest) =
        firstJust (walkDefForApp def) (walkDeclsForApp rest)
    walkDeclsForApp (Can.DeclareRec def defs rest) =
        firstJust (foldr (\d a -> firstJust (walkDefForApp d) a) Nothing (def : defs))
                  (walkDeclsForApp rest)

    walkDefForApp (Can.Def _ _ body) = walkExprForApp body
    walkDefForApp (Can.TypedDef _ _ _ body _) = walkExprForApp body
    walkDefForApp (Can.DestructDef _ expr) = walkExprForApp expr

    walkExprForApp (Ann.At _ expr) = case expr of
        Can.Call (Ann.At _ (Can.VarKernel "Live" "app")) [Ann.At _ (Can.Record fields)] ->
            Just fields
        Can.Call fn args -> firstJust (walkExprForApp fn) (foldr (\a acc -> firstJust (walkExprForApp a) acc) Nothing args)
        Can.Lambda _ body -> walkExprForApp body
        Can.Let def body -> firstJust (walkDefForApp def) (walkExprForApp body)
        Can.LetRec defs body -> firstJust (foldr (\d a -> firstJust (walkDefForApp d) a) Nothing defs) (walkExprForApp body)
        Can.LetDestruct _ e0 body -> firstJust (walkExprForApp e0) (walkExprForApp body)
        Can.Case scrut branches -> firstJust (walkExprForApp scrut) (foldr (\(Can.CaseBranch _ b) a -> firstJust (walkExprForApp b) a) Nothing branches)
        Can.If branches elseBranch -> firstJust (foldr (\(c, t) a -> firstJust (walkExprForApp c) (firstJust (walkExprForApp t) a)) Nothing branches) (walkExprForApp elseBranch)
        Can.Binop _ _ _ _ a b -> firstJust (walkExprForApp a) (walkExprForApp b)
        Can.Access r _ -> walkExprForApp r
        Can.Update _ r updates -> firstJust (walkExprForApp r) (foldr (\(_, Can.FieldUpdate _ e0) a -> firstJust (walkExprForApp e0) a) Nothing (Map.toList updates))
        Can.Record flds -> foldr (\(_, e0) a -> firstJust (walkExprForApp e0) a) Nothing (Map.toList flds)
        Can.List es -> foldr (\e0 a -> firstJust (walkExprForApp e0) a) Nothing es
        Can.Tuple a b rest -> foldr (\e0 acc -> firstJust (walkExprForApp e0) acc) Nothing (a:b:rest)
        Can.Negate e0 -> walkExprForApp e0
        _ -> Nothing

    firstJust (Just x) _ = Just x
    firstJust Nothing  y = y

    -- Step 2: name -> def maps from ALL modules (bare type names as keys).
    unions  = Map.unions (map Can._unions mods)
    aliases = Map.unions (map Can._aliases mods)

    -- Rust codegen name for a (modName, name) pair — matches typeDefToString's
    -- naming (toCamelCase of the mangled module prefix + the type name).
    rustName modName name = toCamelCase (moduleNameToRust modName ++ "_" ++ name)

    -- Is this type one we register as a runtime-opaque bridge (e.g.
    -- Std.Html.Html -> sky_runtime::Html)? Those are NOT our structs/enums, so
    -- we must NOT try to derive serde on them.
    isOpaque modName name =
        Map.member (ModuleName._name modName, name) runtimeOpaqueTypes

    -- Step 3: BFS the closure from the model type. The accumulating Set is the
    -- visited set (it holds rust names of types whose closure is already in
    -- progress / done), terminating recursion on cycles (recursive ADTs).
    bfs :: Set.Set String -> Can.Type -> Set.Set String
    bfs acc ty = case ty of
        Can.TType modName name args ->
            let rn = rustName modName name
                -- Recurse into type args regardless (e.g. List Foo, Maybe Bar).
                accArgs = foldl bfs acc args
            in if isOpaque modName name
                  then accArgs
                  else if Map.member name unions && not (Set.member rn accArgs)
                       then let acc' = Set.insert rn accArgs
                                ctorFts = concatMap (\(Can.Ctor _ _ _ fts) -> fts)
                                                    (Can._u_alts (unions Map.! name))
                            in foldl bfs acc' ctorFts
                  else if Map.member name aliases && not (Set.member rn accArgs)
                       then let acc' = Set.insert rn accArgs
                                Can.Alias _ body = aliases Map.! name
                            in bfs acc' body
                  else accArgs  -- builtin (Int/String/List/...) or already visited
        Can.TAlias modName name pairs aliasType ->
            let rn = rustName modName name
            in if isOpaque modName name
                  then foldl bfs acc (map snd pairs ++ [aliasInner aliasType])
                  else if Set.member rn acc
                       then foldl bfs acc (map snd pairs ++ [aliasInner aliasType])
                  else let acc' = Set.insert rn acc
                           acc'' = bfs acc' (aliasInner aliasType)
                       in foldl bfs acc'' (map snd pairs)
        Can.TRecord fields _ ->
            -- An UNANNOTATED `view model = …` gives an OPEN record (no named
            -- type) as the model; the BFS would add the field structs but not
            -- the model struct itself → MainModel never serde-stamped (18). Match
            -- the open record's field names to its concrete struct and stamp it.
            let acc' = case serdeMatchStruct recordMap (Map.keysSet fields) of
                         Just nm -> Set.insert nm acc
                         Nothing -> acc
            in foldl (\a (Can.FieldType _ ft) -> bfs a ft) acc' (Map.elems fields)
        Can.TTuple a b rest -> foldl bfs acc (a : b : rest)
        Can.TLambda a b -> bfs (bfs acc a) b
        Can.TVar _ -> acc
        Can.TUnit -> acc

    aliasInner (Can.Hoisted t) = t
    aliasInner (Can.Filled t)  = t

-- | Struct (recordMap value) with the FEWEST extra fields whose set is a
-- SUPERSET of `fieldSet` — resolves an open record to its concrete struct.
serdeMatchStruct :: Map.Map String String -> Set.Set String -> Maybe String
serdeMatchStruct recordMap fieldSet
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

-- | Find the first `Live.app { ... }` record's fields anywhere in the program.
-- Shared by the Msg/Model detection pre-passes.
findLiveAppFields :: [Can.Module] -> Maybe (Map.Map String Can.Expr)
findLiveAppFields mods = foldr (\m acc -> case acc of
        Just _  -> acc
        Nothing -> walkDecls (Can._decls m)) Nothing mods
  where
    fj (Just x) _ = Just x
    fj Nothing  y = y
    walkDecls Can.SaveTheEnvironment = Nothing
    walkDecls (Can.Declare def rest) = fj (walkDef def) (walkDecls rest)
    walkDecls (Can.DeclareRec def defs rest) =
        fj (foldr (\d a -> fj (walkDef d) a) Nothing (def : defs)) (walkDecls rest)
    walkDef (Can.Def _ _ body)        = walkExpr body
    walkDef (Can.TypedDef _ _ _ b _)  = walkExpr b
    walkDef (Can.DestructDef _ e)     = walkExpr e
    walkExpr (Ann.At _ e) = case e of
        Can.Call (Ann.At _ (Can.VarKernel "Live" "app")) [Ann.At _ (Can.Record fields)] -> Just fields
        Can.Call fn args -> fj (walkExpr fn) (foldr (\a acc -> fj (walkExpr a) acc) Nothing args)
        Can.Lambda _ b -> walkExpr b
        Can.Let def b -> fj (walkDef def) (walkExpr b)
        Can.LetRec defs b -> fj (foldr (\d a -> fj (walkDef d) a) Nothing defs) (walkExpr b)
        Can.LetDestruct _ e0 b -> fj (walkExpr e0) (walkExpr b)
        Can.Case s bs -> fj (walkExpr s) (foldr (\(Can.CaseBranch _ b) a -> fj (walkExpr b) a) Nothing bs)
        Can.If brs el -> fj (foldr (\(c, t) a -> fj (walkExpr c) (fj (walkExpr t) a)) Nothing brs) (walkExpr el)
        Can.Binop _ _ _ _ a b -> fj (walkExpr a) (walkExpr b)
        Can.Access r _ -> walkExpr r
        Can.Update _ r ups -> fj (walkExpr r) (foldr (\(_, Can.FieldUpdate _ e0) a -> fj (walkExpr e0) a) Nothing (Map.toList ups))
        Can.Record flds -> foldr (\(_, e0) a -> fj (walkExpr e0) a) Nothing (Map.toList flds)
        Can.List es -> foldr (\e0 a -> fj (walkExpr e0) a) Nothing es
        Can.Tuple a b rest -> foldr (\e0 acc -> fj (walkExpr e0) acc) Nothing (a:b:rest)
        Can.Negate e0 -> walkExpr e0
        _ -> Nothing

-- | Detect a Sky.Live app's CONCRETE Msg Rust type (e.g. "StateMsg"), for
-- monomorphising TEA functions whose return is polymorphic in msg. Reads the
-- first `Live.app { update | view }`'s solved type: `update : Msg -> Model ->
-- (Model, Cmd Msg)` (first param is Msg) or `view : Model -> Html Msg` (the Html
-- arg). Module-scoped via `_stPerModuleEnv`, like collectLiveSerdeTypes. Returns
-- Nothing for non-Live programs OR when Msg isn't concrete (then no substitution
-- — safe).
detectAppMsg :: [Can.Module] -> Map.Map String Can.Type
             -> Map.Map String (Map.Map String Can.Type) -> Maybe Can.Type
detectAppMsg mods solvedTypes perModuleEnv =
    case findLiveAppFields mods of
        Nothing     -> Nothing
        Just fields ->
            let fromUpdate = case Map.lookup "update" fields of
                    Just (Ann.At _ (Can.VarTopLevel m vn)) ->
                        case scoped m vn of
                            Just t -> case extractParamTypes t of (msgT : _) -> Just msgT; [] -> Nothing
                            Nothing -> Nothing
                    _ -> Nothing
                fromView = case Map.lookup "view" fields of
                    Just (Ann.At _ (Can.VarTopLevel m vn)) ->
                        case scoped m vn of
                            Just t -> case extractReturnType t of
                                Can.TType _ "Html" [msgT] -> Just msgT
                                _ -> Nothing
                            Nothing -> Nothing
                    _ -> Nothing
            in case fj fromUpdate fromView of
                 Just msgT | not (hasTypeVars msgT) -> Just msgT
                 _ -> Nothing
  where
    fj (Just x) _ = Just x
    fj Nothing  y = y
    scoped modName vname =
        case Map.lookup (ModuleName.toString modName) perModuleEnv of
            Just env -> case Map.lookup vname env of
                          Just t  -> Just t
                          Nothing -> Map.lookup vname solvedTypes
            Nothing -> Map.lookup vname solvedTypes

-- | Detect a Sky.Live app's CONCRETE Model type, to substitute into TEA returns
-- whose Model slot is left a bare TVar by the solver (`(Model, Cmd msg)` →
-- `(_t030, Cmd msg)`). From `update : Msg -> Model -> …` (2nd param) or `view :
-- Model -> Html Msg` (1st param). Concrete-only; Nothing otherwise.
detectAppModel :: [Can.Module] -> Map.Map String Can.Type
               -> Map.Map String (Map.Map String Can.Type) -> Maybe Can.Type
detectAppModel mods solvedTypes perModuleEnv =
    case findLiveAppFields mods of
        Nothing     -> Nothing
        Just fields ->
            let fromUpdate = case Map.lookup "update" fields of
                    Just (Ann.At _ (Can.VarTopLevel m vn)) ->
                        case scoped m vn of
                            Just t -> case extractParamTypes t of (_ : modelT : _) -> Just modelT; _ -> Nothing
                            Nothing -> Nothing
                    _ -> Nothing
                fromView = case Map.lookup "view" fields of
                    Just (Ann.At _ (Can.VarTopLevel m vn)) ->
                        case scoped m vn of
                            Just t -> case extractParamTypes t of (modelT : _) -> Just modelT; _ -> Nothing
                            Nothing -> Nothing
                    _ -> Nothing
            in case fj fromUpdate fromView of
                 Just modelT | not (hasTypeVars modelT) -> Just modelT
                 _ -> Nothing
  where
    fj (Just x) _ = Just x
    fj Nothing  y = y
    scoped modName vname =
        case Map.lookup (ModuleName.toString modName) perModuleEnv of
            Just env -> case Map.lookup vname env of
                          Just t  -> Just t
                          Nothing -> Map.lookup vname solvedTypes
            Nothing -> Map.lookup vname solvedTypes
