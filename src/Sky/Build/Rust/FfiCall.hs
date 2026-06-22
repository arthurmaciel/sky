{-# LANGUAGE OverloadedStrings #-}
-- | Wall #3 of the demand-driven generic Sky→Rust FFI epic — the typed
-- call-AST (Scheme A) that REPLACES Wall #2's @{hole}@ string template.
--
-- == Why a typed AST instead of a string template ==
-- Wall #2 rendered the generic wrapper body by substituting @{param}@ /
-- @{argN}@ holes into a Rust string, then gated on "is every hole filled?".
-- A string template can place a type-param where a value-arg belongs, leave a
-- hole un-substituted, or skip an index — every one of those a cargo-fail with
-- no Sky diagnostic. The Scheme-A 'Call' ADT makes those states UNREPRESENTABLE
-- (parse-don't-validate): generic params are first-class indexed refs, the
-- receiver/args/ret are structurally-fixed slots, and 'renderCall' is TOTAL
-- over a 'Call' that survived 'FromJSON' validation.
--
-- == The parse-time validation contract (guardian constraint #2) ==
-- 'FromJSON Call' VALIDATES against the declared param count at decode time, so
-- a malformed AST is a hard parse error (the build fails to load the registry),
-- never a silent default that leaks into codegen:
--
--   * every @{param:i}@ index is @< |params|@;
--   * @receiver@ is present IFF the method has a @self@ input — encoded as
--     @kind = "method"@ ⇒ receiver present, @kind = "function"@ ⇒ absent;
--   * every @arg@/@param@ ref in @typeArgs@ / @args@ / @ret@ / @receiver@ is in
--     range (param refs @< nParams@; arg refs @< nArgs@, where @nArgs@ is the
--     wrapper's declared value-arg count).
--
-- The retired @{hole}@ contiguity gate is replaced by this structural validity.
--
-- == Go-safety ==
-- A 'Call' is produced ONLY by a Rust-target parametric stub (the Go inspector
-- drops generics at the producer — no Go kernel.json ever carries a @generic@
-- block, let alone a @call@ object). Decoding is keyed under @_ffn_generic =
-- Just@, so the whole module is dead for the Go path.
module Sky.Build.Rust.FfiCall
    ( -- * the typed call-AST
      Call(..)
    , CallKind(..)
    , Receiver(..)
    , ByKind(..)
    , TypeRef(..)
    , callArity
      -- * parse-time validation (exposed for the drift corpus + negative tests)
    , validateCall
    , parseCall
      -- * total render over a validated Call
    , renderCall
    , renderRetType
    , renderArgType
    , renderTypeRef
    ) where

import Control.Monad (foldM, unless)
import Data.List (intercalate)
import qualified Data.Aeson as A
import Data.Aeson ((.:), (.:?), (.!=))
import qualified Data.Aeson.Types as AT
import qualified Data.Text as T

import Sky.Generate.Rust.Builder.Naming (mangleTVar)


-- ─── the typed call-AST ──────────────────────────────────────────────


-- | One Rust call expression, fully structured so illegal param placement is
-- unrepresentable. The wrapper body is @renderCall call params nArgs@.
data Call = Call
    { _call_kind     :: !CallKind     -- ^ method (has receiver) vs free function
    , _call_path     :: ![String]     -- ^ @::@-joined leading path, e.g. @["mycrate","Pair"]@
    , _call_typeArgs :: ![TypeRef]    -- ^ turbofish type-args on the path, e.g. @::<K, V>@
    , _call_method   :: !(Maybe String) -- ^ method/assoc-fn name (Nothing → call the path directly)
    , _call_receiver :: !(Maybe Receiver) -- ^ Just IFF kind == CallMethod with a self input
    , _call_args     :: ![Int]        -- ^ value-arg indices, positional with the wrapper params
    , _call_argTypes :: ![TypeRef]    -- ^ wrapper VALUE-ARG Rust types, indexed by wrapper-arg-index
                                       --   (length == 'callArity'; entry j is the type of @argJ@,
                                       --   covering the receiver arg too, e.g. @::box1::Box1<A>@)
    , _call_ret      :: !TypeRef      -- ^ wrapper return type (inside the @SkyResult<SkyError, _>@)
    }
    deriving (Show, Eq)


-- | Whether the call has a receiver (a self input) or is a free / static call.
-- Drives the parse-time "receiver present iff self input" check.
data CallKind
    = CallMethod    -- ^ @recv.method(args)@ or @Path::method(recv, args)@ with a self input
    | CallFunction  -- ^ @Path::method(args)@ / @Path(args)@ — no self input
    deriving (Show, Eq)


-- | The receiver of a method call: which wrapper value-arg supplies it, and how
-- it is passed (by ref / mut-ref / value). Always @args[0]@ in practice, but the
-- index is explicit so the AST is self-describing and validated.
data Receiver = Receiver
    { _recv_arg :: !Int      -- ^ wrapper value-arg index supplying the receiver
    , _recv_by  :: !ByKind   -- ^ borrow form
    }
    deriving (Show, Eq)


-- | How a receiver is passed to the method.
data ByKind
    = ByRef     -- ^ @&arg@
    | ByRefMut  -- ^ @&mut arg@
    | ByValue   -- ^ @arg@
    deriving (Show, Eq)


-- | A type reference inside @typeArgs@ / @ret@ / nested ctor args. Either an
-- indexed generic param, a concrete primitive, or a (possibly parametric)
-- named constructor. Leaves are data, never control — there is no string-
-- substitution surface, so nothing can be left unfilled or misplaced.
data TypeRef
    = TRParam !Int           -- ^ @{param:i}@ — the i-th generic param (mangled @a → A@)
    | TRPrim  !String        -- ^ @{prim:"i64"}@ — a concrete Rust primitive leaf
    | TRCtor  !String ![TypeRef] -- ^ @{ctor:"Option", args:[…]}@ — @Name<args…>@ (@::@-joined name ok)
    deriving (Show, Eq)


-- | The wrapper's value-arg count: one past the max arg index referenced by the
-- receiver + args. Used by the renderer to emit the param list and by validation
-- to bound arg refs. Densely covered — validation rejects a gap, so this never
-- undercounts a referenced arg.
callArity :: Call -> Int
callArity c =
    let recvIdx = maybe [] (\r -> [_recv_arg r]) (_call_receiver c)
        idxs    = recvIdx ++ _call_args c
    in if null idxs then 0 else maximum idxs + 1


-- ─── parse-time validation (constraint #2) ───────────────────────────


-- | Validate a decoded 'Call' against its declared param count. Returns the
-- 'Call' unchanged on success, or a human-readable reason on failure. Called
-- from 'FromJSON' so a malformed AST is a hard parse error, and EXPOSED so the
-- drift corpus / negative tests can assert acceptance / rejection directly.
--
-- Checks (all structural — 'renderCall' is total once these pass):
--
--   1. every @TRParam i@ anywhere (typeArgs / ret) has @0 <= i < nParams@;
--   2. @CallMethod@ ⇒ @receiver@ present; @CallFunction@ ⇒ @receiver@ absent
--      (the "receiver iff self input" rule);
--   3. every value-arg ref (receiver arg + each @args@ entry) is @>= 0@ and
--      the set of referenced arg indices is GAP-FREE from 0 (so @callArity@
--      covers every referenced arg — no arg index is left without a param);
--   4. arg indices are unique (an arg can't feed two slots — that would be a
--      use-after-move in the rendered Rust).
validateCall :: Int -> Call -> Either String Call
validateCall nParams c = do
    -- (1) param refs in range.
    mapM_ checkParamRef (allTypeRefs c)
    -- (2) receiver presence matches kind.
    case (_call_kind c, _call_receiver c) of
        (CallMethod, Nothing) ->
            Left "call kind \"method\" requires a `receiver`, but none is present"
        (CallFunction, Just _) ->
            Left "call kind \"function\" must not carry a `receiver`"
        _ -> Right ()
    -- (3) + (4) arg indices: non-negative, unique, gap-free from 0.
    let recvIdxs = maybe [] (\r -> [_recv_arg r]) (_call_receiver c)
        argIdxs  = recvIdxs ++ _call_args c
    mapM_ checkArgNonNeg argIdxs
    _ <- foldM checkUnique [] argIdxs
    checkGapFree argIdxs
    -- (5) argTypes covers EXACTLY one type per wrapper value-arg (so the
    -- rendered `fn(argJ: T)` param list has a type for every emitted param).
    let arity = if null argIdxs then 0 else maximum argIdxs + 1
    unless (length (_call_argTypes c) == arity) $
        Left ("argTypes has " ++ show (length (_call_argTypes c))
               ++ " entry(ies) but the call references " ++ show arity
               ++ " value-arg(s)")
    Right c
  where
    checkParamRef i
        | i < 0 || i >= nParams =
            Left ("type-param ref {param:" ++ show i ++ "} is out of range "
                   ++ "(declared " ++ show nParams ++ " param(s))")
        | otherwise = Right ()
    checkArgNonNeg i
        | i < 0 = Left ("value-arg ref {arg:" ++ show i ++ "} is negative")
        | otherwise = Right ()
    checkUnique seen i
        | i `elem` seen =
            Left ("value-arg {arg:" ++ show i ++ "} is referenced more than once")
        | otherwise = Right (i : seen)
    checkGapFree idxs =
        let arity = if null idxs then 0 else maximum idxs + 1
            gaps  = [ j | j <- [0 .. arity - 1], j `notElem` idxs ]
        in case gaps of
            (j : _) -> Left ("value-arg index " ++ show j ++ " is never "
                              ++ "referenced (arg indices must be contiguous "
                              ++ "from 0)")
            []      -> Right ()


-- | Every 'TypeRef' leaf reachable from a 'Call' (typeArgs + ret + nested ctor
-- args), as a flat list of the indices used by @TRParam@. Used by validation to
-- bound param refs.
allTypeRefs :: Call -> [Int]
allTypeRefs c =
    concatMap paramIdxs (_call_typeArgs c ++ _call_argTypes c ++ [_call_ret c])
  where
    paramIdxs (TRParam i)     = [i]
    paramIdxs (TRPrim _)      = []
    paramIdxs (TRCtor _ args) = concatMap paramIdxs args


-- ─── total render over a validated Call ──────────────────────────────


-- | Render the wrapper BODY expression for a validated 'Call'. @params@ are the
-- declared generic param names (positional with @TRParam@ indices); they are
-- mangled @a → A@ via 'mangleTVar' so the emitted Rust matches the @<A: …>@
-- clause Wall #2 renders. Total: every constructor maps to valid Rust.
--
--   * path + turbofish: @::mycrate::Pair::<K, V>@
--   * method + receiver: @::mycrate::Pair::<K, V>::left(&arg0)@
--   * free fn: @::mycrate::make::<A>(arg0)@
--   * no method (path is the callee): @::mycrate::Pair::<K, V>(arg0)@
renderCall :: Call -> [String] -> String
renderCall c params =
    let pathStr   = intercalate "::" (_call_path c)
        turbofish = case _call_typeArgs c of
            []  -> ""
            trs -> "::<" ++ intercalate ", " (map (renderTypeRef params) trs) ++ ">"
        -- The callee: path (+ turbofish) optionally followed by ::method.
        callee = case _call_method c of
            Just m  -> pathStr ++ turbofish ++ "::" ++ m
            Nothing -> pathStr ++ turbofish
        -- Receiver argument (if any), borrow-formed, prepended to the value args.
        recvArg = case _call_receiver c of
            Nothing -> []
            Just r  -> [renderBy (_recv_by r) (argName (_recv_arg r))]
        valArgs = map argName (_call_args c)
        allArgs = recvArg ++ valArgs
    in callee ++ "(" ++ intercalate ", " allArgs ++ ")"


-- | Render the wrapper RETURN type (the @_@ inside @SkyResult<SkyError, _>@)
-- from the call's @ret@ TypeRef.
renderRetType :: Call -> [String] -> String
renderRetType c params = renderTypeRef params (_call_ret c)


-- | Render wrapper value-arg @j@'s Rust type from the call's @argTypes@.
-- Validation proved @length argTypes == callArity@, so the lookup is total via
-- a guarded @drop@ (the @()@ fallback is unreachable post-validation).
renderArgType :: Call -> [String] -> Int -> String
renderArgType c params j = case drop j (_call_argTypes c) of
    (tr : _) -> renderTypeRef params tr
    []       -> "()"   -- unreachable post-validation; total fallback


-- | The wrapper value-arg identifier for index @j@ (matches the param-list the
-- caller emits: @arg0@, @arg1@, …).
argName :: Int -> String
argName j = "arg" ++ show j


-- | Apply the receiver borrow form.
renderBy :: ByKind -> String -> String
renderBy ByRef    s = "&" ++ s
renderBy ByRefMut s = "&mut " ++ s
renderBy ByValue  s = s


-- | Render a 'TypeRef' to a Rust type string. @TRParam i@ → the mangled name of
-- @params !! i@ (validation already proved @i@ in range, so the lookup is total
-- via a guarded @drop@). Total over every constructor.
renderTypeRef :: [String] -> TypeRef -> String
renderTypeRef params tr = case tr of
    TRParam i -> case drop i params of
        (p : _) -> mangleTVar p
        []      -> "()"   -- unreachable post-validation; total fallback, never a panic
    TRPrim p  -> p
    TRCtor nm [] -> nm
    TRCtor nm args ->
        nm ++ "<" ++ intercalate ", " (map (renderTypeRef params) args) ++ ">"


-- ─── JSON decoding (validating) ──────────────────────────────────────


instance A.FromJSON ByKind where
    parseJSON = A.withText "by" $ \t -> case T.unpack t of
        "ref"    -> pure ByRef
        "refmut" -> pure ByRefMut
        "value"  -> pure ByValue
        other    -> fail ("unknown receiver `by` kind: " ++ show other
                          ++ " (expected \"ref\", \"refmut\", or \"value\")")


instance A.FromJSON Receiver where
    parseJSON = A.withObject "Receiver" $ \o -> do
        a  <- o .: "arg"
        by <- o .: "by"
        pure (Receiver a by)


instance A.FromJSON TypeRef where
    parseJSON = A.withObject "TypeRef" $ \o -> do
        mp <- o .:? "param"
        mq <- o .:? "prim"
        mc <- o .:? "ctor"
        case (mp, mq, mc) of
            (Just i, Nothing, Nothing) -> pure (TRParam i)
            (Nothing, Just p, Nothing) -> pure (TRPrim p)
            (Nothing, Nothing, Just nm) -> do
                args <- o .:? "args" .!= []
                pure (TRCtor nm args)
            _ -> fail "TypeRef must have exactly one of `param`, `prim`, or `ctor`"


-- | Decode + VALIDATE a 'Call'. The @nParams@ to validate against is read from
-- the SAME @generic@ object's @params@ list — so 'FfiGeneric' threads it in via
-- a parametrised decoder helper rather than a bare 'FromJSON' instance (a
-- standalone instance has no param count). Exposed so the drift corpus can
-- decode with an explicit count.
--
-- The @kind@ string ⇒ 'CallKind' is itself validated (unknown kind ⇒ fail),
-- closing guardian-4b's "unknown kind ⇒ reject".
parseCall :: Int -> A.Value -> AT.Parser Call
parseCall nParams = A.withObject "Call" $ \o -> do
    kindStr <- o .: "kind" :: AT.Parser String
    kind <- case kindStr of
        "method"   -> pure CallMethod
        "function" -> pure CallFunction
        other      -> fail ("unknown call kind: " ++ show other
                            ++ " (expected \"method\" or \"function\")")
    path     <- o .: "path"
    typeArgs <- o .:? "typeArgs" .!= []
    method   <- o .:? "method"
    receiver <- o .:? "receiver"
    args     <- o .:? "args" .!= []
    argTypes <- o .:? "argTypes" .!= []
    ret      <- o .: "ret"
    let c = Call
            { _call_kind     = kind
            , _call_path     = path
            , _call_typeArgs = typeArgs
            , _call_method   = method
            , _call_receiver = receiver
            , _call_args     = args
            , _call_argTypes = argTypes
            , _call_ret      = ret
            }
    case validateCall nParams c of
        Right ok -> pure ok
        Left err -> fail ("invalid generic FFI call-AST: " ++ err)
