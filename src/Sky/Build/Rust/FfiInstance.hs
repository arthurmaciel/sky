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
      -- * Phase 2: closure-capture Clone allowlist (#28)
    , rustTypeIsClone
    , skyCaptureIsClone
    , mkCaptureNotCloneError
      -- * Phase 3: drop + report unsound closure shapes (#28)
    , closureDropReason
    ) where

import Data.List (intercalate)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set

import qualified Sky.AST.Canonical as Can
import qualified Sky.Build.FfiRegistry as FfiReg
import Sky.Build.Rust.FfiCall
    ( callArity, renderArgType, renderArgTypeAt, renderCall, renderRetType
    , closureBounds, renderTypeRef
    , Call, TypeRef(..), ClosureKind(..)
    , _call_argTypes
    )
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


-- ─── Phase 2: closure-capture Clone allowlist (#28) ──────────────────


-- | A capture is admissible into a multi-call Fn/FnMut slot ONLY when its
-- monomorphised Rust type is positively Clone (guardian B5: never a denylist).
-- Built on the SAME closed-set machinery as the bound check, so a capture type
-- that is not even in the closed set is rejected here too (Left → not Clone).
rustTypeIsClone :: String -> Bool
rustTypeIsClone rustTy = rustTypeHasTrait rustTy "Clone"


-- | Returns 'True' iff the Sky type maps to a closed Rust type that is
-- positively Clone. A type outside the closed set (records, functions, bare
-- TVars, opaque foreign types) is conservatively rejected — the backend cannot
-- prove Clone holds on faith (F2: never admit-and-hope).
skyCaptureIsClone :: Can.Type -> Bool
skyCaptureIsClone ty = case skyTypeToRustClosed ty of
    Right rustTy -> rustTypeIsClone rustTy
    Left _       -> False


-- | E4400: a Sky lambda captures a non-Clone value into a multi-call (Fn/FnMut)
-- FFI closure slot, which Rust requires to be @Fn + Clone@. First-class Sky
-- diagnostic at the call site — never a cargo-fail.
--
-- The message names the captured variable and its Sky type; the hint explains
-- the two escape routes (use a Clone-able type, or restructure for FnOnce).
mkCaptureNotCloneError
    :: A.Region   -- ^ call-site region
    -> FilePath   -- ^ source file
    -> String     -- ^ name of the captured variable
    -> String     -- ^ Sky type of the capture (rendered as a string)
    -> Diag.Diagnostic
mkCaptureNotCloneError region file captureName captureTy =
    let msg = "Capture `" ++ captureName ++ "` of type `" ++ captureTy
            ++ "` is passed into a multi-call closure that Rust requires to be "
            ++ "`Fn + Clone`, but `" ++ captureTy ++ "` is not Clone and must be Clone "
            ++ "for the closure to be called more than once."
    in Diag.withHint
        ("Use a Clone-able captured value, or restructure so the closure "
            ++ "captures nothing (or pass it to a single-call FnOnce slot).")
        (Diag.mkError file region Diag.CatCodegen Diag.ffiE_GenericNotBindable msg)


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
    | WrapperDropped !String !String     -- ^ (ref name, drop reason) — an UNSOUND
                                          --   closure shape (Task 3.3): silently NOT
                                          --   bound, reason recorded for coverage. NOT a
                                          --   hard cargo-fail (the call site is itself
                                          --   tree-shaken away — see 'closureDropReason').
    deriving (Show)


-- | Synthesise wrappers for every generic FFI function; collect the emitted
-- sources (keyed by @(kernelName, refName)@ for the S4 tree-shake's
-- @FfiRef kernelName refName@) and any rejection diagnostics separately. A
-- 'WrapperDropped' (an unsound closure shape per 'closureDropReason') is
-- neither emitted nor a hard reject — it is silently dropped (its reason is
-- recorded on the constructor for coverage tooling).
synthesiseGenericWrappers :: [GenericFn] -> ([(String, String, String)], [Diag.Diagnostic])
synthesiseGenericWrappers fns =
    let results = map synthesiseGenericWrapper fns
        oks  = [ (kn, r, src) | WrapperOk kn r src <- results ]
        bad  = [ d | WrapperRejected d <- results ]
    in (oks, bad)


-- | Synthesise ONE generic wrapper from the Scheme-A typed call-AST. Emits
--
-- @
-- pub fn <base><T: bound + …>(arg0: <argTy0>, …) -> SkyResult<SkyError, <Ret>> {
--     ok_res(<body>)
-- }
-- @
--
-- where, walking the validated 'FfiCall.Call':
--
--   * @<T: …>@ joins the per-param bounds (from @_fg_bounds@) rendered via
--     'traitToRustPath'. A param with no bound emits a bare @T@.
--   * @<Ret>@ is 'FfiCall.renderRetType' over the call's @ret@ TypeRef, with
--     @{param:i}@ refs rendered as the mangled generic name (@a → A@).
--   * @<body>@ is 'FfiCall.renderCall' — path + turbofish type-args + receiver
--     (borrow-formed) + value-args. No string substitution: the AST IS the
--     structure, so there is no hole to leak (the retired @{hole}@ failure
--     mode is unrepresentable, and the parse-time 'FfiCall.validateCall'
--     already proved every ref is in range + gap-free).
--   * @<argTyJ>@ — the wrapper's value-arg Rust types — are taken from the
--     per-param @_fg_argTypes@ marker family rendered the same way; absent →
--     the J-th type-param (the @make : a -> Box1 a@ shape, arg == param).
--
-- The ONLY remaining rejection is F1: a declared bound outside the modellable
-- @{Hash,Eq,Ord,Clone,Default}@ table (never emit-and-hope a crate trait). The
-- template-marker rejections (@// ret:@ missing, unknown @{hole}@, arg-index
-- gap) are GONE — the typed AST + its parse-time validity replace them.
synthesiseGenericWrapper :: GenericFn -> WrapperResult
synthesiseGenericWrapper gf =
    let gen    = _gf_generic gf
        params = FfiReg._fg_params gen
        bounds = FfiReg._fg_bounds gen
        call   = FfiReg._fg_call gen
        -- Task 3.3: an UNSOUND closure shape (mut-slot / ho-return / by-ref
        -- non-Clone) is DROPPED, not bound — a silent drop with a recorded
        -- reason, never a hard cargo-fail. Checked FIRST: an unsound closure
        -- isn't worth a bound-modellability pass.
        dropReasons =
            [ reason
            | tr <- _call_argTypes call
            , Just reason <- [closureDropReason tr] ]
        -- F1: any declared bound outside the modellable table → reject.
        unmodellable =
            [ (p, t)
            | p <- params
            , t <- Map.findWithDefault [] p bounds
            , not (modellableTrait t) ]
    in case (dropReasons, unmodellable) of
        (reason : _, _) -> WrapperDropped (_gf_refName gf) reason
        (_, (p, t) : _) -> WrapperRejected (mkUnmodellableFnError gf p t)
        ([], []) ->
            let -- The wrapper's value-arg count, derived from the call's
                -- receiver + value-arg refs (validated gap-free at parse).
                arity = callArity call
                -- <Ret> and <body> walked from the validated AST. mangleTVar
                -- (`a → A`) is applied INSIDE renderCall/renderRetType so the
                -- one mangled name matches the <A: …> decl below.
                retR  = renderRetType call params
                bodyR = renderCall call params
                -- <T: bound + …> per param; bare param when unbounded.
                paramDecls =
                    [ case mapMaybe traitToRustPath
                              (Map.findWithDefault [] p bounds) of
                        []    -> mangleTVar p
                        paths -> mangleTVar p ++ ": " ++ intercalate " + " paths
                    | p <- params ]
                -- Closure args (B1): each closure-typed wrapper arg introduces a
                -- fresh `Fj: Fn(..) -> R [+ Clone]` type-param. Splice those bounds
                -- into the `<…>` clause AFTER the named generic params so the
                -- closure param's Rust type (`Fj`, emitted by 'renderArgTypeAt')
                -- has a matching bound. `params` is the REAL declared param list
                -- (so the closure's own arg/ret TypeRefs render correctly — C-A).
                closureDecls = closureBounds call params
                allDecls = paramDecls ++ closureDecls
                generics
                    | null allDecls = ""
                    | otherwise = "<" ++ intercalate ", " allDecls ++ ">"
                -- Wrapper value-arg J's Rust type, walked from the per-arg
                -- TypeRef in the call's argTypes (a parametric-foreign arg such
                -- as `::box1::Box1<A>` for `get`, the bare type-param `A` for
                -- `make`, or `Fj` for a closure arg). Renders to a CONCRETE Rust
                -- type (F2) — 'renderArgTypeAt' maps a 'TRClosure' to `Fj`.
                valArgTypes =
                    [ renderArgTypeAt params j tr
                    | (j, tr) <- zip [0 :: Int ..] (_call_argTypes call) ]
                paramDecl
                    | arity == 0 = "_: ()"
                    | otherwise  = intercalate ", "
                        [ "arg" ++ show j ++ ": " ++ t
                        | (j, t) <- zip [0 :: Int ..] valArgTypes ]
                -- B2: the wrapper BODY. When any wrapper arg is a Sky closure, a
                -- panic INSIDE the host call most likely originated in the Sky
                -- closure the host invoked. Catch it at this FFI boundary and map
                -- it to a typed `Err` instead of unwinding across the boundary
                -- (UB-adjacent on a `panic = "abort"` profile, and never the
                -- product's "no panic from well-typed Sky" contract). The total
                -- match has no `.unwrap()` / index / `panic!` — it is the
                -- sanctioned no-panic shape. A closure-free wrapper keeps the
                -- plain `ok_res(<body>)` form (byte-identical to pre-Phase-3).
                body
                    | callHasClosureArg call =
                        [ "    match ::std::panic::catch_unwind("
                            ++ "::std::panic::AssertUnwindSafe(|| {"
                        , "        " ++ bodyR
                        , "    })) {"
                        , "        Ok(__v)  => ok_res(__v),"
                        , "        Err(_)   => SkyResult::Err(str_err::<SkyError>("
                            ++ "\"a Sky closure passed to FFI panicked\")),"
                        , "    }"
                        ]
                    | otherwise = [ "    ok_res(" ++ bodyR ++ ")" ]
                src = unlines $
                    [ "// [ffi-generic] " ++ _gf_baseName gf
                        ++ " <" ++ intercalate ", " params ++ ">"
                    , "pub fn " ++ _gf_baseName gf ++ generics
                        ++ "(" ++ paramDecl ++ ") -> SkyResult<SkyError, "
                        ++ retR ++ "> {"
                    ] ++ body ++
                    [ "}" ]
            in WrapperOk (_gf_kernelName gf) (_gf_refName gf) src


-- | @True@ when any of the wrapper's value-args is a Sky closure (a
-- 'TRClosure' directly in @_call_argTypes@ — validation already proved a
-- closure can only appear there, never nested). Drives the B2 'catch_unwind'
-- panic boundary: a closure-carrying wrapper invokes Sky code inside the host
-- call, so a panic must be caught and mapped to a typed @Err@ at the boundary.
callHasClosureArg :: Call -> Bool
callHasClosureArg call = any isClosure (_call_argTypes call)
  where
    isClosure TRClosure{} = True
    isClosure _           = False


-- | #28 Phase 3 — classify a wrapper-arg 'TypeRef' as an UNSOUND closure shape
-- that must be DROPPED (the method is silently not bound + the reason recorded
-- for coverage), or @Nothing@ for a bindable shape. Three unsound shapes:
--
--   * @closure-mut-slot@ — an @FnMut@/@FnOnce@ closure passed BY REF. A by-ref
--     mut/once slot means the host wants @Fn{Mut,Once}(&mut T)@; the owned-clone
--     bridge (Task 3.2) clones the borrow to an OWNED value, so mutations to the
--     clone never propagate back to the host's referent — binding it would
--     silently lose writes. (A by-VALUE FnMut/FnOnce is fine — no bridge.)
--   * @closure-ho-return@ — the closure RETURNS a function/closure type. The
--     closed Sky↔Rust set has no function arm, so a returned closure cannot be
--     marshalled back across the boundary.
--   * @closure-by-ref-noclone@ — a BY-REF closure whose borrowed arg is a
--     CONCRETE type the backend cannot prove @Clone@ (a 'TRPrim'/'TRCtor' outside
--     the closed Clone set). The owned-clone bridge needs @.clone()@ on the
--     borrow; a non-Clone borrowed type makes that bridge ill-typed. A 'TRParam'
--     borrowed arg is NOT flagged: it is generic and the @+ Clone@ bound on the
--     closure's @Fj@ (from 'closureBounds') enforces Clone at instantiation.
--
-- A non-'TRClosure' 'TypeRef' is never a closure drop (@Nothing@).
closureDropReason :: TypeRef -> Maybe String
closureDropReason (TRClosure kind byRef argTRs ret)
    | byRef && kind /= FnKind            = Just "closure-mut-slot"
    | returnsClosure ret                 = Just "closure-ho-return"
    | byRef, any concreteNotClone argTRs = Just "closure-by-ref-noclone"
    | otherwise                          = Nothing
  where
    returnsClosure TRClosure{} = True
    returnsClosure _           = False
    -- A concrete (non-generic) leaf the backend cannot prove Clone. A TRParam is
    -- generic — its Clone-ness is enforced by the closure's `+ Clone` bound, so
    -- it is NOT a drop here. A nested closure in an arg is itself out of the
    -- closed set, so treat it as not-Clone (drop).
    concreteNotClone (TRParam _)    = False
    concreteNotClone TRClosure{}    = True
    concreteNotClone tr             = not (rustTypeIsClone (renderTypeRef [] tr))
closureDropReason _ = Nothing


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
