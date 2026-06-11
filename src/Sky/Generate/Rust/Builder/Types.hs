module Sky.Generate.Rust.Builder.Types
  ( CanonicalModule
  , UsedKernels(..)
  , RustBuilder(..)
  , RustModule(..)
  , RustItem(..)
  , RustTypeDef(..)
  , EmitCtx(..)
  , intercalate
  , runtimeOpaqueTypes
  , topLevelErrorPin
  , kernelsNeedingErrorPin
  , kernelsZeroArg
  ) where

import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Sky.AST.Canonical as Can
import qualified Sky.Reporting.Annotation as Ann

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
    , usesEmail :: Bool           -- Std.Email used → email module + reqwest
    , usesLive :: Bool            -- Std.Live used → live module (Html bridge)
    , usesHtml :: Bool            -- Std.Html / Std.Ui used → needs the live module's
                                  -- Html/Attribute/Event ADTs + html_render_ kernel,
                                  -- even for a non-Live (CLI/Tui) render via Html.toString
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
        , usesEmail = usesEmail a || usesEmail b
        , usesLive = usesLive a || usesLive b
        , usesHtml = usesHtml a || usesHtml b
        }
instance Monoid UsedKernels where
    mempty = UsedKernels False False False False False False False False False False False False False False False False

data RustBuilder = RustBuilder
    { builderModules    :: [RustModule]
    , builderTypes      :: [RustTypeDef]
    , builderKernels    :: UsedKernels
    , builderFfiOpaques :: Set.Set String  -- types defined by Rust FFI bindings, skip placeholders
    , builderFormTargets :: Set.Set String
        -- P2-T5: Rust type names of records targeted by an `Ev.onSubmit handler`
        -- (handler : T -> Msg). Only THESE structs gain `serde::Deserialize` in
        -- typeDefToString — deriving it on every struct would force serde bounds
        -- on function-typed fields (E0277). Computed by collectFormTargets, which
        -- shares the handler-arg-type -> rustT logic with the onSubmit peephole.
    , builderLiveInitFns :: Set.Set String
        -- P4-T3: Sky binding names of `Live.app` init functions whose `init`
        -- field is a top-level reference. defToRustItem overrides param 0 of
        -- each to `sky_runtime::LiveReq`. Computed by collectLiveInitFns.
    , builderLiveSerdeTypes :: Set.Set String
        -- P5-T4b: Rust type names in the Sky.Live model's transitive type
        -- closure. ONLY these gain serde::Serialize + serde::Deserialize in
        -- typeDefToString — the runtime's `Model: Serialize + DeserializeOwned`
        -- bound (for session persistence) demands it, but deriving serde on
        -- every struct/enum would force serde bounds on function-typed fields
        -- (E0277). Computed by collectLiveSerdeTypes (precise BFS).
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
    -- | Bridge for Sky parametric types whose representation lives in
    -- `sky_runtime` AND whose bridge is itself generic (the Sky type carries a
    -- type variable, e.g. `Html msg`). Selected by unionToRustTypeDef when
    -- runtimeOpaqueTypes contains a `{M}` placeholder in the path. Codegen
    -- emits `pub type <name><vars> = <rustPathWithVarSubstituted>;` — a
    -- GENERIC type alias (vs RAliasDef's non-generic form and RPubUseAlias's
    -- `pub use` form). The `{M}` mechanism currently binds only the FIRST Sky
    -- type var (single-placeholder). See typeDefToString for the emission shape.
    | RAliasDefGen String String String  -- codegenName, generics_decl (e.g. "<msg>"), rustPathWithVar

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
    -- Sky.Core.Http.Stream.ChunkEvent — bridged so the runtime can CONSTRUCT it
    -- (in sub_subscribe_stream's drain) to hand to the user's `toMsg`. Generic
    -- (`Errored` carries Error), so the bridge emits a `pub type … =
    -- sky_runtime::ChunkEvent<SkyError>;` alias (see unionToRustTypeDef's generic
    -- arm); the Sky `e` var is phantom and dropped, like WsServerCfg msg.
    , (("Sky.Core.Http.Stream", "ChunkEvent"), "sky_runtime::ChunkEvent<SkyError>")
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
    -- Sky.Http.Server.Stream: StreamWriter is the opaque writer handle the
    -- runtime constructs to pass to the user's handler; the stdlib's
    -- `case w of StreamWriter raw` lowers onto the bridged enum's variant.
    -- (StreamId on the client side stays a generated Sky enum — its kernels
    -- only ever see the unwrapped Int.)
    , (("Sky.Http.Server.Stream", "StreamWriter"), "sky_runtime::StreamWriter")
    -- Std.Email: the message + attachment + config records map to runtime
    -- structs (pub fields, camelCase verbatim) so `defaultMessage`/`with*`
    -- record literals + updates resolve onto them; EmailProvider maps to the
    -- runtime enum so `Resend "k"` / `Ses cfg` construct its variants directly.
    , (("Std.Email", "EmailMessage"), "sky_runtime::EmailMessage")
    , (("Std.Email", "Attachment"), "sky_runtime::EmailAttachment")
    , (("Std.Email", "SesConfig"), "sky_runtime::SesConfig")
    , (("Std.Email", "SmtpConfig"), "sky_runtime::SmtpConfig")
    , (("Std.Email", "EmailProvider"), "sky_runtime::EmailProvider")
    -- Sky.Live: Html/Attribute/Event bridge to runtime generic enums, carrying
    -- the app's `msg` var through ({M} = the union's own type var, substituted in
    -- unionToRustTypeDef). render/diff are msg-agnostic; only dispatch uses M.
    -- The {M} mechanism currently binds only the FIRST Sky type var (single-placeholder).
    , (("Std.Html", "Html"),                 "sky_runtime::Html<{M}>")
    , (("Std.Html.Attributes", "Attribute"), "sky_runtime::Attribute<{M}>")
    , (("Std.Html.Attributes", "Event"),     "sky_runtime::Event<{M}>")
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
    , ("server_api",               "::<SkyError, _>")
    -- chunks → sub_subscribe_stream<E, M, F>: pin E=SkyError (the ChunkEvent
    -- error slot is phantom from the call site), infer M + F.
    , ("sub_subscribe_stream",     "::<SkyError, _, _>")
    , ("server_listen",            "::<SkyError>")
    -- Sky.Core.Http client — each returns SkyTask<E, HttpResponse>; pin E.
    , ("http_get",                 "::<SkyError>")
    , ("http_post",                "::<SkyError>")
    , ("http_request",             "::<SkyError>")
    -- Std.Email — email_send returns SkyTask<E, String>; pin E.
    , ("email_send",               "::<SkyError>")
    -- Std.Live P0 scaffold — live_render_static<E, Model, Msg, FView>; pin E,
    -- leave Model/Msg/FView inferred from the view function and model arg.
    , ("live_render_static",       "::<SkyError, _, _, _>")
    -- Std.Live live_app — <E, Model, Msg, FInit, FUpdate, FView, FSubs>; pin E
    -- (no error-determining arg), infer the rest from the four spliced callbacks.
    , ("live_app",                 "::<SkyError, _, _, _, _, _, _>")
    -- Sky.Core.Http.Stream (client) — open/close have no E-determining arg.
    , ("http_stream_open",         "::<SkyError>")
    , ("http_stream_close",        "::<SkyError>")
    -- Sky.Http.Server.Stream (server) — stream/emit/finish/withContentType.
    -- stream is <E, H> (H inferred); the rest are <E>. forEachChunk's body
    -- closure determines E, so it's deliberately NOT pinned.
    , ("server_stream_stream",            "::<SkyError, _>")
    , ("server_stream_emit",              "::<SkyError>")
    , ("server_stream_finish",            "::<SkyError>")
    , ("server_stream_with_content_type", "::<SkyError>")
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
    -- Std.Auth hashPassword/verifyToken — single E param (returns
    -- SkyResult<E, String/Claims>). When the Err is discarded (`case … of Ok h
    -- -> h; Err _ -> ""`), E is unconstrained → E0283. Pin E=SkyError.
    , ("auth_hash_password",       "::<SkyError>")
    , ("auth_hash_password_cost",  "::<SkyError>")
    , ("auth_verify_password",     "::<SkyError>")
    , ("auth_verify_token",        "::<SkyError>")
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
    -- JsonEnc.null : Value is a zero-arg constant (`Ffi.kernel "JsonEnc_null"`);
    -- used as a value (`("x", JsonEnc.null)`) it must be CALLED, not left a bare
    -- fn item (35-composite-generics). Runtime json_enc_null() is zero-arg.
    , "json_enc_null"
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
    , ecLiveInitFns :: Set.Set String
        -- ^ P4-T3: Sky binding names of `Live.app` top-level-ref init functions.
        --   defToRustItem forces param 0 of these to `sky_runtime::LiveReq` so
        --   the generated init fn satisfies the runtime's
        --   `FInit: Fn(LiveReq) -> (Model, SkyCmd<Msg>)` bound.
    , ecLiveStore :: (String, String)
        -- ^ P5-T4b: (storeKind, storePath) from `[live] store` / `storePath`.
        --   The Live.app peephole emits these as the trailing two string args of
        --   the `live_app` / `live_app_routed` call; the runtime's choose_store
        --   builds the backend (empty kind -> memory). Default ("", "").
    , ecAppMsg :: Maybe Can.Type
        -- ^ The Sky.Live app's CONCRETE Msg type (e.g. State.Msg), or
        --   Nothing for non-Live programs. Used to monomorphise TEA functions
        --   whose return type is polymorphic in `msg` (a handler returning
        --   `(Model, Cmd msg)` via `Cmd.none`, a view returning `Html msg`):
        --   return-inference otherwise collapses these to `()`, which then
        --   mismatches the real body at every call site (the Sky.Live cascade).
        --   Substituting the concrete app Msg keeps the type CONCRETE (no
        --   uninferrable per-fn generic — that approach regressed 4 examples).
    , ecAppModel :: Maybe Can.Type
        -- ^ The Sky.Live app's CONCRETE Model type, to substitute into a TEA
        --   return's Model slot when the solver left it a bare TVar
        --   (`(Model, Cmd msg)` → `(_t030, Cmd msg)`). Companion to ecAppMsg.
    , ecClosureDefs :: Map.Map String ([Can.Pattern], Can.Expr)
        -- ^ Let-bound closure DEFINITIONS (name -> (params, body)) in the
        --   current function body, for closure-param inference across
        --   user-closure flow: a param flowing into a local closure
        --   (`writeAll db = … insertRow db …`) resolves by recursively inferring
        --   the target closure's param at that position. Closes 18's
        --   user-closure E0282 cluster (depth-limited to avoid cycles).
    , ecModuleEnv :: Map.Map String Can.Type
        -- ^ The CURRENT module's own per-module solved env (`_stPerModuleEnv[M]`),
        --   used ONLY to resolve the DEFINED function's own signature (param /
        --   return types) so a dep module's binding isn't lost in the flat
        --   `ecSolvedTypes` (the mass-E0308 keystone). It must NOT replace
        --   `ecSolvedTypes` wholesale — doing so shadowed cross-module calls to
        --   same-named functions (Std.Money.fromString hiding Std.Decimal's →
        --   wrong arity/currying). Body lowering keeps using the flat map.
    , ecForcedClosureParam :: Maybe String
        -- ^ When set, a closure ARG's single param is annotated with this Rust
        --   type (highest priority, before the ambiguous field-match
        --   inferRecordClosureParam). Set by emitDefaultCall for a list HOF
        --   (`List.filter (\m -> m.id == …) model.monitors`): the closure's
        --   element type is the list arg's element type (StateMonitor), NOT the
        --   field-match guess (StateAlertRule — 3 structs share `id`). Closes
        --   17-skymon's filter/map ADT-mismatch.
    , ecStructFields :: Map.Map String (Map.Map String Can.Type)
        -- ^ Rust struct name -> (field name -> field type), over every record
        --   alias in the program. Lets a record-UPDATE arm
        --   (`{ model | configInput = Dict.empty }`) seed ecExpectedType for each
        --   updated field's VALUE from the field's declared type, so an empty
        --   collection / literal turbofishes correctly (dict_empty::<String>
        --   not ::<i64>). Record LITERALS already get this via region types;
        --   updates don't, hence the explicit map. 17-skymon update sites.
    , ecCurrentModule :: String
        -- ^ The current module's canonical name (e.g. "Lib.Database"), so a
        --   sibling-fn lookup can verify a VarTopLevel callee belongs to THIS
        --   module before resolving it against ecSiblingFns. Without the check,
        --   a qualified cross-module call to a same-named fn (`Db.exec` from
        --   Lib.Db, whose own `exec` is a sibling) collides on the bare name and
        --   mis-infers (12-skyvote regression).
    , ecSiblingFns :: Map.Map String ([Can.Pattern], Can.Expr)
        -- ^ The current module's TOP-LEVEL function definitions (bare name ->
        --   (params, body)), for body-driven param inference across sibling
        --   calls. A wrapper `execOrLog l q args = … exec q args …` whose `args`
        --   flows into the sibling `exec` (itself `Db.exec … args` → kernel
        --   db_exec arg2 = Vec<String>) resolves by recursively inferring exec's
        --   param at that position — the VarTopLevel analogue of ecClosureDefs'
        --   local-closure recursion. Closes 17-skymon's exec/query wrapper
        --   cluster (cycle-broken via Map.delete on recursion).
    , ecReturnElem :: Maybe String
        -- ^ The Rust element-type string of the ENCLOSING function's
        --   `SkyTask<T>` return (the `T`), seeded when emitting a def body.
        --   Fallback for `taskFailPin`: a `Task.fail` in the function's tail
        --   Task chain (`Time.sleep ms |> Task.andThen (\\_ -> Task.fail …)`)
        --   has element type = the function's return element, but the solver
        --   leaves the helper's own sig polymorphic (`Task Error a`), so
        --   `ecExpectedType` carries a TVar. Without this, the turbofish
        --   defaults to `i64` and mismatches the resolved `SkyTask<String>`
        --   signature (18-job-queue's sleepThenFail E0308). Priority is below
        --   a concrete `ecExpectedType`; only fires as the last resort before
        --   the `i64` default.
    , ecEnclosingRet :: Maybe Can.Type
        -- ^ The ENCLOSING function's full return type (Can.Type), seeded when
        --   emitting a def body. Sources the turbofish for a phantom-polymorphic
        --   ADT constructor in the body tail (`none : Element msg` body
        --   `StdUiElement::Empty` -> `StdUiElement::<msg>::Empty`); the phantom
        --   `msg` is otherwise un-inferrable (E0282). The enclosing fn declares
        --   the matching generic, so the return type's args name what's in scope.
    , ecGenParams :: [String]
        -- ^ The ENCLOSING function's DECLARED generic param names (its
        --   `<msg, …>` decl). The ctor turbofish only fires when every type arg
        --   is one of these — a return-type TVar that ISN'T declared (a
        --   monomorphised `a`, a synthesised `_a_inst171`) is NOT in scope and a
        --   turbofish over it is E0412 (cannot find type). Concrete returns skip
        --   the turbofish entirely (Rust infers the param).
    }

intercalate :: String -> [String] -> String
intercalate _ [] = ""
intercalate _ [x] = x
intercalate s (x:xs) = x ++ s ++ intercalate s xs
