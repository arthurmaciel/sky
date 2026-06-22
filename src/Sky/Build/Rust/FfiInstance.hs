-- | Wall #2 of the demand-driven generic Sky→Rust FFI epic, the (A)-model:
-- per-instance bindability checking + ONE generic Rust wrapper per generic
-- FFI function.
--
-- == Why the (A)-model ==
-- The Rust FFI call path has no call-site-rewrite seam: every instantiation of
-- a generic FFI fn resolves through @kernelToRust@ to the SAME base name
-- (@rust_box1_make@), and Rust monomorphises via rustc's own generics + type
-- inference. So instead of emitting N per-instance monomorphic wrappers (the
-- Go model), this module emits ONE @<T: bounds>@ generic wrapper under the
-- base name, and rustc specialises the unchanged call sites:
--
-- @
-- pub fn rust_box1_make<T: ::std::hash::Hash + ::std::cmp::Eq>(arg0: T)
--     -> SkyResult<SkyError, ::box1::Box1<T>>
-- { ok_res(::box1::Box1::<T>::make(arg0)) }
-- @
--
-- == Two independent responsibilities ==
--
--   1. BINDABILITY CHECK — PER USED INSTANTIATION (each reachable call
--      instance carrying concrete type-args). Proves the instantiation is
--      soundly mappable:
--        (a) every concrete type-arg lies in the closed Sky↔Rust set
--            (primitive / String / Vec<T> / Option<T> recursive);
--        (b) every type-param's declared trait bounds are satisfied by its
--            concrete arg, via a STATIC closed-set × trait table.
--      A violation is a first-class 'Sky.Reporting.Diagnostic' (E4400) keyed
--      on the call-site region — NEVER a silent codegen drop. This feeds ONLY
--      the build-fail gate; it does NOT drive wrapper naming or emission.
--
--   2. GENERIC-WRAPPER SYNTHESIS — PER GENERIC FFI FUNCTION (one wrapper). From
--      the stub's @"generic"@ block (params + per-param bounds + Rust
--      template) emit one @pub fn@ under the base @kernelToRust@ name with
--      @<T: bounds>@ rendered from the metadata. The bounds are load-bearing
--      (the body needs them) AND satisfied-by-construction (the per-instance
--      check already gated every reached instantiation).
--
-- == F1 — bound-completeness + the unmodellable-bound rule ==
-- The model is sound only if the recorded bounds for a fn are the UNION of
-- every trait bound the wrapper body depends on (the type's bounds AND the
-- method's own bounds AND anything @::crate::Type::<T>::method@ requires). The
-- bindability check and the rendered @<T: …>@ both derive from the SAME
-- @_fg_bounds@, so a missing bound is the fixture author's contract violation
-- (documented in the fixture), and a wrapper whose declared bound is NOT
-- modellable by the static @{Hash,Eq,Ord,Clone,Default}@ table (a crate-
-- specific trait like @Serialize@) is REJECTED with a first-class diagnostic
-- (E4400) — NEVER emit-and-hope a cargo-fail, and NEVER a silent skip (the
-- call site references the base name, so a skip is a downstream @E0425@).
--
-- == Go-safety ==
-- An 'FfiReg.FfiGeneric' is produced ONLY by a Rust-target parametric stub
-- (the Go inspector drops generics at the producer, so no Go kernel.json ever
-- carries a @generic@ object). Every entry point here filters on
-- @_ffn_generic = Just _@, so the whole module is dead for the Go path.
module Sky.Build.Rust.FfiInstance
    ( -- * inputs
      FfiInstance(..)
    , GenericFn(..)
      -- * per-instance bindability check
    , checkInstance
    , checkInstances
      -- * per-function generic-wrapper synthesis
    , WrapperResult(..)
    , synthesiseGenericWrapper
    , synthesiseGenericWrappers
      -- * exposed for unit tests
    , skyTypeToRustClosed
    , traitsOfRustType
    , traitToRustPath
    , modellableTrait
    ) where

import Data.List (intercalate)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set

import qualified Sky.AST.Canonical as Can
import qualified Sky.Build.FfiRegistry as FfiReg
import Sky.Generate.Rust.Builder.Naming (mangleTVar)
import qualified Sky.Reporting.Annotation as A
import qualified Sky.Reporting.Diagnostic as Diag


-- ─── inputs ──────────────────────────────────────────────────────────


-- | A single reachable generic FFI CALL INSTANCE, used ONLY to drive the
-- per-instance bindability check. Built by Compile.hs from the reachable
-- call-site instances joined with the FFI registry's generic blocks.
data FfiInstance = FfiInstance
    { _fi_callee  :: !String              -- ^ qualified Sky callee, e.g. "Rust.Box1.make"
    , _fi_types   :: ![Can.Type]          -- ^ concrete type-args, positional with @_fg_params@
    , _fi_region  :: !A.Region            -- ^ call-site region for diagnostics
    , _fi_file    :: !FilePath            -- ^ source file for diagnostics
    , _fi_generic :: !FfiReg.FfiGeneric   -- ^ template + per-param bounds
    }
    deriving (Show)


-- | A single generic FFI FUNCTION, used to synthesise ONE generic wrapper.
-- Built by Compile.hs from each FFI-registry function whose @_ffn_generic@ is
-- @Just@. The region/file are for the unmodellable-bound diagnostic (a stub
-- that declares a non-table trait is malformed); when no call site exists they
-- are a synthetic whole-file region.
data GenericFn = GenericFn
    { _gf_kernelName :: !String             -- ^ owning kernel name (S4 FfiRef key, e.g. "Rust_Box1")
    , _gf_baseName   :: !String             -- ^ base kernelToRust wrapper name (e.g. "rust_box1_make")
    , _gf_refName    :: !String             -- ^ S4 tree-shake ref name (kernel.json "name")
    , _gf_generic    :: !FfiReg.FfiGeneric  -- ^ params + bounds + template
    , _gf_region     :: !A.Region           -- ^ region for the unmodellable-bound diagnostic
    , _gf_file       :: !FilePath           -- ^ source file for that diagnostic
    }
    deriving (Show)


-- ─── per-instance bindability check ──────────────────────────────────


-- | Check every reachable generic FFI instance. Returns ALL diagnostics; the
-- caller fails the build when the list is non-empty (mirroring the auth-
-- boundary gate), BEFORE generating the Rust project.
checkInstances :: [FfiInstance] -> [Diag.Diagnostic]
checkInstances = concatMap checkInstance


-- | All bindability violations for one instance. The closed-set check runs
-- first (a non-mappable arg has no Rust type to even check bounds against),
-- then the per-param trait-bound check on the args that ARE closed.
checkInstance :: FfiInstance -> [Diag.Diagnostic]
checkInstance fi =
    let params = FfiReg._fg_params (_fi_generic fi)
        bounds = FfiReg._fg_bounds (_fi_generic fi)
        tys    = _fi_types fi
        -- Positional alignment: param[i] ↔ tys[i]. A length mismatch is a
        -- malformed stub (params/skyType disagree) — zip truncates to the
        -- shorter, never indexes out of range.
        paired = zip params tys
        closedErrs =
            [ mkClosedSetError fi pname ty
            | (pname, ty) <- paired
            , Left _ <- [skyTypeToRustClosed ty]
            ]
        -- Trait-bound check only on args that ARE closed (a non-closed arg
        -- already produced a closed-set error; don't double-report).
        boundErrs =
            [ err
            | (pname, ty) <- paired
            , Right rustTy <- [skyTypeToRustClosed ty]
            , trait <- Map.findWithDefault [] pname bounds
            , err <- traitBoundErrors fi pname ty rustTy trait
            ]
    in closedErrs ++ boundErrs


-- | A declared bound on a closed Rust type yields a diagnostic when EITHER the
-- trait is not modellable by the static table (an unmodellable bound on a
-- reached generic fn — F1: never silent-skip, it would be a downstream E0425),
-- OR the trait is modellable but the concrete Rust type does not satisfy it.
traitBoundErrors :: FfiInstance -> String -> Can.Type -> String -> String -> [Diag.Diagnostic]
traitBoundErrors fi pname ty rustTy trait
    | not (modellableTrait trait) = [ mkUnmodellableBoundError fi pname trait ]
    | not (rustTypeHasTrait rustTy trait) = [ mkTraitBoundError fi pname ty rustTy trait ]
    | otherwise = []


mkClosedSetError :: FfiInstance -> String -> Can.Type -> Diag.Diagnostic
mkClosedSetError fi pname ty =
    let tyStr = renderSkyType ty
        msg = "This generic FFI call instantiates type parameter `" ++ pname
            ++ "` at `" ++ tyStr ++ "`, which is outside the Sky↔Rust "
            ++ "bindable type set. A generic FFI type-arg must be a "
            ++ "primitive (Int / Float / Bool / Char / String), a "
            ++ "`List` of one, or a `Maybe` of one."
    in Diag.withHint
        ("Use a primitive, `List`, or `Maybe` of a bindable type for `"
            ++ pname ++ "`, or bind a non-generic FFI wrapper for `"
            ++ tyStr ++ "`.")
        (Diag.mkError (_fi_file fi) (_fi_region fi)
            Diag.CatCodegen Diag.ffiE_GenericNotBindable msg)


mkTraitBoundError :: FfiInstance -> String -> Can.Type -> String -> String -> Diag.Diagnostic
mkTraitBoundError fi pname ty rustTy trait =
    let tyStr = renderSkyType ty
        msg = "This generic FFI call instantiates type parameter `" ++ pname
            ++ "` at `" ++ tyStr ++ "` (Rust `" ++ rustTy ++ "`), but the FFI "
            ++ "binding requires `" ++ pname ++ "` to satisfy the Rust trait "
            ++ "bound `" ++ trait ++ "`. `" ++ rustTy ++ "` does not implement `"
            ++ trait ++ "`."
        hint = case trait of
            "Hash" -> "Use Int, String, Bool, or Char (hashable types) — "
                   ++ "Float is not hashable in Rust."
            "Eq"   -> "Use Int, String, Bool, or Char — "
                   ++ "Float does not implement Eq in Rust."
            "Ord"  -> "Use Int, String, Bool, or Char — "
                   ++ "Float does not implement Ord in Rust."
            _      -> "Use a type whose Rust mapping implements `" ++ trait ++ "`."
    in Diag.withHint hint
        (Diag.mkError (_fi_file fi) (_fi_region fi)
            Diag.CatCodegen Diag.ffiE_GenericNotBindable msg)


-- | A bound the static @{Hash,Eq,Ord,Clone,Default}@ table cannot model (a
-- crate-specific trait like @Serialize@). The backend cannot prove the bound
-- holds for an arbitrary closed type, so it refuses to emit the wrapper. The
-- message names the BOUND, not the concrete type (the type might well satisfy
-- it — `String` is `Serialize` — so a per-instance "String lacks Serialize"
-- would be misleading; the real cause is the backend's modelling limit).
mkUnmodellableBoundError :: FfiInstance -> String -> String -> Diag.Diagnostic
mkUnmodellableBoundError fi pname trait =
    let msg = "The generic FFI binding `" ++ _fi_callee fi ++ "` declares the "
            ++ "Rust trait bound `" ++ trait ++ "` on type parameter `" ++ pname
            ++ "`, but the Sky→Rust backend can only model the bounds "
            ++ "{Hash, Eq, Ord, Clone, Default}. It cannot prove `" ++ trait
            ++ "` holds for an arbitrary bindable type, so it will not emit an "
            ++ "unsound generic wrapper."
    in Diag.withHint
        ("Drop the `" ++ trait ++ "` bound, or bind a non-generic FFI "
            ++ "wrapper at the concrete type(s) you need.")
        (Diag.mkError (_fi_file fi) (_fi_region fi)
            Diag.CatCodegen Diag.ffiE_GenericNotBindable msg)


-- ─── closed set: Sky type → Rust type ────────────────────────────────


-- | Map a Sky 'Can.Type' to the Rust type used in a generic FFI
-- instantiation, restricted to the CLOSED bindable set:
--
--   * primitives: Int→i64, Float→f64, Bool→bool, Char→char, String→String
--   * @List a@   → @Vec<a'>@      (recursive — element must be closed)
--   * @Maybe a@  → @SkyMaybe<a'>@ (recursive — element must be closed)
--   * @()@       → @()@
--
-- Anything else (records, tuples, functions, opaque foreign types, bare
-- TVars that survived monomorphisation) is @Left <reason>@ — outside the
-- closed set, so synthesis would be unsound.
--
-- NOTE: a residual @TVar@ here means Sky's monomorphiser did NOT specialise a
-- real use to a concrete type — the conservative sound behaviour is a Left
-- (a closed-set diagnostic), NEVER a @Box<dyn Any>@ / boxed fallback (F2).
-- Opaque @Clone@-deriving foreign types are admissible in principle but
-- require the inspector's derive-scan metadata (Wall #3); admitting one on
-- faith would be unsound, so they are rejected here (the conservative default).
skyTypeToRustClosed :: Can.Type -> Either String String
skyTypeToRustClosed ty = case ty of
    Can.TType _ "Int" []    -> Right "i64"
    Can.TType _ "Float" []  -> Right "f64"
    Can.TType _ "Bool" []   -> Right "bool"
    Can.TType _ "Char" []   -> Right "char"
    Can.TType _ "String" [] -> Right "String"
    Can.TType _ "List" [el] ->
        case skyTypeToRustClosed el of
            Right r -> Right ("Vec<" ++ r ++ ">")
            Left e  -> Left e
    Can.TType _ "Maybe" [el] ->
        case skyTypeToRustClosed el of
            Right r -> Right ("SkyMaybe<" ++ r ++ ">")
            Left e  -> Left e
    Can.TUnit -> Right "()"
    Can.TVar n -> Left ("unresolved type variable `" ++ n ++ "`")
    Can.TType _ n _ -> Left ("non-closed type constructor `" ++ n ++ "`")
    Can.TRecord{} -> Left "record type"
    Can.TTuple{}  -> Left "tuple type"
    Can.TLambda{} -> Left "function type"
    Can.TAlias _ n _ _ -> Left ("type alias `" ++ n ++ "`")


-- ─── static trait table ──────────────────────────────────────────────


-- | The bounds the backend can statically model. A declared bound outside
-- this set is rejected (F1: never emit-and-hope a crate-specific trait).
modellableTrait :: String -> Bool
modellableTrait t = t `elem` ["Hash", "Eq", "Ord", "Clone", "Default"]


-- | Does the (already-closed) Rust type satisfy the named MODELLABLE trait?
rustTypeHasTrait :: String -> String -> Bool
rustTypeHasTrait rustTy trait = Set.member trait (traitsOfRustType rustTy)


-- | The set of @{Hash, Eq, Ord, Clone, Default}@ traits a closed Rust type
-- satisfies. Exposed for unit tests.
--
-- Cells (F3 — each verified against the runtime + std):
--
--   * i64 / String / bool / char / () : Hash + Eq + Ord + Clone + Default
--   * f64 / f32 : Clone + Default only — NOT Hash/Eq/Ord (IEEE-754: no total
--     order, no Eq in Rust). The security-critical cell.
--   * @Vec<T>@ (std)   : Clone IFF T:Clone; Default ALWAYS (empty vec);
--                        Hash/Eq/Ord IFF T has them.
--   * @SkyMaybe<T>@    : our runtime enum (core.rs:134) derives
--                        @Clone, PartialEq, Serialize, Deserialize@ ONLY —
--                        NO @Default@, NO @Hash@, NO @Eq@ (PartialEq ≠ Eq),
--                        NO @Ord@. So: Clone IFF T:Clone; nothing else.
--                        (Differs from std @Option<T>@ — do NOT assume std.)
--
-- An unrecognised trait name conservatively returns False (handled upstream by
-- 'modellableTrait', which rejects unmodellable bounds before this is asked).
traitsOfRustType :: String -> Set.Set String
traitsOfRustType rustTy = case rustTy of
    "i64"    -> fullEq
    "String" -> fullEq
    "bool"   -> fullEq
    "char"   -> fullEq
    "()"     -> fullEq
    "f64"    -> floatSet
    "f32"    -> floatSet
    _ | Just inner <- stripWrap "Vec<" rustTy      -> vecTraits inner
      | Just inner <- stripWrap "SkyMaybe<" rustTy -> skyMaybeTraits inner
      | otherwise -> Set.empty
  where
    -- Primitive integers / strings / bools / chars: total order, Eq, Hash.
    fullEq = Set.fromList ["Hash", "Eq", "Ord", "Clone", "Default"]
    -- Floats: Clone + Default, but NOT Hash/Eq/Ord.
    floatSet = Set.fromList ["Clone", "Default"]
    -- std @Vec<T>@: Default always (empty vec); Clone IFF T:Clone; Hash/Eq/Ord
    -- IFF T has them.
    vecTraits inner =
        let it = traitsOfRustType inner
            conditional = Set.intersection it
                            (Set.fromList ["Hash", "Eq", "Ord", "Clone"])
        in Set.insert "Default" conditional
    -- runtime @SkyMaybe<T>@: Clone IFF T:Clone; nothing else (no Default/Hash/
    -- Eq/Ord derive on the enum).
    skyMaybeTraits inner =
        Set.intersection (traitsOfRustType inner) (Set.singleton "Clone")


-- | Map a modellable trait name to its fully-qualified Rust path, for the
-- @<T: …>@ bound rendering in the generic wrapper signature.
traitToRustPath :: String -> Maybe String
traitToRustPath t = case t of
    "Hash"    -> Just "::std::hash::Hash"
    "Eq"      -> Just "::std::cmp::Eq"
    "Ord"     -> Just "::std::cmp::Ord"
    "Clone"   -> Just "::core::clone::Clone"
    "Default" -> Just "::core::default::Default"
    _         -> Nothing


-- | Strip a @Wrapper<…>@ prefix/suffix, returning the inner type string.
stripWrap :: String -> String -> Maybe String
stripWrap pfx s =
    case stripPrefixStr pfx s of
        Just rest | not (null rest) && last rest == '>' -> Just (init rest)
        _ -> Nothing
  where
    stripPrefixStr [] ys = Just ys
    stripPrefixStr (x:xs) (y:ys) | x == y = stripPrefixStr xs ys
    stripPrefixStr _ _ = Nothing


-- ─── per-function generic-wrapper synthesis ──────────────────────────


-- | Outcome of synthesising one generic FFI function's wrapper.
data WrapperResult
    = WrapperOk !String !String !String  -- ^ (kernel name, ref name, synthesised @pub fn@ source)
    | WrapperRejected !Diag.Diagnostic   -- ^ unmodellable bound / malformed stub
    deriving (Show)


-- | Synthesise wrappers for every generic FFI function; collect the emitted
-- sources (keyed by @(kernelName, refName)@ for the S4 tree-shake's
-- @FfiRef kernelName refName@) and any rejection diagnostics separately.
synthesiseGenericWrappers :: [GenericFn] -> ([(String, String, String)], [Diag.Diagnostic])
synthesiseGenericWrappers fns =
    let results = map synthesiseGenericWrapper fns
        oks  = [ (kn, r, src) | WrapperOk kn r src <- results ]
        bad  = [ d | WrapperRejected d <- results ]
    in (oks, bad)


-- | Synthesise ONE generic wrapper. Emits
--
-- @
-- pub fn <base><T: bound + …>(arg0: <argTy0>, …) -> SkyResult<SkyError, <Ret>> {
--     ok_res(<body>)
-- }
-- @
--
-- where:
--
--   * @<T: …>@ joins the per-param bounds (from @_fg_bounds@) rendered via
--     'traitToRustPath'. A param with no bound emits a bare @T@.
--   * @<Ret>@ is the template's leading @// ret: <type>@ marker, with @{param}@
--     holes kept as the generic param names (so @::box1::Box1<{T}>@ →
--     @::box1::Box1<T>@).
--   * @<body>@ is the template (sans the @// ret:@ line) with @{param}@ →
--     param name and @{argJ}@ → @argJ@.
--   * @<argTyJ>@ — the wrapper's value-arg types — are the J-th type-param
--     name for the hand-stub's @make : a -> Box1 a@ shape (arity == #params).
--
-- Rejections (return 'WrapperRejected'):
--   * a declared bound is not modellable (F1 — never emit-and-hope);
--   * the template has no @// ret:@ marker (can't emit a valid @-> <Ret>@).
synthesiseGenericWrapper :: GenericFn -> WrapperResult
synthesiseGenericWrapper gf =
    let gen      = _gf_generic gf
        params   = FfiReg._fg_params gen
        bounds   = FfiReg._fg_bounds gen
        template = FfiReg._fg_template gen
        -- F1: any declared bound outside the modellable table → reject.
        unmodellable =
            [ (p, t)
            | p <- params
            , t <- Map.findWithDefault [] p bounds
            , not (modellableTrait t) ]
        markers   = leadingMarkers template
        body      = stripLeadingMarkers template
        -- Every `{...}` hole anywhere in the template (markers' values + body).
        allHoles  = collectHoles template
        -- Holes split into `argN` value-holes (carrying their index) and
        -- everything else (which MUST be a declared type-param `{p}`).
        argIdxs   = [ j | h <- allHoles, Just j <- [argHoleIndex h] ]
        nonArg    = [ h | h <- allHoles, argHoleIndex h == Nothing ]
        -- The wrapper's VALUE-arg count: one past the max `{argJ}` index, so
        -- the param list always covers every referenced hole (densely — the
        -- coverage gate below rejects a gap, so this can't undercount).
        arity     = if null argIdxs then 0 else maximum argIdxs + 1
        -- COVERAGE (guardian): prove every hole is substitutable BEFORE
        -- emitting, so a malformed template can never leak an un-substituted
        -- `{…}` into the Rust (which would be a cargo-fail with no Sky
        -- diagnostic — the exact failure mode this epic eliminates). Two ways
        -- a hole is unsubstitutable: a NON-arg hole that isn't a declared
        -- type-param, OR a GAP in the arg indices (`{arg0}` + `{arg2}` skips
        -- `{arg1}`, so `arg1` would never be a wrapper param).
        unknownParamHoles = [ h | h <- nub' nonArg, h `notElem` params ]
        argGaps = [ j | j <- [0 .. arity - 1], j `notElem` argIdxs ]
    in case unmodellable of
        ((p, t) : _) -> WrapperRejected (mkUnmodellableFnError gf p t)
        [] | (h : _) <- unknownParamHoles ->
               WrapperRejected (mkUnknownHoleError gf h)
           | (j : _) <- argGaps ->
               WrapperRejected (mkArgGapError gf j)
        _ -> case lookup "ret" markers of
            Nothing -> WrapperRejected (mkMissingRetError gf)
            Just retTy ->
                let -- σ_type: {param} → the UpperCamelCase Rust generic name
                    -- (`a` → `A`); Sky type-var names are lowercase-leading and
                    -- would trip `non_camel_case_types`. Applied IDENTICALLY at
                    -- the decl, bounds, arg types, ret, and body `::<…>` so the
                    -- one mangled name is referenced consistently.
                    typeSubst = [ ("{" ++ p ++ "}", mangleTVar p) | p <- params ]
                    argSubst  = [ ("{arg" ++ show j ++ "}", "arg" ++ show j)
                                | j <- [0 .. arity - 1] ]
                    bodyR  = applySubsts (typeSubst ++ argSubst) body
                    retR   = applySubsts typeSubst retTy
                    -- <T: bound + …> per param; bare param when unbounded.
                    paramDecls =
                        [ case mapMaybe traitToRustPath
                                  (Map.findWithDefault [] p bounds) of
                            []    -> mangleTVar p
                            paths -> mangleTVar p ++ ": " ++ intercalate " + " paths
                        | p <- params ]
                    generics
                        | null paramDecls = ""
                        | otherwise = "<" ++ intercalate ", " paramDecls ++ ">"
                    -- Wrapper value-arg J's Rust type: an explicit `// argJ:`
                    -- marker when present (needed whenever the arg is NOT a
                    -- bare type-param — e.g. `get : Box1 a -> a` whose arg is
                    -- the foreign `::box1::Box1<a>`, `keyedCount : Keyed a ->
                    -- Int` whose arg is `::box1::Keyed<a>`). Absent → the
                    -- J-th type-param (the `make : a -> Box1 a` shape, arg ==
                    -- param). `{param}` holes in the marker resolve to the
                    -- param name. This keeps every parametric-foreign arg type
                    -- CONCRETE (F2) with the crate path author-supplied (same
                    -- contract as `// ret:`).
                    valArgTypes =
                        [ case lookup ("arg" ++ show j) markers of
                            Just m  -> applySubsts typeSubst m
                            Nothing -> case drop j params of
                                (p : _) -> mangleTVar p
                                []      -> "String"  -- defensive; never hit
                        | j <- [0 .. arity - 1] ]
                    paramDecl
                        | arity == 0 = "_: ()"
                        | otherwise  = intercalate ", "
                            [ "arg" ++ show j ++ ": " ++ t
                            | (j, t) <- zip [0 :: Int ..] valArgTypes ]
                    src = unlines
                        [ "// [ffi-generic] " ++ _gf_baseName gf
                            ++ " <" ++ intercalate ", " params ++ ">"
                        , "pub fn " ++ _gf_baseName gf ++ generics
                            ++ "(" ++ paramDecl ++ ") -> SkyResult<SkyError, "
                            ++ retR ++ "> {"
                        , "    ok_res(" ++ bodyR ++ ")"
                        , "}"
                        ]
                in WrapperOk (_gf_kernelName gf) (_gf_refName gf) src


mkUnmodellableFnError :: GenericFn -> String -> String -> Diag.Diagnostic
mkUnmodellableFnError gf pname trait =
    let msg = "The generic FFI binding `" ++ _gf_baseName gf ++ "` declares the "
            ++ "Rust trait bound `" ++ trait ++ "` on type parameter `" ++ pname
            ++ "`, but the Sky→Rust backend can only model the bounds "
            ++ "{Hash, Eq, Ord, Clone, Default}. It will not emit an unsound "
            ++ "generic wrapper for an un-modellable bound."
    in Diag.withHint
        ("Drop the `" ++ trait ++ "` bound from the stub, or bind a non-"
            ++ "generic FFI wrapper at the concrete type(s) you need.")
        (Diag.mkError (_gf_file gf) (_gf_region gf)
            Diag.CatCodegen Diag.ffiE_GenericNotBindable msg)


mkMissingRetError :: GenericFn -> Diag.Diagnostic
mkMissingRetError gf =
    Diag.withHint
        ("Add a leading `// ret: <RustType>` line to the `rustTemplate` for `"
            ++ _gf_baseName gf ++ "` in its kernel.json.")
        (Diag.mkError (_gf_file gf) (_gf_region gf)
            Diag.CatCodegen Diag.ffiE_GenericNotBindable
            ("The generic FFI binding `" ++ _gf_baseName gf
                ++ "` is missing a `// ret:` return-type marker in its Rust "
                ++ "template; cannot synthesise a concrete wrapper."))


-- | A @{hole}@ in the template that is neither an @argN@ value-hole nor a
-- declared type-param — it would leak un-substituted into the emitted Rust
-- (a cargo-fail with no Sky diagnostic), so the wrapper is rejected instead.
mkUnknownHoleError :: GenericFn -> String -> Diag.Diagnostic
mkUnknownHoleError gf hole =
    Diag.withHint
        ("Use `{argN}` for value args and `{<param>}` only for a type "
            ++ "parameter declared in the `generic.params` list.")
        (Diag.mkError (_gf_file gf) (_gf_region gf)
            Diag.CatCodegen Diag.ffiE_GenericNotBindable
            ("The generic FFI binding `" ++ _gf_baseName gf
                ++ "`'s Rust template references an unknown hole `{" ++ hole
                ++ "}` that is neither a value arg (`{argN}`) nor a declared "
                ++ "type parameter; cannot synthesise a sound wrapper."))


-- | A gap in the @{argN}@ value-hole indices (e.g. @{arg0}@ + @{arg2}@ with no
-- @{arg1}@) — the missing index would never become a wrapper parameter, so a
-- referenced @{argN}@ could leak. Rejected.
mkArgGapError :: GenericFn -> Int -> Diag.Diagnostic
mkArgGapError gf j =
    Diag.withHint
        "Use contiguous value-arg holes `{arg0}`, `{arg1}`, … with no gaps."
        (Diag.mkError (_gf_file gf) (_gf_region gf)
            Diag.CatCodegen Diag.ffiE_GenericNotBindable
            ("The generic FFI binding `" ++ _gf_baseName gf
                ++ "`'s Rust template skips value-arg `{arg" ++ show j
                ++ "}`; value-arg holes must be contiguous from `{arg0}`."))


-- ─── template helpers ────────────────────────────────────────────────


-- | Parse the CONTIGUOUS leading @// key: value@ marker lines off a template
-- into @(key, value)@ pairs (value @{param}@ holes intact). A key is one of
-- @ret@ / @arg0@ / @arg1@ / … (the keys this synthesiser consults); any other
-- leading @//@ comment that isn't a @key: value@ marker stops the scan and is
-- treated as body. Parsing stops at the first non-marker line.
leadingMarkers :: String -> [(String, String)]
leadingMarkers tmpl = go (lines tmpl)
  where
    go (l : ls) = case parseMarker l of
        Just kv -> kv : go ls
        Nothing -> []
    go [] = []


-- | Drop the contiguous leading @// key: value@ marker lines, returning the
-- remaining body. Mirrors 'leadingMarkers' so consumed lines never leak into
-- the emitted body.
stripLeadingMarkers :: String -> String
stripLeadingMarkers tmpl = intercalate "\n" (dropWhile isMarker (lines tmpl))
  where
    isMarker l = case parseMarker l of
        Just _  -> True
        Nothing -> False


-- | Parse a single @// <key>: <value>@ line. The key must match @ret@ or
-- @argN@ (a deliberate allow-list so an ordinary @// comment@ inside the body
-- isn't mistaken for a marker). Returns @Nothing@ for any non-marker line.
parseMarker :: String -> Maybe (String, String)
parseMarker line0 =
    let s = dropWhile (== ' ') line0
    in case stripPfx "// " s of
        Just rest ->
            case break (== ':') rest of
                (key, ':' : ' ' : val)
                    | isMarkerKey key -> Just (key, trim val)
                _ -> Nothing
        Nothing -> Nothing
  where
    isMarkerKey "ret" = True
    isMarkerKey ('a':'r':'g':ds) = not (null ds) && all (`elem` ("0123456789" :: String)) ds
    isMarkerKey _ = False
    stripPfx [] ys = Just ys
    stripPfx (x:xs) (y:ys) | x == y = stripPfx xs ys
    stripPfx _ _ = Nothing
    trim = f . f where f = reverse . dropWhile (== ' ')


-- | Collect EVERY @{...}@ hole name in a string (the text between a @{@ and the
-- next @}@), in order of appearance. Used to prove every hole is substitutable
-- before emission (a leaked hole would be a cargo-fail with no Sky diagnostic).
collectHoles :: String -> [String]
collectHoles [] = []
collectHoles ('{' : rest) =
    case break (== '}') rest of
        (name, '}' : after) -> name : collectHoles after
        (_, [])             -> []   -- unterminated `{` → no further holes
collectHoles (_ : rest) = collectHoles rest


-- | If a hole name is @argN@ (N a run of digits), its index; else Nothing.
argHoleIndex :: String -> Maybe Int
argHoleIndex ('a':'r':'g':ds)
    | not (null ds) && all (`elem` ("0123456789" :: String)) ds = Just (read ds)
argHoleIndex _ = Nothing


-- | Order-preserving dedupe (avoids a Data.List import for nub).
nub' :: Eq a => [a] -> [a]
nub' = go []
  where
    go _ [] = []
    go seen (x:xs)
        | x `elem` seen = go seen xs
        | otherwise     = x : go (x : seen) xs


-- | Apply a list of literal find→replace substitutions left-to-right. Holes
-- are unique (@{a}@, @{arg0}@) and a replacement never reintroduces a hole, so
-- order between distinct holes is irrelevant.
applySubsts :: [(String, String)] -> String -> String
applySubsts subs s0 = foldl (\acc (from, to) -> replaceAll from to acc) s0 subs


-- | Replace every non-overlapping occurrence of @from@ with @to@.
replaceAll :: String -> String -> String -> String
replaceAll _ _ [] = []
replaceAll from to s@(c:cs)
    | from `isPrefixOfStr` s = to ++ replaceAll from to (drop (length from) s)
    | otherwise              = c : replaceAll from to cs
  where
    isPrefixOfStr [] _ = True
    isPrefixOfStr _ [] = False
    isPrefixOfStr (x:xs) (y:ys) = x == y && isPrefixOfStr xs ys


-- | 'Data.Maybe.mapMaybe' inlined to avoid an extra import.
mapMaybe :: (a -> Maybe b) -> [a] -> [b]
mapMaybe f = foldr (\x acc -> maybe acc (: acc) (f x)) []


-- | Render a 'Can.Type' as a Sky-source-shaped string for diagnostic
-- messages. Covers the closed set + a generic fallback for the rest.
renderSkyType :: Can.Type -> String
renderSkyType ty = case ty of
    Can.TType _ n [] -> n
    Can.TType _ "List" [el]  -> "List " ++ parenIf el
    Can.TType _ "Maybe" [el] -> "Maybe " ++ parenIf el
    Can.TType _ n args -> n ++ " " ++ unwords (map parenIf args)
    Can.TVar n -> n
    Can.TUnit -> "()"
    Can.TRecord{} -> "{ … }"
    Can.TTuple a b cs -> "(" ++ intercalate ", " (map renderSkyType (a:b:cs)) ++ ")"
    Can.TLambda{} -> "<function>"
    Can.TAlias _ n _ _ -> n
  where
    parenIf t = case t of
        Can.TType _ _ (_:_) -> "(" ++ renderSkyType t ++ ")"
        _                   -> renderSkyType t
