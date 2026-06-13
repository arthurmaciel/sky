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
                  , "pub fn db_open(driver: String, path: String) -> SkyTask<Db> { sky_runtime::db::db_open(driver, path) }"
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
    let hasTokio = usesTaskRun uk || usesTaskParallel uk || usesDb uk || usesHttpServer uk || usesEmail uk || usesLive uk
        -- sky_main returns SkyTask<()> (needs block_on) UNLESS the user calls
        -- Task.run itself, in which case sky_main returns () and runs the task
        -- inline. Sky.Live is NOT an exception: `live_app`/`live_app_routed`
        -- return SkyTask<()> (a `Box::pin(async move { serve_live(...).await })`
        -- future), so the entry MUST block_on it — dropping it exits the process
        -- before axum binds a port (the binary appeared to "run" but served
        -- nothing). Server.listen is the same shape (returns a block_on'd Task).
        -- #56 / #24 tenet 3: a backend-entry program (Live.app / Tui.app /
        -- Tui.program / Webview.app) has its driver future as the real entry, so
        -- ANY backend-app usage forces the block_on even when usesTaskRun is set
        -- — otherwise the future is dropped and the app never runs. The inline
        -- Task.run calls each run on their own throwaway runtime, fine. (Was
        -- usesLive-only; broadened so pure-Tui / pure-Webview mains, whose
        -- `App {…} |> Task.run` is now dropped by tenet 2, return a SkyTask too.)
        mainIsTask = usesLive uk || usesTui uk || usesWebview uk || not (usesTaskRun uk)
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
    let derive = if name `Set.member` serdeTypes
                 then "#[derive(Clone, Debug, PartialEq, serde::Serialize, serde::Deserialize)]"
                 else "#[derive(Clone, Debug, PartialEq)]"
    in derive ++ "\npub enum " ++ name ++ gens ++ " {\n" ++ intercalate ",\n" (map (\(n, mt) -> "    " ++ n ++ maybe "" (\x -> "(" ++ x ++ ")") mt) variants) ++ "\n}"
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
        defaultField (n, t) =
            "            " ++ n ++ ": sky_runtime::core::disconnected_fn" ++ show (fnArgCount t) ++ "()"
        defaultImpl
            | hasFnField =
                "\nimpl Default for " ++ name ++ gens ++ " {\n    fn default() -> Self {\n        "
                ++ name ++ " {\n" ++ intercalate ",\n" (map defaultField fields) ++ "\n        }\n    }\n}"
            | otherwise = ""
    in structDef ++ defaultImpl
typeDefToString _ _ _ (RAliasDef name ty) = "pub type " ++ name ++ " = " ++ ty ++ ";"
typeDefToString _ _ _ (RPubUseAlias codegenName rustPath) =
    "pub use " ++ rustPath ++ " as " ++ codegenName ++ ";"
typeDefToString _ _ _ (RAliasDefGen name gens path) =
    "pub type " ++ name ++ gens ++ " = " ++ path ++ ";"

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
    -- `db` (which gates the copied `#[cfg(feature=\"db\")] SqliteStore` in the
    -- always-compiled live/store.rs) is on ONLY when the app actually needs
    -- sqlx: a Std.Db app, or a Sky.Live app with `[live] store = \"sqlite\"`.
    -- A memory-store Live app must NOT enable `db` (no sqlx dep → would fail).
    -- `live` is enabled when the app uses Sky.Live so live-gated code inside the
    -- always-compiled modules activates — e.g. `#[cfg(feature="live")] impl SkyRow
    -- for LiveReq` in db.rs, which lets `Db.getString "path" req` read an init
    -- handler's typed request (#52). Without it the impl is excluded and the
    -- generated project fails with `LiveReq: SkyRow not satisfied`.
    , "default = [" ++ intercalate ", " (map show (["tokio", "crypto", "json"] ++ ["db" | needsDb] ++ ["redis_store" | needsRedis] ++ ["live" | usesLive uk])) ++ "]"
    , "tokio = []"
    , "crypto = []"
    , "json = []"
    , "db = []"
    ] ++
    -- Std.Live with `[live] store = "redis"`: gates the copied
    -- `#[cfg(feature="redis_store")] RedisStore`.
    [ "redis_store = []" | needsRedis ] ++
    -- Std.Live: declare the live feature so #[cfg(feature = "live")] in the
    -- copied runtime files evaluates to true when the project uses Sky.Live.
    [ "live = []" | usesLive uk ] ++
    [ ""
    , "[dependencies]"
    , "tokio = { version = \"1\", features = [" ++ intercalate ", " (map show tokioFeats) ++ "] }"
    ] ++
    -- sqlx: a Std.Db app, OR a Sky.Live app whose `[live] store` is a sqlx
    -- backend (sqlite/postgres). The feature list is the UNION of the Std.Db
    -- driver and the live-store driver, so an app using e.g. Std.Db(sqlite) +
    -- `[live] store = "postgres"` links both. (Memory/redis live apps don't
    -- emit sqlx — that would fail to compile with no sqlx dep.)
    [ "sqlx = { version = \"0.8\", features = [" ++ intercalate ", " (map show sqlxFeats) ++ "] }" | needsDb ] ++
    -- P5 follow-on: `[live] store = "redis"` needs the redis crate for the
    -- copied `#[cfg(feature="redis_store")] RedisStore`.
    [ "redis = { version = \"0.27\", features = [\"tokio-comp\"] }" | needsRedis, "redis" `notElem` userDepNames ] ++
    -- P5-T4b: the live SessionStore trait is `#[async_trait]` — pull the crate
    -- whenever the project uses Sky.Live.
    [ "async-trait = \"0.1\"" | usesLive uk, "async-trait" `notElem` userDepNames ] ++
    [ "serde_json = \"1\""
    , "sha2 = \"0.10\""
    ] ++
    -- serde must be UNCONDITIONAL: core.rs's SkyMaybe/SkyResult derive
    -- serde::Serialize/Deserialize (so a Sky.Live model with a `Maybe`/`Result`
    -- field serialises), and core.rs is compiled in every project — not just
    -- Sky.Live ones. Gating this on `usesLive` broke every non-Live example with
    -- E0433 (unresolved crate `serde`). serde is already a transitive dep via
    -- serde_json (unconditional above), so the only added cost is the derive
    -- macro. Std.Live's live/diff.rs Patch wire type also relies on it.
    [ "serde = { version = \"1\", features = [\"derive\"] }"
    | "serde" `notElem` userDepNames ] ++
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
    -- Sub-D.1: axum + tower-http when Sky.Http.Server OR Std.Live is used.
    -- live_app mounts its own axum Router (self-contained — no `server` module),
    -- so it needs axum even when Sky.Http.Server isn't.
    [ name ++ " = " ++ spec
    | usesHttpServer uk || usesLive uk
    , (name, spec) <-
        [ ("axum",       "{ version = \"0.7\", features = [\"ws\"] }")
        , ("tower-http", "{ version = \"0.5\", features = [\"fs\", \"catch-panic\"] }")
        ]
    , name `notElem` userDepNames ] ++
    -- Sky.Core.Http client + Std.Email: reqwest when used. rustls (no system
    -- OpenSSL). `stream` feature for Http.Stream's bytes_stream(). Std.Live ALSO
    -- pulls it: the live runtime's console reverse-proxy (live/console_proxy.rs,
    -- epic A) forwards to the spawned console child via reqwest + streams the
    -- response (bytes_stream → axum Body::from_stream) so SSE passes through.
    -- Any of the three flags pulls it; emit once.
    [ "reqwest = { version = \"0.12\", default-features = false, features = [\"rustls-tls\", \"gzip\", \"stream\"] }"
    | usesHttp uk || usesEmail uk || usesLive uk, "reqwest" `notElem` userDepNames ] ++
    -- futures-util: WebSocket client, plus the streaming paths — http_stream.rs
    -- (StreamExt::next) and server_stream.rs (stream::unfold for the body).
    [ "futures-util = \"0.3\""
    | usesWsClient uk || usesHttp uk || usesHttpServer uk || usesLive uk, "futures-util" `notElem` userDepNames ] ++
    -- Sky.Core.WebSocket client: tokio-tungstenite (futures-util above).
    [ "tokio-tungstenite = \"0.24\""
    | usesWsClient uk, "tokio-tungstenite" `notElem` userDepNames ] ++
    -- Std.Tui: crossterm (raw mode) + unicode-width (display width).
    [ "crossterm = \"0.28\""
    | usesTui uk, "crossterm" `notElem` userDepNames ] ++
    [ "unicode-width = \"0.1\""
    | usesTui uk, "unicode-width" `notElem` userDepNames ] ++
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
    (if usesLive uk && "libc" `notElem` userDepNames then
        [ ""
        , "[target.'cfg(unix)'.dependencies]"
        , "libc = \"0.2\""
        ]
     else []) ++
    [ ""
    , "[profile.dev]"
    , "debug = 0"
    , "incremental = true"
    ]
  where
    userDepNames = [ n | (n, _) <- rustDeps, not (null n) ]
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
        ++ (if usesLive uk && needsDb then ["sqlite", "postgres"] else [])))
    -- Sky.Http.Server's axum serve loop + the reqwest client both need tokio net.
    -- The TEA loop (tea.rs) uses tokio::sync::mpsc + tokio::time + tokio::spawn;
    -- axum pulls `sync` transitively for the server case, but a plain Sky.Cli
    -- program has no axum, so request it explicitly.
    tokioFeats = ["rt", "rt-multi-thread", "macros", "time"]
                 ++ ["net" | usesHttpServer uk || usesHttp uk || usesWsClient uk || usesEmail uk || usesLive uk]
                 -- Std.Live: live/session.rs + live/sse.rs use tokio::sync::mpsc.
                 ++ ["sync" | usesTea uk || usesWsClient uk || usesLive uk]
                 -- Std.Live console proxy (epic A): live/console_proxy.rs spawns
                 -- the pre-built console child (tokio::process) and kills it on
                 -- SIGTERM/SIGINT (tokio::signal).
                 ++ (if usesLive uk then ["process", "signal"] else [])
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
