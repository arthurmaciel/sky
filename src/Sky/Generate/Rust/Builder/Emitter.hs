module Sky.Generate.Rust.Builder.Emitter
  ( emitRust
  , emitCargoToml
  , dbPoolType
  , dbRowType
  , dbBackendHelpers
  , headerSection
  , importSection
  , basicTypeSection
  , kernelHelperSection
  , userTypeSection
  , skyErrorLine
  , entryPointSection
  , typeDefToString
  , moduleToRustFile
  , exprToStatement
  , itemToRustStrings
  , collectUndefinedTypes
  , hasErrorType
  , ffiPlaceholder
  ) where

import Data.Char (isAlphaNum)
import Data.List (isPrefixOf, isInfixOf)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Sky.Sky.Toml as Toml (RustDepSpec(..))
import Sky.Generate.Rust.Builder.Types
    ( UsedKernels(..), RustBuilder(..), RustModule(..), RustItem(..)
    , RustTypeDef(..), intercalate, runtimeOpaqueTypes
    )
import Sky.Generate.Rust.Builder.Naming (toCamelCase, toSnakeCase)
import Sky.Generate.Rust.Builder.CrateSpecs (cargoDependencyFor, crateVersionFor)

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
    [ "// Postgres has no LastInsertId; db_insert_row appends `RETURNING id`"
    , "// (see DB_USES_RETURNING_ID) so this execute-result helper stays 0."
    , "pub fn db_last_insert_id(_res: &sqlx::postgres::PgQueryResult) -> i64 { 0 }"
    , "pub const DB_USES_RETURNING_ID: bool = true;"
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
    , "pub const DB_USES_RETURNING_ID: bool = false;"
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
    , "pub const DB_USES_RETURNING_ID: bool = false;"
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
            -- `pub`: these are the canonical project-pinned (E = SkyError)
            -- bindings; the crate-root `pub use sky_runtime::*;` glob also
            -- re-exports the generic `SkyTask`/`Decoder`, so a PRIVATE alias
            -- here would warn `private item shadows public glob re-export`. An
            -- explicit `pub` item shadowing a glob is well-defined + warning-free.
            [ "pub type SkyTask<A> = sky_runtime::SkyTask<SkyError, A>;"
            , "pub type Decoder<T> = sky_runtime::json::Decoder<SkyError, T>;"
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
            , "pub fn log_error(msg: String) -> SkyTask<()> { sky_runtime::log::log_error(msg) }"
            -- `println` routes here (Log.println / bare println, kept bare — no
            -- prefix). It MUST have the E-pinning wrapper too; without it a
            -- discarded `let _ = log_println(...)` leaves E un-inferrable → E0283
            -- (regressed 00/36/simple when println split off from log_info).
            , "pub fn log_println(msg: String) -> SkyTask<()> { sky_runtime::log::log_println(msg) }"
            -- Keep the attr-element type GENERIC (`A`): Sky's `*With : String ->
            -- List a -> …` is polymorphic in the attr element, and the common
            -- structured-log shape passes `List (String, String)` tuples
            -- (`[("errId", id), ("error", msg)]`) OR a flat `List String`
            -- (`["errId", id]`). Hardcoding `Vec<String>` rejected the tuple form
            -- (E0308 — composite-server). `A` is bounded by `SkyStringify` (NOT
            -- `Display` — tuples + generated records don't impl `Display`, which
            -- was the E0277), the TOTAL Go-`%v` stringifier every Sky-representable
            -- type implements, so the runtime can flatten the attrs onto the line
            -- byte-for-byte like Go's `renderLogMsgWithAttrs`. The bound is
            -- satisfiable at every concrete element type, so it never rejects a
            -- valid call site. The wrapper still pins `E = SkyError` via the
            -- `SkyTask<()>` return alias (the reason it exists — E is otherwise
            -- un-inferrable from the args). All four levels are hardcoded so the
            -- E-pinning + `SkyStringify` bound are consistent regardless of which
            -- `*With` an app uses.
            , "pub fn log_info_with<A: SkyStringify>(msg: String, attrs: Vec<A>) -> SkyTask<()> { sky_runtime::log::log_info_with(msg, attrs) }"
            , "pub fn log_error_with<A: SkyStringify>(msg: String, attrs: Vec<A>) -> SkyTask<()> { sky_runtime::log::log_error_with(msg, attrs) }"
            , "pub fn log_debug_with<A: SkyStringify>(msg: String, attrs: Vec<A>) -> SkyTask<()> { sky_runtime::log::log_debug_with(msg, attrs) }"
            , "pub fn log_warn_with<A: SkyStringify>(msg: String, attrs: Vec<A>) -> SkyTask<()> { sky_runtime::log::log_warn_with(msg, attrs) }"
            , "pub fn system_args(_: ()) -> SkyTask<Vec<String>> { sky_runtime::system::system_args(()) }"
            , "pub fn system_setenv(key: String, val: String) -> SkyTask<()> { sky_runtime::system::system_setenv(key, val) }"
            , "pub fn system_unsetenv(key: String) -> SkyTask<()> { sky_runtime::system::system_unsetenv(key) }"
            , "pub fn time_now(_: ()) -> SkyTask<i64> { sky_runtime::time::time_now(()) }"
            , "pub fn time_sleep(ms: i64) -> SkyTask<()> { sky_runtime::time::time_sleep(ms) }"
            , "pub fn time_unix_millis(_: ()) -> SkyTask<i64> { sky_runtime::time::time_unix_millis(()) }"
            , "pub fn random_int(lo: i64, hi: i64) -> SkyTask<i64> { sky_runtime::random::random_int(lo, hi) }"
            , "pub fn random_float(lo: f64, hi: f64) -> SkyTask<f64> { sky_runtime::random::random_float(lo, hi) }"
            , "pub fn random_choice(items: Vec<String>) -> SkyTask<String> { sky_runtime::random::random_choice(items) }"
            , "pub fn file_read_file(path: String) -> SkyTask<String> { sky_runtime::file::file_read_file(path) }"
            , "pub fn file_write_file(path: String, content: String) -> SkyTask<()> { sky_runtime::file::file_write_file(path, content) }"
            , "pub fn file_delete(path: String) -> SkyTask<()> { sky_runtime::file::file_delete(path) }"
            , "pub fn crypto_random_bytes(n: i64) -> SkyTask<String> { sky_runtime::crypto::crypto_random_bytes(n) }"
            , "pub fn crypto_random_token(n: i64) -> SkyTask<String> { sky_runtime::crypto::crypto_random_token(n) }"
            ] ++
            (if usesDb (builderKernels b)
             then [ "pub fn db_connect(_: ()) -> SkyTask<Db> { sky_runtime::db::db_connect(()) }"
                  , "pub fn db_open(driver: String, path: String) -> SkyTask<Db> { sky_runtime::db::db_open(driver, path) }"
                  , "pub fn db_open_with_path(path: String) -> SkyTask<Db> { sky_runtime::db::db_open_with_path(path) }"
                  , "pub fn db_exec_raw(conn: Db, sql: String) -> SkyTask<i64> { sky_runtime::db::db_exec_raw(conn, sql) }"
                  , "pub fn db_exec(conn: Db, sql: String, params: Vec<String>) -> SkyTask<i64> { sky_runtime::db::db_exec(conn, sql, params) }"
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
            , entryPointSection (builderKernels b) (builderMainReturnsTask b)
            ]
    in (mainCode, moduleFiles)

-- | Header and file-level attributes
headerSection :: [String]
headerSection =
    [ "// Generated by Sky compiler (Rust target)"
    , "#![allow(unused, non_snake_case)]"
    , ""
    -- Static-build allocator. `sky build --static` (musl on Linux) adds
    -- `--features static_alloc`, swapping in mimalloc as the global allocator so
    -- musl's slower default malloc doesn't erode the server throughput wins.
    -- Inert (not compiled) on every other build → behaviourally unchanged.
    , "#[cfg(feature = \"static_alloc\")]"
    , "#[global_allocator]"
    , "static SKY_GLOBAL_ALLOC: mimalloc::MiMalloc = mimalloc::MiMalloc;"
    , ""
    , "pub mod sky_runtime;"
    , "pub use sky_runtime::*;"
    , ""
    ]

-- | Conditional imports — only include tokio/sqlx when actually used
importSection :: UsedKernels -> String -> [String]
importSection uk dbDriver =
    [ "use std::collections::HashMap;"
    , "use std::collections::BTreeSet;"
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
        [ "pub use " ++ dbPoolType dbDriver ++ " as DbPool;"  -- pub: shadows the sky_runtime glob's DbPool (warning-free explicit-over-glob)
        , "pub use " ++ dbRowType dbDriver ++ " as DbRow;"
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
    ] ++ map (typeDefToString (builderFormTargets b) (builderLiveSerdeTypes b) fnFieldStructs) (builderTypes b)
  where
    -- #69/A: structs with a function-typed field (`Arc<dyn Fn>`) — derive only
    -- Clone + a Default; a serde Model field of such a type is serde-skipped.
    fnFieldStructs = Set.fromList
        [ nm | RStructDef nm _ flds <- builderTypes b
             , any (\(_, t) -> "dyn Fn" `isInfixOf` t) flds ]

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
                , "pub fn str_err(s: &str) -> SkyError {"
                , "    " ++ errName ++ "::Error("
                , "        " ++ kindName ++ "::Unexpected,"
                , "        " ++ infoName ++ " { details: SkyMaybe::Nothing, message: s.to_string() }"
                , "    )"
                , "}"
                ]
      else "type SkyError = String;\npub fn str_err(s: &str) -> SkyError { s.to_string() }"
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
entryPointSection :: UsedKernels -> Bool -> [String]
entryPointSection uk mainReturnsTask =
    let _hasTokio = usesTaskRun uk || usesTaskParallel uk || usesDb uk || usesHttpServer uk || usesEmail uk || usesLive uk
        -- sky_main returns SkyTask<()> (needs block_on) UNLESS the user calls
        -- Task.run itself, in which case sky_main returns () and runs the task
        -- inline. Sky.Live is NOT an exception: `live_app`/`live_app_routed`
        -- return SkyTask<()> (a `Box::pin(async move { serve_live(...).await })`
        -- future), so the entry MUST block_on it — dropping it exits the process
        -- before axum binds a port (the binary appeared to "run" but served
        -- nothing). Server.listen is the same shape (returns a block_on'd Task).
        -- `mainIsTask` ⟺ `sky_main` returns a `SkyTask<…>` (then the entry MUST
        -- block_on it). The SOUND signal is `builderMainReturnsTask` — the entry
        -- main body TAIL's task-ness (computed in ModuleEmitter), which also folds
        -- in backend-entry apps (Live/Tui/Webview drivers return a Task). The old
        -- `not (usesTaskRun uk)` heuristic was UNSOUND: a main that calls
        -- `Task.run` inline AND returns a Task tail (14-task-demo:
        -- `… let _ = Task.run a; printResult "Fail" (Task.run b)`) has
        -- `usesTaskRun=True` yet `sky_main` keeps `SkyTask<()>`. Pre-deferral the
        -- mismatch was masked (eager effect kernels fired even on a dropped tail
        -- future); with deferred effects a dropped tail Task silently loses its
        -- effect. Mirroring the emitter's `retTy` decision makes the entry and the
        -- signature agree by construction.
        mainIsTask = mainReturnsTask
        -- Sky.Webview MUST drive its entry Task on the process's TRUE main
        -- thread: tao/winit's `EventLoop` + Cocoa's `NSApplication` require the
        -- main thread on macOS (hard Cocoa requirement, no any-thread escape),
        -- and Windows expects it too. `webview_app`'s `event_loop.run(...)`
        -- lives inside the entry future, so the future has to be polled on the
        -- main thread. The default `block_on` spawns an OS thread (for
        -- panic-to-`Err` mapping) → the event loop would build OFF the main
        -- thread → macOS panic. So a Sky.Webview entry uses
        -- `block_on_current_thread` (a current-thread tokio runtime, no spawn —
        -- it still drives any pre-webview async on this one thread). Every other
        -- backend shape (cli / live / tui / server) keeps the spawning
        -- `block_on` unchanged.
        entryDriver = if usesWebview uk then "block_on_current_thread" else "block_on"
        -- Synchronous-panic gate (Go parity: rt.LogPanicAndExit). Installed on
        -- every SYNCHRONOUS main shape (Sky.Cli / Sky.Tui / Sky.Webview / batch)
        -- but NOT on a server (Sky.Live / Sky.Http.Server): a server's request
        -- handlers must recover-to-500 per request, so a process-global
        -- exit-on-panic hook would crash the WHOLE server on a single bad
        -- request. Mirrors Go, whose synchronous LogPanicAndExit is the
        -- non-server path while handlers carry their own per-request recover.
        installPanicGate = not (usesHttpServer uk || usesLive uk)
        panicGate = if installPanicGate then
            [ "    // Synchronous-panic gate (Go parity: rt.LogPanicAndExit) —"
            , "    // classify an escaping panic (div-by-zero / index-OOB /"
            , "    // overflow) into a Sky error + exit 1, not a raw Rust backtrace."
            , "    sky_runtime::core::install_panic_classifier();"
            ]
          else []
    in
    [ ""
    , "// ==========================================="
    , "// ENTRY POINT"
    , "// ==========================================="
    , ""
    , "fn main() {"
    ] ++ panicGate ++ (if mainIsTask then
        -- sky_main returns SkyTask<()> → run it via block_on. The `tokio`
        -- Cargo feature is ALWAYS in the default set (see emitCargoToml), so
        -- `block_on` is unconditionally available. This MUST block_on even when
        -- no "tokio kernel" (db/http/parallel/run) is used: effect kernels are
        -- DEFERRED (the side effect lives inside the returned future and fires
        -- only on `.await`), so a `main : Task ()` built from log/io alone would
        -- silently skip its tail effect if its future were dropped. (`hasTokio`
        -- is retained for documentation but no longer gates the entry — the
        -- pre-deferral "no tokio → call and drop" path was only sound while
        -- effects fired eagerly.)
        [ "    match " ++ entryDriver ++ "(sky_main()) {"
        , "        SkyResult::Ok(_) => (),"
        , "        SkyResult::Err(e) => { eprintln!(\"{:?}\", e); std::process::exit(1); }"
        , "    }"
        , "}"
        ]
      else
        -- sky_main returns (), Task.run is used inside
        [ "    sky_main();"
        , "}"
        ])

-- | Render a Rust type def. The form-target set (P2-T5) gates the
-- `serde::Deserialize` derive: ONLY structs whose name is an `Ev.onSubmit`
-- target gain it. Deriving serde on every struct would force serde bounds on
-- function-typed fields (e.g. closures in a config record) and reject with
-- E0277, so the stamp is opt-in per form target.
-- | First Set: form-target structs (serde::Deserialize). Second Set: Sky.Live
-- model-closure types (serde::Serialize + serde::Deserialize). serdeTypes is a
-- superset of the Deserialize need, so a type in both gets the full pair once.
typeDefToString :: Set.Set String -> Set.Set String -> Set.Set String -> RustTypeDef -> String
typeDefToString _ serdeTypes _ (REnumDef name gens variants) =
    let baseDerive = if name `Set.member` serdeTypes
                     then "#[derive(Clone, Debug, PartialEq, serde::Serialize, serde::Deserialize)]"
                     else "#[derive(Clone, Debug, PartialEq)]"
        -- A `fn(…)` pointer in a variant payload (e.g. `ShouldRetry`'s
        -- `RetryWhen (e -> Bool)` → `fn(E) -> bool`; `SkyTestTest`'s
        -- `Leaf(String, fn(()) -> …)`) makes the DERIVED PartialEq compare fn
        -- ADDRESSES — `unpredictable_function_pointer_comparisons` warns (the
        -- addresses aren't unique). We KEEP PartialEq: a struct field of this
        -- enum (e.g. `RetryPolicy { shouldRetry : ShouldRetry e }`) derives
        -- PartialEq and needs it (dropping it cascades E0369 to every holder).
        -- These enums are pattern-matched, never semantically `==`-compared on
        -- the fn variant, so the fn-address compare is dead — `#[allow]` it.
        hasFnPtrVariant = any (\(_, mt) -> maybe False ("fn(" `isInfixOf`) mt) variants
        derive = if hasFnPtrVariant
                 then "#[allow(unpredictable_function_pointer_comparisons)]\n" ++ baseDerive
                 else baseDerive
        enumDef = derive ++ "\npub enum " ++ name ++ gens ++ " {\n" ++ intercalate ",\n" (map (\(n, mt) -> "    " ++ n ++ maybe "" (\x -> "(" ++ x ++ ")") mt) variants) ++ "\n}"
    in enumDef ++ skyStringifyEnumImpl name gens variants
typeDefToString formTargets serdeTypes fnFieldStructs (RStructDef name gens fields) =
    -- Sky record field names are camelCase and match the form `name=` attrs
    -- 1:1, so no #[serde(rename)] is needed.
    -- P5-T4b: a model-closure struct needs Serialize+Deserialize (session
    -- persistence). That implies Deserialize, so it subsumes the form-target case.
    -- #69/A: a struct with function-typed fields (`Arc<dyn Fn>`, e.g. the console
    -- `StateStore`) CANNOT derive Debug/PartialEq/serde — derive only Clone, and
    -- give it a `Default` (disconnected error-closures) so the Model that holds it
    -- can `#[serde(skip)]` the field and reconstruct it on deserialize.
    let hasFnField = any (\(_, t) -> "dyn Fn" `isInfixOf` t) fields
        isSerde = name `Set.member` serdeTypes
        -- A struct (e.g. the Model) that HOLDS a fn-field struct can't derive
        -- Debug/PartialEq either (the held struct has no Debug/PartialEq) — derive
        -- only Clone + serde (the held field is serde-skipped below).
        hasCallbackField = any (\(_, t) -> fieldTypeBase t `Set.member` fnFieldStructs) fields
        derives
            | hasFnField = "#[derive(Clone)]"
            | hasCallbackField && isSerde = "#[derive(Clone, serde::Serialize, serde::Deserialize)]"
            | hasCallbackField = "#[derive(Clone)]"
            | isSerde = "#[derive(Clone, Debug, PartialEq, serde::Serialize, serde::Deserialize)]"
            | name `Set.member` formTargets = "#[derive(Clone, Debug, PartialEq, serde::Deserialize)]"
            | otherwise = "#[derive(Clone, Debug, PartialEq)]"
        -- A serde struct's field whose TYPE is a fn-field struct can't serialize:
        -- skip it (reconstructed via that struct's Default on deserialize).
        skipField (_, t) = isSerde && fieldTypeBase t `Set.member` fnFieldStructs
        renderField fld@(n, t) =
            (if skipField fld then "    #[serde(skip)]\n" else "") ++ "    " ++ n ++ ": " ++ t
        structDef = derives ++ "\npub struct " ++ name ++ gens ++ " {\n"
            ++ intercalate ",\n" (map renderField fields) ++ "\n}"
        -- Only a BARE fn field (`Arc<dyn Fn..>` / `fn(..)`) can be defaulted via
        -- `disconnected_fnN()` (which returns exactly `Arc<dyn Fn(..) -> SkyTask>`).
        -- Any other field — a plain field that happens to co-exist in a
        -- function-typed struct, OR a WRAPPED fn field (`Vec<Arc<dyn Fn>>`,
        -- `Option<Arc<dyn Fn>>`, `HashMap<.., Arc<dyn Fn>>`) — must default via
        -- `Default::default()`; `disconnected_fnN()` would mistype it (E0308/E0599).
        defaultField (n, t)
            | isBareFnField t =
                "            " ++ n ++ ": sky_runtime::core::disconnected_fn" ++ show (fnArgCount t) ++ "()"
            | otherwise =
                "            " ++ n ++ ": Default::default()"
        defaultImpl
            | hasFnField =
                "\nimpl Default for " ++ name ++ gens ++ " {\n    fn default() -> Self {\n        "
                ++ name ++ " {\n" ++ intercalate ",\n" (map defaultField fields) ++ "\n        }\n    }\n}"
            | otherwise = ""
    in structDef ++ defaultImpl ++ skyStringifyStructImpl name gens fields
typeDefToString _ _ _ (RAliasDef name ty) = "pub type " ++ name ++ " = " ++ ty ++ ";"
typeDefToString _ _ _ (RPubUseAlias codegenName rustPath) =
    "pub use " ++ rustPath ++ " as " ++ codegenName ++ ";"
typeDefToString _ _ _ (RAliasDefGen name gens path) =
    "pub type " ++ name ++ gens ++ " = " ++ path ++ ";"

-- ============================================================
-- SkyStringify impls for generated records/ADTs
-- ============================================================
-- `errorToString`/`Sky.Test.debugShow` stringify any value via the total
-- `SkyStringify` trait (runtime-rust/src/sky_runtime/stringify.rs). Every
-- generated struct/ADT must impl it so the bound on a stringifying generic
-- function (ModuleEmitter `bodyStringifies`) is always satisfiable. Render to
-- match Go's `%v`:
--   * record -> `{f0 f1 ...}` (fields in declared order, space-separated, no names)
--   * ADT    -> best-effort `Ctor`/`Ctor p0 p1` (NOT byte-identical to Go's
--               flattened-struct layout — documented residual; the Error ADT,
--               which Sky models as `String`, renders its message verbatim via
--               the runtime `String` impl, so a user-facing Error reads cleanly).
-- Function-typed fields/payloads (`Arc<dyn Fn`, `fn(`) render a `<fn>`
-- placeholder rather than calling `.sky_show()` (they aren't SkyStringify and
-- never carry user-visible data).

-- | Strip a bare gens decl `<msg, a>` into its param-name list (["msg","a"]).
-- The struct/enum gens carry NO bounds at the type def (just `<msg>` / `<msg, a>`).
genParamNames :: String -> [String]
genParamNames g = case dropWhile (/= '<') g of
    ('<':rest) -> [ trim seg | seg <- splitTopComma (takeWhile (/= '>') rest), not (null (trim seg)) ]
    _ -> []
  where
    trim = f . f where f = reverse . dropWhile (== ' ')
    -- gens here are flat name lists (no nested `<>`), so a plain comma split is exact.
    splitTopComma s = case break (== ',') s of
        (a, ',':b) -> a : splitTopComma b
        (a, _)     -> [a]

-- | The bounded impl generics + the type-use generics for a SkyStringify impl.
-- `<msg, a>` -> ("<msg: SkyStringify + Debug, a: SkyStringify + Debug>", "<msg, a>").
-- Empty gens -> ("", "").
--
-- Each param carries BOTH `SkyStringify` (so it can render via the trait when a
-- field IS the bare param) AND `std::fmt::Debug` (so the autoref-`Debug` fallback
-- is satisfiable when a field is a generic payload over the param — e.g.
-- `ChunkEvent<E>` needs `E: Debug` to be `Debug`). Every generated/runtime type
-- derives Debug, so `+ Debug` is always satisfiable; it is what makes the field
-- dispatch TOTAL for generic-payload fields.
skyStringifyImplGens :: String -> (String, String)
skyStringifyImplGens g =
    let names = genParamNames g
    in if null names then ("", "")
       else ( "<" ++ intercalate ", " (map (++ ": SkyStringify + std::fmt::Debug") names) ++ ">"
            , "<" ++ intercalate ", " names ++ ">" )

-- | True if a Rust field/payload type holds a function (stored callback or fn
-- pointer) — not stringifiable, render a placeholder.
isFnType :: String -> Bool
isFnType t = "dyn Fn" `isInfixOf` t || "fn(" `isInfixOf` t

-- | Is this field type a BARE function pointer/closure — i.e. exactly the shape
-- `disconnected_fnN()` produces (`Arc<dyn Fn(..) -> SkyTask>`) or a raw `fn(..)`?
-- A WRAPPED fn field (`Vec<Arc<dyn Fn>>`, `Option<Arc<dyn Fn>>`,
-- `HashMap<.., Arc<dyn Fn>>`) is NOT bare: its container can't hold a
-- `disconnected_fnN()` value, so it must default via `Default::default()`.
isBareFnField :: String -> Bool
isBareFnField t0 =
    let t = dropWhile (== ' ') t0
        afterArc
            | "std::sync::Arc<" `isPrefixOf` t = Just (drop (length ("std::sync::Arc<" :: String)) t)
            | "Arc<" `isPrefixOf` t            = Just (drop (length ("Arc<" :: String)) t)
            | otherwise                        = Nothing
    in case afterArc of
        Just inner -> "dyn Fn" `isPrefixOf` dropWhile (== ' ') inner
        Nothing    -> "dyn Fn" `isPrefixOf` t || "fn(" `isPrefixOf` t

-- | Render one field/payload value via the TOTAL autoref-specialization dispatch
-- (`stringify.rs` `Wrap` / `ViaSkyStringify` / `ViaDebug`): the field renders via
-- `SkyStringify` if its type impls it, ELSE via `Debug`. Emitted INLINE at the
-- concrete field site (a generic free wrapper can't dispatch — the two arms share
-- a method name and are ambiguous when the type's bounds are unknown).
--
-- `expr` is a place expression that already evaluates to a `&FieldType`
-- (`&self.field` for a struct, a bound `pN` for an enum variant), so we form
-- `(&Wrap(expr)).dispatch()`. This can NEVER E0599 regardless of the field type —
-- the soundness-floor fix.
skyShowFieldDispatch :: String -> String
skyShowFieldDispatch refExpr =
    "(&sky_runtime::stringify::Wrap(" ++ refExpr ++ ")).dispatch()"

skyStringifyStructImpl :: String -> String -> [(String, String)] -> String
skyStringifyStructImpl name gens fields =
    let (implGens, useGens) = skyStringifyImplGens gens
        renderField (fname, ftype)
            | isFnType ftype = "\"<fn>\".to_string()"
            | otherwise      = skyShowFieldDispatch ("&self." ++ fname)
        -- Go `%v` on a struct: `{v0 v1 ...}` space-separated, no field names.
        fmtStr = "{{" ++ intercalate " " (replicate (length fields) "{}") ++ "}}"
        args = map renderField fields
        bodyExpr
            | null fields = "\"{}\".to_string()"
            | otherwise   = "format!(\"" ++ fmtStr ++ "\", " ++ intercalate ", " args ++ ")"
    in "\nimpl" ++ implGens ++ " SkyStringify for " ++ name ++ useGens
       ++ " {\n    fn sky_show(&self) -> String {\n        " ++ bodyExpr ++ "\n    }\n}"

skyStringifyEnumImpl :: String -> String -> [(String, Maybe String)] -> String
skyStringifyEnumImpl name gens variants =
    let (implGens, useGens) = skyStringifyImplGens gens
        arm (vname, Nothing) =
            "            " ++ name ++ "::" ++ vname ++ " => \"" ++ vname ++ "\".to_string(),"
        arm (vname, Just payload) =
            let parts = splitTopLevelCommas payload
                n = length parts
                -- A fn-typed payload renders a `<fn>` placeholder and never reads
                -- its binder, so name it `_pN` to avoid an unused-variable warning
                -- (some generated crates are warning-sensitive; this keeps it clean).
                binder i pty = (if isFnType pty then "_p" else "p") ++ show i
                binders = [ binder i pty | (i, pty) <- zip [0 :: Int ..] parts ]
                renderBind (b, pty)
                    | isFnType pty = "\"<fn>\".to_string()"
                    -- `b` is a `match self` binder → already a `&PayloadType`,
                    -- so `Wrap(b)` carries the reference the dispatch expects.
                    | otherwise    = skyShowFieldDispatch b
                fmtStr = vname ++ " " ++ intercalate " " (replicate n "{}")
                args = map renderBind (zip binders parts)
            in "            " ++ name ++ "::" ++ vname ++ "(" ++ intercalate ", " binders
               ++ ") => format!(\"" ++ fmtStr ++ "\", " ++ intercalate ", " args ++ "),"
        arms = intercalate "\n" (map arm variants)
    in "\nimpl" ++ implGens ++ " SkyStringify for " ++ name ++ useGens
       ++ " {\n    fn sky_show(&self) -> String {\n        match self {\n"
       ++ arms ++ "\n        }\n    }\n}"

-- | Split a Rust type-arg list on TOP-LEVEL commas only (so `Vec<(A,B)>, T`
-- splits into two, not on the inner comma). Used for an enum variant's payload
-- field types.
splitTopLevelCommas :: String -> [String]
splitTopLevelCommas = go 0 ""
  where
    trim = f . f where f = reverse . dropWhile (== ' ')
    go :: Int -> String -> String -> [String]
    go _ acc [] = [trim (reverse acc)]
    go d acc (c:cs)
        | c == ',' && d == 0 = trim (reverse acc) : go d "" cs
        | c `elem` "(<[" = go (d + 1) (c:acc) cs
        | c `elem` ")>]" = go (d - 1) (c:acc) cs
        | otherwise = go d (c:acc) cs

-- | The base type name of a Rust field type, stripping generics/whitespace
-- (`Foo<..>` / `Foo ` -> `Foo`). Used to test a Model field's type against the
-- set of function-typed structs.
fieldTypeBase :: String -> String
fieldTypeBase = takeWhile (\c -> c /= '<' && c /= ' ')

-- | Count the argument types in the first `Fn(...)` clause of a Rust type string:
-- `Fn()` -> 0, `Fn(())` -> 1, `Fn(String, T)` -> 2. Balanced-paren / generic
-- aware (so `Fn(Vec<(A,B)>)` counts 1). Drives the `disconnected_fnN` arity in a
-- function-typed struct's generated `Default`.
fnArgCount :: String -> Int
fnArgCount s = case extractFnArgs s of
    Nothing -> 0
    Just inner -> if all (== ' ') inner then 0 else 1 + topLevelCommas inner
  where
    extractFnArgs ('F' : 'n' : '(' : rest) = Just (takeBalanced (0 :: Int) rest)
    extractFnArgs (_ : cs) = extractFnArgs cs
    extractFnArgs [] = Nothing
    takeBalanced _ [] = []
    takeBalanced d (c : cs)
        | c == ')' && d == 0 = []
        | c == ')' = c : takeBalanced (d - 1) cs
        | c == '(' = c : takeBalanced (d + 1) cs
        | otherwise = c : takeBalanced d cs
    topLevelCommas = go (0 :: Int)
      where
        go _ [] = 0
        go d (c : cs)
            | c == ',' && d == 0 = 1 + go d cs
            | c `elem` "(<[" = go (d + 1) cs
            | c `elem` ")>]" = go (d - 1) cs
            | otherwise = go d cs

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
            [ defName name | RAliasDefGen name _ _ <- builderTypes b ]
            `Set.union` Set.fromList
            [ defName name | RPubUseAlias name _ <- builderTypes b ]
            `Set.union` builderFfiOpaques b  -- types defined by Rust FFI bindings
            -- Hardcoded preamble aliases (wrapperFns + the SkyBool/SkyString/
            -- Value header) aren't in builderTypes; without them, the
            -- return-type scan re-synthesises duplicate placeholders (E0428 on
            -- `Value`/`Decoder` for a JSON-heavy program — 35-composite-generics).
            `Set.union` Set.fromList ["SkyTask", "Decoder", "SkyBool", "SkyString", "Value"]
        -- Collect type names from function parameter types (after ": ")
        -- Sub-D step 4: compare/emit the BASE type name (generic args stripped).
        -- A generic ADT param like `MainRetry<e>` is "defined" by the bare
        -- `MainRetry` enum, so it must not be treated as undefined (which would
        -- emit a colliding `type MainRetry<e> = String;` placeholder — E0428).
        -- A type string is a placeholder candidate if it's an undefined Sky
        -- opaque (not a primitive / generic builtin / qualified path / tuple).
        -- The base name (generics stripped) is what becomes the alias LHS.
        isCandidate t =
            not (null t)
            && not (elem t ["String", "i64", "f64", "bool", "char", "()", "Db", "SkyTask", "SkyError", "HashMap"])
            && not ("impl " `isPrefixOf` t)
            && not ("&" `isPrefixOf` t)
            && not ("Vec<" `isPrefixOf` t)
            && not ("HashMap" `isPrefixOf` t)
            && not ("Option" `isPrefixOf` t)
            && not ("Result" `isPrefixOf` t)
            && not ("SkyMaybe" `isPrefixOf` t)
            && not ("SkyResult" `isPrefixOf` t)
            -- SkyTask<A> (generic form slips past the exact-match list above) —
            -- excluding it avoids a colliding `type SkyTask = String;` (E0428).
            && not ("SkyTask" `isPrefixOf` t)
            && not ("Box<" `isPrefixOf` t)
            && not ("fn(" `isPrefixOf` t)
            -- ANY fully-qualified Rust path (`sky_runtime::LiveReq`,
            -- `std::sync::Arc<…>`) is a real type; its base name carries `::`,
            -- which would synthesise an invalid `type std::sync::Arc = String;`.
            && not ("::" `isInfixOf` t)
            -- A TUPLE type (`(String, i64)`) is already valid Rust — never a
            -- placeholder `type (String, i64) = String;` (invalid alias LHS).
            && not ("(" `isPrefixOf` t)
        -- Param types: the substring after the `name: ` prefix.
        paramTypes = [ dropWhile (== ' ') ty
                     | RustFunction _ _ params _ _ <- allItems, p <- params
                     , let (_, rest) = break (== ':') p, (':':ty) <- [rest] ]
        -- Return types too: a runtimeOpaque used ONLY in return position (e.g.
        -- `report_encode_* -> SkyCoreJsonEncodeValue`) must still get its
        -- `pub use sky_runtime::JsonVal as …;` alias, else it's undefined.
        -- ONLY non-generic return types: a `type X = String;` placeholder drops
        -- type args, so synthesising one for a generic return (`SkyCmd<Msg>`,
        -- `SkyMaybe<T>`) yields E0107 (0 args supplied vs 1). The undefined
        -- opaque we actually need to catch (SkyCoreJsonEncodeValue) is bare.
        returnTypes = [ r | RustFunction _ _ _ r _ <- allItems, '<' `notElem` r ]
        -- A runtime-opaque type can be referenced ONLY by a surviving union/
        -- struct/alias FIELD (not by any function) — e.g. `Jwt.Claims` carries
        -- `Vec<(String, SkyCoreJsonEncodeValue)>` after whole-program DCE prunes
        -- every Jwt function that took a `Value` arg. The function-signature
        -- scan above misses it, leaving its `pub use sky_runtime::JsonVal as …;`
        -- alias unsynthesised (E0412). Scan field-type strings too, keeping only
        -- names in the runtimeOpaque registry so we never synthesise a bogus
        -- `type Vec = String;` from a container ident.
        opaqueNames = Set.fromList
            [ toCamelCase (modPrefix ++ "_" ++ ty)
            | ((mod', ty), _) <- Map.toList runtimeOpaqueTypes
            , let modPrefix = map (\c -> if c == '.' then '_' else c) mod' ]
        typeIdents s = words (map (\c -> if isAlphaNum c || c == '_' then c else ' ') s)
        fieldTypeStrs =
            [ ft | REnumDef _ _ variants <- builderTypes b, (_, Just ft) <- variants ]
            ++ [ ft | RStructDef _ _ fields <- builderTypes b, (_, ft) <- fields ]
            ++ [ ft | RAliasDef _ ft <- builderTypes b ]
            ++ [ ft | RAliasDefGen _ _ ft <- builderTypes b ]
        fieldOpaqueRefs = [ idn | ft <- fieldTypeStrs, idn <- typeIdents ft
                                , Set.member idn opaqueNames ]
        referenced = Set.fromList
            ([ takeWhile (/= '<') t | t <- paramTypes ++ returnTypes, isCandidate t ]
             ++ fieldOpaqueRefs)
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
emitCargoToml :: UsedKernels -> String -> String -> [(String, Toml.RustDepSpec)] -> String -> String
emitCargoToml uk dbDriver sqlxTls rustDeps liveStore = unlines $
    -- The sky_runtime files copied into sky-out/rust/src/ carry cfg(feature = "X")
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
    -- `db` (which gates the copied `#[cfg(feature=\"db\")] SqliteStore` in the
    -- always-compiled live/store.rs) is on ONLY when the app actually needs
    -- sqlx: a Std.Db app, or a Sky.Live app with `[live] store = \"sqlite\"`.
    -- A memory-store Live app must NOT enable `db` (no sqlx dep → would fail).
    -- `live` is enabled when the app uses Sky.Live so live-gated code inside the
    -- always-compiled modules activates — e.g. `#[cfg(feature="live")] impl SkyRow
    -- for LiveReq` in db.rs, which lets `Db.getString "path" req` read an init
    -- handler's typed request (#52). Without it the impl is excluded and the
    -- generated project fails with `LiveReq: SkyRow not satisfied`.
    , "default = [" ++ intercalate ", " (map show (["tokio", "crypto", "json"] ++ ["db" | needsDb] ++ ["redis_store" | needsRedis] ++ ["live" | needsLive] ++ ["webview" | usesWebview uk])) ++ "]"
    , "tokio = []"
    , "crypto = []"
    , "json = []"
    , "db = []"
    -- `live` / `redis_store` / `webview` are DECLARED unconditionally (but only
    -- ENABLED via `default` above under their respective conditions). The
    -- always-compiled `telemetry.rs` carries `#[cfg(feature = "live")]`, and
    -- declaring an unused feature is free — without the declaration, rustc's
    -- `unexpected_cfgs` lint fires on every cfg referencing an undeclared
    -- feature (22 occ for `feature = "live"` in a non-Live project). Declaring
    -- redis_store/webview here too future-proofs the same lint if an
    -- always-copied module later gains one of those gates.
    , "live = []"
    , "redis_store = []"
    , "webview = []"
    -- `static_alloc` activates the optional mimalloc dep + the cfg-gated global
    -- allocator (crate preamble). Declared unconditionally, enabled only by
    -- `sky build --static` via `--features static_alloc`. Off by default.
    , "static_alloc = [\"mimalloc\"]"
    ] ++
    [ ""
    , "[dependencies]"
    , "tokio = { version = " ++ show (crateVersionFor "tokio") ++ ", features = [" ++ intercalate ", " (map show tokioFeats) ++ "] }"
    -- mimalloc: OPTIONAL, pulled only by the `static_alloc` feature (musl static
    -- builds). Inlined here (not crate-specs.toml) because it is a
    -- generated-project, build-mode-only dep — NOT a runtime-crate dep, so it
    -- must stay out of the crate-specs ↔ runtime-rust/Cargo.toml drift sync.
    , "mimalloc = { version = \"0.1\", optional = true }"
    ] ++
    -- sqlx: a Std.Db app, OR a Sky.Live app whose `[live] store` is a sqlx
    -- backend (sqlite/postgres). The feature list is the UNION of the Std.Db
    -- driver and the live-store driver, so an app using e.g. Std.Db(sqlite) +
    -- `[live] store = "postgres"` links both. (Memory/redis live apps don't
    -- emit sqlx — that would fail to compile with no sqlx dep.)
    [ "sqlx = { version = " ++ show (crateVersionFor "sqlx") ++ ", features = [" ++ intercalate ", " (map show sqlxFeats) ++ "] }" | needsDb ] ++
    -- P5 follow-on: `[live] store = "redis"` needs the redis crate for the
    -- copied `#[cfg(feature="redis_store")] RedisStore`.
    [ cargoDependencyFor "redis" | needsRedis, "redis" `notElem` userDepNames ] ++
    -- P5-T4b: the live SessionStore trait is `#[async_trait]` — pull the crate
    -- whenever the project uses Sky.Live.
    [ cargoDependencyFor "async-trait" | needsLive, "async-trait" `notElem` userDepNames ] ++
    [ cargoDependencyFor "serde_json"
    , cargoDependencyFor "sha2"
    ] ++
    -- serde must be UNCONDITIONAL: core.rs's SkyMaybe/SkyResult derive
    -- serde::Serialize/Deserialize (so a Sky.Live model with a `Maybe`/`Result`
    -- field serialises), and core.rs is compiled in every project — not just
    -- Sky.Live ones. Gating this on `usesLive` broke every non-Live example with
    -- E0433 (unresolved crate `serde`). serde is already a transitive dep via
    -- serde_json (unconditional above), so the only added cost is the derive
    -- macro. Std.Live's live/diff.rs Patch wire type also relies on it.
    [ cargoDependencyFor "serde"
    | "serde" `notElem` userDepNames ] ++
    -- Sub-project A — stdlib kernel crates. Always pulled in because
    -- Project.hs declares the corresponding sky_runtime modules in mod.rs
    -- unconditionally. Mostly small pure-Rust crates; cold-build impact is
    -- modest. When sub-A modules become demand-loaded these can match.
    --
    -- Skip names already declared by the user in [rust.dependencies] — Cargo
    -- errors on duplicate keys, and a user-declared entry takes precedence.
    -- (Std.Config front-ends `toml`/`serde_yaml` parse into serde_json::Value,
    -- then the shared json Decoder runs — config_decode.rs.)
    [ cargoDependencyFor name
    | name <-
        [ "regex", "base64", "hex", "percent-encoding", "chrono", "chrono-tz"
        , "rust_decimal", "hmac", "sha1", "md-5", "subtle", "rsa", "aes-gcm"
        , "chacha20poly1305", "pbkdf2", "flate2", "zstd", "csv", "jsonwebtoken"
        , "bcrypt", "toml", "serde_yaml"
        ]
    , name `notElem` userDepNames
    ] ++
    -- uuid is conditional: only when Sky.Core.Uuid is used (uuid_kernel needs
    -- v4+v7). Skipped if the user declared uuid themselves (e.g. FFI'ing the
    -- crate with different features) to avoid a duplicate-key / feature clash.
    [ cargoDependencyFor "uuid"
    | usesUuid uk, "uuid" `notElem` userDepNames ] ++
    -- Sub-D.1: axum + tower-http when Sky.Http.Server OR Std.Live is used.
    -- live_app mounts its own axum Router (self-contained — no `server` module),
    -- so it needs axum even when Sky.Http.Server isn't.
    [ cargoDependencyFor name
    | usesHttpServer uk || needsLive
    , name <- ["axum", "tower-http"]
    , name `notElem` userDepNames ] ++
    -- Std.Live form decode: serde_urlencoded gives TYPE-DIRECTED coercion (a
    -- numeric/bool record field decodes "42"/"true", a String field keeps the
    -- raw string) — the all-String serde_json path rejected non-String fields.
    [ cargoDependencyFor "serde_urlencoded"
    | needsLive, "serde_urlencoded" `notElem` userDepNames ] ++
    -- Sky.Core.Http client + Std.Email: reqwest when used. rustls (no system
    -- OpenSSL). `stream` feature for Http.Stream's bytes_stream(). Std.Live ALSO
    -- pulls it: the live runtime's console reverse-proxy (live/console_proxy.rs,
    -- epic A) forwards to the spawned console child via reqwest + streams the
    -- response (bytes_stream → axum Body::from_stream) so SSE passes through.
    -- Any of the three flags pulls it; emit once.
    [ cargoDependencyFor "reqwest"
    | usesHttp uk || usesEmail uk || needsLive, "reqwest" `notElem` userDepNames ] ++
    -- Std.Email SMTP transport: lettre (async tokio + rustls, no system OpenSSL —
    -- matches reqwest's rustls). Resend/SendGrid/SES go over reqwest above; only
    -- the Smtp provider needs lettre's SMTP client + MIME builder.
    [ cargoDependencyFor "lettre"
    | usesEmail uk, "lettre" `notElem` userDepNames ] ++
    -- futures-util: WebSocket client, plus the streaming paths — http_stream.rs
    -- (StreamExt::next) and server_stream.rs (stream::unfold for the body).
    [ cargoDependencyFor "futures-util"
    | usesWsClient uk || usesHttp uk || usesHttpServer uk || needsLive, "futures-util" `notElem` userDepNames ] ++
    -- Sky.Core.WebSocket client: tokio-tungstenite (futures-util above).
    [ cargoDependencyFor "tokio-tungstenite"
    | usesWsClient uk, "tokio-tungstenite" `notElem` userDepNames ] ++
    -- Std.Tui: crossterm (raw mode) + unicode-width (display width).
    [ cargoDependencyFor "crossterm"
    | usesTui uk, "crossterm" `notElem` userDepNames ] ++
    [ cargoDependencyFor "unicode-width"
    | usesTui uk, "unicode-width" `notElem` userDepNames ] ++
    -- Sky.Webview native window: modern wry/tao (objc2 + current windows-rs;
    -- webkit2gtk-4.1 + libsoup-3.0 on Linux). Only when Std.Webview is used; the
    -- webview feature (default-on above for these projects) compiles webview.rs's
    -- real backend against them.
    [ cargoDependencyFor name
    | usesWebview uk
    , name <- ["wry", "tao"]
    , name `notElem` userDepNames ] ++
    [ emitDepLine name spec
    | (name, spec) <- rustDeps
    , not (null name)
    ] ++
    -- Dev-profile tuning for fast iteration (per user 2026-06-10): drop debuginfo
    -- (debug=0) — the heaviest part of dev linking — and keep incremental on so
    -- only changed codegen units recompile. sccache + a shared CARGO_TARGET_DIR
    -- cover cross-example dep reuse; this cuts the per-example link step. No
    -- effect on release builds (`--release` uses [profile.release]).
    -- Std.Live console proxy: libc on unix for PR_SET_PDEATHSIG (Linux) so the
    -- spawned console child dies with the parent even on SIGKILL. Referenced
    -- only under cfg(target_os = "linux"); the unix-scoped table keeps it off
    -- non-unix builds.
    (if needsLive && "libc" `notElem` userDepNames then
        [ ""
        , "[target.'cfg(unix)'.dependencies]"
        , cargoDependencyFor "libc"
        ]
     else []) ++
    [ ""
    , "[profile.dev]"
    , "debug = 0"
    , "incremental = true"
    -- Go-parity arithmetic: Go's int is 64-bit two's-complement and WRAPS on
    -- overflow (never traps); Rust debug builds default overflow-checks=true and
    -- PANIC on bare `+`/`-`/`*` overflow. A well-typed Sky program doing extreme
    -- i64 arithmetic must not panic (no-panic-from-well-typed-Sky is the product),
    -- so disable the debug overflow trap to match Go's wraparound. Release already
    -- defaults overflow-checks=false; this aligns dev with release AND with Go.
    -- The explicit `checked_*`/saturate kernel guards (Math.abs, Basics.modBy,
    -- Std.Decimal, Auth.signToken, Cache.withTTL) are unaffected — they call
    -- `.checked_*()` regardless of profile, so the intended total semantics hold.
    , "overflow-checks = false"
    -- Release-profile tuning: strip symbols + debuginfo from the release binary
    -- (Go strips via `-ldflags=-s -w`; this is the Rust equivalent). Pure size
    -- win, no functional effect — the no-panic-by-construction runtime doesn't
    -- rely on symbolized backtraces. Only `--release` builds (perf sweep,
    -- deploy) are affected; [profile.dev] keeps symbols for debugging.
    , ""
    , "[profile.release]"
    , "strip = true"
    ]
  where
    userDepNames = [ n | (n, _) <- rustDeps, not (null n) ]
    -- Sky.Webview reuses Sky.Live's renderer + event dispatch (webview.rs imports
    -- live::dispatch::{build_index, HandlerIndex}), so a Webview app needs the
    -- whole `live` stack (module + feature + deps) even though it runs no HTTP
    -- server. needsLive therefore covers both.
    needsLive = usesLive uk || usesWebview uk
    -- A sqlx backend is needed for Std.Db OR a sqlx-backed live store.
    needsDb = usesDb uk || (usesLive uk && liveStore `elem` ["sqlite", "postgres"])
    -- The redis crate is needed only for a redis live store.
    needsRedis = usesLive uk && liveStore == "redis"
    -- Union of sqlx driver features: TLS + Std.Db driver + live-store drivers.
    -- When the live store module compiles with `db` on, store.rs builds BOTH
    -- SqliteStore and PostgresStore (each `#[cfg(feature="db")]`), so both sqlx
    -- drivers must be present regardless of which one `[live] store` selects. A
    -- non-live Std.Db app keeps just its own single driver (no bloat).
    sqlxTlsFeature = if sqlxTls == "native-tls" then "runtime-tokio-native-tls" else "runtime-tokio-rustls"
    sqlxFeats = sqlxTlsFeature : Set.toList (Set.fromList (
        [ dbFeature dbDriver | usesDb uk ]
        -- The console spool (telemetry_spill.rs) is compiled on EVERY Std.Db build
        -- (Project.hs `dbMod`, gated on usesDb). It is an inherently-SQLite local
        -- file (Go-parity SKY_CONSOLE_DB_PATH) and uses `sqlx::SqlitePool`, so the
        -- `sqlite` driver feature must be present whenever Std.Db is used —
        -- regardless of the app's OWN driver. Without this a `[database] driver =
        -- "postgres"` (or mysql) app fails: sqlx's `sqlite` feature is off, so
        -- `sqlx::SqlitePool` is E0432 and the spool's `sqlx::query` is E0282.
        ++ [ "sqlite" | usesDb uk ]
        ++ (if usesLive uk && needsDb then ["sqlite", "postgres"] else [])))
    -- Sky.Http.Server's axum serve loop + the reqwest client both need tokio net.
    -- The TEA loop (tea.rs) uses tokio::sync::mpsc + tokio::time + tokio::spawn;
    -- axum pulls `sync` transitively for the server case, but a plain Sky.Cli
    -- program has no axum, so request it explicitly.
    tokioFeats = ["rt", "rt-multi-thread", "macros", "time"]
                 ++ ["net" | usesHttpServer uk || usesHttp uk || usesWsClient uk || usesEmail uk || needsLive]
                 -- Std.Live: live/session.rs + live/sse.rs use tokio::sync::mpsc.
                 ++ ["sync" | usesTea uk || usesWsClient uk || needsLive]
                 -- Std.Live console proxy (epic A): live/console_proxy.rs spawns
                 -- the pre-built console child (tokio::process) and kills it on
                 -- SIGTERM/SIGINT (tokio::signal). Sky.Webview pulls the live
                 -- module too (needsLive), so it needs these features as well.
                 ++ (if needsLive then ["process", "signal"] else [])
    dbFeature "postgres" = "postgres"
    dbFeature "mysql"    = "mysql"
    dbFeature _          = "sqlite"
    -- Guard: crate names must be [A-Za-z0-9_-] (Cargo convention).
    validCrateName n = not (null n) && all (\c -> isAlphaNum c || c == '_' || c == '-') n
    -- Guard: TOML inline string values must not contain characters that can
    -- escape the surrounding double-quote or inject extra lines.
    validTomlStr v = not (any (`elem` ("\"\\\n\r" :: String)) v)
    emitDepLine name (Toml.RustVersion ver feats)
        | not (validCrateName name) =
            error $ "sky codegen: invalid Rust crate name in sky.toml: " ++ show name
        | not (validTomlStr ver) =
            error $ "sky codegen: invalid version string for crate " ++ show name ++ ": " ++ show ver
        | not (all validTomlStr feats) =
            error $ "sky codegen: invalid feature string for crate " ++ show name
        | null feats    = name ++ " = \"" ++ ver ++ "\""
        | otherwise     = name ++ " = { version = \"" ++ ver ++ "\", features = [" ++ intercalate ", " (map show feats) ++ "] }"
    emitDepLine name (Toml.RustGitDep url mRev mBranch mTag)
        | not (validCrateName name) =
            error $ "sky codegen: invalid Rust crate name in sky.toml: " ++ show name
        | not (validTomlStr url) =
            error $ "sky codegen: invalid git URL for crate " ++ show name ++ ": " ++ show url
        | not (all validTomlStr (maybe [] pure mRev ++ maybe [] pure mBranch ++ maybe [] pure mTag)) =
            error $ "sky codegen: invalid git ref (rev/branch/tag) for crate " ++ show name
        | otherwise =
            let fields = [ "git = " ++ show url ]
                    ++ maybe [] (\r -> ["rev = " ++ show r]) mRev
                    ++ maybe [] (\b -> ["branch = " ++ show b]) mBranch
                    ++ maybe [] (\t -> ["tag = " ++ show t]) mTag
            in name ++ " = { " ++ intercalate ", " fields ++ " }"
