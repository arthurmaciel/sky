module Sky.Generate.Rust.Kernel where

import Sky.AST.Canonical
import Sky.Generate.Rust.Expr

data KernelFn
    = KString String
    | KList ListFn
    | KDict DictFn
    | KMaybe MaybeFn
    | KResult ResultFn
    | KTask TaskFn
    | KMath MathFn
    | KTime TimeFn
    | KRandom RandomFn
    | KFile FileFn
    | KHttp HttpFn
    | KIo IoFn
    | KSystem SystemFn
    deriving (Eq, Show)

data ListFn
    = LMap | LFilter | LFoldl | LFoldr | LLength | LHead | LTail
    | LReverse | LAppend | LCons | LTake | LDrop | LIndex | LMember
    | LSort | LSortBy | LConcat | LConcatMap | LFind | LAny | LAll
    deriving (Eq, Show)

data DictFn
    = DGet | DInsert | DRemove | DMember | DKeys | DValues | DToList | DFromList
    | DMap | DFoldl | DFoldr | DEmpty
    deriving (Eq, Show)

data MaybeFn
    = MWithDefault | MMap | MAndThen | MMaybe | MJust | MNothing
    deriving (Eq, Show)

data ResultFn
    = RWithDefault | RMap | RMapError | RAndThen | ROk | RErr | RSucceed | RFail
    deriving (Eq, Show)

data TaskFn
    = TSucceed | TFail | TMap | TAndThen | TPerform | TParallel | TLazy | TRun
    deriving (Eq, Show)

data MathFn
    = MAdd | MSub | MMul | MDiv | MMod | MPow | MAbs | MFloor | MCeil | MRound
    | MMin | MMax | MSqrt | MLog | MSin | MCos | MTan | MPi | Me
    deriving (Eq, Show)

data TimeFn
    = TNow | TSleep | TEvery | TUnixMillis | TFormatISO | TFormatRFC | TFormat | TParse
    deriving (Eq, Show)

data RandomFn
    = RInt | RFloat | RChoice | RShuffle
    deriving (Eq, Show)

data FileFn
    = FReadFile | FWriteFile | FAppend | FMkdir | FReadDir | FExists | FRemove | FIsDir
    deriving (Eq, Show)

data HttpFn
    = HGet | HPost | HRequest
    deriving (Eq, Show)

data IoFn
    = IReadLine | IWriteStdout | IWriteStderr
    deriving (Eq, Show)

data SystemFn
    = SArgs | SGetArg | SGetEnv | SGetEnvOr | SGetEnvInt | SGetEnvBool | SCwd | SExit | SLoadEnv
    deriving (Eq, Show)

kernelToExpr :: String -> Maybe KernelFn
kernelToExpr name = case name of
    "String.length" -> Just $ KString "length"
    "String.reverse" -> Just $ KString "reverse"
    "String.append" -> Just $ KString "append"
    "String.split" -> Just $ KString "split"
    "String.join" -> Just $ KString "join"
    "String.contains" -> Just $ KString "contains"
    "String.startsWith" -> Just $ KString "startsWith"
    "String.endsWith" -> Just $ KString "endsWith"
    "String.toInt" -> Just $ KString "toInt"
    "String.fromInt" -> Just $ KString "fromInt"
    "String.toFloat" -> Just $ KString "toFloat"
    "String.fromFloat" -> Just $ KString "fromFloat"
    "String.toUpper" -> Just $ KString "toUpper"
    "String.toLower" -> Just $ KString "toLower"
    "String.trim" -> Just $ KString "trim"
    "String.replace" -> Just $ KString "replace"
    "String.slice" -> Just $ KString "slice"
    "String.isEmpty" -> Just $ KString "isEmpty"

    "List.map" -> Just $ KList LMap
    "List.filter" -> Just $ KList LFilter
    "List.foldl" -> Just $ KList LFoldl
    "List.foldr" -> Just $ KList LFoldr
    "List.length" -> Just $ KList LLength
    "List.head" -> Just $ KList LHead
    "List.tail" -> Just $ KList LTail
    "List.reverse" -> Just $ KList LReverse
    "List.append" -> Just $ KList LAppend
    "List.take" -> Just $ KList LTake
    "List.drop" -> Just $ KList LDrop
    "List.indexedMap" -> Just $ KList LIndex
    "List.member" -> Just $ KList LMember
    "List.find" -> Just $ KList LFind
    "List.any" -> Just $ KList LAny
    "List.all" -> Just $ KList LAll
    "List.concatMap" -> Just $ KList LConcatMap
    "List.range" -> Just $ KList LMap

    "Dict.get" -> Just $ KDict DGet
    "Dict.insert" -> Just $ KDict DInsert
    "Dict.remove" -> Just $ KDict DRemove
    "Dict.member" -> Just $ KDict DMember
    "Dict.keys" -> Just $ KDict DKeys
    "Dict.values" -> Just $ KDict DValues
    "Dict.toList" -> Just $ KDict DToList
    "Dict.fromList" -> Just $ KDict DFromList
    "Dict.empty" -> Just $ KDict DEmpty

    "Maybe.withDefault" -> Just $ KMaybe MWithDefault
    "Maybe.map" -> Just $ KMaybe MMap
    "Maybe.andThen" -> Just $ KMaybe MAndThen

    "Result.withDefault" -> Just $ KResult RWithDefault
    "Result.map" -> Just $ KResult RMap
    "Result.mapError" -> Just $ KResult RMapError
    "Result.andThen" -> Just $ KResult RAndThen

    "Task.succeed" -> Just $ KTask TSucceed
    "Task.fail" -> Just $ KTask TFail
    "Task.map" -> Just $ KTask TMap
    "Task.andThen" -> Just $ KTask TAndThen
    "Task.lazy" -> Just $ KTask TLazy

    "+" -> Just $ KMath MAdd
    "-" -> Just $ KMath MSub
    "*" -> Just $ KMath MMul
    "/" -> Just $ KMath MDiv
    "modBy" -> Just $ KMath MMod
    "Basics.abs" -> Just $ KMath MAbs
    "Basics.floor" -> Just $ KMath MFloor
    "Basics.ceiling" -> Just $ KMath MCeil
    "Basics.round" -> Just $ KMath MRound
    "Basics.min" -> Just $ KMath MMin
    "Basics.max" -> Just $ KMath MMax
    "Math.sqrt" -> Just $ KMath MSqrt
    "Math.pow" -> Just $ KMath MPow
    "Math.sin" -> Just $ KMath MSin
    "Math.cos" -> Just $ KMath MCos
    "Math.tan" -> Just $ KMath MTan
    "Math.pi" -> Just $ KMath MPi
    "Math.e" -> Just $ KMath Me

    _ -> Nothing

kernelToRust :: KernelFn -> String
kernelToRust kf = case kf of
    KString fn -> "sky_string::" ++ stringFnToRust fn
    KList fn -> "sky_list::" ++ listFnToRust fn
    KDict fn -> "sky_dict::" ++ dictFnToRust fn
    KMaybe fn -> "sky_maybe::" ++ maybeFnToRust fn
    KResult fn -> "sky_result::" ++ resultFnToRust fn
    KTask fn -> "sky_task::" ++ taskFnToRust fn
    KMath fn -> "sky_math::" ++ mathFnToRust fn
    KTime _ -> "sky_time::now()"
    KRandom fn -> "sky_random::" ++ randomFnToRust fn
    KFile fn -> "sky_file::" ++ fileFnToRust fn
    KHttp fn -> "sky_http::" ++ httpFnToRust fn
    KIo fn -> "sky_io::" ++ ioFnToRust fn
    KSystem fn -> "sky_system::" ++ systemFnToRust fn

stringFnToRust :: String -> String
stringFnToRust fn = case fn of
    "length" -> "length"
    "reverse" -> "reverse"
    "append" -> "append"
    "split" -> "split"
    "join" -> "join"
    "contains" -> "contains"
    "startsWith" -> "starts_with"
    "endsWith" -> "ends_with"
    "toInt" -> "to_int"
    "fromInt" -> "from_int"
    "toFloat" -> "to_float"
    "fromFloat" -> "from_float"
    "toUpper" -> "to_uppercase"
    "toLower" -> "to_lowercase"
    "trim" -> "trim"
    "replace" -> "replace"
    "slice" -> "slice"
    "isEmpty" -> "is_empty"
    _ -> fn

listFnToRust :: ListFn -> String
listFnToRust fn = case fn of
    LMap -> "map"
    LFilter -> "filter"
    LFoldl -> "foldl"
    LFoldr -> "foldr"
    LLength -> "length"
    LHead -> "head"
    LTail -> "tail"
    LReverse -> "reverse"
    LAppend -> "append"
    LCons -> "cons"
    LTake -> "take"
    LDrop -> "drop"
    LIndex -> "indexed_map"
    LMember -> "member"
    LFind -> "find"
    LAny -> "any"
    LAll -> "all"
    LSort -> "sort"
    LSortBy -> "sort_by"
    LConcat -> "concat"
    LConcatMap -> "concat_map"

dictFnToRust :: DictFn -> String
dictFnToRust fn = case fn of
    DGet -> "get"
    DInsert -> "insert"
    DRemove -> "remove"
    DMember -> "member"
    DKeys -> "keys"
    DValues -> "values"
    DToList -> "to_list"
    DFromList -> "from_list"
    DEmpty -> "new"

maybeFnToRust :: MaybeFn -> String
maybeFnToRust fn = case fn of
    MWithDefault -> "with_default"
    MMap -> "map"
    MAndThen -> "and_then"
    MJust -> "just"
    MNothing -> "nothing"

resultFnToRust :: ResultFn -> String
resultFnToRust fn = case fn of
    RWithDefault -> "with_default"
    RMap -> "map"
    RMapError -> "map_error"
    RAndThen -> "and_then"
    ROk -> "ok"
    RErr -> "err"

taskFnToRust :: TaskFn -> String
taskFnToRust fn = case fn of
    TSucceed -> "succeed"
    TFail -> "fail"
    TMap -> "map"
    TAndThen -> "and_then"
    TLazy -> "lazy"

mathFnToRust :: MathFn -> String
mathFnToRust fn = case fn of
    MAdd -> "add"
    MSub -> "sub"
    MMul -> "mul"
    MDiv -> "div"
    MMod -> "mod"
    MPow -> "pow"
    MAbs -> "abs"
    MFloor -> "floor"
    MCeil -> "ceil"
    MRound -> "round"
    MMin -> "min"
    MMax -> "max"
    MSqrt -> "sqrt"
    MLog -> "log"
    MSin -> "sin"
    MCos -> "cos"
    MTan -> "tan"
    MPi -> "pi"
    Me -> "e"

randomFnToRust :: RandomFn -> String
randomFnToRust fn = case fn of
    RInt -> "int"
    RFloat -> "float"
    RChoice -> "choice"
    RShuffle -> "shuffle"

fileFnToRust :: FileFn -> String
fileFnToRust fn = case fn of
    FReadFile -> "read_file"
    FWriteFile -> "write_file"
    FAppend -> "append"
    FMkdir -> "mkdir"
    FReadDir -> "read_dir"
    FExists -> "exists"
    FRemove -> "remove"
    FIsDir -> "is_dir"

httpFnToRust :: HttpFn -> String
httpFnToRust fn = case fn of
    HGet -> "get"
    HPost -> "post"
    HRequest -> "request"

ioFnToRust :: IoFn -> String
ioFnToRust fn = case fn of
    IReadLine -> "read_line"
    IWriteStdout -> "write_stdout"
    IWriteStderr -> "write_stderr"

systemFnToRust :: SystemFn -> String
systemFnToRust fn = case fn of
    SArgs -> "args"
    SGetArg -> "get_arg"
    SGetEnv -> "getenv"
    SGetEnvOr -> "getenv_or"
    SGetEnvInt -> "getenv_int"
    SGetEnvBool -> "getenv_bool"
    SCwd -> "cwd"
    SExit -> "exit"
    SLoadEnv -> "load_env"