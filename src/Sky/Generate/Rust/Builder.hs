module Sky.Generate.Rust.Builder where

import Data.List (isSuffixOf, isPrefixOf, isInfixOf, stripPrefix, sortBy, nub)
import Data.Maybe (fromMaybe)
import qualified Sky.Sky.Toml as Toml (RustDepSpec(..))
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Sky.AST.Canonical as Can
import qualified Sky.Sky.ModuleName as ModuleName
import qualified Sky.Reporting.Annotation as Ann
import Data.Char (toLower, toUpper, isUpper, isDigit, isLower)
import Numeric (showHex)

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



type CanonicalModule = Can.Module

-- | Which kernel features the user's code actually uses (scanned from AST)
data UsedKernels = UsedKernels
    { usesDb :: Bool           -- Std.Db imported → needs sqlx
    , usesTaskRun :: Bool       -- Task.run called → needs tokio runtime
    , usesTaskParallel :: Bool  -- Task.parallel called → needs tokio::spawn
    , usesJson :: Bool          -- Json.* imported → needs serde_json
    , usesCrypto :: Bool         -- Crypto.* imported → needs sha2
    , usesTime :: Bool            -- Time.* imported
    , usesRandom :: Bool          -- Random.* imported
    , usesFile :: Bool            -- File.* imported
    , usesUuid :: Bool            -- Sky.Core.Uuid.* used → uuid_kernel + uuid crate (v4+v7)
    , usesHttpServer :: Bool      -- Sky.Http.Server.* used → server module + axum
    , usesHttp :: Bool            -- Sky.Core.Http.* used → http client module + reqwest
    , usesTea :: Bool             -- Cmd/Sub/Cli.program used → tea module (tokio)
    , usesWsClient :: Bool        -- Sky.Core.WebSocket used → ws_client + tokio-tungstenite
    } deriving (Show, Eq)

instance Semigroup UsedKernels where
    a <> b = UsedKernels
        { usesDb = usesDb a || usesDb b
        , usesTaskRun = usesTaskRun a || usesTaskRun b
        , usesTaskParallel = usesTaskParallel a || usesTaskParallel b
        , usesJson = usesJson a || usesJson b
        , usesCrypto = usesCrypto a || usesCrypto b
        , usesTime = usesTime a || usesTime b
        , usesRandom = usesRandom a || usesRandom b
        , usesFile = usesFile a || usesFile b
        , usesUuid = usesUuid a || usesUuid b
        , usesHttpServer = usesHttpServer a || usesHttpServer b
        , usesHttp = usesHttp a || usesHttp b
        , usesTea = usesTea a || usesTea b
        , usesWsClient = usesWsClient a || usesWsClient b
        }
instance Monoid UsedKernels where
    mempty = UsedKernels False False False False False False False False False False False False False

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
            -- suffix check can't collide — Server is "Sky.Http.Server").
            , if modName == "Http" || "Sky.Core.Http" `isSuffixOf` modName
              then mempty { usesHttp = True } else mempty
            -- Sub-E: TEA — Cmd / Sub / Cli.program → tea module (tokio). Cli's
            -- program returns a Task, so it also needs the tokio runtime.
            , if modName `elem` ["Cmd", "Sub", "Cli"]
                 || "Std.Cmd" `isSuffixOf` modName || "Std.Sub" `isSuffixOf` modName
                 || "Std.Cli" `isSuffixOf` modName || "Sky.Cli" `isSuffixOf` modName
              then mempty { usesTea = True } else mempty
            -- Sky.Core.WebSocket client (distinct from Sky.Http.Server.WebSocket;
            -- the suffix can't collide). Pulls ws_client + tokio-tungstenite. Its
            -- onMessage Sub also needs the TEA loop.
            , if "Sky.Core.WebSocket" `isSuffixOf` modName
              then mempty { usesWsClient = True, usesTea = True } else mempty
            , if "Time" `isPrefixOf` modName || "Sky.Core.Time" `isPrefixOf` modName
              then mempty { usesTime = True } <> (if fnName == "sleep" then mempty { usesTaskRun = True } else mempty)
              else mempty
            , if "Random" `isPrefixOf` modName || "Sky.Core.Random" `isPrefixOf` modName
              then mempty { usesRandom = True } else mempty
            , if "File" `isPrefixOf` modName || "Sky.Core.File" `isPrefixOf` modName
              then mempty { usesFile = True } else mempty
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
    -- True if the body is exactly `Ffi.kernel "X"` (zero or N args don't matter —
    -- the alias is a value-level declaration; the kernel itself may take args).
    isFfiKernelAlias (Ann.At _ (Can.Call (Ann.At _ (Can.VarKernel "Ffi" "kernel")) _)) = True
    isFfiKernelAlias _ = False

data RustBuilder = RustBuilder
    { builderModules    :: [RustModule]
    , builderTypes      :: [RustTypeDef]
    , builderKernels    :: UsedKernels
    , builderFfiOpaques :: Set.Set String  -- types defined by Rust FFI bindings, skip placeholders
    }

data RustModule = RustModule
    { modName :: String
    , modItems :: [RustItem]
    }

data RustItem
    = RustFunction String String [String] String String  -- name, generics_decl, params, ret_type, body
    | RustStruct String [(String, String)]
    | RustEnum String [(String, Maybe String)]
    | RustTypeAlias String String

data RustTypeDef
    = REnumDef String String [(String, Maybe String)]  -- name, generics_decl, variants
    | RStructDef String String [(String, String)]  -- name, generics_decl, fields
    | RAliasDef String String
    -- | Bridge for Sky opaque types whose representation lives in `sky_runtime`.
    -- Codegen emits `pub use <rustPath> as <codegenName>;` instead of a
    -- placeholder enum. Populated via runtimeOpaqueTypes registry hit in
    -- unionToRustTypeDef. See typeDefToString for the emission shape.
    | RPubUseAlias String String  -- codegenName, rustPath

-- | Sky opaque types whose Rust representation lives in `sky_runtime`.
-- Keyed on (Sky module name with dots, Sky type name). When unionToRustTypeDef
-- would otherwise produce a placeholder enum (e.g.
-- `pub enum StdDecimalDecimal { Decimal__Internal(f64) }`), this registry hit
-- redirects the emission to an `RPubUseAlias` — the runtime newtype IS the
-- canonical representation.
--
-- Sub-projects B-F add entries here as their runtime newtypes land.
runtimeOpaqueTypes :: Map.Map (String, String) String
runtimeOpaqueTypes = Map.fromList
    [ (("Std.Decimal", "Decimal"), "sky_runtime::Decimal")
    , (("Sky.Core.Json.Encode", "Value"), "sky_runtime::JsonVal")
    -- Sub-D: Std.Csv.Csv record maps to the runtime CsvDoc struct (matching
    -- field names/types) so the Csv kernels return/take it directly — no kernel
    -- can name a generated per-project struct. Field access + the synthesized
    -- record constructor resolve onto CsvDoc's pub fields.
    , (("Std.Csv", "Csv"), "sky_runtime::CsvDoc")
    -- Sub-D.1: Sky.Http.Server records (Request/Response) + opaque ADTs
    -- (Route/Cookie) map to runtime structs so the server kernels return/take
    -- them directly. The handler closure is erased into a non-generic
    -- ServerRoute (see server.rs), so no type-arg threading is needed.
    , (("Sky.Http.Server", "Request"), "sky_runtime::ServerRequest")
    , (("Sky.Http.Server", "Response"), "sky_runtime::ServerResponse")
    , (("Sky.Http.Server", "Route"), "sky_runtime::ServerRoute")
    , (("Sky.Http.Server", "Cookie"), "sky_runtime::ServerCookie")
    -- Sky.Core.Http client: the response record + the request record map to
    -- runtime structs. HttpResponse is kernel-returned; HttpRequest is built in
    -- Sky (defaultRequest + with* updates) so its struct fields must be pub.
    , (("Sky.Core.Http", "HttpResponse"), "sky_runtime::HttpResponse")
    , (("Sky.Core.Http", "HttpRequest"), "sky_runtime::HttpRequest")
    -- Sub-D.2: Sky.Http.Server.WebSocket. WebSocketServer is the opaque per-peer
    -- handle the stdlib pattern-matches (-> WsHandle enum, variant name matches
    -- the Sky ctor). WebSocketServerCfg -> WsServerCfg (fn-pointer callbacks),
    -- so `defaultCfg |> withOnX` record updates compile.
    -- Sky.Core.WebSocket client: WebSocketMessage is bridged so the runtime can
    -- construct frames for the user's toMsg; WebSocketCfg is built in Sky. The
    -- WebSocket handle stays a generated enum (kernels take the raw Int).
    , (("Sky.Core.WebSocket", "WebSocketMessage"), "sky_runtime::WsClientMessage")
    , (("Sky.Core.WebSocket", "WebSocketCfg"), "sky_runtime::WsClientCfg")
    -- CloseCode: bridged so onClose's toMsg receives a runtime-built code, and so
    -- closeWithCode's `case code of Normal -> …` matches the runtime variants.
    , (("Sky.Core.WebSocket", "CloseCode"), "sky_runtime::WsCloseCode")
    , (("Sky.Http.Server.WebSocket", "WebSocketServer"), "sky_runtime::WsHandle")
    -- WsServerCfg is generic over the error E (the project's concrete error is
    -- unnameable from the runtime). The value bakes in <SkyError>; the parametric
    -- bridge (aliasToRustTypeDef) emits a generic alias that absorbs the phantom
    -- `msg`: `pub type …Cfg<msg> = sky_runtime::WsServerCfg<SkyError>;`.
    , (("Sky.Http.Server.WebSocket", "WebSocketServerCfg"), "sky_runtime::WsServerCfg<SkyError>")
    ]

-- | Runtime kernels whose Rust signatures are generic and need a turbofish
-- at call sites whose match arms / surrounding context don't pin the
-- generic parameters. Maps kernel name to the EXACT turbofish suffix to
-- inject (depends on the kernel's arity — 1 param = ::<SkyError>, 2 params
-- = ::<SkyError, _>, etc.). `From<String>` for E is provided by `str_err`.
-- | Sub-D: non-kernel stdlib (VarTopLevel) functions that construct a value
-- whose only type variable is the error type — always SkyError in Sky (Cardinal
-- Rule 1) but phantom here (e.g. `RetryPolicy e` / `ShouldRetry e` from a policy
-- builder never tied to a concrete error). Pin e=SkyError at the call site so it
-- infers and propagates through builder chains. Keyed on (canonical module, fn).
topLevelErrorPin :: Map.Map (String, String) String
topLevelErrorPin = Map.fromList
    [ (("Sky.Core.Task", "linearBackoff"),       "::<SkyError>")
    , (("Sky.Core.Task", "exponentialBackoff"),  "::<SkyError>")
    , (("Sky.Core.Task", "defaultRetryPolicy"),  "::<SkyError>")
    , (("Sky.Core.Task", "retryAlways"),         "::<SkyError>")
    ]

kernelsNeedingErrorPin :: Map.Map String String
kernelsNeedingErrorPin = Map.fromList
    [ -- Task.run / Task.perform — <E, A>; pin E (always SkyError), infer A from
      -- context. Without this a phantom error type (a task that never errs, e.g.
      -- Task.perform (retryWith p (Task.succeed v))) is unconstrained -> E0283.
      ("task_run",                 "::<SkyError, _>")
    -- Task.fail : err -> Task err a — the success type `a` is phantom (a failing
    -- task never yields a value). When the value is discarded (e.g. matched with
    -- `Ok _`) `a` is unconstrained -> E0283; default it to i64. A determining
    -- context that needs a different `a` surfaces a loud E0308 (annotate then).
    , ("task_fail",                "::<_, i64>")
    -- Csv parse — single E parameter (returns SkyResult<E, CsvDoc>)
    , ("csv_parse",                "::<SkyError>")
    , ("csv_parse_with_delimiter", "::<SkyError>")
    -- Sub-D.1: Http server route ctors — <E, H>; pin E (the handler's phantom
    -- error type), leave H inferred. server_listen — <E> for its Task<()>.
    , ("server_get",               "::<SkyError, _>")
    , ("server_post",              "::<SkyError, _>")
    , ("server_put",               "::<SkyError, _>")
    , ("server_delete",            "::<SkyError, _>")
    , ("server_any",               "::<SkyError, _>")
    , ("server_listen",            "::<SkyError>")
    -- Sky.Core.Http client — each returns SkyTask<E, HttpResponse>; pin E.
    , ("http_get",                 "::<SkyError>")
    , ("http_post",                "::<SkyError>")
    , ("http_request",             "::<SkyError>")
    -- Sky.Core.WebSocket client — Task-tier kernels; pin E.
    , ("web_socket_connect",          "::<SkyError>")
    , ("web_socket_connect_with",     "::<SkyError>")
    , ("web_socket_send",             "::<SkyError>")
    , ("web_socket_send_binary",      "::<SkyError>")
    , ("web_socket_close",            "::<SkyError>")
    , ("web_socket_close_with_code",  "::<SkyError>")
    -- Sub-D.2: Sky.Http.Server.WebSocket kernels — each returns SkyTask<E, _>.
    , ("server_web_socket_upgrade",              "::<SkyError>")
    , ("server_web_socket_send_to_client",       "::<SkyError>")
    , ("server_web_socket_send_binary_to_client","::<SkyError>")
    , ("server_web_socket_broadcast",            "::<SkyError>")
    , ("server_web_socket_close_client",         "::<SkyError>")
    -- AEAD encrypt/decrypt — single E parameter (sub-D)
    , ("crypto_aes_gcm_encrypt",   "::<SkyError>")
    , ("crypto_aes_gcm_decrypt",   "::<SkyError>")
    , ("crypto_chacha20_encrypt",  "::<SkyError>")
    , ("crypto_chacha20_decrypt",  "::<SkyError>")
    -- Encoding decoders — single E parameter
    , ("base64_decode",          "::<SkyError>")
    , ("url_decode",             "::<SkyError>")
    , ("encoding_hex_decode",    "::<SkyError>")
    -- JsonDecode primitives — single E parameter
    , ("json_dec_string",        "::<SkyError>")
    , ("json_dec_int",           "::<SkyError>")
    , ("json_dec_float",         "::<SkyError>")
    , ("json_dec_bool",          "::<SkyError>")
    -- JsonDecode null: <E, A: Default>
    , ("json_dec_null",          "::<SkyError, _>")
    -- JsonDecode combinators: <E, T> — pin E, leave T inferred
    , ("json_dec_field",         "::<SkyError, _>")
    , ("json_dec_at",            "::<SkyError, _>")
    , ("json_dec_list",          "::<SkyError, _>")
    , ("json_dec_decode_string", "::<SkyError, _>")
    -- JsonDecode mapping: <E, A, B>
    , ("json_dec_map",           "::<SkyError, _, _>")
    , ("json_dec_and_then",      "::<SkyError, _, _>")
    -- sub-A.11 C1: dict_empty() returns HashMap<String, T>; T defaults to
    -- i64 when call sites (like dict_keys(dict_empty())) can't pin T.
    -- The map is just "turbofish injection"; not all entries are error-pins.
    , ("dict_empty",             "::<i64>")
    ]

-- | Runtime kernels whose Rust signatures are zero-arg functions returning a
-- value (e.g. `pub fn dict_empty<T>() -> HashMap<...>`, `json_dec_int<E>() -> Decoder<E, i64>`).
-- At Can.VarTopLevel call sites the codegen takes the "then" branch and emits
-- the bare kernel name without `()`, leaving the function pointer where a
-- value is expected. This set pins the call.
kernelsZeroArg :: Set.Set String
kernelsZeroArg = Set.fromList
    [ "json_dec_string", "json_dec_int", "json_dec_float"
    , "json_dec_bool", "json_dec_null"
    , "dict_empty"
    , "math_pi", "math_e"
    , "uuid_v4", "uuid_v7"
    -- Sub-E: Cmd.none / Sub.none are zero-arg values (Cmd msg / Sub msg) reached
    -- via the Ffi.kernel alias path -> emitKernel checks this bare-name set.
    , "cmd_none", "sub_none"
    ]

-- | Context threaded through expression emission
data EmitCtx = EmitCtx
    { ecRecordMap :: Map.Map String String  -- field-key -> struct name
    , ecSolvedTypes :: Map.Map String Can.Type  -- function name -> inferred type
    , ecRegionTypes :: Map.Map Ann.Region Can.Type
        -- Sub-A.13: per-region solved type from Sky.Type.Solve._stRegions.
        -- exprToRustString consults this on entry to set ecExpectedType so
        -- empty-literal emit sites (Can.List [], SkyMaybe::Nothing,
        -- SkyResult::Err) can emit turbofish instead of relying on Rust's
        -- local type inference (which can't see through them).
    , ecExpectedType :: Maybe Can.Type
        -- Sub-A.13: type at the current expression's region, looked up from
        -- ecRegionTypes at the top of exprToRustString. Nothing when no entry
        -- exists for the region (the emit sites then fall back to a default).
    , ecInGenericFn :: Bool
        -- Sub-A.13: True while emitting the body of a function that declares
        -- Rust generic params. An empty-literal whose type is not fully
        -- concrete stays BARE inside a generic fn (Rust infers it from the
        -- signature) but is DEFAULTED in a monomorphic fn (Rust can't infer
        -- and there's no generic param to bind — the genuine E0283 case).
    , ecCloneVars :: Set.Set String  -- vars that need .clone() at every use site
    , ecCopyVars  :: Set.Set String  -- vars whose type is Rust Copy (i64, f64, bool, ...)
    , ecPipeInnerType :: Maybe String  -- inner type of piped Task<A>, set by |>
    , ecUsesTaskRun :: Bool  -- user calls Task.run → main returns ()
    , ecZeroArgDefs :: Set.Set (String, String)  -- (modPrefix, name) for zero-arg definitions
    , ecNoCloneVars :: Set.Set String  -- vars whose types don't implement Clone (e.g. Decoder)
    , ecCtorArity :: Map.Map String Int  -- alias name -> field count (for succeed curry wrapping)
    , ecCtorFieldTypes :: Map.Map String [Can.Type]
        -- Sub-A.13: ADT constructor name -> declared field types (from unions).
        -- Lets a ctor call propagate a concrete field type into an empty-
        -- collection argument (e.g. Claims [] where the field is
        -- List (String, Value)) so the arg pins the right element type instead
        -- of falling back to the monomorphic i64 default.
    , ecKernelAliases :: Map.Map (String, String) (String, String)
        -- ^ Stage-4 kernel alias map: (canonicalModuleName, fnName) ->
        --   (kernelMod, kernelFn).  Populated during generateRust from
        --   the same Ffi.kernel dispatch table the Go codegen uses.
    }

-- | Build a map from field-name-signature to struct name
buildRecordMap :: [Can.Module] -> Map.Map String String
buildRecordMap mods = Map.fromList
    [ (intercalate "," (Map.keys fields), toCamelCase (modPrefix ++ "_" ++ name))
    | mod <- mods
    , let modPrefix = moduleNameToRust (Can._name mod)
    , (name, Can.Alias _ (Can.TRecord fields _)) <- Map.toList (Can._aliases mod)
    ]

-- | Anonymous record struct name prefix
anonStructName :: String -> String
anonStructName key = toCamelCase ("Anon_" ++ map (\c -> if c == ',' then '_' else c) key)

-- | Walk all expressions collecting anonymous record field signatures.
-- Returns field-key → [(field-name, HM-inferred-type)] for records NOT
-- covered by type-alias-defined structs.  Skips records with unresolved
-- type variables (TVar) to avoid emitting invalid generic struct fields.
collectAnonRecordTypes :: [Can.Module] -> Map.Map String [String]
collectAnonRecordTypes = foldMap walkMod
  where
    walkMod m = walkDecls (Can._decls m)

    walkDecls Can.SaveTheEnvironment = Map.empty
    walkDecls (Can.Declare def rest) = walkDef def <> walkDecls rest
    walkDecls (Can.DeclareRec def defs rest) = walkDef def <> foldMap walkDef defs <> walkDecls rest

    walkDef (Can.Def _ _ body) = walkExpr body
    walkDef (Can.TypedDef _ _ _ body _) = walkExpr body
    walkDef (Can.DestructDef _ expr) = walkExpr expr

    walkExpr (Ann.At _ expr) = case expr of
        Can.Record fields ->
            let key = intercalate "," (Map.keys fields)
                fieldNames = map fst (Map.toList fields)
            in Map.singleton key fieldNames <> walkFields fields
        _ -> walkSubExprs expr
      where
        walkFields flds = foldMap (\(_, e) -> walkExpr e) (Map.toList flds)

        walkSubExprs e = case e of
            Can.Call fn args -> walkExpr fn <> foldMap walkExpr args
            Can.Lambda _ body -> walkExpr body
            Can.Let def body -> walkDef def <> walkExpr body
            Can.LetRec defs body -> foldMap walkDef defs <> walkExpr body
            Can.LetDestruct _ e0 body -> walkExpr e0 <> walkExpr body
            Can.Case scrut branches -> walkExpr scrut <> foldMap (\(Can.CaseBranch _ b) -> walkExpr b) branches
            Can.If branches elseBranch -> foldMap (\(c, t) -> walkExpr c <> walkExpr t) branches <> walkExpr elseBranch
            Can.Binop _ _ _ _ a b -> walkExpr a <> walkExpr b
            Can.Access r _ -> walkExpr r
            Can.Update _ r updates -> walkExpr r <> foldMap (\(_, Can.FieldUpdate _ e) -> walkExpr e) (Map.toList updates)
            Can.Record _ -> mempty  -- already handled above
            Can.List es -> foldMap walkExpr es
            Can.Tuple a b rest -> foldMap walkExpr (a:b:rest)
            Can.Negate e0 -> walkExpr e0
            _ -> mempty  -- literals, variables: no sub-expressions

buildModule :: EmitCtx -> Can.Module -> RustModule
buildModule ctx mod = 
    let modPrefix = moduleNameToRust (Can._name mod)
        items = declsToRustItems ctx modPrefix (Can._decls mod)
        -- Existing function names after prefixing (to avoid double-emit)
        prefixed = map (\(RustFunction n g p r b) -> toSnakeCase (modPrefix ++ "_" ++ n)) 
                    [ f | f@(RustFunction _ _ _ _ _) <- items ]
        existingNames = Set.fromList prefixed
        -- Synthesize record alias constructors
        synCtorItems = concat [synCtor aliasName vars fields | (aliasName, Can.Alias vars (Can.TRecord fields _)) <- Map.toList (Can._aliases mod)]
        synCtor aliasName vars0 fields =
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
                rustFlds = [(n, typeToRustString rm ft) | (n, Can.FieldType _ ft) <- sortedFields]
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
            | n == "sky_main" || n == "main" = RustFunction n g p r b
            | otherwise = RustFunction (toSnakeCase (modPrefix ++ "_" ++ n)) g p r b
        prefixItem (RustStruct n f) = RustStruct (toCamelCase (modPrefix ++ "_" ++ n)) f
        prefixItem (RustEnum n v) = RustEnum (toCamelCase (modPrefix ++ "_" ++ n)) v
        prefixItem (RustTypeAlias n t) = RustTypeAlias (toCamelCase (modPrefix ++ "_" ++ n)) t
        prefixItem other = other
    in RustModule
        { modName = modPrefix
        , modItems = map prefixItem items ++ synCtorItems
        }

moduleNameToRust :: ModuleName.Canonical -> String
moduleNameToRust mod = 
    map (\c -> if c == '.' then '_' else c) (ModuleName._name mod)

declsToRustItems :: EmitCtx -> String -> Can.Decls -> [RustItem]
declsToRustItems _ctx _mod Can.SaveTheEnvironment = []
declsToRustItems ctx modPrefix (Can.Declare def rest) = defToRustItem ctx modPrefix def : declsToRustItems ctx modPrefix rest
declsToRustItems ctx modPrefix (Can.DeclareRec def defs rest) = 
    map (defToRustItem ctx modPrefix) (def : defs) ++ declsToRustItems ctx modPrefix rest

-- | Walk TLambda chain to extract the innermost (return) type
extractReturnType :: Can.Type -> Can.Type
extractReturnType (Can.TLambda _ ret) = extractReturnType ret
extractReturnType ty = ty

-- | Extract parameter types from a function type (TLambda chain), converting
-- each to a Rust type string.  Returns [] for non-function types.
extractParamTypes :: Can.Type -> [Can.Type]
extractParamTypes (Can.TLambda paramTy restTy) = paramTy : extractParamTypes restTy
extractParamTypes _ = []

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
-- (E0107/E0283). Used where a function's generic-param list is computed.
collectRenderedTVars :: Can.Type -> [String]
collectRenderedTVars t = case t of
    Can.TVar v -> [v]
    Can.TLambda a b -> collectRenderedTVars a ++ collectRenderedTVars b
    Can.TType modName name args
        | Map.member (ModuleName._name modName, name) runtimeOpaqueTypes -> []
        | otherwise -> concatMap collectRenderedTVars args
    Can.TTuple a b rest -> concatMap collectRenderedTVars (a:b:rest)
    Can.TRecord fields _ -> concatMap (collectRenderedTVars . Can._fieldType) (Map.elems fields)
    Can.TAlias modName name pairs _
        | Map.member (ModuleName._name modName, name) runtimeOpaqueTypes -> []
        | otherwise -> concatMap (collectRenderedTVars . snd) pairs
    _ -> []

-- | Simple check: does the body match a parameter with list patterns (cons, list)?
bodyUsesList :: Can.Expr -> Bool
bodyUsesList (Ann.At _ e) = case e of
    Can.Case scrut branches ->
        any (\(Can.CaseBranch pat _) -> isListPat pat) branches
        || any (\(Can.CaseBranch _ body) -> bodyUsesList body) branches
    Can.Let _ body -> bodyUsesList body
    Can.LetRec _ body -> bodyUsesList body
    Can.LetDestruct _ _ body -> bodyUsesList body
    Can.If branches elseBranch -> any (\(_, t) -> bodyUsesList t) branches || bodyUsesList elseBranch
    _ -> False
  where
    isListPat (Ann.At _ p) = case p of
        Can.PCons _ _ -> True
        Can.PList _ -> True
        Can.PAlias pat _ -> isListPat pat
        _ -> False

-- | Does this top-level pattern match a string literal?
hasStrPat :: Can.Pattern -> Bool
hasStrPat (Ann.At _ p) = case p of
    Can.PStr _ -> True
    _ -> False

-- | Collect all (non-wildcard) variable names bound by a pattern.
-- For PCons head bindings these will be &T0; for tail bindings &[T0].
patBindingVars :: Can.Pattern -> [String]
patBindingVars (Ann.At _ pat) = case pat of
    Can.PVar n -> [n]
    Can.PCons a b -> patBindingVars a ++ patBindingVars b
    Can.PList items -> concatMap patBindingVars items
    Can.PAlias inner n -> n : patBindingVars inner
    Can.PTuple a b rest -> concatMap patBindingVars (a:b:rest)
    Can.PCtor{Can._p_args = args} -> concatMap (\(Can.PatternCtorArg _ _ p) -> patBindingVars p) args
    Can.PRecord fields -> fields
    _ -> []

-- | Known signatures for common Def functions (stdlib etc.), keyed by (module_prefix, name, arity)
knownDefSig :: String -> String -> Int -> Maybe ([String], String)
-- List module
knownDefSig p n a | "Sky_Core_List" `isPrefixOf` p = listSig n a
-- Maybe module
knownDefSig p n a | "Sky_Core_Maybe" `isPrefixOf` p = maybeSig n a
-- Error module
knownDefSig p n a | "Sky_Core_Error" `isPrefixOf` p = errorSig n a
knownDefSig p n a | "Sky_Core_Result" `isPrefixOf` p = resultSig n a
knownDefSig p n a | "Sky_Core_String" `isPrefixOf` p = stringSig n a
-- Main module helpers
knownDefSig _ _ _ = Nothing

listSig :: String -> Int -> Maybe ([String], String)
listSig "map" 2 = Just (["impl Fn(T0) -> T1 + Clone", "Vec<T0>"], "Vec<T1>")
-- `filterMap` return T1 doesn't need Clone (Task or other non-Clone types)
listSig "filterMap" 2 = Just (["impl Fn(T0) -> SkyMaybe<T1> + Clone", "Vec<T0>"], "Vec<T1>")
-- `map` with discarded side effects: T1 doesn't need Clone (Task results)
listSig "mapToList" 2 = Just (["impl Fn(T0) -> T1 + Clone", "Vec<T0>"], "Vec<T1>")
-- filter pred takes T0 by value; double-clone in branch prefix + VarLocal clone in body covers the two uses
listSig "filter" 2 = Just (["impl Fn(T0) -> bool + Clone", "Vec<T0>"], "Vec<T0>")
-- Generated body calls r#fn(x, acc) — element first, accumulator second
listSig "foldl" 3 = Just (["impl Fn(T0, T1) -> T1 + Clone", "T1", "Vec<T0>"], "T1")
listSig "foldr" 3 = Just (["impl Fn(T0, T1) -> T1 + Clone", "T1", "Vec<T0>"], "T1")
listSig "cons" 2 = Just (["T0", "Vec<T0>"], "Vec<T0>")
listSig "head" 1 = Just (["Vec<T0>"], "SkyMaybe<T0>")
listSig "tail" 1 = Just (["Vec<T0>"], "SkyMaybe<Vec<T0>>")
listSig "isEmpty" 1 = Just (["Vec<T0>"], "bool")
-- length needs no Clone (just counts elements)
listSig "length" 1 = Just (["Vec<T0>"], "i64")
listSig "reverse" 1 = Just (["Vec<T0>"], "Vec<T0>")
-- reverseHelp list acc = case list of { [] -> acc; x::rest -> reverseHelp rest (x::acc) }
listSig "reverseHelp" 2 = Just (["Vec<T0>", "Vec<T0>"], "Vec<T0>")
listSig "append" 2 = Just (["Vec<T0>", "Vec<T0>"], "Vec<T0>")
-- concat : List (List a) -> List a
listSig "concat" 1 = Just (["Vec<Vec<T0>>"], "Vec<T0>")
listSig "member" 2 = Just (["T0", "Vec<T0>"], "bool")
-- any/all: pred takes T0 by value; Clone required for recursive pass
listSig "any" 2 = Just (["impl Fn(T0) -> bool + Clone", "Vec<T0>"], "bool")
listSig "all" 2 = Just (["impl Fn(T0) -> bool + Clone", "Vec<T0>"], "bool")
-- find pred takes T0 by value; Clone for recursive pass
listSig "find" 2 = Just (["impl Fn(T0) -> bool + Clone", "Vec<T0>"], "SkyMaybe<T0>")
listSig "range" 2 = Just (["i64", "i64"], "Vec<i64>")
listSig "take" 2 = Just (["i64", "Vec<T0>"], "Vec<T0>")
listSig "drop" 2 = Just (["i64", "Vec<T0>"], "Vec<T0>")
listSig "concatMap" 2 = Just (["impl Fn(T0) -> Vec<T1> + Clone", "Vec<T0>"], "Vec<T1>")
-- zip : List a -> List b -> List (a, b)
listSig "zip" 2 = Just (["Vec<T0>", "Vec<T1>"], "Vec<(T0, T1)>")
listSig "indexedMap" 2 = Just (["impl Fn(i64, T0) -> T1 + Clone", "Vec<T0>"], "Vec<T1>")
listSig "indexedMapHelp" 3 = Just (["impl Fn(i64, T0) -> T1 + Clone", "i64", "Vec<T0>"], "Vec<T1>")
listSig _ _ = Nothing

stringSig :: String -> Int -> Maybe ([String], String)
stringSig "fromInt" 1  = Just (["i64"], "String")
stringSig "fromFloat" 1  = Just (["f64"], "String")
stringSig "length" 1  = Just (["String"], "i64")
stringSig "isEmpty" 1  = Just (["String"], "bool")
stringSig "reverse" 1  = Just (["String"], "String")
stringSig "append" 2  = Just (["String", "String"], "String")
stringSig "contains" 2  = Just (["String", "String"], "bool")
stringSig "startsWith" 2 = Just (["String", "String"], "bool")
stringSig "endsWith" 2 = Just (["String", "String"], "bool")
stringSig "toInt" 1  = Just (["String"], "SkyMaybe<i64>")
stringSig "toLower" 1  = Just (["String"], "String")
stringSig "toUpper" 1  = Just (["String"], "String")
stringSig "trim" 1  = Just (["String"], "String")
stringSig "split" 2  = Just (["String", "String"], "Vec<String>")
stringSig "join" 2  = Just (["Vec<String>", "String"], "String")
stringSig "replace" 3 = Just (["String", "String", "String"], "String")
stringSig "slice" 3 = Just (["String", "i64", "i64"], "String")
stringSig _ _ = Nothing

maybeSig :: String -> Int -> Maybe ([String], String)
maybeSig "map" 2 = Just (["impl Fn(T0) -> T1 + Clone", "SkyMaybe<T0>"], "SkyMaybe<T1>")
maybeSig "andThen" 2 = Just (["impl Fn(T0) -> SkyMaybe<T1> + Clone", "SkyMaybe<T0>"], "SkyMaybe<T1>")
maybeSig "withDefault" 2 = Just (["T0", "SkyMaybe<T0>"], "T0")
maybeSig "map2" 3 = Just (["impl Fn(T0, T1) -> T2 + Clone", "SkyMaybe<T0>", "SkyMaybe<T1>"], "SkyMaybe<T2>")
maybeSig "map3" 4 = Just (["impl Fn(T0, T1, T2) -> T3 + Clone", "SkyMaybe<T0>", "SkyMaybe<T1>", "SkyMaybe<T2>"], "SkyMaybe<T3>")
maybeSig "map4" 5 = Just (["impl Fn(T0, T1, T2, T3) -> T4 + Clone", "SkyMaybe<T0>", "SkyMaybe<T1>", "SkyMaybe<T2>", "SkyMaybe<T3>"], "SkyMaybe<T4>")
maybeSig "map5" 6 = Just (["impl Fn(T0, T1, T2, T3, T4) -> T5 + Clone", "SkyMaybe<T0>", "SkyMaybe<T1>", "SkyMaybe<T2>", "SkyMaybe<T3>", "SkyMaybe<T4>"], "SkyMaybe<T5>")
maybeSig "andMap" 2 = Just (["SkyMaybe<T0>", "SkyMaybe<impl Fn(T0) -> T1 + Clone>"], "SkyMaybe<T1>")
maybeSig "isJust" 1 = Just (["SkyMaybe<T0>"], "bool")
maybeSig "isNothing" 1 = Just (["SkyMaybe<T0>"], "bool")
-- combine : List (Maybe a) -> Maybe (List a)
maybeSig "combine" 1 = Just (["Vec<SkyMaybe<T0>>"], "SkyMaybe<Vec<T0>>")
maybeSig _ _ = Nothing

resultSig :: String -> Int -> Maybe ([String], String)
resultSig "map" 2 = Just (["impl Fn(T0) -> T1 + Clone", "SkyResult<SkyError, T0>"], "SkyResult<SkyError, T1>")
resultSig "andThen" 2 = Just (["impl Fn(T0) -> SkyResult<SkyError, T1> + Clone", "SkyResult<SkyError, T0>"], "SkyResult<SkyError, T1>")
-- sub-A.12 F1: Sky source `mapError : (e -> e2) -> Result e a -> Result e2 a`
-- is fully polymorphic in BOTH error types. Previously hardcoded as
-- (SkyError -> String) which mis-typed wrapper calls — the closure may
-- well return Error not String. Use T1/T2 for the error transform.
resultSig "mapError" 2 = Just (["impl Fn(T1) -> T2 + Clone", "SkyResult<T1, T0>"], "SkyResult<T2, T0>")
resultSig "withDefault" 2 = Just (["T0", "SkyResult<SkyError, T0>"], "T0")
resultSig "map2" 3 = Just (["impl Fn(T0, T1) -> T2 + Clone", "SkyResult<SkyError, T0>", "SkyResult<SkyError, T1>"], "SkyResult<SkyError, T2>")
resultSig "map3" 4 = Just (["impl Fn(T0, T1, T2) -> T3 + Clone", "SkyResult<SkyError, T0>", "SkyResult<SkyError, T1>", "SkyResult<SkyError, T2>"], "SkyResult<SkyError, T3>")
resultSig "map4" 5 = Just (["impl Fn(T0, T1, T2, T3) -> T4 + Clone", "SkyResult<SkyError, T0>", "SkyResult<SkyError, T1>", "SkyResult<SkyError, T2>", "SkyResult<SkyError, T3>"], "SkyResult<SkyError, T4>")
resultSig "map5" 6 = Just (["impl Fn(T0, T1, T2, T3, T4) -> T5 + Clone", "SkyResult<SkyError, T0>", "SkyResult<SkyError, T1>", "SkyResult<SkyError, T2>", "SkyResult<SkyError, T3>", "SkyResult<SkyError, T4>"], "SkyResult<SkyError, T5>")
resultSig "andMap" 2 = Just (["SkyResult<SkyError, T0>", "SkyResult<SkyError, impl Fn(T0) -> T1 + Clone>"], "SkyResult<SkyError, T1>")
resultSig "combine" 1 = Just (["Vec<SkyResult<SkyError, T0>>"], "SkyResult<SkyError, Vec<T0>>")
resultSig "traverse" 2 = Just (["impl Fn(T0) -> SkyResult<SkyError, T1> + Clone", "Vec<T0>"], "SkyResult<SkyError, Vec<T1>>")
resultSig _ _ = Nothing

errorSig :: String -> Int -> Maybe ([String], String)
errorSig "mkInfo" 1 = Just (["String"], "SkyError")
errorSig "io" 1 = Just (["String"], "SkyError")
errorSig "network" 1 = Just (["String"], "SkyError")
errorSig "ffi" 1 = Just (["String"], "SkyError")
errorSig "decode" 1 = Just (["String"], "SkyError")
errorSig "timeout" 0 = Just ([], "SkyError")
errorSig "notFound" 0 = Just ([], "SkyError")
errorSig "permissionDenied" 0 = Just ([], "SkyError")
errorSig "invalidInput" 1 = Just (["String"], "SkyError")
errorSig "conflict" 1 = Just (["String"], "SkyError")
errorSig "unavailable" 1 = Just (["String"], "SkyError")
errorSig "unexpected" 1 = Just (["String"], "SkyError")
errorSig "withMessage" 2 = Just (["String", "SkyError"], "SkyError")
errorSig "withDetails" 2 = Just ([toCamelCase "Sky_Core_Error_ErrorDetails", "SkyError"], "SkyError")
errorSig "kindLabel" 1 = Just ([toCamelCase "Sky_Core_Error_ErrorKind"], "String")
errorSig "toString" 1 = Just (["SkyError"], "String")
errorSig "isRetryable" 1 = Just (["SkyError"], "bool")
errorSig _ _ = Nothing

-- | Extract type variable names (T0, T1, …) from parameter and return type strings.
-- Works for any nesting depth: Vec<Vec<T0>>, Vec<(T0,T1)>, SkyMaybe<Vec<T0>>, etc.
sigTVars :: [String] -> String -> [String]
sigTVars paramTypes retType =
    Set.toList $ Set.fromList $ concatMap scanTVars (paramTypes ++ [retType])

-- | Scan a type string for all Tnn identifiers (T0, T1, T10, …).
scanTVars :: String -> [String]
scanTVars [] = []
scanTVars ('T':rest)
    | not (null digits) && (null after || not (isIdentChar (head after))) =
        ('T':digits) : scanTVars after
  where
    digits = takeWhile isDigit rest
    after  = dropWhile isDigit rest
    isDigit c = c >= '0' && c <= '9'
    isIdentChar c = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || isDigit c || c == '_'
scanTVars (_:rest) = scanTVars rest

defToRustItem :: EmitCtx -> String -> Can.Def -> RustItem
defToRustItem ctx modPrefix (Can.Def (Ann.At _ name) params body) = 
    let rustName = if name == "main" then "sky_main" else name
        n = length params
        (paramStrs, genVars) =
            -- Try solvedTypes FIRST (HM-inferred types, most accurate).
            -- Falls through to knownDefSig (stdlib overrides) then body analysis.
            let solvedParamTys = case Map.lookup name (ecSolvedTypes ctx) of
                    Just ty -> extractParamTypes ty
                    Nothing -> []
            -- Only use solved types when they're fully concrete (no TVars).
            -- Polymorphic functions still route through knownDefSig for
            -- proper generic bounds like `T0: Clone`.
            in if length solvedParamTys == length params
                  && all (not . hasTypeVars) solvedParamTys
               then -- Use solved types (all concrete, no TVars)
                    let rm = ecRecordMap ctx
                        argTriples = zipWith3
                            (\i p t -> let (nm, pre) = patternToRustArg i p
                                       in (nm ++ ": " ++ typeToRustString rm t, pre))
                            [0..] params solvedParamTys
                        pStrs = map fst argTriples
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
                       -- Fallback: body analysis
                       let counts = collectVarLocalsMulti body
                           paramNames = [ n | Ann.At _ (Can.PVar n) <- params ]
                           anyCloneNeeded = any (\n -> Map.lookup n counts >= Just 2) paramNames
                               || bodyUsesList body
                           useVec = bodyUsesList body
                           pStrs = map (\(i, p) ->
                               let tn = "T" ++ show i
                                   (nm, _pre) = patternToRustArg i p
                               in nm ++ ": " ++ (if useVec then "Vec<" ++ tn ++ ">" else "String")
                               ) (zip [0..] params)
                           genList = if anyCloneNeeded
                                     then map (\i -> "T" ++ show i ++ ": Clone") [0..length params - 1]
                                     else []
                           gs = if null genList then "" else "<" ++ intercalate ", " genList ++ ">"
                       in (pStrs, gs)
        retTy = case Map.lookup name (ecSolvedTypes ctx) of
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
                                Nothing -> if name == "main"
                                           then if ecUsesTaskRun ctx then "()" else "SkyTask<()>"
                                           else "()"
                            else "SkyTask<" ++ bodyInner ++ ">"
        -- Track multi-use variables in the function body so they get
        -- cloned at each function-call argument site (ownership safety).
        multiBody = collectVarLocalsMulti body
        multiVars = [ v | (v, c) <- Map.toList multiBody, c >= 2 ]
        -- Step 4: skip .clone() for params whose type is Rust Copy (i64, f64, bool, ...)
        paramNames = [ n | Ann.At _ (Can.PVar n) <- params ]
        paramTys = case Map.lookup name (ecSolvedTypes ctx) of
            Just ty -> extractParamTypes ty
            Nothing -> []
        copyVars = Set.fromList
            [ n | (n, t) <- zip paramNames paramTys
            , not (hasTypeVars t) && isCanTypeCopy t ]
        ctx' = ctx { ecCloneVars = Set.fromList multiVars
                   , ecCopyVars = copyVars
                   , ecInGenericFn = not (null genVars) }  -- Sub-A.13
        bodyStr = exprToRustString ctx' body
        -- Collect destructure preludes for non-trivial pattern args. The
        -- prelude is `let <Pattern> = __pN else { unreachable!() };` per
        -- patternToRustArg. Empty for PVar/PAnything/PTuple params.
        preludes = concat [ snd (patternToRustArg i p) | (i, p) <- zip [0..] params ]
        -- S6: When the function returns SkyTask<T> but the body tail is a
        -- bare value (not already a Task expression), wrap in task_succeed({...}).
        -- Walk through let chains to find the tail expression, then check
        -- whether the tail is already a Task expression.
        bodyWrapped = if "SkyTask<" `isPrefixOf` retTy && needsTaskWrap (ecSolvedTypes ctx) body
                      then "task_succeed({ " ++ bodyStr ++ " })"
                      else bodyStr
     in RustFunction rustName genVars paramStrs retTy (preludes ++ bodyWrapped)
defToRustItem ctx _modPrefix (Can.TypedDef (Ann.At _ name) _ pats body retTy) =
    let rm = ecRecordMap ctx
        rustName = if name == "main" then "sky_main" else name
        argTriples = zipWith
            (\i (pat, ty) -> let (nm, pre) = patternToRustArg i pat
                             in (nm ++ ": " ++ typeToRustString rm ty, pre))
            [0..] pats
        params = map fst argTriples
        preludes = concatMap snd argTriples
        -- `main : Task Error ()` lowers to `sky_main() -> SkyTask<()>` so the
        -- entry can `block_on` it. Only when the program calls `Task.run` itself
        -- (main returns ()) does sky_main return unit. Hardcoding "()" here
        -- dropped the task — composed (`andThen`) mains never ran.
        ret = if name == "main"
              then if ecUsesTaskRun ctx then "()" else typeToRustString rm retTy
              else typeToRustString rm retTy
        -- Collect type variable names from annotation types, emit as generic params
        allAnnotTys = map snd pats ++ [retTy | name /= "main"]
        -- collectRenderedTVars (not collectTVars): a var that appears only inside
        -- a runtimeOpaque type's dropped args (e.g. `msg` in WebSocketServerCfg
        -- msg) must NOT become a function generic — it'd be unused in the Rust
        -- sig (E0107 on the return type / E0283 at call sites).
        tvarNames = nub [ v | t <- allAnnotTys, v <- collectRenderedTVars t ]
        genDecl = if null tvarNames then ""
                  else "<" ++ intercalate ", " (map (\v -> v ++ ": Clone + PartialEq + std::fmt::Debug + Send + 'static") tvarNames) ++ ">"
        multiBody = collectVarLocalsMulti body
        multiVars = [ v | (v, c) <- Map.toList multiBody, c >= 2 ]
        ctx' = ctx { ecCloneVars = Set.fromList multiVars, ecCopyVars = ecCopyVars ctx
                   , ecInGenericFn = not (null tvarNames) }  -- Sub-A.13
    in RustFunction rustName genDecl params ret (preludes ++ exprToRustString ctx' body)
defToRustItem ctx modPrefix (Can.DestructDef pat expr) =
    let vars = intercalate "_" (patBindingVars pat)
        fnName = if null vars then "__destruct" else "__destruct_" ++ vars
    in RustFunction fnName "" [patternToRustParam pat] "()" (exprToRustString ctx expr)

-- | Lower a Sky return type that may contain TVars to a Rust type string,
-- generating fresh generic parameters for unresolved TVars.
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

-- | Infer the return type of a function whose body is a constructor call
-- (Ok x, Err e, Just y, Nothing, ::, etc.) by inspecting the constructor
-- and the types of its arguments via solveArgType.
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

-- | Is a Can.Type a Rust `Copy` type?  When true, the codegen should
-- skip `.clone()` even if the variable is used ≥ 2 times, because
-- `Copy` types are cheap to copy and Rust's borrow checker doesn't
-- require explicit `.clone()` for them.
isCanTypeCopy :: Can.Type -> Bool
isCanTypeCopy Can.TUnit                          = True
isCanTypeCopy (Can.TType _ "Int" [])             = True
isCanTypeCopy (Can.TType _ "Float" [])           = True
isCanTypeCopy (Can.TType _ "Bool" [])            = True
isCanTypeCopy (Can.TType _ "Char" [])            = True
isCanTypeCopy _                                   = False

-- | Walk through let chains to find the tail expression.
tailExpr :: Can.Expr -> Can.Expr
tailExpr (Ann.At _ (Can.Let _ b))         = tailExpr b
tailExpr (Ann.At _ (Can.LetRec _ b))      = tailExpr b
tailExpr (Ann.At _ (Can.LetDestruct _ _ b)) = tailExpr b
tailExpr e                                = e

-- | Does the body need a task_succeed(...) wrap? True when the tail
-- expression is a bare value (not already a Task expression).
-- Uses solved types to check if known bindings have Task type.
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

-- | `skyModName` is the un-mangled Sky module name (dots preserved, e.g.
-- "Std.Decimal") used to look up the runtimeOpaqueTypes registry.
-- `modPrefix` is the mangled form (dots -> underscores) used in the
-- generated Rust type name.
unionsToRustTypes :: Map.Map String String -> String -> String -> Map.Map String Can.Union -> [RustTypeDef]
unionsToRustTypes recordMap skyModName modPrefix unions =
    -- The opaque `Decoder a` from Sky.Core.Json.Decode AND Std.Config is the
    -- runtime json::Decoder (rendered via the global `Decoder<T>` alias by
    -- typeToRustString). Its Sky def is a phantom (`type Decoder a` with a unit
    -- placeholder), so emitting it as a Rust enum yields `pub enum Decoder<a> {
    -- Decoder }` — an unused type param a (E0392). Skip it; the alias covers all
    -- references and the combinators route to json_dec_* / config_* kernels.
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
               else "<" ++ intercalate ", " uvars ++ ">"
    in case Map.lookup (skyModName, typeName) runtimeOpaqueTypes of
        -- Registry hit: emit a `pub use sky_runtime::X as <codegenName>;` alias.
        -- The runtime newtype IS the canonical representation; the Sky-side
        -- placeholder constructor (e.g. `Decimal__Internal Float`) is a
        -- phantom-shape that exists only so the Sky type has a slot.
        Just rustPath -> RPubUseAlias codegenName rustPath
        -- No registry entry: emit the regular enum/ADT (one constructor per alt).
        Nothing       -> REnumDef codegenName gens (map ctorToRust alts)
  where
    ctorToRust (Can.Ctor name _idx _arity argTypes) =
        (name, if null argTypes then Nothing
               else Just (intercalate ", " (map (typeToRustString recordMap) argTypes)))

aliasesToRustTypes :: Map.Map String String -> String -> String -> Map.Map String Can.Alias -> [RustTypeDef]
aliasesToRustTypes recordMap skyModName modPrefix aliases = concatMap (\(name, alias) -> aliasToRustTypeDef recordMap skyModName modPrefix name alias) (Map.toList aliases)

-- | Sort record fields by their declaration index (_fieldIndex)
sortFieldsByIndex :: [(String, Can.FieldType)] -> [(String, Can.FieldType)]
sortFieldsByIndex = sortBy (\(_, Can.FieldType i _) (_, Can.FieldType j _) -> compare i j)

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
            gens = if null vars then "" else "<" ++ intercalate ", " vars ++ ">"
        in [RStructDef (toCamelCase (modPrefix ++ "_" ++ name)) gens (map (\(n, Can.FieldType _ ft) -> (n, typeToRustString recordMap ft)) sortedFields)]
    _ ->
        [RAliasDef (toCamelCase (modPrefix ++ "_" ++ name)) (typeToRustString recordMap ty)]

-- | Flatten a curried arrow type `A -> B -> C` into ([A, B], C) so it renders
-- as an uncurried Rust fn pointer. Mirrors the codegen's uncurried lambda/call
-- convention.
flattenArrowType :: Can.Type -> ([Can.Type], Can.Type)
flattenArrowType (Can.TLambda a b) = let (ps, r) = flattenArrowType b in (a : ps, r)
flattenArrowType ty = ([], ty)

typeToRustString :: Map.Map String String -> Can.Type -> String
typeToRustString recordMap t = case t of
    Can.TType modName "Int" [] -> "i64"
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
    -- (`cfgDecoder : Config.Decoder DbCfg`) matches the json_dec_* / config_*
    -- kernels its call sites route to. The placeholder enum is skipped at the
    -- def site (see the Decoder guard in the union emitter).
    Can.TType _ "Decoder" [a] -> "Decoder<" ++ typeToRustString recordMap a ++ ">"
    Can.TUnit -> "()"
    Can.TType _ "List" [a] -> "Vec<" ++ typeToRustString recordMap a ++ ">"
    Can.TType _ "Maybe" [a] -> "SkyMaybe<" ++ typeToRustString recordMap a ++ ">"
    Can.TType _ "Dict" [k, v] -> "HashMap<" ++ typeToRustString recordMap k ++ ", " ++ typeToRustString recordMap v ++ ">"
    Can.TType _ "Result" [e, a] -> "SkyResult<" ++ typeToRustString recordMap e ++ ", " ++ typeToRustString recordMap a ++ ">"
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
                Nothing -> "String"
            -- Anonymous record structs have generic type params (T0..Tn).
            -- Fill them from the TRecord's actual field types so references
            -- like `AnonXxx<String, i64, bool>` compile correctly.
            gens = if "Anon" `isPrefixOf` structName
                   then let sorted = sortFieldsByIndex (Map.toList fields)
                        in "<" ++ intercalate ", " [typeToRustString recordMap (Can._fieldType ft) | (_, ft) <- sorted] ++ ">"
                   else ""
        in structName ++ gens
    Can.TTuple a b rest -> "(" ++ intercalate ", " (map (typeToRustString recordMap) (a:b:rest)) ++ ")"
    Can.TVar v -> v
    Can.TType modName name [] ->
        let modStr = ModuleName._name modName
            modPrefix = if null modStr then "" else map (\c -> if c == '.' then '_' else c) modStr ++ "_"
        in toCamelCase (modPrefix ++ name)
    Can.TType modName name args ->
        let modStr = ModuleName._name modName
            modPrefix = if null modStr then "" else map (\c -> if c == '.' then '_' else c) modStr ++ "_"
        -- A registered runtimeOpaque type renders to its non-generic codegen
        -- alias (its generics are pinned in the registry value, e.g.
        -- WsServerCfg<SkyError>); drop the Sky args.
        in if Map.member (modStr, name) runtimeOpaqueTypes
           then toCamelCase (modPrefix ++ name)
           else toCamelCase (modPrefix ++ name) ++ "<" ++ intercalate ", " (map (typeToRustString recordMap) args) ++ ">"
    -- A curried Sky arrow chain (A -> B -> C) renders as an UNCURRIED Rust fn
    -- pointer fn(A, B) -> C, matching how the codegen lowers multi-arg lambda
    -- VALUES (`\a b ->` -> |a, b|) and multi-arg CALLS (`f a b` -> f(a, b)).
    -- Rendering it curried (fn(A) -> fn(B) -> C) was latent-broken: any
    -- multi-arg function-typed param/field mismatched its uncurried value.
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
        -- runtimeOpaque alias: non-generic (generics pinned in its def); drop args.
        in if Map.member (modStr, name) runtimeOpaqueTypes then base
           else if null args then base
           else base ++ "<" ++ intercalate ", " (map (typeToRustString recordMap) args) ++ ">"
    _ -> "String"

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

isWildcard :: Can.Pattern -> Bool
isWildcard (Ann.At _ Can.PAnything) = True
isWildcard _ = False

patternToRustParam :: Can.Pattern -> String
patternToRustParam (Ann.At _ pat) = case pat of
    Can.PVar n -> rustSafeIdent n
    Can.PAnything -> "_"
    Can.PTuple a b rest ->
        "(" ++ intercalate ", " (map patternToRustParam (a:b:rest)) ++ ")"
    _ -> "_"

-- | Emit a Rust pattern syntax that destructures a value of the
-- corresponding Sky type. Used by `patternToRustArg` when a function
-- parameter is a non-trivial pattern (e.g. PCtor) and the body needs
-- the bound variables in scope.
patternToRustPattern :: Can.Pattern -> String
patternToRustPattern (Ann.At _ pat) = case pat of
    Can.PVar n        -> rustSafeIdent n
    Can.PAnything     -> "_"
    Can.PTuple a b rest ->
        "(" ++ intercalate ", " (map patternToRustPattern (a:b:rest)) ++ ")"
    Can.PCtor{Can._p_home = mod', Can._p_type = ty, Can._p_name = ctor, Can._p_args = args} ->
        let modName = ModuleName._name mod'
            modPrefix' = map (\c -> if c == '.' then '_' else c) modName
            enumName = toCamelCase (modPrefix' ++ "_" ++ ty)
            argStrs = map (\(Can.PatternCtorArg _ _ p) -> patternToRustPattern p) args
            argsRendered = if null argStrs then "" else "(" ++ intercalate ", " argStrs ++ ")"
        in enumName ++ "::" ++ ctor ++ argsRendered
    _ -> "_"

-- | Decompose a pattern function-argument into:
--   (rustParamName, prelude)
-- where `prelude` is a `let-else` statement to be prepended to the
-- function body, binding the pattern's variables in scope. Trivial
-- patterns (PVar / PAnything / PTuple) get an empty prelude — the
-- pattern itself is the rustParamName. Non-trivial patterns (PCtor)
-- get a synthesised `__pN` parameter and a destructure prelude.
--
-- Rust's `let <pattern> = <expr> else { unreachable!() };` accepts both
-- irrefutable and refutable patterns; the else branch is dead code when
-- the pattern is irrefutable (single-variant enum), and dead by
-- exhaustiveness when the pattern is refutable (the Sky type-checker
-- already proved this on the calling side).
patternToRustArg :: Int -> Can.Pattern -> (String, String)
patternToRustArg _ pat@(Ann.At _ (Can.PVar _))       = (patternToRustParam pat, "")
patternToRustArg _ pat@(Ann.At _ Can.PAnything)      = (patternToRustParam pat, "")
patternToRustArg _ pat@(Ann.At _ (Can.PTuple _ _ _)) = (patternToRustParam pat, "")
patternToRustArg idx pat =
    let paramName = "__p" ++ show idx
        rustPat = patternToRustPattern pat
        prelude = "let " ++ rustPat ++ " = " ++ paramName ++ " else { unreachable!() }; "
    in (paramName, prelude)

-- | Walk an expression and collect VarLocal names, counting occurrences.
-- Used to decide which variables need .clone() (those used ≥ 2 times).
-- | Substitute every VarLocal matching a name with an inline string
-- (e.g. `vec![...]`).  Handles common expression forms.  The println
-- special case (Log.println → log_info) is mirrored from exprToRustInner.
substVar :: EmitCtx -> String -> String -> Can.Expr -> String
substVar ctx name inline = go
  where
    go e@(Ann.At _ expr) = case expr of
        Can.VarLocal n | n == name -> inline
        Can.VarLocal n -> rustSafeIdent n ++ if n `Set.member` ecCloneVars ctx && not (n `Set.member` ecCopyVars ctx) then ".clone()" else ""
        Can.VarTopLevel mod n ->
            let modName = ModuleName._name mod
                modPrefix = map (\c -> if c == '.' then '_' else c) modName
                fnName = toSnakeCase (modPrefix ++ "_" ++ n)
                -- Check kernel aliases so VarTopLevel routes through kernel dispatch
                kernelName = kernelToRust modName n
            in if fnName /= kernelName && not ("ffi_kernel" `isPrefixOf` kernelName)
               then kernelName
               else case Map.lookup (modName, n) (ecKernelAliases ctx) of
                    Just (kMod, kFn) -> kernelToRust kMod kFn
                    Nothing -> if Set.member (modPrefix, n) (ecZeroArgDefs ctx) then fnName ++ "()" else fnName
        Can.VarKernel mod n ->
            let fnName = kernelToRust mod n
            in if Set.member (mod, n) (ecZeroArgDefs ctx) then fnName ++ "()" else fnName
        Can.VarCtor _ mn tn cn _ -> kernelCtorToRust mn tn cn
        Can.Chr [c] -> rustCharLit c
        Can.Chr s -> rustStringLit s  -- multi-char or empty: fall back to string
        Can.Str s -> rustStringLit s ++ ".to_string()"
        Can.Int i -> show i
        Can.Float f -> show f
        Can.Unit -> "()"
        Can.List es -> "vec![" ++ intercalate ", " (map go es) ++ "]"
        Can.Negate e -> "-" ++ go e
        Can.Lambda params body ->
            "|" ++ intercalate ", " (map patternToRustParam params) ++ "| { " ++ go body ++ " }"
        Can.Call fn args ->
            let fs = go fn
                isPrintln = "println" `isSuffixOf` fs
            in if isPrintln
               then "log_info(" ++ intercalate " ++ \" \" ++ " (map go args) ++ ")"
               else let noClone = case fn of
                            Ann.At _ (Can.VarKernel _ n2) -> n2 == "run" || n2 == "sequence" || n2 == "parallel"
                            _ -> False
                        as = map (\a -> case a of
                             Ann.At _ (Can.VarLocal n2) | n2 == name -> inline
                             Ann.At _ (Can.VarLocal n2) | noClone -> rustSafeIdent n2
                             Ann.At _ (Can.VarLocal n2) ->
                                 (let needClone = Set.member n2 (ecCloneVars ctx) && not (Set.member n2 (ecCopyVars ctx))
                                  in if needClone then rustSafeIdent n2 ++ ".clone()" else rustSafeIdent n2)
                             _ -> go a) args
                    in fs ++ "(" ++ intercalate ", " as ++ ")"
        Can.Let def body -> goDef def ++ go body
          where
            goDef (Can.Def (Ann.At _ n) [] dBody) = "let " ++ n ++ " = " ++ go dBody ++ "; "
            goDef (Can.Def (Ann.At _ n) ps dBody) = "let " ++ n ++ " = |" ++ intercalate ", " (map patternToRustParam ps) ++ "| { " ++ go dBody ++ " }; "
            goDef _ = error "Builder.Rust.substVar.goDef: unsupported Can.Def variant"
        Can.LetRec defs body ->
            let strs = map (\(Can.Def (Ann.At _ n) ps d) -> n ++ " = |" ++ intercalate ", " (map patternToRustParam ps) ++ "| { " ++ go d ++ " }") defs
            in "let mut " ++ intercalate "; let mut " strs ++ "; " ++ go body
        Can.LetDestruct pat e0 body ->
            "let " ++ patternToMatchString (ecRecordMap ctx) pat ++ " = " ++ go e0 ++ "; " ++ go body
        Can.Case scrut branches ->
            "match " ++ go scrut ++ " { " ++ intercalate ", " (map (\(Can.CaseBranch p b) -> patternToMatchString (ecRecordMap ctx) p ++ " => " ++ go b) branches) ++ " }"
        Can.If [] elseExpr -> go elseExpr
        Can.If ((c,t):rest) elseExpr ->
            "if " ++ go c ++ " { " ++ go t ++ " }"
            ++ concatMap (\(c2,t2) -> " else if " ++ go c2 ++ " { " ++ go t2 ++ " }") rest
            ++ " else { " ++ go elseExpr ++ " }"
        Can.Binop op _ _ _ a b
            | op == "|>" -> go b ++ "(" ++ go a ++ ")"
            | op == "<|" -> go a ++ "(" ++ go b ++ ")"
            | op == "::" -> "sky_list_cons(" ++ go a ++ ", " ++ go b ++ ")"
            | op == "++" -> "format!(\"{}{}\", " ++ go a ++ ", " ++ go b ++ ")"
            | otherwise -> "(" ++ go a ++ " " ++ binopToRust op ++ " " ++ go b ++ ")"
        -- Uncommon expression forms — fall back to normal emission
        Can.Record _ -> exprToRustString ctx e
        Can.Tuple _ _ _ -> exprToRustString ctx e
        Can.Access _ _ -> exprToRustString ctx e
        Can.Accessor _ -> exprToRustString ctx e
        Can.Update _ _ _ -> exprToRustString ctx e

collectVarLocalsMulti :: Can.Expr -> Map.Map String Int
collectVarLocalsMulti = go Set.empty
  where
    go bound (Ann.At _ expr) = case expr of
        Can.VarLocal n | n `Set.notMember` bound -> Map.singleton n 1
        Can.VarLocal _ -> Map.empty
        Can.Call fn args -> Map.unionsWith (+) (go bound fn : map (go bound) args)
        Can.Lambda params body ->
            let bound' = foldl (\s p -> foldr Set.insert s (patBindingVars p)) bound params
            in go bound' body
        Can.Let (Can.Def _ _ defBody) body ->
            Map.unionWith (+) (go bound defBody) (go bound body)
        Can.LetRec defs body ->
            let goDefs = foldl (\a (Can.Def _ _ d) -> Map.unionWith (+) a (go bound d)) Map.empty defs
            in Map.unionWith (+) (go bound body) goDefs
        Can.LetDestruct pat expr body ->
            Map.unionWith (+) (go bound expr) (go bound body)
        -- Sub-D: count the scrutinee too. A var used in a case scrutinee
        -- (e.g. `case f key of …`) AND again elsewhere must be marked multi-use
        -- so it gets cloned at the first use — otherwise it's moved and the
        -- second use fails (E0382). The scrutinee was previously ignored.
        Can.Case scrut branches -> foldl (\a (Can.CaseBranch _ b) ->
            Map.unionWith (+) a (go bound b)) (go bound scrut) branches
        Can.If branches elseBranch ->
            foldl (\a (c, t) -> Map.unionWith (+) a (Map.unionWith (+) (go bound c) (go bound t))) (go bound elseBranch) branches
        Can.Binop _ _ _ _ a b -> Map.unionWith (+) (go bound a) (go bound b)
        Can.Access r _ -> go bound r
        Can.Update _ r updates -> Map.unionWith (+) (go bound r) (foldl (\a (_, Can.FieldUpdate _ e) -> Map.unionWith (+) a (go bound e)) Map.empty (Map.toList updates))
        Can.Record fields -> foldl (\a (_, v) -> Map.unionWith (+) a (go bound v)) Map.empty (Map.toList fields)
        Can.List es -> foldl (\a e -> Map.unionWith (+) a (go bound e)) Map.empty es
        Can.Tuple a b rest -> foldl (\a e -> Map.unionWith (+) a (go bound e)) Map.empty (a:b:rest)
        Can.Negate e -> go bound e
        Can.Accessor _ -> Map.empty
        Can.VarTopLevel _ _ -> Map.empty
        Can.VarKernel _ _ -> Map.empty
        Can.VarCtor _ _ _ _ _ -> Map.empty
        Can.Chr _ -> Map.empty
        Can.Str _ -> Map.empty
        Can.Int _ -> Map.empty
        Can.Float _ -> Map.empty
        Can.Unit -> Map.empty

-- | Like collectVarLocalsMulti but counts ONLY variables that are FREE in the
-- expression — every binder (case patterns, let names, lambda params, destructs)
-- is added to `bound`, so inner-bound vars are excluded. Used by the clone
-- PRELUDE in defToRustString, which must clone only outer-captured vars; a
-- case-pattern var like `Ok parsed -> …parsed…parsed…` is bound inside the body,
-- so it must NOT get a `let parsed = parsed.clone();` prelude (it isn't in scope
-- there — E0425). Use-site cloning of such vars is handled separately via
-- ecCloneVars (which intentionally still counts them).
collectFreeVarLocalsMulti :: Can.Expr -> Map.Map String Int
collectFreeVarLocalsMulti = go Set.empty
  where
    go bound (Ann.At _ expr) = case expr of
        Can.VarLocal n | n `Set.notMember` bound -> Map.singleton n 1
        Can.VarLocal _ -> Map.empty
        Can.Call fn args -> Map.unionsWith (+) (go bound fn : map (go bound) args)
        Can.Lambda params body ->
            let bound' = foldl (\s p -> foldr Set.insert s (patBindingVars p)) bound params
            in go bound' body
        Can.Let (Can.Def (Ann.At _ n) _ defBody) body ->
            Map.unionWith (+) (go bound defBody) (go (Set.insert n bound) body)
        Can.LetRec defs body ->
            let names = [ n | Can.Def (Ann.At _ n) _ _ <- defs ]
                bound' = foldr Set.insert bound names
                goDefs = foldl (\a (Can.Def _ _ d) -> Map.unionWith (+) a (go bound' d)) Map.empty defs
            in Map.unionWith (+) (go bound' body) goDefs
        Can.LetDestruct pat e0 body ->
            let bound' = foldr Set.insert bound (patBindingVars pat)
            in Map.unionWith (+) (go bound e0) (go bound' body)
        Can.Case scrut branches -> foldl (\a (Can.CaseBranch pat b) ->
            let bound' = foldr Set.insert bound (patBindingVars pat)
            in Map.unionWith (+) a (go bound' b)) (go bound scrut) branches
        Can.If branches elseBranch ->
            foldl (\a (c, t) -> Map.unionWith (+) a (Map.unionWith (+) (go bound c) (go bound t))) (go bound elseBranch) branches
        Can.Binop _ _ _ _ a b -> Map.unionWith (+) (go bound a) (go bound b)
        Can.Access r _ -> go bound r
        Can.Update _ r updates -> Map.unionWith (+) (go bound r) (foldl (\a (_, Can.FieldUpdate _ e) -> Map.unionWith (+) a (go bound e)) Map.empty (Map.toList updates))
        Can.Record fields -> foldl (\a (_, v) -> Map.unionWith (+) a (go bound v)) Map.empty (Map.toList fields)
        Can.List es -> foldl (\a e -> Map.unionWith (+) a (go bound e)) Map.empty es
        Can.Tuple a b rest -> foldl (\acc e -> Map.unionWith (+) acc (go bound e)) Map.empty (a:b:rest)
        Can.Negate e -> go bound e
        _ -> Map.empty

-- | Walk an expression and collect VarLocal names that refer to variables
-- from ENCLOSING scopes (not bound within the expression itself).
-- Used to insert .clone() calls for ownership-safe closure capture.
collectVarLocals :: Can.Expr -> Set.Set String
collectVarLocals = go Set.empty
  where
    go :: Set.Set String -> Can.Expr -> Set.Set String
    go bound (Ann.At _ expr) = case expr of
        Can.VarLocal n | n `Set.notMember` bound -> Set.singleton n
        Can.VarLocal _ -> Set.empty
        Can.Call fn args -> foldl (\a e -> Set.union a (go bound e)) (go bound fn) args
        Can.Lambda params body ->
            let bound' = foldl (\s p -> foldr Set.insert s (patBindingVars p)) bound params
            in go bound' body
        Can.Let (Can.Def (Ann.At _ name) _ defBody) body ->
            let bound' = Set.insert name bound
            in Set.union (go bound' defBody) (go bound' body)
        Can.LetRec defs body ->
            let bound' = foldl (\s (Can.Def (Ann.At _ n) _ _) -> Set.insert n s) bound defs
                goDefs = foldl (\a (Can.Def _ _ d) -> Set.union a (go bound' d)) Set.empty defs
            in Set.union (go bound' body) goDefs
        Can.LetDestruct pat expr body ->
            let bound' = foldr Set.insert bound (patBindingVars pat)
            in Set.union (go bound expr) (go bound' body)
        Can.Case _ branches -> foldl (\a (Can.CaseBranch pat b) ->
            let bound' = foldr Set.insert bound (patBindingVars pat)
            in Set.union a (go bound' b)) Set.empty branches
        Can.If branches elseBranch ->
            foldl (\a (c, t) -> Set.union a (Set.union (go bound c) (go bound t))) (go bound elseBranch) branches
        Can.Binop _ _ _ _ a b -> Set.union (go bound a) (go bound b)
        Can.Access r _ -> go bound r
        Can.Update _ r updates -> Set.union (go bound r) (foldl (\a (_, Can.FieldUpdate _ e) -> Set.union a (go bound e)) Set.empty (Map.toList updates))
        Can.Record fields -> foldl (\a (_, v) -> Set.union a (go bound v)) Set.empty (Map.toList fields)
        Can.List es -> foldl (\a e -> Set.union a (go bound e)) Set.empty es
        Can.Tuple a b rest -> foldl (\a e -> Set.union a (go bound e)) Set.empty (a:b:rest)
        Can.Negate e -> go bound e
        Can.Accessor _ -> Set.empty
        Can.VarTopLevel _ _ -> Set.empty
        Can.VarKernel _ _ -> Set.empty
        Can.VarCtor _ _ _ _ _ -> Set.empty
        Can.Chr _ -> Set.empty
        Can.Str _ -> Set.empty
        Can.Int _ -> Set.empty
        Can.Float _ -> Set.empty
        Can.Unit -> Set.empty

-- | Helper: render a single function-call argument string, handling
-- lambda capture cloning and VarLocal ownership.
-- Clones every VarLocal argument by default (most Sky types implement Clone).
-- Exceptions: Task.run (Pin<Box<dyn Future>> which is not Clone).
argToRustString :: EmitCtx -> Bool -> Can.Expr -> String
argToRustString ctx noCloneFn (Ann.At _ a) = case a of
    Can.Lambda ps body ->
        let paramNames = Set.fromList (concatMap patBindingVars ps)
            captured = Set.toList (Set.difference (collectVarLocals body) paramNames)
            clones = concatMap (\v -> "let " ++ v ++ " = " ++ v ++ ".clone(); ") captured
            innerCounts = collectVarLocalsMulti body
            innerMulti = [ v | (v, c) <- Map.toList innerCounts, c >= 2 ]
            -- sub-A.10 C6: For move closures, EVERY captured non-Copy variable
            -- used inside needs to be cloned at use site (the closure is
            -- Fn-shaped — called multiple times — so each use consumes
            -- ownership unless cloned). Add every captured var to ecCloneVars
            -- so internal uses pick up .clone() via the Can.VarLocal arm.
            capturedSet = Set.fromList captured
            outerInherited = Set.difference (ecCloneVars ctx) paramNames
            allCloneVars = Set.unions [ Set.fromList innerMulti
                                      , outerInherited
                                      , capturedSet ]
            ctx' = ctx { ecCloneVars = allCloneVars, ecCopyVars = ecCopyVars ctx }
            annot = case ecPipeInnerType ctx of
                Just t | length ps == 1 -> ": " ++ t
                _ -> ""
            psStr = intercalate ", " (map (\p -> patternToRustParam p ++ annot) ps)
            retAnnot = case ecPipeInnerType ctx of
                Just t -> " -> SkyTask<" ++ t ++ ">"
                Nothing -> ""
            hasTaskRet = case ecPipeInnerType ctx of
                Just _ -> True
                Nothing -> False
            closure = "move |" ++ psStr ++ "|" ++ retAnnot ++ " { " ++ exprToRustString ctx' body ++ " }"
        in if not hasTaskRet && null captured
           then "move |" ++ psStr ++ "| { " ++ exprToRustString ctx' body ++ " }"
           else if null captured
                then closure
                else "{ " ++ clones ++ closure ++ " }"
    Can.VarLocal n ->
        let needsClone = (not noCloneFn) && (n `Set.member` ecCloneVars ctx)
                         && not (n `Set.member` ecCopyVars ctx)
        in if needsClone then rustSafeIdent n ++ ".clone()" else rustSafeIdent n
    _ -> exprToRustString ctx (Ann.At Ann.one a)

-- | Emit a Rust string literal from a Haskell string.
-- Handles non-ASCII characters via \\u{NNNN} escapes (Rust uses hex, not
-- Haskell's decimal \\NNN).  Inline UTF-8 for ASCII-safe chars.
rustStringLit :: String -> String
rustStringLit s = "\"" ++ concatMap escapeChar s ++ "\""
  where
    escapeChar '\"' = "\\\""
    escapeChar '\\' = "\\\\"
    escapeChar '\n' = "\\n"
    escapeChar '\t' = "\\t"
    escapeChar '\r' = "\\r"
    escapeChar c
        | c < ' ' || c == '\x7f' = "\\u{" ++ showHex (fromEnum c) "}"
        | c > '\x7f'             = "\\u{" ++ showHex (fromEnum c) "}"
        | otherwise              = [c]

-- | Emit a Rust char literal, using \\u{NNNN} for non-ASCII.
rustCharLit :: Char -> String
rustCharLit c
    | c > '\x7f' = "'\\u{" ++ showHex (fromEnum c) "}'"
    | c == '\''  = "'\\''"
    | c == '\\'  = "'\\\\'"
    | otherwise  = "'" ++ [c] ++ "'"

exprToRustString :: EmitCtx -> Can.Expr -> String
exprToRustString ctx (Ann.At region expr) =
    -- Sub-A.13: look up the wrapping region's solver-inferred type and inject
    -- it as ecExpectedType so the empty-literal emit sites can turbofish.
    let expected = Map.lookup region (ecRegionTypes ctx)
        ctx'     = ctx { ecExpectedType = expected }
    in exprToRustInner ctx' expr

-- | Sub-A.13: an empty-collection literal whose element type Rust cannot infer
-- from a bare emission. These are the args resolved by call-site param-type
-- propagation in emitDefaultCall.
data EmptyKind = EKList | EKNothing

emptyArgKind :: Can.Expr -> Maybe EmptyKind
emptyArgKind (Ann.At _ (Can.List [])) = Just EKList
emptyArgKind (Ann.At _ (Can.VarCtor _ _ "Maybe" "Nothing" _)) = Just EKNothing
emptyArgKind _ = Nothing

isEmptyishArg :: Can.Expr -> Bool
isEmptyishArg e = case emptyArgKind e of
    Just _  -> True
    Nothing -> False

-- | Where a callee's parameter-type strings came from. SrcKnownSig means
-- knownDefSig — a "T0" param there reliably indicates a GENERIC Rust signature,
-- so an unpinned empty arg must be defaulted (Rust can't infer). SrcInferred
-- (solved types / ctor fields) may be Sky-polymorphic even though the generated
-- Rust signature is concrete (e.g. Std.Db.query : List any -> ... compiles to a
-- Vec<String> param), so an unpinned empty arg stays bare and lets Rust infer.
data ParamSrc = SrcKnownSig | SrcInferred deriving (Eq)

-- | Sub-A.13: the Rust parameter-type strings for a call's callee, plus their
-- source. Nothing when the callee is unknown — the caller emits empty args bare.
calleeParamStrings :: EmitCtx -> Can.Expr -> Int -> Maybe (ParamSrc, [String])
calleeParamStrings ctx fn arity = case fn of
    Ann.At _ (Can.VarCtor _ _ _ ctorName _) ->
        case Map.lookup ctorName (ecCtorFieldTypes ctx) of
            Just tys -> Just (SrcInferred, map (typeToRustString (ecRecordMap ctx)) tys)
            Nothing  -> Nothing
    Ann.At _ (Can.VarKernel modName name) ->
        (\(ps, _) -> (SrcKnownSig, ps)) <$> knownDefSig (kernelSigPrefix modName) name arity
    Ann.At _ (Can.VarTopLevel modName name) ->
        -- Stdlib source modules (Sky.Core.Maybe/List/Result/...) compile to
        -- VarTopLevel, not VarKernel, so consult knownDefSig FIRST (it carries
        -- the type-var-bearing param strings). Fall back to the solved type for
        -- genuine user functions / Std kernels not in knownDefSig.
        case knownDefSig (kernelSigPrefix (ModuleName._name modName)) name arity of
            Just (ps, _) -> Just (SrcKnownSig, ps)
            Nothing ->
                case Map.lookup name (ecSolvedTypes ctx) of
                    Just ty -> let ps = extractParamTypes ty
                               in if null ps then Nothing
                                  else Just (SrcInferred, map (typeToRustString (ecRecordMap ctx)) ps)
                    Nothing -> Nothing
    _ -> Nothing

-- | Normalise a kernel module name to the underscore prefix knownDefSig keys
-- on. Short names ("List") get the "Sky_Core_" prefix; dotted names
-- ("Sky.Core.List") just swap dots for underscores.
kernelSigPrefix :: String -> String
kernelSigPrefix m
    | '.' `elem` m = map (\c -> if c == '.' then '_' else c) m
    | otherwise    = "Sky_Core_" ++ m

-- | Tokenise a Rust type string into bare identifier tokens.
rustTypeTokens :: String -> [String]
rustTypeTokens = words . map (\c -> if c `elem` ("<>,()+&[]:;" :: String) then ' ' else c)

-- | Is a token a Rust type variable as produced by our type sources?
-- knownDefSig uses T0, T1, ...; typeToRustString renders Can.TVar verbatim,
-- which can be a user var (a, b, e) OR an internal solver var
-- (_consElem214, _a_inst51, carg48, number7). Classification:
--   * T<digits>           -> var (knownDefSig)
--   * starts uppercase    -> concrete (String, Vec, SkyMaybe, SkyCoreJwtClaims)
--   * a known primitive / keyword -> concrete (i64, bool, impl, dyn, ...)
--   * anything else (lowercase/underscore ident) -> var
isRustTypeVarTok :: String -> Bool
isRustTypeVarTok t = case t of
    [] -> False
    (c : _)
        | head t == 'T' && length t >= 2 && all isDigit (tail t) -> True
        | isUpper c -> False
        | t `elem` rustConcreteLowerToks -> False
        | otherwise -> True

-- | Is a Rust parameter-type string a closure parameter (impl Fn(..))? Such a
-- param does not pin its type vars, so it doesn't count toward sibling pinning.
isClosureParamStr :: String -> Bool
isClosureParamStr p = "impl Fn" `isInfixOf` p || "Fn(" `isInfixOf` p

-- | Lowercase Rust tokens that are concrete types or type-level keywords, not
-- type variables. Everything else lowercase/underscore is treated as a var.
rustConcreteLowerToks :: [String]
rustConcreteLowerToks =
    [ "i8", "i16", "i32", "i64", "i128", "isize"
    , "u8", "u16", "u32", "u64", "u128", "usize"
    , "f32", "f64", "bool", "char", "str"
    , "impl", "dyn", "fn" ]

-- | Sub-A.13: decide how to emit an empty-collection argument at position i of
-- a call, given the callee's known parameter-type strings.
--   * param concrete                  -> turbofish the exact type
--   * param has a var shared w/ sibling -> bare (Rust infers from the sibling)
--   * param var appears only here      -> default filler (i64)
--   * callee unknown / shape unexpected -> bare (Rust infers from the sig)
emitEmptyArg :: EmitCtx -> Maybe (ParamSrc, [String]) -> Int -> Can.Expr -> String
emitEmptyArg _ mps i arg =
    let kind = case emptyArgKind arg of
            Just k  -> k
            Nothing -> EKList  -- unreachable: only called on empty-ish args
        bare = case kind of
            EKList    -> "vec![]"
            EKNothing -> "SkyMaybe::Nothing"
        defaultFiller = case kind of
            EKList    -> "Vec::<i64>::new()"
            EKNothing -> "SkyMaybe::<i64>::Nothing"
        -- Insert the turbofish "::" before the first '<' of a concrete param.
        turbofish pt = case break (== '<') pt of
            (h, rest@('<' : _)) -> Just $ case kind of
                EKList    | "Vec" == h        -> h ++ "::" ++ rest ++ "::new()"
                EKNothing | "SkyMaybe" == h   -> h ++ "::" ++ rest ++ "::Nothing"
                _ -> "" -- param shape doesn't match the arg kind
            _ -> Nothing
    in case mps of
        Just (src, ps) | i < length ps ->
            let pt   = ps !! i
                vars = filter isRustTypeVarTok (rustTypeTokens pt)
                -- A var is "pinned" only by a DATA sibling param. A closure
                -- param (impl Fn(..)) that mentions the var does NOT pin it —
                -- the closure's own param/return may be just as unconstrained
                -- (e.g. `map (\x -> x * 2) Nothing`: T0 is the closure arg,
                -- itself ambiguous). withDefault's value param DOES pin it.
                dataSiblingToks = concatMap rustTypeTokens
                    [ ps !! j | j <- [0 .. length ps - 1]
                              , j /= i, not (isClosureParamStr (ps !! j)) ]
                pinnedBySibling = any (`elem` dataSiblingToks) vars
            in if null vars
               then case turbofish pt of
                   Just s | not (null s) -> s
                   _ -> bare
               else if pinnedBySibling then bare
                    -- Unpinned var: default only when the sig is known-generic
                    -- (knownDefSig). For inferred sigs the generated Rust param
                    -- may be concrete, so stay bare and let Rust infer.
                    else if src == SrcKnownSig then defaultFiller else bare
        _ -> bare

-- | Does a closure pattern discard its argument (wildcard / `_`-prefixed)?
isWildcardPat :: Can.Pattern -> Bool
isWildcardPat (Ann.At _ Can.PAnything) = True
isWildcardPat (Ann.At _ (Can.PVar n)) | "_" `isPrefixOf` n = True
isWildcardPat _ = False

-- | Does a closure argument discard its argument entirely?
isWildcardClosure :: Can.Expr -> Bool
isWildcardClosure (Ann.At _ (Can.Lambda [pat] _)) = isWildcardPat pat
isWildcardClosure _ = False

-- | When a Task combinator's closure argument is a wildcard and the task
-- argument has an unconstrained success type, emit the task call with a
-- `::<_, ()>` turbofish so Rust can infer the success type.
pinTaskCall :: EmitCtx -> String -> [Can.Expr] -> Map.Map String Can.Type -> Maybe String
pinTaskCall ctx nameStr (closeExpr : taskExpr : rest) solved
    | isWildcardClosure closeExpr
    , null (taskExprInnerType solved taskExpr) =
        let closeStr = exprToRustString ctx closeExpr
            taskStr  = emitPinnedTask ctx solved taskExpr
            restStrs = map (exprToRustString ctx) rest
        in Just $ nameStr ++ "(" ++ intercalate ", " (closeStr : taskStr : restStrs) ++ ")"
    | otherwise = Nothing
pinTaskCall _ _ _ _ = Nothing

emitPinnedTask :: EmitCtx -> Map.Map String Can.Type -> Can.Expr -> String
emitPinnedTask ctx solved (Ann.At _ (Can.Call fnExpr taskArgs)) =
    let fnStr = exprToRustString ctx fnExpr
        argStrs = map (exprToRustString ctx) taskArgs
    in fnStr ++ "::<_, ()>(" ++ intercalate ", " argStrs ++ ")"
emitPinnedTask ctx _ other = exprToRustString ctx other  -- fallback: no pin

-- | Split a Sky kernel-name like "Decimal_fromInt" into ("Decimal", "fromInt").
-- The FIRST underscore is the module/fn boundary; subsequent underscores
-- stay in the function name ("Decimal_toStringFixed" -> ("Decimal", "toStringFixed")).
-- Used by the Ffi.callPure peephole to feed kernelToRust.
splitKernelName :: String -> (String, String)
splitKernelName s = case break (== '_') s of
    (m, '_' : f) -> (m, f)
    (m, "")      -> (m, "")  -- malformed; kernelToRust returns the snake-cased default

-- | Argument emission inside a matched Ffi.callPure peephole.
-- `Ffi.toAny x` collapses to bare `x` — the value retains its concrete Rust
-- type. Everything else routes to the standard expression emit.
peepholeArg :: EmitCtx -> Can.Expr -> String
peepholeArg ctx (Ann.At _ (Can.Call (Ann.At _ (Can.VarKernel "Ffi" "toAny")) [inner])) =
    exprToRustString ctx inner
peepholeArg ctx e = exprToRustString ctx e

exprToRustInner :: EmitCtx -> Can.Expr_ -> String
exprToRustInner ctx e = case e of
    Can.VarLocal name -> rustSafeIdent name ++ if name `Set.member` ecCloneVars ctx && not (name `Set.member` ecCopyVars ctx) then ".clone()" else ""
    Can.VarTopLevel mod name ->
        let modName = ModuleName._name mod
            modPrefix = map (\c -> if c == '.' then '_' else c) modName
            fnName = toSnakeCase (modPrefix ++ "_" ++ name)
            -- Check kernelToRust first (direct kernel dispatch)
            kernelName = kernelToRust modName name
            -- sub-A.10 C4 + sub-A.11: kernels generic over E (and possibly
            -- T, A, B) need a per-kernel turbofish to pin the generics at
            -- call sites whose match arms / context don't constrain them.
            pinE n = case Map.lookup n kernelsNeedingErrorPin of
                Just suffix -> n ++ suffix
                Nothing     -> n
            -- sub-A.11: zero-arg kernels (json_dec_*, dict_empty, math_pi/e)
            -- returning a value (Decoder, HashMap, f64) reached via the
            -- "then" branch — append () to call them. Turbofish goes
            -- BEFORE the (), e.g. json_dec_int::<SkyError>().
            -- Lookup is on the BARE kernel name (pre-turbofish).
            emitKernel bare = let pinned = pinE bare
                              in if Set.member bare kernelsZeroArg
                                 then pinned ++ "()" else pinned
        in if fnName /= kernelName && not ("ffi_kernel" `isPrefixOf` kernelName)
           then emitKernel kernelName
           else -- Check Stage-4 alias table: some VarTopLevel bindings are
                -- Ffi.kernel aliases that should route through kernel dispatch.
                case Map.lookup (modName, name) (ecKernelAliases ctx) of
                    Just (kMod, kFn) -> emitKernel (kernelToRust kMod kFn)
                    Nothing ->
                        -- Sub-D: RetryPolicy/ShouldRetry constructors return a
                        -- type whose only var is the (always-SkyError) error
                        -- type, which is phantom when the policy isn't tied to a
                        -- concrete error. Pin it so e infers and propagates
                        -- through builder chains (E0283 otherwise). ONLY in a
                        -- monomorphic context — inside a generic fn (e.g.
                        -- linearBackoff<e>'s body using retryAlways) the var is
                        -- the fn's own param, which the pin must not override.
                        let pin = if ecInGenericFn ctx then ""
                                  else Map.findWithDefault "" (modName, name) topLevelErrorPin
                        in if Set.member (modPrefix, name) (ecZeroArgDefs ctx) then fnName ++ pin ++ "()" else fnName ++ pin
    Can.VarKernel mod name ->
        let fnName = kernelToRust mod name
            -- sub-A.10 C4 + sub-A.11: per-kernel turbofish (E pinning + arity).
            tf = case Map.lookup fnName kernelsNeedingErrorPin of
                Just suffix -> suffix
                Nothing     -> ""
        in if mod == "Basics" && name == "not" then "!"
           -- Zero-arg kernels (via ecZeroArgDefs OR kernelsZeroArg) need
           -- both the turbofish AND () to call. Turbofish goes before ().
           else if Set.member (mod, name) (ecZeroArgDefs ctx)
                then fnName ++ tf ++ "()"
           else if Set.member fnName kernelsZeroArg
                then fnName ++ tf ++ "()"
           else fnName ++ tf
    Can.VarCtor _ modName typeName ctorName _
        -- Sub-A.13: the nullary Maybe/Nothing ctor. Three states (see the
        -- Can.List arm below for the full rationale):
        --   * concrete Maybe<val> -> SkyMaybe::<val>::Nothing
        --   * Maybe<val> w/ TVars -> bare (generic context, Rust infers)
        --   * no region type      -> SkyMaybe::<i64>::Nothing (phantom default)
        -- kernelCtorToRust doesn't see ctx, so handle Nothing inline here.
        -- Concrete region type -> turbofish. Otherwise BARE: a call-arg
        -- Nothing is resolved precisely at the call site (emitDefaultCall);
        -- a non-call-arg Nothing keeps Rust's own inference (the pre-fix
        -- behaviour).
        | typeName == "Maybe", ctorName == "Nothing"
        , Just (Can.TType _ "Maybe" [valTy]) <- ecExpectedType ctx
        , Just rustVal <- rustifyExpectedType (ecRecordMap ctx) valTy ->
            "SkyMaybe::<" ++ rustVal ++ ">::Nothing"
        | otherwise -> kernelCtorToRust modName typeName ctorName
    Can.Chr [c] -> rustCharLit c
    Can.Chr s -> rustStringLit s
    Can.Str s -> rustStringLit s ++ ".to_string()"
    Can.Int i -> show i
    Can.Float f -> show f
    Can.List es
        -- Sub-A.13: an empty list literal gives Rust no element type to infer.
        -- Three states drive the choice (set in exprToRustString from the
        -- region's solver type — see ecExpectedType):
        --   * concrete List<elem>  -> Vec::<elem>::new()  (pin the type)
        --   * List<elem> w/ TVars  -> bare vec![]         (generic context: the
        --       element is the fn's own type param, which Rust infers from the
        --       signature; turbofishing would clobber the generic)
        --   * no region type       -> Vec::<i64>::new()   (monomorphic phantom:
        --       Rust can't infer and there's no generic param to bind; any
        --       concrete type is safe because the list is empty)
        -- Concrete region type -> turbofish. Otherwise BARE: a call-arg []
        -- is resolved precisely at the call site (emitDefaultCall); a
        -- non-call-arg [] keeps Rust's own inference (the pre-fix behaviour).
        | null es
        , Just (Can.TType _ "List" [elemTy]) <- ecExpectedType ctx
        , Just rustElem <- rustifyExpectedType (ecRecordMap ctx) elemTy ->
            "Vec::<" ++ rustElem ++ ">::new()"
        | otherwise ->
            "vec![" ++ intercalate ", " (map (exprToRustString ctx) es) ++ "]"
    Can.Negate e -> "-" ++ exprToRustString ctx e
    Can.Binop op _ _ _ a b 
        | op == "|>" -> case b of
            Ann.At _ (Can.Call fn callArgs) ->
                let dummySpan = Ann.Region (Ann.Position 1 1) (Ann.Position 1 1)
                in exprToRustString ctx (Ann.At dummySpan (Can.Call fn (callArgs ++ [a])))
            _ ->
                let inner = taskExprInnerType (ecSolvedTypes ctx) a
                    ctx' = ctx { ecPipeInnerType = if null inner then Nothing else Just inner }
                in exprToRustString ctx' b ++ "(" ++ exprToRustString ctx' a ++ ")"
        | op == "<|" -> case a of
            Ann.At _ (Can.Call fn callArgs) ->
                let dummySpan = Ann.Region (Ann.Position 1 1) (Ann.Position 1 1)
                in exprToRustString ctx (Ann.At dummySpan (Can.Call fn (callArgs ++ [b])))
            _ ->
                exprToRustString ctx a ++ "(" ++ exprToRustString ctx b ++ ")"
        | op == "::" -> "sky_list_cons(" ++ exprToRustString ctx a ++ ", " ++ exprToRustString ctx b ++ ")"
        | op == "++" ->
            -- Sky's ++ is polymorphic: String -> String -> String AND
            -- List a -> List a -> List a. Dispatch on inferred type via
            -- solveArgType (which inspects literals + VarLocal lookups +
            -- nested binops). Vec<T> -> chain-extend block; otherwise
            -- format! (string concat).
            let lhsTy = solveArgType (ecSolvedTypes ctx) a
                rhsTy = solveArgType (ecSolvedTypes ctx) b
                isList = "Vec<" `isPrefixOf` lhsTy || "Vec<" `isPrefixOf` rhsTy
                aStr  = exprToRustString ctx a
                bStr  = exprToRustString ctx b
            in if isList
               then "{ let mut __r = " ++ aStr ++ ".clone(); __r.extend(" ++ bStr ++ "); __r }"
               else "format!(\"{}{}\", " ++ aStr ++ ", " ++ bStr ++ ")"
        | otherwise -> 
            "(" ++ exprToRustString ctx a ++ " " ++ binopToRust op ++ " " ++ exprToRustString ctx b ++ ")"
    Can.Lambda params body ->
        let counts = collectVarLocalsMulti body
            innerMulti = [ v | (v, c) <- Map.toList counts, c >= 2 ]
            -- sub-A.10 C6: union with outer ecCloneVars so captures from a
            -- non-Copy outer scope (the typical case: `move |x| f(captured)`)
            -- get cloned at every internal use. The closure is `Fn`-shaped
            -- (callable multiple times); each call consumes the captures by
            -- ownership unless cloned.
            paramNames = Set.fromList [ pn | Ann.At _ (Can.PVar pn) <- params ]
            outerInherited = Set.difference (ecCloneVars ctx) paramNames
            ctx' = ctx { ecCloneVars = Set.union (Set.fromList innerMulti) outerInherited
                       , ecCopyVars = ecCopyVars ctx }
        in "|" ++ intercalate ", " (map patternToRustParam params) ++ "| { " ++ exprToRustString ctx' body ++ " }"
    -- Ffi.callPure peephole — literal kernel name + literal args list -> direct
    -- kernel call. Splits "Decimal_fromInt" -> ("Decimal", "fromInt"), looks up
    -- kernelToRust, emits the resolved kernel name with the args spliced inline.
    -- Ffi.toAny inside a matched args list collapses to identity (see peepholeArg).
    -- The deprecated Ffi.call alias gets the same treatment.
    -- Non-matched shapes (variable kernel name, non-literal args list) fall
    -- through to the existing Can.Call arm, which routes to the polyfill via
    -- kernelToRust's "Ffi.callPure" -> "ffi_call_pure_polyfill" arm.
    Can.Call (Ann.At _ (Can.VarKernel "Ffi" fnName))
             [Ann.At _ (Can.Str kernelName), Ann.At _ (Can.List argExprs)]
        | fnName == "callPure" || fnName == "call" ->
            let (skyMod, skyFn) = splitKernelName kernelName
                rustFn = kernelToRust skyMod skyFn
                args = map (peepholeArg ctx) argExprs
            in rustFn ++ "(" ++ intercalate ", " args ++ ")"
    -- Standalone Ffi.toAny peephole — outside a matched Ffi.callPure args list,
    -- Ffi.toAny x collapses to bare x. The value retains its concrete Rust type;
    -- the toAny call is dropped entirely (kernelToRust's polyfill arm is a safety
    -- net for indirect references, but most call sites match here).
    Can.Call (Ann.At _ (Can.VarKernel "Ffi" "toAny")) [inner] ->
        exprToRustString ctx inner
    -- A bare `Ffi.kernel "X"` body for a ZERO-ARG kernel (e.g. stdlib `none =
    -- Ffi.kernel "Sub_none"`) must resolve to the real kernel call, not the
    -- ffi_kernel_polyfill panic — a zero-arg value alias (Sub.none) reached in a
    -- nested position calls the generated wrapper, so its body has to work.
    -- Restricted to zero-arg kernels; multi-arg function aliases fall through
    -- (their wrappers are bypassed by direct call sites, so the polyfill there
    -- is dead, and emitting a bare kernel fn would mistype their return).
    Can.Call (Ann.At _ (Can.VarKernel "Ffi" "kernel")) [Ann.At _ (Can.Str kernelName)]
        | (skyMod, skyFn) <- splitKernelName kernelName
        , let rustFn = kernelToRust skyMod skyFn
          -- Restricted to TEA value kernels whose generic runtime return
          -- (SkyCmd<M> / SkySub<M>) matches the generic wrapper. Other zero-arg
          -- kernels (e.g. dict_empty : HashMap<String,T>) would mistype the
          -- generic wrapper (HashMap<k,v>), so they keep the dead-but-typesafe
          -- ffi_kernel_polyfill body.
        , rustFn `elem` ["cmd_none", "sub_none"] ->
            rustFn ++ "()"
    -- Sub-A.13: Result/Ok and Result/Err constructor calls. The wrapping
    -- region's type is Result<E, A>; emit SkyResult::<E, A>::Ctor(inner) so
    -- Rust doesn't have to infer the unused-side type from a discarded value
    -- (the E0283 'type annotations needed' class). Only fires when BOTH sides
    -- are fully concrete — a free side means we're in a generic context where
    -- Rust infers from the signature, and turbofishing would clobber it. When
    -- the guards fail this arm does not match and control falls through to the
    -- generic Can.Call path below, preserving today's inference-driven output.
    -- concrete both sides -> turbofish
    Can.Call (Ann.At _ (Can.VarCtor _ _ "Result" ctorName _)) [innerArg]
        | ctorName == "Ok" || ctorName == "Err"
        , Just (Can.TType _ "Result" [errTy, okTy]) <- ecExpectedType ctx
        , Just rustErr <- rustifyExpectedType (ecRecordMap ctx) errTy
        , Just rustOk  <- rustifyExpectedType (ecRecordMap ctx) okTy ->
            "SkyResult::<" ++ rustErr ++ ", " ++ rustOk ++ ">::"
                ++ ctorName ++ "(" ++ exprToRustString ctx innerArg ++ ")"
    -- monomorphic fn, type not fully concrete -> default the unconstrained
    -- side. Err carries Sky's Error idiom (Cardinal Rule 1); the Ok side is
    -- phantom so i64 is a safe filler. Inside a GENERIC fn this arm does not
    -- match, so control falls through to the generic Can.Call path where Rust
    -- infers from the signature.
    Can.Call (Ann.At _ (Can.VarCtor _ _ "Result" ctorName _)) [innerArg]
        | (ctorName == "Ok" || ctorName == "Err")
        , not (ecInGenericFn ctx) ->
            "SkyResult::<SkyError, i64>::" ++ ctorName
                ++ "(" ++ exprToRustString ctx innerArg ++ ")"  -- default (Task 8: stderr warning)
    -- Sub-E: Cli.program { init, update, view, subscriptions, onLine } — the cfg
    -- is an anonymous record the runtime can't name, so splice its fields into
    -- the generic cli_program(init, update, view, subs, onLine) directly.
    Can.Call (Ann.At _ (Can.VarKernel "Cli" "program")) [Ann.At _ (Can.Record fields)] ->
        let fld n = case Map.lookup n fields of
                Just e  -> exprToRustString ctx e
                Nothing -> "/* Cli.program: missing field " ++ n ++ " */"
        in "cli_program(" ++ intercalate ", "
               (map fld ["init", "update", "view", "subscriptions", "onLine"]) ++ ")"
    -- Sub-E step 3: Cmd.perform with a DIVERGING task (System.exit -> `!`) leaves
    -- the task's success/error types free (E0283). Pin them — the value is never
    -- produced (the process exits first), so A is a phantom i64 filler.
    Can.Call cmdPerformFn (task0 : rest)
        | "cmd_perform" == exprToRustString ctx cmdPerformFn
          -- require the call form `system_exit(...)`, not just a "system_exit"
          -- prefix, so a future kernel/fn named system_exit_* can't false-match.
        , "system_exit(" `isPrefixOf` exprToRustString ctx task0 ->
            "cmd_perform::<SkyError, i64, _, _>("
                ++ intercalate ", " (map (exprToRustString ctx) (task0 : rest)) ++ ")"
    -- Sub-E step 4/5: Sub_subscribeWebSocket raw KIND toMsg. The four wrappers
    -- (onOpen/onMessage/onClose/onError) feed heterogeneous toMsg (bare msg /
    -- WebSocketMessage->msg / CloseCode->msg / Error->msg) through this one
    -- `any`-typed kernel, which can't share a single bounded Rust fn. Route by the
    -- compile-time literal kind to a per-kind TYPED kernel — the codegen does the
    -- split a stdlib override would otherwise do.
    Can.Call subFn [rawArg, Ann.At _ (Can.Str kind), toMsgArg]
        | "sub_subscribe_web_socket" == exprToRustString ctx subFn ->
            let fn = case kind of
                    "message" -> "sub_subscribe_ws_message"
                    "open"    -> "sub_subscribe_ws_open"
                    "close"   -> "sub_subscribe_ws_close"
                    "error"   -> "sub_subscribe_ws_error"
                    _         -> "sub_subscribe_ws_message"
            in fn ++ "(" ++ exprToRustString ctx rawArg ++ ", " ++ exprToRustString ctx toMsgArg ++ ")"
    Can.Call fn args ->
        let calleeName = exprToRustString ctx fn
            -- sub-A.12 F2: detect partial application (Sky source has currying;
            -- Rust doesn't). If the callee is a top-level fn with known arity > supplied,
            -- wrap the residual args in a `move |..| f(supplied.., residual..)` closure.
            calleeArity = case fn of
                Ann.At _ (Can.VarTopLevel _ fnName) ->
                    case Map.lookup fnName (ecSolvedTypes ctx) of
                        Just ty -> length (extractParamTypes ty)
                        Nothing -> 0
                _ -> 0
            isPartialApp = calleeArity > length args && not (null args)
            succeedArity = case fn of
                Ann.At _ (Can.VarKernel _ name) | name == "succeed" && not (null args) ->
                    case head args of
                        Ann.At _ (Can.Lambda ps _) | length ps > 1 -> Just (length ps)
                        Ann.At _ (Can.VarTopLevel _ fnName) ->
                            case Map.lookup fnName (ecSolvedTypes ctx) of
                                Just ty | let n = length (extractParamTypes ty), n > 1 -> Just n
                                _ -> case Map.lookup fnName (ecCtorArity ctx) of
                                    Just n | n > 1 -> Just n
                                    _ -> Nothing
                        _ -> Nothing
                _ -> Nothing
        in if isPartialApp
           then
               -- sub-A.12 F2: partial application -> wrap residual args in
               -- a `move |..| f(supplied.., residual..)` closure. Sky source
               -- like `result_and_then (validateTime now) (...)` curries
               -- `validateTime now` into `String -> Result Error String`.
               let supplied = length args
                   missing = calleeArity - supplied
                   freshParams = ["__pa" ++ show i | i <- [1..missing]]
                   suppliedStrs = map (exprToRustString ctx) args
               in "(move |" ++ intercalate ", " freshParams ++ "| " ++
                  calleeName ++ "(" ++ intercalate ", " (suppliedStrs ++ freshParams) ++ "))"
           else
            case succeedArity of
            Just n ->
                let [arg] = args
                in case arg of
                    Ann.At _ (Can.Lambda params body) ->
                        let counts = collectVarLocalsMulti body
                            innerMulti = [v | (v, c) <- Map.toList counts, c >= 2]
                            ctx' = ctx { ecCloneVars = Set.fromList innerMulti, ecCopyVars = ecCopyVars ctx }
                            psStr = intercalate ", " (map patternToRustParam params)
                        in calleeName ++ "(curry" ++ show n ++ "(|" ++ psStr ++ "| { " ++ exprToRustString ctx' body ++ " }))"
                    _ ->
                        calleeName ++ "(curry" ++ show n ++ "(" ++ exprToRustString ctx arg ++ "))"
            Nothing -> case calleeName of
                fn | "println" `isSuffixOf` fn ->
                    "log_info(" ++ intercalate " ++ \" \" ++ " (map (\a -> exprToRustString ctx a) args) ++ ")"
                cname | cname `elem` ["task_and_then", "task_on_error", "task_map_error"] ->
                    case pinTaskCall ctx cname args (ecSolvedTypes ctx) of
                        Just pinned -> pinned
                        Nothing -> emitDefaultCall ctx fn calleeName args
                cname | "json_dec_and_then" `isPrefixOf` cname, [contArg, decArg] <- args ->
                    -- Sky's `andThen : (a -> Decoder b) -> Decoder a -> Decoder b`
                    -- puts the continuation FIRST, but the runtime kernel is
                    -- `json_dec_and_then(decoder, f)`. Emit decoder-first so Rust
                    -- unifies the decoder's value type `a` BEFORE type-checking the
                    -- continuation closure — a closure-first arg leaves `a`
                    -- un-inferred (E0282). Closes the Json.Decode/Std.Config
                    -- `andThen` record-decode path.
                    emitDefaultCall ctx fn calleeName [decArg, contArg]
                _ -> emitDefaultCall ctx fn calleeName args
    Can.If [] elseBranch ->
        exprToRustString ctx elseBranch
    Can.If ((firstCond, firstBody):rest) elseBranch ->
        "if " ++ exprToRustString ctx firstCond ++ " { " ++ exprToRustString ctx firstBody ++ " }"
        ++ concatMap (\(c, t) -> " else if " ++ exprToRustString ctx c ++ " { " ++ exprToRustString ctx t ++ " }") rest
        ++ " else { " ++ exprToRustString ctx elseBranch ++ " }"
    Can.Let def body ->
        case def of
            Can.Def (Ann.At _ name) [] (Ann.At _ (Can.List items))
                | Just n <- Map.lookup name (collectVarLocalsMulti body), n >= 2 ->
                    let inline = "vec![" ++ intercalate ", " (map (exprToRustString ctx) items) ++ "]"
                    in substVar ctx name inline body
            _ -> "let " ++ defToRustString ctx def ++ "; " ++ exprToRustString ctx body
    Can.LetRec defs body ->
        "let mut " ++ intercalate "; let mut " (map (defToRustString ctx) defs) ++ "; " ++ exprToRustString ctx body
    Can.LetDestruct pat expr body ->
        -- Clone captured locals used ≥ 2 times so each use gets its own copy.
        let counts = collectVarLocalsMulti expr
            multi = [ v | (v, c) <- Map.toList counts, c >= 2 ]
            clones = concatMap (\v -> "let " ++ v ++ " = " ++ v ++ ".clone(); ") multi
            hasClone = not (null multi)
            exprStr = case expr of
                Ann.At _ (Can.Lambda ps lambdaBody)
                    | null ps || all isWildcard ps ->
                        let inner = "(move || { " ++ exprToRustString ctx lambdaBody ++ " })()"
                        in if not hasClone then inner else "{ " ++ clones ++ inner ++ " }"
                Ann.At _ (Can.Lambda ps lambdaBody) ->
                    let paramNames = Set.fromList [ n | Ann.At _ p <- ps, let n = case p of Can.PVar s -> s; _ -> "_" ]
                        innerCapt = Set.toList (Set.difference (collectVarLocals lambdaBody) paramNames)
                        innerClones = concatMap (\v -> "let " ++ v ++ " = " ++ v ++ ".clone(); ") innerCapt
                        psStr = intercalate ", " (map patternToRustParam ps)
                        inner = "move |" ++ psStr ++ "| { " ++ exprToRustString ctx lambdaBody ++ " }"
                    in if null innerCapt && not hasClone then inner
                       else "{ " ++ clones ++ innerClones ++ inner ++ " }"
                _ -> if not hasClone then exprToRustString ctx expr
                     else "{ " ++ clones ++ exprToRustString ctx expr ++ " }"
        in "let " ++ patternToMatchString (ecRecordMap ctx) pat ++ " = " ++ exprStr ++ "; " ++ exprToRustString ctx body
    Can.Case scrut branches ->
        let scrutStr = exprToRustString ctx scrut
            -- Detect slice patterns → wrap with .as_slice()
            hasCons = any (\(Can.CaseBranch pat _) -> hasConsP pat) branches
            -- Detect string literal patterns → wrap with .as_str() so &str patterns compile
            hasStr  = any (\(Can.CaseBranch pat _) -> hasStrPat pat) branches
            wrapped = if hasCons then "(" ++ scrutStr ++ ").as_slice()"
                      else if hasStr then scrutStr ++ ".as_str()"
                      else scrutStr
            -- sub-A.10 C5: when the scrutinee was .as_str()-wrapped, wildcard
            -- PVar bindings are &str. Convert to String at the body's binding
            -- site so constructor args expecting String work.
            renderBranch = if hasStr then branchToRustStringStrWrap ctx
                                     else branchToRustString ctx
        in "match " ++ wrapped ++ " { " ++
        intercalate ", " (map renderBranch branches) ++ " }"
      where
        hasConsP (Ann.At _ p) = case p of
            Can.PCons _ _ -> True
            Can.PList _ -> True
            Can.PAlias pat _ -> hasConsP pat
            _ -> False
    Can.Accessor field -> "|_record| _record." ++ field
    Can.Access record (Ann.At _ field) -> 
        exprToRustString ctx record ++ "." ++ field
    Can.Update (Ann.At _ _field) record updates ->
        let sorted = sortBy (\(_, Can.FieldUpdate r1 _) (_, Can.FieldUpdate r2 _) -> compare (Ann._line (Ann._start r1)) (Ann._line (Ann._start r2))) (Map.toList updates)
        in "{ let mut result = " ++ exprToRustString ctx record ++ "; " ++
        intercalate "; " (map (\(f, Can.FieldUpdate _ expr) -> "result." ++ f ++ " = " ++ exprToRustString ctx expr) sorted) ++
        "; result }"
    Can.Record fields -> 
        let key = intercalate "," (Map.keys fields)
        in case Map.lookup key (ecRecordMap ctx) of
            Just structName -> 
                structName ++ " { " ++ intercalate ", " (map (\(k, v) -> 
                    k ++ ": " ++ exprToRustString ctx v) (Map.toList fields)) ++ " }"
            Nothing -> 
                "{ " ++ intercalate ", " (map (\(k, v) -> k ++ ": " ++ exprToRustString ctx v) (Map.toList fields)) ++ " }"
    Can.Unit -> "()"
    Can.Tuple a b rest -> 
        "(" ++ intercalate ", " (map (exprToRustString ctx) (a:b:rest)) ++ ")"

-- | Given a Task-typed expression (like Db_query(…)), return the Rust type
-- string of the SkyTask's inner success type A (i.e.  SkyTask<A> → A).
-- Returns "" when the type can't be determined.
-- Takes a solvedTypes map so Task.succeed(arg) can look up arg's type.
taskExprInnerType :: Map.Map String Can.Type -> Can.Expr -> String
taskExprInnerType solved (Ann.At _ expr) = case expr of
    Can.VarLocal name -> case Map.lookup name solved of
        Just ty -> taskInnerTypeStr (extractReturnType ty)
        Nothing -> ""
    -- Check kernel calls (VarKernel or VarTopLevel with kernel alias)
    Can.Call callee args -> taskExprInnerTypeCall solved callee args
    -- Pipeline: extract type from left side (the task being piped)
    Can.Binop "|>" _ _ _ a _ ->
        let t = taskExprInnerType solved a
        in if null t then "String" else t
    Can.Case _ branches ->
        -- If ALL case branches are Task expressions, propagate the inner type
        let innerTypes = [ taskExprInnerType solved b | Can.CaseBranch _ b <- branches ]
        in if not (null innerTypes) && all (not . null) innerTypes
           then head innerTypes  -- same inner type for all branches
           else ""
    Can.VarTopLevel mod name ->
        -- Look up the solved type of this VarTopLevel and extract Task inner type
        case Map.lookup name solved of
            Just ty -> let ret = extractReturnType ty in taskInnerTypeStr ret
            Nothing -> ""
    _ -> ""

-- | Extract the inner type string from a Sky type (task or not).
-- If the type is Task e a, return the Rust string of a.
-- Otherwise return "" (not a Task expression).
taskInnerTypeStr :: Can.Type -> String
taskInnerTypeStr (Can.TType _ "Task" [_, a]) = typeToRustString Map.empty a
taskInnerTypeStr _                           = ""

-- | Inner helper for taskExprInnerType: try to determine the Task inner
-- type from a call expression.  Handles both VarKernel and VarTopLevel
-- callees that route through kernelToRust.
taskExprInnerTypeCall :: Map.Map String Can.Type -> Can.Expr -> [Can.Expr] -> String
taskExprInnerTypeCall solved (Ann.At _ (Can.VarTopLevel mod name)) args =
    let rawMod = ModuleName._name mod
        snakeName = toSnakeCase (map (\c -> if c == '.' then '_' else c) rawMod ++ "_" ++ name)
        kName = kernelToRust rawMod name
        fakeSpan = Ann.Region (Ann.Position 0 0) (Ann.Position 0 0)
    in if snakeName /= kName
       then taskExprInnerTypeCall solved (Ann.At fakeSpan (Can.VarKernel rawMod name)) args
       else -- Not a kernel: check solved types for the function name
            case Map.lookup name solved of
                Just ty -> let ret = extractReturnType ty in taskInnerTypeStr ret
                Nothing -> ""
taskExprInnerTypeCall solved (Ann.At _ (Can.VarKernel modName fnName)) args
        | "Task" `isSuffixOf` modName || modName == "Task" = case fnName of
            "succeed"  -> case args of
                [arg] -> solveArgType solved arg
                _ -> "String"
            "fail"     -> ""  -- polymorphic success type A — empty signals unconstrained
            "map"      -> "String"  -- result type is B (fn's return), not derivable statically
            "andThen"  -> "String"  -- same
            "onError"  -> case args of
                [_, task] -> taskExprInnerType solved task
                _ -> "String"
            "mapError" -> case args of
                [_, task] -> taskExprInnerType solved task  -- same success type A
                _ -> "String"
            _ -> ""
        | "Db" `isSuffixOf` modName || modName == "Db" = case fnName of
            "query"    -> "Vec<HashMap<String, String>>"
            "exec"     -> "()"
            "execRaw"  -> "()"
            "connect"  -> "Db"
            "getField" -> "String"
            "getString" -> "String"
            "getInt"   -> "i64"
            _ -> ""
        | "System" `isSuffixOf` modName || modName == "System" = case fnName of
            "args"        -> "Vec<String>"
            "exit"        -> "()"
            "setenv"      -> "()"
            "unsetenv"    -> "()"
            _ -> ""
        | "Log" `isSuffixOf` modName || modName == "Log" = "()"
        | "Time" `isSuffixOf` modName || modName == "Time" = case fnName of
            "now"       -> "i64"
            "sleep"     -> "()"
            "unixMillis" -> "i64"
            _ -> ""
        | "Random" `isSuffixOf` modName || modName == "Random" = case fnName of
            "int"    -> "i64"
            "float"  -> "f64"
            "choice" -> "String"
            _ -> ""
        | "Crypto" `isSuffixOf` modName || modName == "Crypto" = case fnName of
            "randomBytes"  -> "Vec<i64>"
            "randomToken"  -> "String"
            _ -> ""
        | "File" `isSuffixOf` modName || modName == "File" = case fnName of
            "readFile"  -> "String"
            "writeFile" -> "()"
            "exists"    -> "bool"
            _ -> ""
        | otherwise = ""
taskExprInnerTypeCall _ _ _ = ""

-- | Default call emission for non-special-cased function calls.
-- Handles `isZeroArgFn` wrapping (Ffi.kernel stubs) and `isListDec`
-- factory closures.
emitDefaultCall :: EmitCtx -> Can.Expr -> String -> [Can.Expr] -> String
-- Sub-D: Task.retryWith policy task — run-once on target=rust (see task.rs).
-- Drop the policy arg: it's unused, and emitting the policy builder
-- (`linearBackoff … : RetryPolicy e`) introduces a phantom error-type var `e`
-- Rust can't infer (E0283). task_retry_with takes only the task. retryWith is a
-- VarTopLevel kernel-alias, so it lands here rather than the VarKernel peephole.
emitDefaultCall ctx _fn "task_retry_with" [_policy, task] =
    "task_retry_with(" ++ exprToRustString ctx task ++ ")"
emitDefaultCall ctx fn calleeName args =
    let noCloneFn = case fn of
            Ann.At _ (Can.VarKernel _ n) -> n == "run"
            _ -> False
        -- isPrefixOf (not isSuffixOf): the callee carries a turbofish
        -- (`json_dec_list::<SkyError, _>`), so the bare name is a prefix, not a
        -- suffix. `list` takes `impl Fn() -> Decoder`, so its decoder arg is
        -- wrapped in a `||` factory closure below. (Suffix-matching silently
        -- skipped the wrap once the turbofish was added — list never re-runs its
        -- element decoder otherwise.)
        isListDec = "json_dec_list" `isPrefixOf` calleeName
        -- Sub-A.13: empty-collection args (`[]`, `Nothing`) carry no element
        -- type for Rust to infer. Resolve each from the callee's param types:
        -- concrete -> turbofish, var-shared-with-sibling -> bare, var-only-here
        -- -> default filler, unknown callee -> bare. Non-empty args keep the
        -- normal clone-aware emit.
        paramStrs = calleeParamStrings ctx fn (length args)
        emitArg i a
            | isEmptyishArg a = emitEmptyArg ctx paramStrs i a
            | otherwise       = argToRustString ctx noCloneFn a
        argsStrs = if isListDec && not (null args)
                   then ("|| " ++ argToRustString ctx noCloneFn (head args)) : map (argToRustString ctx noCloneFn) (tail args)
                   else zipWith emitArg [0..] args
        isZeroArgFn = case fn of
            Ann.At _ (Can.VarKernel modName name) ->
                let fnName = kernelToRust modName name
                    defaultName = toSnakeCase (map (\c -> if c == '.' then '_' else c) modName ++ "_" ++ name)
                in Set.member (modName, name) (ecZeroArgDefs ctx)
                   && fnName == defaultName
            Ann.At _ (Can.VarTopLevel modName name) ->
                let modPrefix = map (\c -> if c == '.' then '_' else c) (ModuleName._name modName)
                    fnName = toSnakeCase (modPrefix ++ "_" ++ name)
                    kernelName = kernelToRust (ModuleName._name modName) name
                in Set.member (modPrefix, name) (ecZeroArgDefs ctx)
                   && (fnName == kernelName || kernelName == "ffi_kernel")
            _ -> False
        callee = exprToRustString ctx fn
    in if isZeroArgFn && not (null args)
       then callee ++ "()(" ++ intercalate ", " argsStrs ++ ")"
       else callee ++ "(" ++ intercalate ", " argsStrs ++ ")"

-- | Try to extract the Rust type string from a single argument expression
-- by looking up its type in solvedTypes.
solveArgType :: Map.Map String Can.Type -> Can.Expr -> String
solveArgType solvedMap arg = case arg of
    Ann.At _ (Can.Int _)   -> "i64"
    Ann.At _ (Can.Float _) -> "f64"
    Ann.At _ (Can.Str _)   -> "String"
    Ann.At _ (Can.Chr _)   -> "char"
    Ann.At _ (Can.VarLocal name) ->
        case Map.lookup name solvedMap of
            Just ty -> typeToRustString Map.empty ty
            Nothing -> "String"
    Ann.At _ (Can.Binop op _ _ _ a _) ->
        case op of
            "+" -> "i64"; "-" -> "i64"; "*" -> "i64"
            "/" -> "i64"; "%" -> "i64"
            "++" -> "String"
            "&&" -> "bool"; "||" -> "bool"
            "==" -> "bool"; "/=" -> "bool"
            _ -> solveArgType solvedMap a
    _ -> "String"

binopToRust :: String -> String
binopToRust op = case op of
    "+" -> "+"
    "-" -> "-"
    "*" -> "*"
    "/" -> "/"
    "%" -> "%"
    "==" -> "=="
    "/=" -> "!="
    "<" -> "<"
    ">" -> ">"
    "<=" -> "<="
    ">=" -> ">="
    "&&" -> "&&"
    "||" -> "||"
    "::" -> "::"  -- cons
    "++" -> "++"
    _ -> op

defToRustString :: EmitCtx -> Can.Def -> String
-- Zero-arg Def: inject .clone() for captured locals that are used ≥ 2 times,
-- so multiple uses of the same variable (f(x); g(x) pattern) compile.
defToRustString ctx (Can.Def (Ann.At _ name) [] body) =
    -- Only outer-captured multi-use vars get a clone prelude — collectFree…
    -- excludes vars bound inside `body` (e.g. case-pattern vars), which aren't
    -- in scope at the prelude. Their use-site clones come from ecCloneVars.
    let counts = collectFreeVarLocalsMulti body
        multi = [ v | (v, c) <- Map.toList counts, c >= 2 ]
        clones = concatMap (\v -> "let " ++ v ++ " = " ++ v ++ ".clone(); ") multi
    in case body of
        Ann.At _ (Can.Lambda [] lambdaBody) ->
            let inner = "|| { " ++ exprToRustString ctx lambdaBody ++ " }"
            in name ++ " = " ++ if null multi then inner else "{ " ++ clones ++ inner ++ " }"
        _ ->
            let inner = exprToRustString ctx body
            in name ++ " = " ++ if null multi then inner else "{ " ++ clones ++ inner ++ " }"
-- Multi-arg Def: closure binding.
defToRustString ctx (Can.Def (Ann.At _ name) params body) =
    name ++ " = |" ++ intercalate ", " (map patternToRustParam params) ++ "| { " ++ exprToRustString ctx body ++ " }"
defToRustString _ctx _ = "_ = unimplemented()"

branchToRustString :: EmitCtx -> Can.CaseBranch -> String
branchToRustString ctx (Can.CaseBranch pat body) =
    let patStr  = patternToMatchString (ecRecordMap ctx) pat
        -- Zero-arg top-level functions used as case values must be called.
        bodyExpr = case body of
            Ann.At _ (Can.VarTopLevel mod name) ->
                let modStr = ModuleName._name mod
                    rawName = (if null modStr then "" else map (\c -> if c == '.' then '_' else c) modStr ++ "_") ++ name
                in toSnakeCase rawName ++ "()"
            _ -> exprToRustString ctx body
        -- Slice patterns bind references (&T for head, &[T] for tail).
        -- Inject .clone() / .to_vec() so the body sees owned values.
        prefix = case pat of
            Ann.At _ (Can.PCons headPat tailPat) ->
                let hc = concatMap (\v -> "let " ++ v ++ " = " ++ v ++ ".clone(); ") (patBindingVars headPat)
                    tv = concatMap (\v -> "let " ++ v ++ " = " ++ v ++ ".to_vec(); ") (patBindingVars tailPat)
                in hc ++ tv
            Ann.At _ (Can.PList items) ->
                concatMap (\v -> "let " ++ v ++ " = " ++ v ++ ".clone(); ") (concatMap patBindingVars items)
            _ -> ""
    in if null prefix && not ("let " `isPrefixOf` bodyExpr) && not ("if " `isPrefixOf` bodyExpr)
       then patStr ++ " => " ++ bodyExpr
       else patStr ++ " => { " ++ prefix ++ bodyExpr ++ " }"

-- | Sub-A.10 C5: case-arm emit for branches under a `.as_str()`-wrapped
-- scrutinee. PVar bindings are `&str`; convert them to `String` at the body
-- binding site so downstream uses (e.g. constructor args) get the owned
-- value. Non-PVar patterns delegate to the normal emit.
branchToRustStringStrWrap :: EmitCtx -> Can.CaseBranch -> String
branchToRustStringStrWrap ctx br@(Can.CaseBranch pat body) =
    case pat of
        Ann.At _ (Can.PVar n) ->
            let patStr = rustSafeIdent n
                bodyStr = exprToRustString ctx body
                prelude = "let " ++ patStr ++ " = " ++ patStr ++ ".to_string(); "
            in patStr ++ " => { " ++ prelude ++ bodyStr ++ " }"
        _ -> branchToRustString ctx br

patternToMatchString :: Map.Map String String -> Can.Pattern -> String
patternToMatchString _recMap (Ann.At _ pat) = case pat of
    Can.PVar n -> rustSafeIdent n
    Can.PAnything -> "_"
    Can.PInt i -> show i
    Can.PBool b -> if b then "true" else "false"
    Can.PChr c -> "'" ++ c ++ "'"
    Can.PStr s -> show s
    Can.PUnit -> "()"
    Can.PCtor{Can._p_home = home, Can._p_type = typeName, Can._p_name = name, Can._p_args = args} ->
        let subPats = map (\(Can.PatternCtorArg _ _ p) -> patternToMatchString _recMap p) args
            fullName = kernelCtorToRust home typeName name
        in fullName ++ if null subPats then "" else "(" ++ intercalate ", " subPats ++ ")"
    Can.PTuple a b rest -> 
        "(" ++ intercalate ", " (map (patternToMatchString _recMap) (a:b:rest)) ++ ")"
    Can.PRecord fields ->
        let key = intercalate "," fields
        in case Map.lookup key _recMap of
            Just structName -> structName ++ " { " ++ intercalate ", " fields ++ " }"
            Nothing -> "{ " ++ intercalate ", " fields ++ " }"
    Can.PCons a b ->
        let (heads, tailPat) = flattenCons _recMap a b
            allParts = heads ++ if tailPat == "_" then [".."] else [tailPat ++ " @ .."]
        in "[" ++ intercalate ", " allParts ++ "]"
    Can.PList items -> "[" ++ intercalate ", " (map (patternToMatchString _recMap) items) ++ "]"
    Can.PAlias pat _ -> patternToMatchString _recMap pat
    _ -> "_"

ctorArgToPattern :: Can.PatternCtorArg -> String
ctorArgToPattern (Can.PatternCtorArg _ _ pat) = patternToMatchString Map.empty pat

-- | Flatten nested cons patterns into a head-list and tail.
-- e.g. x::y::rest → (["x", "y"], "rest")  → emits [x, y, rest @ ..]
flattenCons :: Map.Map String String -> Can.Pattern -> Can.Pattern -> ([String], String)
flattenCons recMap headPat tailPat =
    let h = patternToMatchString recMap headPat
    in case tailPat of
        Ann.At _ (Can.PCons h2 t2) ->
            let (moreHeads, tail) = flattenCons recMap h2 t2
            in (h : moreHeads, tail)
        Ann.At _ (Can.PList items) ->
            let itemStrs = map (patternToMatchString recMap) items
            in (h : itemStrs, "_")
        Ann.At _ (Can.PVar v) ->
            ([h], v)
        Ann.At _ Can.PAnything ->
            ([h], "_")
        _ ->
            ([h], "_")
    where
    unwrapPat (Ann.At _ (Can.PAlias inner _)) = inner
    unwrapPat p = p

buildProgram :: [Can.Module] -> Map.Map String Can.Type -> Map.Map Ann.Region Can.Type -> Map.Map (String, String) (String, String) -> RustBuilder
buildProgram mods solvedTypes regionTypes kernelAliases =
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
        
        recordMap = Map.union aliasMap anonKeyMap

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

        ctx = EmitCtx { ecRecordMap = recordMap, ecSolvedTypes = solvedTypes, ecRegionTypes = regionTypes, ecExpectedType = Nothing, ecInGenericFn = False, ecCloneVars = Set.empty, ecCopyVars = Set.empty, ecPipeInnerType = Nothing, ecUsesTaskRun = usesTaskRun usage, ecZeroArgDefs = zeroArgDefs, ecNoCloneVars = noCloneVars, ecCtorArity = ctorArity, ecCtorFieldTypes = ctorFieldTypes, ecKernelAliases = kernelAliases }
        usage = analyzeKernelUsage mods
        zeroArgDefs = collectZeroArgDefs mods
        noCloneVars = Set.empty
        existingTypes = concatMap (\m ->
            let skyModName = ModuleName._name (Can._name m)         -- "Std.Decimal" — un-mangled, for runtimeOpaqueTypes lookup
                prefix     = moduleNameToRust (Can._name m)          -- "Std_Decimal" — mangled, for codegen names
            in unionsToRustTypes recordMap skyModName prefix (Can._unions m)
            ++ aliasesToRustTypes recordMap skyModName prefix (Can._aliases m)) mods
    in RustBuilder
        { builderModules = map (buildModule ctx) mods
        , builderTypes = existingTypes ++ anonDefs
        , builderKernels = usage
        , builderFfiOpaques = Set.empty  -- populated by generateRust via passed FFI types
        }

-- | Backend-specific sqlx types
dbPoolType :: String -> String
dbPoolType "postgres" = "sqlx::postgres::PgPool"
dbPoolType "mysql"    = "sqlx::mysql::MySqlPool"
dbPoolType _          = "sqlx::sqlite::SqlitePool"

dbRowType :: String -> String
dbRowType "postgres" = "sqlx::postgres::PgRow"
dbRowType "mysql"    = "sqlx::mysql::MySqlRow"
dbRowType _          = "sqlx::sqlite::SqliteRow"

-- | Driver-specific helper functions emitted into the generated config.rs.
-- Two helpers:
--
--   db_last_insert_id(&QueryResult) -> i64
--     sqlite: res.last_insert_rowid()
--     mysql:  res.last_insert_id() as i64
--     postgres: 0 (postgres has no auto last-insert-id; use INSERT ... RETURNING id)
--
--   db_format_sql(String) -> String
--     sqlite + mysql: identity (both use `?` placeholders)
--     postgres: rewrites `?` to `$1, $2, …` (postgres's numbered placeholders)
--
-- These keep db.rs backend-agnostic — it just calls into config:: helpers
-- and the right impl is generated based on the sky.toml [database] driver.
dbBackendHelpers :: String -> [String]
dbBackendHelpers "postgres" =
    [ "// Postgres has no auto last-insert-id. Returns 0; use"
    , "// `INSERT … RETURNING id` + Db.queryDecode to fetch it explicitly."
    , "pub fn db_last_insert_id(_res: &sqlx::postgres::PgQueryResult) -> i64 { 0 }"
    , ""
    , "/// Rewrite sqlx-canonical `?` placeholders to postgres `$1, $2, …`."
    , "pub fn db_format_sql(sql: String) -> String {"
    , "    let mut out = String::with_capacity(sql.len() + 4);"
    , "    let mut n = 0usize;"
    , "    for c in sql.chars() {"
    , "        if c == '?' { n += 1; out.push_str(&format!(\"${}\", n)); }"
    , "        else { out.push(c); }"
    , "    }"
    , "    out"
    , "}"
    , ""
    , "/// Sub-C.1 — DDL fragment for an auto-incrementing primary key column."
    , "/// Postgres: BIGSERIAL (auto-id, 64-bit)."
    , "pub fn db_auto_id_column() -> &'static str { \"id BIGSERIAL PRIMARY KEY\" }"
    ]
dbBackendHelpers "mysql" =
    [ "pub fn db_last_insert_id(res: &sqlx::mysql::MySqlQueryResult) -> i64 {"
    , "    res.last_insert_id() as i64"
    , "}"
    , ""
    , "/// MySQL uses `?` placeholders, same as sqlite — identity."
    , "pub fn db_format_sql(sql: String) -> String { sql }"
    , ""
    , "/// Sub-C.1 — DDL fragment for an auto-incrementing primary key column."
    , "/// MySQL: BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY."
    , "pub fn db_auto_id_column() -> &'static str {"
    , "    \"id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY\""
    , "}"
    ]
dbBackendHelpers _ =  -- sqlite default
    [ "pub fn db_last_insert_id(res: &sqlx::sqlite::SqliteQueryResult) -> i64 {"
    , "    res.last_insert_rowid()"
    , "}"
    , ""
    , "/// SQLite uses `?` placeholders — identity."
    , "pub fn db_format_sql(sql: String) -> String { sql }"
    , ""
    , "/// Sub-C.1 — DDL fragment for an auto-incrementing primary key column."
    , "/// SQLite: INTEGER PRIMARY KEY AUTOINCREMENT."
    , "pub fn db_auto_id_column() -> &'static str {"
    , "    \"id INTEGER PRIMARY KEY AUTOINCREMENT\""
    , "}"
    ]

emitRust :: RustBuilder -> String -> String -> [String] -> (String, [(String, String)])
emitRust b dbPath dbDriver ffiSlugs =
    let modules = builderModules b
        -- Each module gets its own .rs file (except Main — kept inline
        -- to avoid naming conflict with main.rs).  Included via
        -- pub mod + pub use so re-exports keep bare names working.
        moduleFiles = map moduleToRustFile (filter (\m -> modName m /= "Main") modules)
        inlineModules = filter (\m -> modName m == "Main") modules
        modDecls = concatMap (\(name, _) ->
            [ "pub mod " ++ toSnakeCase name ++ ";"
            , "pub use " ++ toSnakeCase name ++ "::*;"
            ]) moduleFiles
            ++ concatMap (\slug ->
            [ "pub mod " ++ slug ++ ";"
            , "pub use " ++ slug ++ "::*;"
            ]) ffiSlugs
        -- Wrappers for functions where E can't be inferred from args.
        -- These delegate to the generic sky_runtime functions, instantiating E = SkyError.
        wrapperFns = 
            [ "type SkyTask<A> = sky_runtime::SkyTask<SkyError, A>;"
            , "type Decoder<T> = sky_runtime::json::Decoder<SkyError, T>;"
            , ""
            ] ++
            -- Wrappers for functions where E can't be inferred from args.
            -- These shadow the re-exported generic versions from sky_runtime
            -- (with #[allow(unused)] the warning is suppressed).
            [ "pub fn ok_res<A>(a: A) -> SkyResult<SkyError, A> { sky_runtime::core::ok_res(a) }"
            , "pub fn task_succeed<A: Send + 'static>(a: A) -> SkyTask<A> { sky_runtime::task::task_succeed(a) }"
            , "pub fn log_info(msg: String) -> SkyTask<()> { sky_runtime::log::log_info(msg) }"
            , "pub fn log_debug(msg: String) -> SkyTask<()> { sky_runtime::log::log_debug(msg) }"
            , "pub fn log_warn(msg: String) -> SkyTask<()> { sky_runtime::log::log_warn(msg) }"
            , "pub fn log_info_with(msg: String, attrs: Vec<String>) -> SkyTask<()> { sky_runtime::log::log_info_with(msg, attrs) }"
            , "pub fn log_error_with(msg: String, attrs: Vec<String>) -> SkyTask<()> { sky_runtime::log::log_error_with(msg, attrs) }"
            , "pub fn system_args(_: ()) -> SkyTask<Vec<String>> { sky_runtime::system::system_args(()) }"
            , "pub fn system_setenv(key: String, val: String) -> SkyTask<()> { sky_runtime::system::system_setenv(key, val) }"
            , "pub fn system_unsetenv(key: String) -> SkyTask<()> { sky_runtime::system::system_unsetenv(key) }"
            , "pub fn time_now(_: ()) -> SkyTask<i64> { sky_runtime::time::time_now(()) }"
            , "pub fn time_sleep(ms: i64) -> SkyTask<()> { sky_runtime::time::time_sleep(ms) }"
            , "pub fn time_unix_millis(_: ()) -> SkyTask<i64> { sky_runtime::time::time_unix_millis(()) }"
            , "pub fn random_int(lo: i64, hi: i64) -> SkyTask<i64> { sky_runtime::random::random_int(lo, hi) }"
            , "pub fn random_float(_: ()) -> SkyTask<f64> { sky_runtime::random::random_float(()) }"
            , "pub fn random_choice(items: Vec<String>) -> SkyTask<String> { sky_runtime::random::random_choice(items) }"
            , "pub fn file_read_file(path: String) -> SkyTask<String> { sky_runtime::file::file_read_file(path) }"
            , "pub fn file_write_file(path: String, content: String) -> SkyTask<()> { sky_runtime::file::file_write_file(path, content) }"
            , "pub fn file_delete(path: String) -> SkyTask<()> { sky_runtime::file::file_delete(path) }"
            , "pub fn crypto_random_bytes(n: i64) -> SkyTask<Vec<i64>> { sky_runtime::crypto::crypto_random_bytes(n) }"
            , "pub fn crypto_random_token(n: i64) -> SkyTask<String> { sky_runtime::crypto::crypto_random_token(n) }"
            ] ++
            (if usesDb (builderKernels b)
             then [ "pub fn db_connect(_: ()) -> SkyTask<Db> { sky_runtime::db::db_connect(()) }"
                  , "pub fn db_open(_: ()) -> SkyTask<Db> { sky_runtime::db::db_open(()) }"
                  , "pub fn db_open_with_path(path: String) -> SkyTask<Db> { sky_runtime::db::db_open_with_path(path) }"
                  , "pub fn db_exec_raw(conn: Db, sql: String) -> SkyTask<()> { sky_runtime::db::db_exec_raw(conn, sql) }"
                  , "pub fn db_exec(conn: Db, sql: String, params: Vec<String>) -> SkyTask<()> { sky_runtime::db::db_exec(conn, sql, params) }"
                   , "pub fn db_query(conn: Db, sql: String, params: Vec<String>) -> SkyTask<Vec<HashMap<String, String>>> { sky_runtime::db::db_query(conn, sql, params) }"
                   , "pub fn db_migrate_apply(db: Db, migrations: Vec<(String, String)>) -> SkyTask<Vec<String>> { sky_runtime::db::db_migrate_apply::<SkyError>(db, migrations) }"
                   ]
              else [])
        -- impl From<String> for SkyError when Sky.Core.Error is present
        fromStrImpl = if hasErrorType b
            then let errName = "SkyCoreErrorError"
                     kindName = "SkyCoreErrorErrorKind"
                     infoName = "SkyCoreErrorErrorInfo"
                 in [ "impl From<String> for " ++ errName ++ " {"
                    , "    fn from(s: String) -> Self {"
                    , "        " ++ errName ++ "::Error("
                    , "            " ++ kindName ++ "::Unexpected,"
                    , "            " ++ infoName ++ " { details: SkyMaybe::Nothing, message: s }"
                    , "        )"
                    , "    }"
                    , "}"
                    ]
            else []
        mainCode = unlines $ concat
            [ headerSection
            , modDecls
            , [""]
            , importSection (builderKernels b) dbDriver
            , basicTypeSection
            , userTypeSection b
            , fromStrImpl
            , skyErrorLine b
            , wrapperFns
            , [""]
            , concatMap (concatMap itemToRustStrings . modItems) inlineModules
            , kernelHelperSection
            , ffiPlaceholderSection b
            , entryPointSection (builderKernels b)
            ]
    in (mainCode, moduleFiles)

-- | Header and file-level attributes
headerSection :: [String]
headerSection =
    [ "// Generated by Sky compiler (Rust target)"
    , "#![allow(unused, non_snake_case)]"
    , ""
    , "pub mod sky_runtime;"
    , "pub use sky_runtime::*;"
    , ""
    ]

-- | Conditional imports — only include tokio/sqlx when actually used
importSection :: UsedKernels -> String -> [String]
importSection uk dbDriver =
    [ "use std::collections::HashMap;"
    , "use std::fmt;"
    , "use std::future::Future;"
    , "use std::future::ready;"
    , "use std::pin::Pin;"
    , "use std::sync::Arc;"
    , "use std::task::{Wake, Waker, Context, Poll};"
    ] ++
    (if usesTaskRun uk || usesTaskParallel uk || usesDb uk
     then ["use tokio::runtime::Runtime;"] else []) ++
    (if usesTaskParallel uk
     then [] else []) ++  -- tokio::spawn used via fully-qualified path
    (if usesDb uk
     then
        [ "use " ++ dbPoolType dbDriver ++ " as DbPool;"
        , "use " ++ dbRowType dbDriver ++ " as DbRow;"
        , "use sqlx::{Column, Row};"
        ]
     else [])

-- | Basic type aliases (always emitted)
basicTypeSection :: [String]
basicTypeSection =
    [ ""
    , "// Basic types"
    , "type SkyInt = i64;"
    , "type SkyFloat = f64;"
    , "type SkyBool = bool;"
    , "type SkyString = String;"
    , "type Value = JsonVal;"
    , ""
    ]

-- | Ffi.kernel polyfill — kernel dispatch stubs that are never called at
-- runtime (codegen routes calls directly to kernel implementations).
-- | Non-recursive List.map for Task-returning closures (no T1: Clone required).
-- Referenced from kernelToRust for List.map.
kernelHelperSection :: [String]
kernelHelperSection =
    [ ""
    , "// Ffi.kernel polyfill — should be unreachable in Rust target;"
    , "// the codegen routes Ffi.kernel calls directly, but some construction"
    , "// paths (e.g. inline let-bindings of Ffi.kernel) leave a residual call."
    , "#[allow(unreachable_code)]"
    , "fn ffi_kernel_polyfill<T>(_name: String) -> T { panic!(\"Ffi.kernel '{}' should not be called in Rust target\", _name) }"
    , ""
    , "// List helpers"
    , "pub fn list_map_consume<T0, T1>(f: impl Fn(T0) -> T1, list: Vec<T0>) -> Vec<T1> {"
    , "    list.into_iter().map(f).collect()"
    , "}"
    , ""
    ]
 
-- | User defined types (unions, aliases)
userTypeSection :: RustBuilder -> [String]
userTypeSection b =
    [ ""
    , "// ==========================================="
    , "// USER TYPES"
    , "// ==========================================="
    , ""
    ] ++ map typeDefToString (builderTypes b)

-- | SkyError type alias + str_err helper — conditional on Error module presence.
-- Must be emitted AFTER userTypeSection (SkyCoreErrorError ADT) and BEFORE
-- dbSection/jsonSection/extraKernelSection (which call str_err).
skyErrorLine :: RustBuilder -> [String]
skyErrorLine b =
    [ ""
    , if hasErrorType b
      then let errName = toCamelCase "Sky_Core_Error_Error"
               kindName = toCamelCase "Sky_Core_Error_ErrorKind"
               infoName = toCamelCase "Sky_Core_Error_ErrorInfo"
           in unlines
                [ "type SkyError = " ++ errName ++ ";"
                , "fn str_err(s: &str) -> SkyError {"
                , "    " ++ errName ++ "::Error("
                , "        " ++ kindName ++ "::Unexpected,"
                , "        " ++ infoName ++ " { details: SkyMaybe::Nothing, message: s.to_string() }"
                , "    )"
                , "}"
                ]
      else "type SkyError = String;\nfn str_err(s: &str) -> SkyError { s.to_string() }"
    , ""
    ]

-- | User modules (functions, types, etc.)
-- | FFI placeholder types
ffiPlaceholderSection :: RustBuilder -> [String]
ffiPlaceholderSection b =
    [ ""
    , "// ==========================================="
    , "// FFI PLACEHOLDER TYPES (types referenced but not defined)"
    , "// ==========================================="
    , ""
    ] ++ map ffiPlaceholder (collectUndefinedTypes b)

-- | Entry point
entryPointSection :: UsedKernels -> [String]
entryPointSection uk =
    let hasTokio = usesTaskRun uk || usesTaskParallel uk || usesDb uk || usesHttpServer uk
        mainIsTask = not (usesTaskRun uk)  -- if user uses Task.run, main returns ()
    in
    [ ""
    , "// ==========================================="
    , "// ENTRY POINT"
    , "// ==========================================="
    , ""
    , "fn main() {"
    ] ++ (if hasTokio && mainIsTask then
        -- sky_main returns SkyTask<()>, run it via block_on
        [ "    match block_on(sky_main()) {"
        , "        SkyResult::Ok(_) => (),"
        , "        SkyResult::Err(e) => { eprintln!(\"{:?}\", e); std::process::exit(1); }"
        , "    }"
        , "}"
        ]
      else if mainIsTask then
        -- sky_main returns SkyTask<()> but no tokio: side effects fire
        -- eagerly inside log_info etc.  Call and drop.
        [ "    sky_main();",
          "}"
        ]
      else
        -- sky_main returns (), Task.run is used inside
        [ "    sky_main();"
        , "}"
        ])

typeDefToString :: RustTypeDef -> String
typeDefToString (REnumDef name gens variants) =
    "#[derive(Clone, Debug, PartialEq)]\npub enum " ++ name ++ gens ++ " {\n" ++ intercalate ",\n" (map (\(n, mt) -> "    " ++ n ++ maybe "" (\x -> "(" ++ x ++ ")") mt) variants) ++ "\n}"
typeDefToString (RStructDef name gens fields) =
    "#[derive(Clone, Debug, PartialEq)]\npub struct " ++ name ++ gens ++ " {\n" ++ intercalate ",\n" (map (\(n, t) -> "    " ++ n ++ ": " ++ t) fields) ++ "\n}"
typeDefToString (RAliasDef name ty) = "pub type " ++ name ++ " = " ++ ty ++ ";"
typeDefToString (RPubUseAlias codegenName rustPath) =
    "pub use " ++ rustPath ++ " as " ++ codegenName ++ ";"

-- | Extract a module's content as (snake_case_file_stem, source_content).
-- Used by emitRust to produce per-module .rs files.
-- Each module file starts with `use crate::*;` so inline stubs (ok_res,
-- SkyResult, task_*, etc.) and sky_runtime types are visible inside the
-- real module boundary created by `pub mod`.
moduleToRustFile :: RustModule -> (String, String)
moduleToRustFile m =
    let name = modName m
        items = concatMap itemToRustStrings (modItems m)
    in (toSnakeCase name, "#[allow(unused)]\nuse crate::*;\n\n" ++ unlines items)

kernelCtorToRust :: ModuleName.Canonical -> String -> String -> String
kernelCtorToRust modName typeName ctorName =
    let modStr = ModuleName._name modName
    in case (modStr, typeName, ctorName) of
        ("Sky.Core.Basics", "Bool", "True") -> "true"
        ("Sky.Core.Basics", "Bool", "False") -> "false"
        ("Sky.Core.Maybe", "Maybe", c) -> "SkyMaybe::" ++ c
        ("Sky.Core.Result", "Result", c) -> "SkyResult::" ++ c
        _ -> let modPrefix = if null modStr then "" else map (\c -> if c == '.' then '_' else c) modStr ++ "_"
             in toCamelCase (modPrefix ++ typeName) ++ "::" ++ ctorName

kernelToRust :: String -> String -> String
kernelToRust mod name = case (mod, name) of
    -- List functions (Q3)
    ("List", "map") -> "list_map_consume"
    ("Sky.Core.List", "map") -> "list_map_consume"
    ("List", "foldl") -> "list_foldl"
    ("Sky.Core.List", "foldl") -> "list_foldl"
    ("List", "foldr") -> "list_foldr"
    ("Sky.Core.List", "foldr") -> "list_foldr"
    ("List", "range") -> "list_range"
    ("Sky.Core.List", "range") -> "list_range"
    ("List", "indexedMap") -> "list_indexed_map"
    ("Sky.Core.List", "indexedMap") -> "list_indexed_map"
    ("List", "concatMap") -> "list_concat_map"
    ("Sky.Core.List", "concatMap") -> "list_concat_map"
    ("List", "zip") -> "list_zip"
    ("Sky.Core.List", "zip") -> "list_zip"
    ("List", "filter") -> "list_filter"
    ("Sky.Core.List", "filter") -> "list_filter"
    ("List", "member") -> "list_member"
    ("Sky.Core.List", "member") -> "list_member"
    ("List", "any") -> "list_any"
    ("Sky.Core.List", "any") -> "list_any"
    ("List", "all") -> "list_all"
    ("Sky.Core.List", "all") -> "list_all"
    -- String kernel functions: route directly to runtime implementations
    ("String", "fromInt") -> "string_from_int"
    ("Sky.Core.String", "fromInt") -> "string_from_int"
    ("String", "fromFloat") -> "string_from_float"
    ("Sky.Core.String", "fromFloat") -> "string_from_float"
    ("String", "length") -> "string_length"
    ("Sky.Core.String", "length") -> "string_length"
    ("String", "isEmpty") -> "string_is_empty"
    ("Sky.Core.String", "isEmpty") -> "string_is_empty"
    ("String", "reverse") -> "string_reverse"
    ("Sky.Core.String", "reverse") -> "string_reverse"
    ("String", "append") -> "string_append"
    ("Sky.Core.String", "append") -> "string_append"
    ("String", "toInt") -> "string_to_int"
    ("Sky.Core.String", "toInt") -> "string_to_int"
    ("String", "toLower") -> "string_to_lower"
    ("Sky.Core.String", "toLower") -> "string_to_lower"
    ("String", "toUpper") -> "string_to_upper"
    ("Sky.Core.String", "toUpper") -> "string_to_upper"
    ("String", "trim") -> "string_trim"
    ("Sky.Core.String", "trim") -> "string_trim"
    ("String", "split") -> "string_split"
    ("Sky.Core.String", "split") -> "string_split"
    ("String", "join") -> "string_join"
    ("Sky.Core.String", "join") -> "string_join"
    -- Encoding (sub-A.1)
    ("Encoding", "base64Encode")        -> "base64_encode"
    ("Sky.Core.Encoding", "base64Encode") -> "base64_encode"
    ("Encoding", "base64Decode")        -> "base64_decode"
    ("Sky.Core.Encoding", "base64Decode") -> "base64_decode"
    ("Encoding", "urlEncode")           -> "url_encode"
    ("Sky.Core.Encoding", "urlEncode")  -> "url_encode"
    ("Encoding", "urlDecode")           -> "url_decode"
    ("Sky.Core.Encoding", "urlDecode")  -> "url_decode"
    -- Renamed (was hex_encode/hex_decode) to avoid colliding with
    -- user-FFI bindings to the `hex` crate (examples/rust/16-hex).
    ("Encoding", "hexEncode")           -> "encoding_hex_encode"
    ("Sky.Core.Encoding", "hexEncode")  -> "encoding_hex_encode"
    ("Encoding", "hexDecode")           -> "encoding_hex_decode"
    ("Sky.Core.Encoding", "hexDecode")  -> "encoding_hex_decode"
    -- Regex (sub-A.2)
    ("Regex", "match")              -> "regex_match"
    ("Sky.Core.Regex", "match")     -> "regex_match"
    ("Regex", "find")               -> "regex_find"
    ("Sky.Core.Regex", "find")      -> "regex_find"
    ("Regex", "findAll")            -> "regex_find_all"
    ("Sky.Core.Regex", "findAll")   -> "regex_find_all"
    ("Regex", "replace")            -> "regex_replace"
    ("Sky.Core.Regex", "replace")   -> "regex_replace"
    ("Regex", "split")              -> "regex_split"
    ("Sky.Core.Regex", "split")     -> "regex_split"
    -- Crypto completion (sub-A.3) — sha256 + random* already present
    ("Crypto", "sha512")                       -> "crypto_sha512"
    ("Sky.Core.Crypto", "sha512")              -> "crypto_sha512"
    ("Crypto", "sha1")                         -> "crypto_sha1"
    ("Sky.Core.Crypto", "sha1")                -> "crypto_sha1"
    ("Crypto", "md5")                          -> "crypto_md5"
    ("Sky.Core.Crypto", "md5")                 -> "crypto_md5"
    ("Crypto", "hmacSha256")                   -> "crypto_hmac_sha256"
    ("Sky.Core.Crypto", "hmacSha256")          -> "crypto_hmac_sha256"
    ("Crypto", "hmacSha512")                   -> "crypto_hmac_sha512"
    ("Sky.Core.Crypto", "hmacSha512")          -> "crypto_hmac_sha512"
    ("Crypto", "rsaSha256Sign")                -> "crypto_rsa_sha256_sign"
    ("Sky.Core.Crypto", "rsaSha256Sign")       -> "crypto_rsa_sha256_sign"
    ("Crypto", "rsaSha256Verify")              -> "crypto_rsa_sha256_verify"
    ("Sky.Core.Crypto", "rsaSha256Verify")     -> "crypto_rsa_sha256_verify"
    ("Crypto", "constantTimeEqual")            -> "crypto_constant_time_equal"
    ("Sky.Core.Crypto", "constantTimeEqual")   -> "crypto_constant_time_equal"
    -- v0.15.44 symmetric AEAD (sub-D)
    -- Sky.Core.Uuid (String surface; v0.15.x)
    ("Uuid", "v4")                             -> "uuid_v4"
    ("Sky.Core.Uuid", "v4")                    -> "uuid_v4"
    ("Uuid", "v7")                             -> "uuid_v7"
    ("Sky.Core.Uuid", "v7")                    -> "uuid_v7"
    ("Uuid", "parse")                          -> "uuid_parse"
    ("Sky.Core.Uuid", "parse")                 -> "uuid_parse"
    ("Crypto", "aesGcmEncrypt")                -> "crypto_aes_gcm_encrypt"
    ("Sky.Core.Crypto", "aesGcmEncrypt")       -> "crypto_aes_gcm_encrypt"
    ("Crypto", "aesGcmDecrypt")                -> "crypto_aes_gcm_decrypt"
    ("Sky.Core.Crypto", "aesGcmDecrypt")       -> "crypto_aes_gcm_decrypt"
    ("Crypto", "chacha20Encrypt")              -> "crypto_chacha20_encrypt"
    ("Sky.Core.Crypto", "chacha20Encrypt")     -> "crypto_chacha20_encrypt"
    ("Crypto", "chacha20Decrypt")              -> "crypto_chacha20_decrypt"
    ("Sky.Core.Crypto", "chacha20Decrypt")     -> "crypto_chacha20_decrypt"
    ("Crypto", "aesKeyFromPassword")           -> "crypto_aes_key_from_password"
    ("Sky.Core.Crypto", "aesKeyFromPassword")  -> "crypto_aes_key_from_password"
    ("Crypto", "chachaKeyFromPassword")        -> "crypto_chacha_key_from_password"
    ("Sky.Core.Crypto", "chachaKeyFromPassword") -> "crypto_chacha_key_from_password"
    -- Std.Time advanced (sub-A.5)
    ("Time", "inZone")            -> "time_in_zone"
    ("Time", "formatInZone")      -> "time_format_in_zone"
    ("Time", "addDays")           -> "time_add_days"
    ("Time", "addHours")          -> "time_add_hours"
    ("Time", "addMinutes")        -> "time_add_minutes"
    ("Time", "addSeconds")        -> "time_add_seconds"
    ("Time", "addMonths")         -> "time_add_months"
    ("Time", "addYears")          -> "time_add_years"
    ("Time", "year")              -> "time_year"
    ("Time", "month")             -> "time_month"
    ("Time", "day")               -> "time_day"
    ("Time", "dayOfWeek")         -> "time_day_of_week"
    ("Time", "dayOfYear")         -> "time_day_of_year"
    ("Time", "weekOfYear")        -> "time_week_of_year"
    ("Time", "isWeekend")         -> "time_is_weekend"
    ("Time", "daysInMonth")       -> "time_days_in_month"
    ("Time", "isLeapYear")        -> "time_is_leap_year"
    ("Time", "startOfDay")        -> "time_start_of_day"
    ("Time", "endOfDay")          -> "time_end_of_day"
    ("Time", "startOfWeek")       -> "time_start_of_week"
    ("Time", "startOfMonth")      -> "time_start_of_month"
    ("Time", "endOfMonth")        -> "time_end_of_month"
    ("Time", "startOfYear")       -> "time_start_of_year"
    ("Time", "endOfYear")         -> "time_end_of_year"
    -- Std.Decimal (sub-A.6)
    ("Decimal", "fromString")     -> "decimal_from_string"
    ("Decimal", "fromInt")        -> "decimal_from_int"
    ("Decimal", "fromFloat")      -> "decimal_from_float"
    ("Decimal", "fromMinor")      -> "decimal_from_minor"
    ("Decimal", "zero")           -> "decimal_zero"
    ("Decimal", "one")            -> "decimal_one"
    ("Decimal", "oneHundred")     -> "decimal_one_hundred"
    ("Decimal", "toString")       -> "decimal_to_string"
    ("Decimal", "toStringFixed")  -> "decimal_to_string_fixed"
    ("Decimal", "toFloat")        -> "decimal_to_float"
    ("Decimal", "toInt")          -> "decimal_to_int"
    ("Decimal", "toMinor")        -> "decimal_to_minor"
    ("Decimal", "add")            -> "decimal_add"
    ("Decimal", "sub")            -> "decimal_sub"
    ("Decimal", "mul")            -> "decimal_mul"
    ("Decimal", "div")            -> "decimal_div"
    ("Decimal", "mod")            -> "decimal_mod"
    ("Decimal", "neg")            -> "decimal_neg"
    ("Decimal", "abs")            -> "decimal_abs"
    ("Decimal", "round")          -> "decimal_round"
    ("Decimal", "roundHalfUp")    -> "decimal_round_half_up"
    ("Decimal", "truncate")       -> "decimal_truncate"
    ("Decimal", "floor")          -> "decimal_floor"
    ("Decimal", "ceil")           -> "decimal_ceil"
    ("Decimal", "compare")        -> "decimal_compare"
    -- sub-A.8 T1 — Std.Decimal completion (15 kernels)
    ("Decimal", "eq")             -> "decimal_eq"
    ("Decimal", "neq")            -> "decimal_neq"
    ("Decimal", "lt")             -> "decimal_lt"
    ("Decimal", "lte")            -> "decimal_lte"
    ("Decimal", "gt")             -> "decimal_gt"
    ("Decimal", "gte")            -> "decimal_gte"
    ("Decimal", "min")            -> "decimal_min"
    ("Decimal", "max")            -> "decimal_max"
    ("Decimal", "isZero")         -> "decimal_is_zero"
    ("Decimal", "isPositive")     -> "decimal_is_positive"
    ("Decimal", "isNegative")     -> "decimal_is_negative"
    ("Decimal", "percentOf")      -> "decimal_percent_of"
    ("Decimal", "addPercent")     -> "decimal_add_percent"
    ("Decimal", "subPercent")     -> "decimal_sub_percent"
    ("Decimal", "formatWith")     -> "decimal_format_with"
    -- sub-A.8 T2 — Std.Money (11 kernels)
    ("Money", "format")               -> "money_format"
    ("Money", "formatWithCode")       -> "money_format_with_code"
    ("Money", "currencyName")         -> "money_currency_name"
    ("Money", "symbol")               -> "money_symbol"
    ("Money", "minorUnits")           -> "money_minor_units"
    ("Money", "isKnownCurrency")      -> "money_is_known_currency"
    ("Money", "setRate")              -> "money_set_rate"
    ("Money", "getRate")              -> "money_get_rate"
    ("Money", "hasRate")              -> "money_has_rate"
    ("Money", "clearRates")           -> "money_clear_rates"
    ("Money", "allocate")             -> "money_allocate"
    -- sub-A.8 T3 — Sky.Core.Math (8 kernels)
    ("Math", "abs")             -> "math_abs"
    ("Sky.Core.Math", "abs")    -> "math_abs"
    ("Math", "min")             -> "math_min"
    ("Sky.Core.Math", "min")    -> "math_min"
    ("Math", "max")             -> "math_max"
    ("Sky.Core.Math", "max")    -> "math_max"
    ("Math", "sqrt")            -> "math_sqrt"
    ("Sky.Core.Math", "sqrt")   -> "math_sqrt"
    ("Math", "pow")             -> "math_pow"
    ("Sky.Core.Math", "pow")    -> "math_pow"
    ("Math", "floor")           -> "math_floor"
    ("Sky.Core.Math", "floor")  -> "math_floor"
    ("Math", "ceil")            -> "math_ceil"
    ("Sky.Core.Math", "ceil")   -> "math_ceil"
    ("Math", "round")           -> "math_round"
    ("Sky.Core.Math", "round")  -> "math_round"
    ("Math", "pi")              -> "math_pi"
    ("Sky.Core.Math", "pi")     -> "math_pi"
    ("Math", "e")               -> "math_e"
    ("Sky.Core.Math", "e")      -> "math_e"
    -- sub-A.8 T4 — Std.Time advanced (7 kernels)
    ("Time", "diffSeconds")     -> "time_diff_seconds"
    ("Time", "diffMinutes")     -> "time_diff_minutes"
    ("Time", "diffHours")       -> "time_diff_hours"
    ("Time", "diffDays")        -> "time_diff_days"
    ("Time", "fromParts")       -> "time_from_parts"
    ("Time", "zoneOffset")      -> "time_zone_offset"
    ("Time", "zoneName")        -> "time_zone_name"
    -- sub-A.8 T5 — Sky.Core.Dict (6 kernels)
    ("Dict", "empty")           -> "dict_empty"
    ("Sky.Core.Dict", "empty")  -> "dict_empty"
    ("Dict", "insert")          -> "dict_insert"
    ("Sky.Core.Dict", "insert") -> "dict_insert"
    ("Dict", "get")             -> "dict_get"
    ("Sky.Core.Dict", "get")    -> "dict_get"
    ("Dict", "keys")            -> "dict_keys"
    ("Sky.Core.Dict", "keys")   -> "dict_keys"
    ("Dict", "remove")          -> "dict_remove"
    ("Sky.Core.Dict", "remove") -> "dict_remove"
    ("Dict", "member")          -> "dict_member"
    ("Sky.Core.Dict", "member") -> "dict_member"
    ("Dict", "fromList")        -> "dict_from_list"
    ("Sky.Core.Dict", "fromList") -> "dict_from_list"
    -- sub-A.8 T6 — Sky.Core.String additions (4 kernels)
    ("String", "replace")           -> "string_replace"
    ("Sky.Core.String", "replace")  -> "string_replace"
    ("String", "startsWith")        -> "string_starts_with"
    ("Sky.Core.String", "startsWith") -> "string_starts_with"
    ("String", "endsWith")          -> "string_ends_with"
    ("Sky.Core.String", "endsWith") -> "string_ends_with"
    ("String", "repeat")            -> "string_repeat"
    ("Sky.Core.String", "repeat")   -> "string_repeat"
    -- sub-A.8 T7 — Sky.Core.Basics + List (3 kernels)
    ("Basics", "modBy")               -> "basics_mod_by"
    ("Sky.Core.Basics", "modBy")      -> "basics_mod_by"
    ("Basics", "errorToString")       -> "basics_error_to_string"
    ("Sky.Core.Basics", "errorToString") -> "basics_error_to_string"
    ("List", "filterMap")             -> "list_filter_map"
    ("Sky.Core.List", "filterMap")    -> "list_filter_map"
    -- Json.Encode kernel functions: route to runtime implementations
    ("JsonEnc", "string") -> "json_enc_string"
    ("Sky.Core.Json.Encode", "string") -> "json_enc_string"
    ("JsonEnc", "int") -> "json_enc_int"
    ("Sky.Core.Json.Encode", "int") -> "json_enc_int"
    ("JsonEnc", "float") -> "json_enc_float"
    ("Sky.Core.Json.Encode", "float") -> "json_enc_float"
    ("JsonEnc", "bool") -> "json_enc_bool"
    ("Sky.Core.Json.Encode", "bool") -> "json_enc_bool"
    ("JsonEnc", "null") -> "json_enc_null"
    ("Sky.Core.Json.Encode", "null") -> "json_enc_null"
    ("JsonEnc", "encode") -> "json_enc_encode"
    ("Sky.Core.Json.Encode", "encode") -> "json_enc_encode"
    ("JsonEnc", "list") -> "json_enc_list"
    ("Sky.Core.Json.Encode", "list") -> "json_enc_list"
    ("JsonEnc", "object") -> "json_enc_object"
    ("Sky.Core.Json.Encode", "object") -> "json_enc_object"
    -- Json.Decode kernel functions: route to runtime implementations
    ("JsonDec", "string") -> "json_dec_string"
    ("Sky.Core.Json.Decode", "string") -> "json_dec_string"
    ("JsonDec", "int") -> "json_dec_int"
    ("Sky.Core.Json.Decode", "int") -> "json_dec_int"
    ("JsonDec", "float") -> "json_dec_float"
    ("Sky.Core.Json.Decode", "float") -> "json_dec_float"
    ("JsonDec", "bool") -> "json_dec_bool"
    ("Sky.Core.Json.Decode", "bool") -> "json_dec_bool"
    ("JsonDec", "null") -> "json_dec_null"
    ("Sky.Core.Json.Decode", "null") -> "json_dec_null"
    ("JsonDec", "field") -> "json_dec_field"
    ("Sky.Core.Json.Decode", "field") -> "json_dec_field"
    ("JsonDec", "at") -> "json_dec_at"
    ("Sky.Core.Json.Decode", "at") -> "json_dec_at"
    ("JsonDec", "list") -> "json_dec_list"
    ("Sky.Core.Json.Decode", "list") -> "json_dec_list"
    ("JsonDec", "map") -> "json_dec_map"
    ("Sky.Core.Json.Decode", "map") -> "json_dec_map"
    ("JsonDec", "andThen") -> "json_dec_and_then"
    ("Sky.Core.Json.Decode", "andThen") -> "json_dec_and_then"
    ("JsonDec", "succeed") -> "json_dec_succeed"
    ("Sky.Core.Json.Decode", "succeed") -> "json_dec_succeed"
    ("JsonDec", "fail") -> "json_dec_fail"
    ("Sky.Core.Json.Decode", "fail") -> "json_dec_fail"
    ("JsonDec", "decodeString") -> "json_dec_decode_string"
    ("Sky.Core.Json.Decode", "decodeString") -> "json_dec_decode_string"
    ("JsonDec", "oneOf") -> "json_dec_one_of"
    ("Sky.Core.Json.Decode", "oneOf") -> "json_dec_one_of"
    -- Std.Config — typed TOML/YAML/JSON decoders. The `Decoder a` is the same
    -- runtime representation as Json.Decode's (Decoder<E,T> over a serde_json
    -- Value), so the pure combinators route straight to the json_dec_* kernels
    -- (which already carry their turbofish entries). Only nullable + the format
    -- front-ends (String-first arg order) + loadFromFile live in config_decode.rs.
    ("Config", "string")  -> "json_dec_string"
    ("Std.Config", "string")  -> "json_dec_string"
    ("Config", "int")     -> "json_dec_int"
    ("Std.Config", "int")     -> "json_dec_int"
    ("Config", "float")   -> "json_dec_float"
    ("Std.Config", "float")   -> "json_dec_float"
    ("Config", "bool")    -> "json_dec_bool"
    ("Std.Config", "bool")    -> "json_dec_bool"
    ("Config", "field")   -> "json_dec_field"
    ("Std.Config", "field")   -> "json_dec_field"
    ("Config", "at")      -> "json_dec_at"
    ("Std.Config", "at")      -> "json_dec_at"
    ("Config", "list")    -> "json_dec_list"
    ("Std.Config", "list")    -> "json_dec_list"
    ("Config", "map")     -> "json_dec_map"
    ("Std.Config", "map")     -> "json_dec_map"
    ("Config", "andThen") -> "json_dec_and_then"
    ("Std.Config", "andThen") -> "json_dec_and_then"
    ("Config", "succeed") -> "json_dec_succeed"
    ("Std.Config", "succeed") -> "json_dec_succeed"
    ("Config", "fail")    -> "json_dec_fail"
    ("Std.Config", "fail")    -> "json_dec_fail"
    ("Config", "nullable")     -> "config_nullable"
    ("Std.Config", "nullable")     -> "config_nullable"
    ("Config", "decodeJson")   -> "config_decode_json"
    ("Std.Config", "decodeJson")   -> "config_decode_json"
    ("Config", "decodeToml")   -> "config_decode_toml"
    ("Std.Config", "decodeToml")   -> "config_decode_toml"
    ("Config", "decodeYaml")   -> "config_decode_yaml"
    ("Std.Config", "decodeYaml")   -> "config_decode_yaml"
    ("Config", "loadFromFile") -> "config_load_from_file"
    ("Std.Config", "loadFromFile") -> "config_load_from_file"
    -- Task kernel functions: route to runtime implementations
    ("Task", "succeed") -> "task_succeed"
    ("Sky.Core.Task", "succeed") -> "task_succeed"
    ("Task", "map") -> "task_map"
    ("Sky.Core.Task", "map") -> "task_map"
    ("Task", "andThen") -> "task_and_then"
    ("Sky.Core.Task", "andThen") -> "task_and_then"
    ("Task", "mapError") -> "task_map_error"
    ("Sky.Core.Task", "mapError") -> "task_map_error"
    ("Task", "onError") -> "task_on_error"
    ("Sky.Core.Task", "onError") -> "task_on_error"
    -- Task.perform : Task e a -> Result e a (runs synchronously, keeps the
    -- value). That is task_run, not task_perform (which returns a Task<()> and
    -- drops the value). sub-D fix — surfaced by the retryWith test.
    ("Task", "perform") -> "task_run"
    ("Sky.Core.Task", "perform") -> "task_run"
    ("Task", "sequence") -> "task_sequence"
    ("Sky.Core.Task", "sequence") -> "task_sequence"
    ("Task", "run") -> "task_run"
    ("Sky.Core.Task", "run") -> "task_run"
    ("Task", "parallel") -> "task_parallel"
    ("Sky.Core.Task", "parallel") -> "task_parallel"
    ("Task", "lazy") -> "task_lazy"
    ("Task", "retryWith") -> "task_retry_with"  -- sub-D: run-once (see task.rs)
    ("Sky.Core.Task", "lazy") -> "task_lazy"
    ("Task", "fail") -> "task_fail"
    ("Sky.Core.Task", "fail") -> "task_fail"
    ("Task", "fromResult") -> "task_from_result"
    ("Sky.Core.Task", "fromResult") -> "task_from_result"
    ("Task", "andThenResult") -> "task_and_then_result"
    ("Sky.Core.Task", "andThenResult") -> "task_and_then_result"
    -- Json.Decode.Pipeline
    ("JsonDecP", "required") -> "json_dec_p_required"
    ("Sky.Core.Json.Decode.Pipeline", "required") -> "json_dec_p_required"
    ("JsonDecP", "optional") -> "json_dec_p_optional"
    ("Sky.Core.Json.Decode.Pipeline", "optional") -> "json_dec_p_optional"
    -- Log kernel functions: route to runtime implementations
    ("Log", "println") -> "log_info"
    ("Std.Log", "println") -> "log_info"
    ("Log", "info") -> "log_info"
    ("Std.Log", "info") -> "log_info"
    ("Log", "debug") -> "log_debug"
    ("Std.Log", "debug") -> "log_debug"
    ("Log", "warn") -> "log_warn"
    ("Std.Log", "warn") -> "log_warn"
    ("Log", "error") -> "log_error"
    ("Std.Log", "error") -> "log_error"
    ("Log", "infoWith") -> "log_info_with"
    ("Std.Log", "infoWith") -> "log_info_with"
    ("Log", "debugWith") -> "log_debug_with"
    ("Std.Log", "debugWith") -> "log_debug_with"
    ("Log", "warnWith") -> "log_warn_with"
    ("Std.Log", "warnWith") -> "log_warn_with"
    ("Log", "errorWith") -> "log_error_with"
    ("Std.Log", "errorWith") -> "log_error_with"
    -- Db kernel functions: route to runtime implementations
    ("Db", "open") -> "db_open"
    ("Std.Db", "open") -> "db_open"
    ("Db", "connect") -> "db_connect"
    ("Std.Db", "connect") -> "db_connect"
    ("Db", "exec") -> "db_exec"
    ("Std.Db", "exec") -> "db_exec"
    ("Db", "execRaw") -> "db_exec_raw"
    ("Std.Db", "execRaw") -> "db_exec_raw"
    ("Db", "query") -> "db_query"
    ("Std.Db", "query") -> "db_query"
    ("Db", "getField") -> "db_get_field"
    ("Std.Db", "getField") -> "db_get_field"
    ("Db", "getString") -> "db_get_string"
    ("Std.Db", "getString") -> "db_get_string"
    ("Db", "getInt") -> "db_get_int"
    ("Std.Db", "getInt") -> "db_get_int"
    ("Db", "migrateApply") -> "db_migrate_apply"
    ("Std.Db", "migrateApply") -> "db_migrate_apply"
    -- sub-B: 12 missing Std.Db kernels (lifecycle + CRUD + search + tx)
    ("Db", "close")             -> "db_close"
    ("Std.Db", "close")         -> "db_close"
    ("Db", "getBool")           -> "db_get_bool"
    ("Std.Db", "getBool")       -> "db_get_bool"
    ("Db", "insertRow")         -> "db_insert_row"
    ("Std.Db", "insertRow")     -> "db_insert_row"
    ("Db", "getById")           -> "db_get_by_id"
    ("Std.Db", "getById")       -> "db_get_by_id"
    ("Db", "updateById")        -> "db_update_by_id"
    ("Std.Db", "updateById")    -> "db_update_by_id"
    ("Db", "deleteById")        -> "db_delete_by_id"
    ("Std.Db", "deleteById")    -> "db_delete_by_id"
    ("Db", "findOneByField")    -> "db_find_one_by_field"
    ("Std.Db", "findOneByField") -> "db_find_one_by_field"
    ("Db", "findManyByField")   -> "db_find_many_by_field"
    ("Std.Db", "findManyByField") -> "db_find_many_by_field"
    ("Db", "findByConditions")  -> "db_find_by_conditions"
    ("Std.Db", "findByConditions") -> "db_find_by_conditions"
    ("Db", "unsafeFindWhere")   -> "db_unsafe_find_where"
    ("Std.Db", "unsafeFindWhere") -> "db_unsafe_find_where"
    ("Db", "queryDecode")       -> "db_query_decode"
    ("Std.Db", "queryDecode")   -> "db_query_decode"
    ("Db", "withTransaction")   -> "db_with_transaction"
    ("Std.Db", "withTransaction") -> "db_with_transaction"
    -- Sub-C: Std.Auth — 6 pure crypto + 3 DB-touching kernels.
    ("Auth", "hashPassword")     -> "auth_hash_password"
    ("Std.Auth", "hashPassword") -> "auth_hash_password"
    ("Auth", "hashPasswordCost")     -> "auth_hash_password_cost"
    ("Std.Auth", "hashPasswordCost") -> "auth_hash_password_cost"
    ("Auth", "verifyPassword")     -> "auth_verify_password"
    ("Std.Auth", "verifyPassword") -> "auth_verify_password"
    ("Auth", "passwordStrength")     -> "auth_password_strength"
    ("Std.Auth", "passwordStrength") -> "auth_password_strength"
    ("Auth", "signToken")     -> "auth_sign_token"
    ("Std.Auth", "signToken") -> "auth_sign_token"
    ("Auth", "verifyToken")     -> "auth_verify_token"
    ("Std.Auth", "verifyToken") -> "auth_verify_token"
    ("Auth", "register")     -> "auth_register"
    ("Std.Auth", "register") -> "auth_register"
    ("Auth", "login")     -> "auth_login"
    ("Std.Auth", "login") -> "auth_login"
    ("Auth", "setRole")     -> "auth_set_role"
    ("Std.Auth", "setRole") -> "auth_set_role"
    -- Ffi.kernel: the codegen routes every call through the kernel dispatch,
    -- but the Rust target resolves Ffi.kernel calls directly during
    -- canonicalisation.  Any Ffi.kernel reference that reaches codegen is
    -- a polyfill call site — emit a diagnostic panic.
    -- Sub-E: TEA Cmd/Sub/Cli — map directly to the tea.rs kernels (don't rely on
    -- the Ffi.kernel-alias table, which mis-resolves in nested expr positions and
    -- would call the generated stdlib wrapper -> Ffi.kernel polyfill panic).
    ("Cmd", "none")     -> "cmd_none"
    ("Std.Cmd", "none") -> "cmd_none"
    ("Cmd", "batch")     -> "cmd_batch"
    ("Std.Cmd", "batch") -> "cmd_batch"
    ("Cmd", "perform")     -> "cmd_perform"
    ("Std.Cmd", "perform") -> "cmd_perform"
    ("Sub", "none")     -> "sub_none"
    ("Std.Sub", "none") -> "sub_none"
    ("Sub", "batch")     -> "sub_batch"
    ("Std.Sub", "batch") -> "sub_batch"
    ("Sub", "every")     -> "sub_every"
    ("Std.Sub", "every") -> "sub_every"
    ("Cli", "program")     -> "cli_program"
    ("Std.Cli", "program") -> "cli_program"
    -- Sky.Http.Middleware + Sky.Http.RateLimit — map both the short kernel-module
    -- form and the fully-qualified Sky module to the runtime fns (robust against
    -- the alias-table resolution path).
    ("Middleware", "withCors")              -> "middleware_with_cors"
    ("Sky.Http.Middleware", "withCors")     -> "middleware_with_cors"
    ("Middleware", "withLogging")           -> "middleware_with_logging"
    ("Sky.Http.Middleware", "withLogging")  -> "middleware_with_logging"
    ("Middleware", "withBasicAuth")             -> "middleware_with_basic_auth"
    ("Sky.Http.Middleware", "withBasicAuth")    -> "middleware_with_basic_auth"
    ("Middleware", "withRateLimit")             -> "middleware_with_rate_limit"
    ("Sky.Http.Middleware", "withRateLimit")    -> "middleware_with_rate_limit"
    ("RateLimit", "allow")            -> "rate_limit_allow"
    ("Sky.Http.RateLimit", "allow")   -> "rate_limit_allow"
    ("Ffi", "kernel") -> "ffi_kernel_polyfill"
    -- Ffi.callPure / callTask / toAny: the peephole rewriter in exprToRustInner
    -- handles the common case (literal kernel name + literal args list) by
    -- emitting a direct kernel call. Non-peephole-matched references land
    -- here and route to runtime polyfills: ffi_to_any_polyfill is compile-
    -- time identity; ffi_call_pure_polyfill / ffi_call_task_polyfill panic
    -- with an actionable message. See runtime-rust/src/sky_runtime/ffi_polyfills.rs.
    ("Ffi", "callPure") -> "ffi_call_pure_polyfill"
    ("Ffi", "callTask") -> "ffi_call_task_polyfill"
    ("Ffi", "call")     -> "ffi_call_pure_polyfill"  -- deprecated alias of callPure
    ("Ffi", "toAny")    -> "ffi_to_any_polyfill"
    -- Rust user-FFI kernel: snake_case the suffix, no panic stub.
    -- The wrapper function lives in a .skycache/ffi/rust/*_bindings.rs file
    -- that gets copied into sky-out/Rust/src/ at codegen time.
    _ | "Rust_" `isPrefixOf` mod ->
        toSnakeCase (drop 5 mod ++ "_" ++ name)
    _ -> toSnakeCase (map (\c -> if c == '.' then '_' else c) mod ++ "_" ++ name)

exprToStatement :: String -> String
exprToStatement expr = if null expr then "" 
    else if last expr == '}' then expr  -- block expression
    else expr ++ ";"  -- add semicolon for statement

itemToRustStrings :: RustItem -> [String]
itemToRustStrings (RustFunction name generics params retType body) = 
    let ret = if retType == "()" then "" else " -> " ++ retType
        -- Task-returning functions must NOT have semicolon after the body expression:
        -- the last expression IS the return value (Task combinator chain).
        bodyLine = if retType == "()" then exprToStatement body else body
    in ["pub fn " ++ name ++ generics ++ "(" ++ intercalate ", " params ++ ")" ++ ret ++ " {", "    " ++ bodyLine, "}"]
itemToRustStrings (RustStruct name fields) = 
    ["#[derive(Clone, Debug, PartialEq)]",
     "pub struct " ++ name ++ " {", 
     intercalate ",\n" (map (\(n, t) -> "    " ++ n ++ ": " ++ t) fields), 
     "}"]
itemToRustStrings (RustEnum name variants) = 
    ["#[derive(Clone, Debug, PartialEq)]",
     "pub enum " ++ name ++ " {",
     intercalate ",\n" (map (\(n, mt) -> "    " ++ n ++ maybe "" (\x -> "(" ++ x ++ ")") mt) variants),
     "}"]
itemToRustStrings (RustTypeAlias name ty) = ["type " ++ name ++ " = " ++ ty ++ ";"]

-- | Collect the set of type names referenced in func signatures but not defined
collectUndefinedTypes :: RustBuilder -> [String]
collectUndefinedTypes b = 
    let allItems = concatMap modItems (builderModules b)
        -- BASE name (generics stripped) so a parametric def like
        -- `pub type Cfg<msg> = …;` registers as defining `Cfg`, matching the
        -- base-name `referenced` set below (else ffiPlaceholder double-emits an
        -- invalid generic `pub use …<…> as Cfg;`).
        defName = takeWhile (/= '<')
        defined = Set.fromList
            [ defName name | RustStruct name _ <- allItems ]
            `Set.union` Set.fromList
            [ defName name | RStructDef name _ _ <- builderTypes b ]
            `Set.union` Set.fromList
            [ defName name | REnumDef name _ _ <- builderTypes b ]
            `Set.union` Set.fromList
            [ defName name | RAliasDef name _ <- builderTypes b ]
            `Set.union` Set.fromList
            [ defName name | RPubUseAlias name _ <- builderTypes b ]
            `Set.union` builderFfiOpaques b  -- types defined by Rust FFI bindings
        -- Collect type names from function parameter types (after ": ")
        -- Sub-D step 4: compare/emit the BASE type name (generic args stripped).
        -- A generic ADT param like `MainRetry<e>` is "defined" by the bare
        -- `MainRetry` enum, so it must not be treated as undefined (which would
        -- emit a colliding `type MainRetry<e> = String;` placeholder — E0428).
        referenced = Set.fromList
            [ takeWhile (/= '<') t | RustFunction _ _ params _ _ <- allItems
                , p <- params
                , let (_, ':':ty) = break (== ':') p
                , let t = dropWhile (== ' ') ty
                , not (null t)
                , not (elem t ["String", "i64", "f64", "bool", "char", "()", "Db", "SkyTask", "SkyError", "HashMap"])
                , not ("impl " `isPrefixOf` t)
                , not ("&" `isPrefixOf` t)
                , not ("Vec<" `isPrefixOf` t)
                , not ("HashMap" `isPrefixOf` t)
                , not ("Option" `isPrefixOf` t)
                , not ("Result" `isPrefixOf` t)
                , not ("SkyMaybe" `isPrefixOf` t)
                , not ("SkyResult" `isPrefixOf` t)
                -- SkyTask<A> as a param type (a Task-typed function arg) must be
                -- excluded too — the bare "SkyTask" is in the exact-match list
                -- but the generic form slips past it, emitting a colliding
                -- `type SkyTask = String;` placeholder (E0428 vs the real alias).
                , not ("SkyTask" `isPrefixOf` t)
                , not ("Box<" `isPrefixOf` t)
                , not ("fn(" `isPrefixOf` t)
            ]
    in Set.toList (Set.difference referenced defined)

-- | Check if the generated output contains the Sky.Core.Error.Error ADT.
-- If so, SkyError points to it; otherwise SkyError = String.
hasErrorType :: RustBuilder -> Bool
hasErrorType b = any isErrorTypeName (builderTypes b) || any isUserError (builderModules b)
  where
    isErrorTypeName (REnumDef n _ _) = n == toCamelCase "Sky_Core_Error_Error"
    isErrorTypeName _ = False
    isUserError m = any isErrorItem (modItems m)
    isErrorItem (RustTypeAlias n _) = n == "Error" || n == "SkyError"
    isErrorItem _ = False

-- | Synthesise a placeholder for any Sky type referenced but not defined in
-- the program (typically Sky.Core.X opaque tokens with no Sky-source `type`).
-- The default `type Name = String;` aliases to String, which works for most
-- ADT-shaped opaques. For Sky types whose runtime representation is a known
-- newtype in `sky_runtime`, redirect to `pub use sky_runtime::<X> as Name;`
-- — see runtimeOpaqueTypes registry.
ffiPlaceholder :: String -> String
ffiPlaceholder name =
    case Map.lookup name reverseRuntimeOpaque of
        Just rustPath -> "pub use " ++ rustPath ++ " as " ++ name ++ ";"
        Nothing       -> "type " ++ name ++ " = String;"
  where
    reverseRuntimeOpaque :: Map.Map String String
    reverseRuntimeOpaque = Map.fromList
        [ (toCamelCase (modPrefix ++ "_" ++ ty), path)
        | ((mod', ty), path) <- Map.toList runtimeOpaqueTypes
        , let modPrefix = map (\c -> if c == '.' then '_' else c) mod'
        ]

-- | Generate Cargo.toml for the Rust project
emitCargoToml :: UsedKernels -> String -> String -> [(String, Toml.RustDepSpec)] -> String
emitCargoToml uk dbDriver sqlxTls rustDeps = unlines $
    -- The sky_runtime files copied into sky-out/Rust/src/ carry cfg(feature = "X")
    -- gates inherited from runtime-rust/Cargo.toml. The generated Cargo.toml
    -- below declares a [features] section enabling everything by default so the
    -- gates evaluate as true. We also pull in the matching crates directly
    -- (rather than via the optional-dep mechanism the runtime crate uses) so
    -- this project compiles standalone with no `--features` flag.
    [ "[package]"
    , "name = \"sky-app\""
    , "version = \"0.1.0\""
    , "edition = \"2021\""
    , ""
    , "[features]"
    , "default = [\"tokio\", \"crypto\", \"json\", \"db\"]"
    , "tokio = []"
    , "crypto = []"
    , "json = []"
    , "db = []"
    , ""
    , "[dependencies]"
    , "tokio = { version = \"1\", features = [" ++ intercalate ", " (map show tokioFeats) ++ "] }"
    ] ++
    (if usesDb uk
     then let sqlxTlsFeature = if sqlxTls == "native-tls" then "runtime-tokio-native-tls" else "runtime-tokio-rustls"
          in [ "sqlx = { version = \"0.8\", features = [\"" ++ sqlxTlsFeature ++ "\", \"" ++ dbFeature dbDriver ++ "\"] }" ]
     else []) ++
    [ "serde_json = \"1\""
    , "sha2 = \"0.10\""
    ] ++
    -- Sub-project A — stdlib kernel crates. Always pulled in because
    -- Project.hs declares the corresponding sky_runtime modules in mod.rs
    -- unconditionally. Mostly small pure-Rust crates; cold-build impact is
    -- modest. When sub-A modules become demand-loaded these can match.
    --
    -- Skip names already declared by the user in [rust.dependencies] — Cargo
    -- errors on duplicate keys, and a user-declared entry takes precedence.
    [ name ++ " = " ++ spec
    | (name, spec) <-
        [ ("regex",            "\"1\"")
        , ("base64",           "\"0.22\"")
        , ("hex",              "\"0.4\"")
        , ("percent-encoding", "\"2\"")
        , ("chrono",           "\"0.4\"")
        , ("chrono-tz",        "\"0.10\"")
        , ("rust_decimal",     "{ version = \"1\", features = [\"serde\"] }")
        , ("hmac",             "\"0.12\"")
        , ("sha1",             "\"0.10\"")
        , ("md-5",             "\"0.10\"")
        , ("subtle",           "\"2\"")
        , ("rsa",              "{ version = \"0.9\", features = [\"sha2\"] }")
        , ("aes-gcm",          "\"0.10\"")
        , ("chacha20poly1305", "\"0.10\"")
        , ("pbkdf2",           "\"0.12\"")
        , ("flate2",           "\"1\"")
        , ("zstd",             "\"0.13\"")
        , ("csv",              "\"1\"")
        , ("jsonwebtoken",     "\"9\"")
        , ("bcrypt",           "\"0.17\"")
        -- Std.Config front-ends: TOML + YAML parsed into serde_json::Value,
        -- then the shared json Decoder runs (config_decode.rs).
        , ("toml",             "\"0.8\"")
        , ("serde_yaml",       "\"0.9\"")
        ]
    , name `notElem` userDepNames
    ] ++
    -- uuid is conditional: only when Sky.Core.Uuid is used (uuid_kernel needs
    -- v4+v7). Skipped if the user declared uuid themselves (e.g. FFI'ing the
    -- crate with different features) to avoid a duplicate-key / feature clash.
    [ "uuid = { version = \"1\", features = [\"v4\", \"v7\"] }"
    | usesUuid uk, "uuid" `notElem` userDepNames ] ++
    -- Sub-D.1: axum + tower-http only when Sky.Http.Server is used.
    [ name ++ " = " ++ spec
    | usesHttpServer uk
    , (name, spec) <-
        [ ("axum",       "{ version = \"0.7\", features = [\"ws\"] }")
        , ("tower-http", "{ version = \"0.5\", features = [\"fs\", \"catch-panic\"] }")
        ]
    , name `notElem` userDepNames ] ++
    -- Sky.Core.Http client: reqwest only when used. rustls (no system OpenSSL).
    [ "reqwest = { version = \"0.12\", default-features = false, features = [\"rustls-tls\", \"gzip\"] }"
    | usesHttp uk, "reqwest" `notElem` userDepNames ] ++
    -- Sky.Core.WebSocket client: tokio-tungstenite + futures-util.
    [ name ++ " = " ++ spec
    | usesWsClient uk
    , (name, spec) <- [ ("tokio-tungstenite", "\"0.24\""), ("futures-util", "\"0.3\"") ]
    , name `notElem` userDepNames ] ++
    [ emitDepLine name spec
    | (name, spec) <- rustDeps
    , not (null name)
    ]
  where
    userDepNames = [ n | (n, _) <- rustDeps, not (null n) ]
    -- Sky.Http.Server's axum serve loop + the reqwest client both need tokio net.
    -- The TEA loop (tea.rs) uses tokio::sync::mpsc + tokio::time + tokio::spawn;
    -- axum pulls `sync` transitively for the server case, but a plain Sky.Cli
    -- program has no axum, so request it explicitly.
    tokioFeats = ["rt", "rt-multi-thread", "macros", "time"]
                 ++ ["net" | usesHttpServer uk || usesHttp uk || usesWsClient uk]
                 ++ ["sync" | usesTea uk || usesWsClient uk]
    dbFeature "postgres" = "postgres"
    dbFeature "mysql"    = "mysql"
    dbFeature _          = "sqlite"
    emitDepLine name (Toml.RustVersion ver feats) =
        if null feats
            then name ++ " = \"" ++ ver ++ "\""
            else name ++ " = { version = \"" ++ ver ++ "\", features = [" ++ intercalate ", " (map show feats) ++ "] }"
    emitDepLine name (Toml.RustGitDep url mRev mBranch mTag) =
        let fields = [ "git = " ++ show url ]
                ++ maybe [] (\r -> ["rev = " ++ show r]) mRev
                ++ maybe [] (\b -> ["branch = " ++ show b]) mBranch
                ++ maybe [] (\t -> ["tag = " ++ show t]) mTag
        in name ++ " = { " ++ intercalate ", " fields ++ " }"

intercalate :: String -> [String] -> String
intercalate _ [] = ""
intercalate _ [x] = x
intercalate s (x:xs) = x ++ s ++ intercalate s xs
