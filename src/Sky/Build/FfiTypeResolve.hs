{-# LANGUAGE LambdaCase #-}
-- | Phase C plumbing: convert the producer-side FtyAst (parsed
-- from kernel.json's skyType field) into a canonical 'Can.Type' /
-- 'Can.Annotation' that the constraint generator can plug into a
-- @T.CForeign@ for the matching @Can.VarKernel@ reference.
--
-- Lives in Sky.Build (alongside FfiRegistry / FfiTypeParser) so the
-- Sky.Type.Constrain layer doesn't import producer-side modules.
-- The Sky.Type side just queries the Map populated here.
module Sky.Build.FfiTypeResolve
    ( ftyToAnnotation
    , ftyToType
    ) where

import Data.List (nub)
import qualified Data.Map.Strict as Map
import qualified Sky.AST.Canonical as Can
import qualified Sky.Sky.ModuleName as ModuleName
import Sky.Build.FfiTypeParser (FtyAst(..))


-- | Build a 'Can.Annotation' (i.e. @Forall [tvars] Type@) from an
-- FtyAst, namespacing any unrecognised opaque uppercase identifier
-- under the given kernel name (e.g. @ActionCodeSettings@ from the
-- @Auth@ kernel becomes @TType (Canonical "Auth") "ActionCodeSettings" []@).
--
-- The 'Forall' binder collects every distinct lowercase TVar
-- encountered, including the wildcard @any@. Sky.Type.Solve gives
-- @TVar "any"@ wildcard semantics — distinct occurrences mint fresh
-- unification vars (Limitation #18 fix). For any other lowercase,
-- a single Forall scope per FFI symbol is correct: two occurrences
-- of @a@ in the same skyType (e.g. @a -> Result Error a@) MUST
-- unify, since they're the same parameter / return position.
ftyToAnnotation :: String -> FtyAst -> Can.Annotation
ftyToAnnotation kernelName ast =
    let ty = ftyToType kernelName ast
        tvars = nub (collectTVars ty)
    in Can.Forall tvars ty


-- | Convert FtyAst to a canonical 'Can.Type'. Recognised builtins
-- (Result / Maybe / List / Dict / Task / Set / Error / String /
-- Int / Bool / Float / Char / Bytes) resolve to their canonical
-- module homes via 'Sky.Sky.ModuleName' helpers; everything else
-- becomes an opaque @TType@ namespaced under the FFI kernel.
--
-- Multiple FFI modules can each define their own 'Token' / 'Config'
-- without collision — each kernelName is a separate canonical home,
-- and TType identity is by (home, name, args).
ftyToType :: String -> FtyAst -> Can.Type
ftyToType kernelName = go
    -- kernelName pins the canonical home for the parametric-foreign
    -- branch in goApp (Wall #1 of the demand-driven generic FFI
    -- epic). For the nullary opaque path it is still unused — see
    -- the opaqueValue comment for why that path keeps the empty
    -- home (and the future-work note on fully-qualified Go-package
    -- paths in skyType).
  where
    go = \case
        FtyVar name           -> Can.TVar name
        FtyUnit               -> Can.TUnit
        FtyArrow a b          -> Can.TLambda (go a) (go b)
        FtyTuple [t1, t2]     -> Can.TTuple (go t1) (go t2) []
        FtyTuple (t1:t2:rest) -> Can.TTuple (go t1) (go t2) (map go rest)
        FtyTuple _            ->
            -- Single-element tuple is illegal Sky syntax; if it ever
            -- escapes the parser, treat it as a unit fallback rather
            -- than panic.
            Can.TUnit
        FtyApp name args      -> goApp name (map go args)

    goApp :: String -> [Can.Type] -> Can.Type
    goApp name args = case lookup name builtinHome of
        Just home -> Can.TType home name args
        Nothing
            -- v0.17 C17b / PR-21c — qualified opaque types (Go, Cause G).
            -- Inspector-emitted @Customer\@github.com/stripe/stripe-go/v84@
            -- lands here.  Emit the mangled qualified form
            -- @Bare_at_<pkgmangle>@ as a nullary @Can.TType@ with the
            -- empty-home sentinel:
            --   * PR-21a (codegen flatten) — solvedTypeToGo short-circuits
            --     the mangled @_at_@ form to @any@ at 5 renderer sites.
            --   * PR-21b (HM unify axiom) — Sky.Type.Unify's App1 arm
            --     calls @isFfiInterfacePair@ on a qualified↔qualified
            --     mismatch (Go's structural interface satisfaction).
            --   * Registry-key mangle in loadAndSeedFfiRegistry aligns
            --     the @\@@-separated keys with the @_at_@ names HM sees.
            -- This is the Go path; it MUST run BEFORE the Rust
            -- parametric-foreign guard below so a Go qualified name never
            -- falls into the fork-local branch (Rust names never carry
            -- the @\@pkg@ marker → splitQualified is Nothing on Rust).
            | Just (bareName, pkgPath) <- splitQualified name ->
                Can.TType (ModuleName.Canonical "")
                    (bareName ++ "_at_" ++ mangleGoIdent pkgPath)
                    args
            -- Wall #1 (demand-driven generic Sky→Rust FFI epic): a
            -- non-builtin ctor carrying type args is a genuine PARAMETRIC
            -- foreign type (e.g. a Rust @IndexMap<K, V>@ surfaced as
            -- @IndexMap k v@).  Preserve it as @TType <foreignHome> name
            -- args@ so HM can solve a use-site @IndexMap String Int@ and
            -- the monomorphiser sees the concrete @[String, Int]@.  On
            -- the Go path opaque ctors reach here with EMPTY args
            -- (containers are builtins), so this guard never fires for Go
            -- — keeping the Go path byte-identical.
            | not (null args) -> Can.TType foreignHome name args
            -- Nullary non-builtin ctor → unchanged @Value@-sentinel.
            | otherwise       -> opaqueValue
      where
        -- Drop @args@ for opaque types — anything generic at the
        -- Go side would have been filtered by isSkyParseable on
        -- the producer; the only remaining shapes are bare opaque
        -- type names and List/Dict/Maybe applied to them. The
        -- latter still resolve to List (Value) etc. because we
        -- recurse through arg positions before reaching here.
        _used = name : map (const "_") args

    -- (C) Non-empty home for the parametric-foreign branch. The
    -- unifier (Unify.hs) relaxes empty-home matching, so a
    -- @Canonical ""@ home would let two different crates' same-named
    -- @IndexMap@ cross-unify and lose nominal identity. Pin the home
    -- to the FFI binding's kernel/crate name so each crate's
    -- @IndexMap k v@ is a distinct nominal type. If @kernelName@ is
    -- somehow empty (it never is for a real FFI symbol — the
    -- registry always threads a kernel name), fall back to a stable
    -- non-empty sentinel rather than the relaxed empty home.
    foreignHome :: ModuleName.Canonical
    foreignHome
        | null kernelName = ModuleName.Canonical "Sky.Ffi.Foreign"
        | otherwise       = ModuleName.Canonical kernelName

    -- v0.17 C17b — split a qualified opaque marker (Cause G).
    -- Format: @Name\@pkgPath@.  Returns @Just (name, pkgPath)@ on
    -- match.  Tolerates leading '*' (pointer-of-opaque) — strips
    -- the star before splitting so a pointer-of-Customer still
    -- resolves to the Customer home, only the runtime wrapper
    -- cares about the indirection.
    splitQualified :: String -> Maybe (String, String)
    splitQualified s = case dropWhile (== '*') s of
        bare -> case break (== '@') bare of
            (n, '@':pkg) | not (null n) && not (null pkg) ->
                Just (n, pkg)
            _ -> Nothing

    -- v0.17 C17b — Go-identifier-mangle the package path.
    -- '/' '.' '-' all map to '_' so the result is safe to splice
    -- into any downstream Go identifier emission path. Collisions
    -- between distinct paths are theoretical (would require a path
    -- that differs only in separator chars) — fine for FFI surface.
    mangleGoIdent :: String -> String
    mangleGoIdent = map sanit
      where
        sanit c
            | c == '/' || c == '.' || c == '-' = '_'
            | otherwise                        = c

    -- Unqualified opaque FFI types fall back to the @Value@
    -- sentinel — kept as the safety net for older kernel.json
    -- files (pre-C17a) that don't carry the qualified marker.
    -- The trust-boundary wrap (@Result Error _@) is what HM
    -- actually enforces here.  Per CLAUDE.md "every FFI call
    -- returns Result Error T".  The opaque-type name itself is
    -- decorative when unqualified — runtime wrapper still does the
    -- .(*pkg.X) assertion at the Go boundary, so a wrong opaque
    -- mixed across packages panics at the wrapper with ErrFfi.
    opaqueValue :: Can.Type
    opaqueValue = Can.TType (ModuleName.Canonical "") "Value" []

    -- Closed list of recognised builtin type constructors. Order is
    -- arbitrary — it's a small lookup. Keeping it explicit (rather
    -- than a ModuleName.builtins helper) means an FFI package's
    -- own type accidentally named e.g. @List@ would still resolve
    -- to Sky's List, which is the correct behaviour: HM treats them
    -- as the same type, and the runtime wrapper can do an interface
    -- bridge if needed.
    builtinHome :: [(String, ModuleName.Canonical)]
    builtinHome =
        [ ("String",  ModuleName.basics)
        , ("Int",     ModuleName.basics)
        , ("Bool",    ModuleName.basics)
        , ("Float",   ModuleName.basics)
        , ("Char",    ModuleName.basics)
        , ("Bytes",   ModuleName.basics)
        , ("Error",   ModuleName.Canonical "Sky.Core.Error")
        , ("Result",  ModuleName.result_)
        , ("Maybe",   ModuleName.maybe_)
        , ("List",    ModuleName.list)
        , ("Dict",    ModuleName.dict)
        , ("Set",     ModuleName.set)
        , ("Task",    ModuleName.task)
        ]


-- | Walk a Can.Type collecting every TVar name. Order is
-- deterministic (left-to-right traversal) — 'nub' on the result
-- deduplicates while preserving first-seen order so the Forall
-- binder list mirrors the natural reading order of the type
-- string.
collectTVars :: Can.Type -> [String]
collectTVars = \case
    Can.TVar n        -> [n]
    Can.TUnit         -> []
    Can.TLambda a b   -> collectTVars a ++ collectTVars b
    Can.TTuple a b cs -> collectTVars a ++ collectTVars b ++ concatMap collectTVars cs
    Can.TType _ _ ts  -> concatMap collectTVars ts
    Can.TRecord fs r  ->
        concatMap (collectTVars . Can._fieldType) (Map.elems fs)
            ++ maybe [] (\v -> [v]) r
    Can.TAlias _ _ binders body ->
        concatMap (collectTVars . snd) binders
            ++ collectAliasBody body
  where
    collectAliasBody (Can.Hoisted t) = collectTVars t
    collectAliasBody (Can.Filled  t) = collectTVars t
