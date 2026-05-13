-- | v0.13 Phase A2 — Monomorphisation type-level building blocks.
--
-- Given the call-instance table from `Sky.Type.Solve.solveWithInstances`,
-- the monomorphisation pass needs to:
--
--   1. Mangle each `(callee, type-args)` instance into a deterministic
--      Go identifier so emission can declare one function per instance
--      and call sites can reference the right one.
--   2. Build a substitution map (`a |-> Int`, `b |-> String`, …) from
--      the callee's polymorphic scheme + the call site's concrete
--      type-args.
--   3. Apply the substitution to a Sky-source function body — every
--      `TVar` in type annotations / pattern types / inferred shapes
--      is replaced with the concrete type at this instance.
--
-- This module ships the pure type-level pieces.  The downstream
-- `Sky.Build.Compile` integration (collecting call sites, threading
-- the substitution, rewriting call-site names to the mangled instance)
-- lands in a later phase.
--
-- Correctness property: `mangleType` is deterministic — equal types
-- map to equal names regardless of how they were constructed.
-- Equal-types-different-names would create duplicate emissions
-- (wasted code) and fragment the LSP's symbol index.
--
-- v0.13 Phase A2 (this file) — replaces an earlier stub that walked
-- the AST without using the solver's instance capture.  The new
-- architecture: collection happens AT SOLVE TIME via
-- `Solve.solveWithInstances`; this module just mangles + substitutes.
module Sky.Build.Monomorphise
    ( mangleType
    , mangleInstance
    , mangleQualName
    , buildSubstitution
    , substituteType
    , typesEquiv
    ) where

import qualified Data.Map.Strict as Map
import qualified Data.List as List
import qualified Sky.AST.Canonical as Can
import qualified Sky.Type.Solve as Solve


-- ─── mangling ────────────────────────────────────────────────────────


-- | Encode a Sky type as a Go-identifier-safe string.
--
-- Encoding rules (deterministic, reversible-by-inspection):
--
--   * Primitive types collapse to their bare names: `Int`, `String`,
--     `Bool`, `Float`, `Char`, `Unit`.
--   * Parametric types use `<Ctor>Of` then their args separated by
--     `_`: `MaybeOf_Int`, `ListOf_String`, `ResultOf_Error_Int`.
--     Nested parametrics nest:
--       `Maybe (List Int)` → `MaybeOf_ListOf_Int`
--       `Dict String (List Int)` → `DictOf_String_ListOf_Int`
--   * Function types use `FnOf`: `Int -> String` → `FnOf_Int_String`.
--   * Tuples use `Tup<N>Of`: `(Int, String)` → `Tup2Of_Int_String`.
--   * Records collapse to `RecOf_<sorted-field-keys>_<short-hash>`.
--     The hash discriminates structurally-different records that
--     share field names but not types.
--   * Type variables (should not survive monomorphisation but kept
--     for completeness) encode as `TV_<name>`.
--   * Aliases encode the alias's canonical name; the underlying
--     type isn't re-mangled because two aliases of the same shape
--     are still distinct user-facing types.
mangleType :: Can.Type -> String
mangleType ty = case ty of
    Can.TVar name -> "TV_" ++ sanitise name
    Can.TUnit     -> "Unit"
    Can.TLambda from to ->
        "FnOf_" ++ mangleType from ++ "_" ++ mangleType to
    Can.TType _ name [] ->
        -- Primitive / nullary type constructor: bare name.
        sanitise name
    Can.TType _ name args ->
        sanitise name ++ "Of_" ++ List.intercalate "_" (map mangleType args)
    Can.TTuple a b cs ->
        let n = 2 + length cs
        in "Tup" ++ show n ++ "Of_"
        ++ List.intercalate "_" (map mangleType (a : b : cs))
    Can.TRecord fields _ext ->
        -- Sort field keys for determinism; hash the FULL field-and-type
        -- shape so two records with the same keys but different types
        -- get different names.
        let sortedFields = List.sortOn fst (Map.toList fields)
            keyNames = map fst sortedFields
            shapeStr = concatMap
                (\(k, Can.FieldType _ t) -> k ++ ":" ++ mangleType t ++ ";")
                sortedFields
        in "RecOf_" ++ List.intercalate "_" (map sanitise keyNames)
                    ++ "__" ++ shortHash shapeStr
    Can.TAlias _ name _pairs _underlying ->
        -- Alias keeps its name.  Two aliases that expand to the same
        -- type are still distinct user-facing types — the LSP/docs
        -- treat them as named entities.
        sanitise name


-- | Mangle a (callee, type-args) instance into the Go function name
-- the monomorphiser will emit.  Examples:
--
--   @CallInstance "Sky.Core.Maybe.withDefault" [Int]@
--     → @Sky_Core_Maybe_withDefault__Int@
--
--   @CallInstance "Sky.Core.List.map" [Int, String]@
--     → @Sky_Core_List_map__Int_String@
--
--   @CallInstance "Sky.Core.Maybe.withDefault" [List Int]@
--     → @Sky_Core_Maybe_withDefault__ListOf_Int@
--
-- The double-underscore separator distinguishes the callee suffix
-- from the type-arg list, so future renames (e.g. a Sky function
-- gaining an underscore in its name) don't collide with type-arg
-- separators.
mangleInstance :: Solve.CallInstance -> String
mangleInstance (Solve.CallInstance callee tys) =
    mangleQualName callee
    ++ (if null tys
          then ""
          else "__" ++ List.intercalate "_" (map mangleType tys))


-- | Convert a Sky-source qualified name (`Sky.Core.Maybe.withDefault`)
-- to a Go-identifier-safe form (`Sky_Core_Maybe_withDefault`).  Dots
-- become underscores; everything else is left untouched (callers feed
-- already-validated Sky names).
mangleQualName :: String -> String
mangleQualName = map (\c -> if c == '.' then '_' else c)


-- ─── substitution ────────────────────────────────────────────────────


-- | Zip a function's `Forall` quantifier list with the call site's
-- concrete type-args to produce the substitution `σ : TVar → Type`.
--
-- The caller must ensure the lengths match — they do by construction
-- because `solveWithInstances` only records call sites whose fresh
-- vars all resolved to concrete types, and the fresh-var list has the
-- same length as `Forall vars` (minus the wildcard `any`).
buildSubstitution :: Can.Annotation -> [Can.Type] -> Map.Map String Can.Type
buildSubstitution (Can.Forall vars _) tys =
    -- The solver filters out the wildcard `any` from the fresh-var
    -- list (`fromAnnotation` in Instantiate.hs); align by doing the
    -- same here so the zip semantics match.
    let realVars = filter (/= "any") vars
    in Map.fromList (zip realVars tys)


-- | Walk a Sky `Can.Type` replacing every `TVar n` in the substitution
-- map with its concrete type.  Anything else recurses structurally.
substituteType :: Map.Map String Can.Type -> Can.Type -> Can.Type
substituteType σ ty = case ty of
    Can.TVar name -> Map.findWithDefault ty name σ
    Can.TUnit -> ty
    Can.TLambda from to ->
        Can.TLambda (substituteType σ from) (substituteType σ to)
    Can.TType home name args ->
        Can.TType home name (map (substituteType σ) args)
    Can.TRecord fields ext ->
        Can.TRecord (Map.map (substituteFieldType σ) fields) ext
    Can.TTuple a b cs ->
        Can.TTuple (substituteType σ a) (substituteType σ b)
                   (map (substituteType σ) cs)
    Can.TAlias home name pairs aliasTy ->
        Can.TAlias home name
            (map (\(n, t) -> (n, substituteType σ t)) pairs)
            (substituteAliasType σ aliasTy)


substituteFieldType :: Map.Map String Can.Type -> Can.FieldType -> Can.FieldType
substituteFieldType σ (Can.FieldType idx ty) =
    Can.FieldType idx (substituteType σ ty)


substituteAliasType :: Map.Map String Can.Type -> Can.AliasType -> Can.AliasType
substituteAliasType σ at = case at of
    Can.Hoisted t -> Can.Hoisted (substituteType σ t)
    Can.Filled t  -> Can.Filled (substituteType σ t)


-- ─── equivalence ────────────────────────────────────────────────────


-- | Structural type equality for deduplication.  Two types are
-- equivalent when they have identical canonical shape modulo TVar-
-- name aliasing (i.e. `a → a` and `b → b` are equivalent).  Used by
-- the monomorphisation pass to collapse instances that look
-- different syntactically but represent the same Go-emitted
-- function.
typesEquiv :: Can.Type -> Can.Type -> Bool
typesEquiv = go Map.empty
  where
    go env t1 t2 = case (t1, t2) of
        (Can.TVar a, Can.TVar b) ->
            case Map.lookup a env of
                Just b' -> b' == b
                Nothing -> True  -- first occurrence; alias a ~ b
        (Can.TUnit, Can.TUnit) -> True
        (Can.TLambda f1 t1', Can.TLambda f2 t2') ->
            go env f1 f2 && go env t1' t2'
        (Can.TType _ n1 a1, Can.TType _ n2 a2) ->
            n1 == n2 && length a1 == length a2
                     && and (zipWith (go env) a1 a2)
        (Can.TRecord f1 _, Can.TRecord f2 _) ->
            Map.keysSet f1 == Map.keysSet f2
            && all (\k -> case (Map.lookup k f1, Map.lookup k f2) of
                    (Just (Can.FieldType _ x), Just (Can.FieldType _ y)) ->
                        go env x y
                    _ -> False) (Map.keys f1)
        (Can.TTuple a1 b1 c1, Can.TTuple a2 b2 c2) ->
            go env a1 a2 && go env b1 b2
            && length c1 == length c2
            && and (zipWith (go env) c1 c2)
        (Can.TAlias _ n1 _ _, Can.TAlias _ n2 _ _) ->
            n1 == n2
        _ -> False


-- ─── helpers ─────────────────────────────────────────────────────────


-- | Sanitise a name for use as a Go identifier.  Replaces characters
-- not in `[A-Za-z0-9_]` with `_`.  The callers feed already-sensible
-- Sky names — this is defence in depth, not the primary check.
sanitise :: String -> String
sanitise = map (\c ->
    if (c >= 'A' && c <= 'Z')
       || (c >= 'a' && c <= 'z')
       || (c >= '0' && c <= '9')
       || c == '_'
    then c
    else '_')


-- | Short deterministic hash for record-shape disambiguation.
-- 8 hex digits is plenty — anonymous-record collision probability
-- at scale is negligible.  SDBM-ish; identical to the existing
-- `synthAnonRecordName` in Compile.hs so we stay consistent.
shortHash :: String -> String
shortHash = padHash . hex . foldl step (0 :: Int)
  where
    step h c = (h * 33 + fromEnum c) `mod` 0x100000000

    hex 0 = "0"
    hex n = toHex n

    toHex 0 = ""
    toHex n =
        let (q, r) = n `divMod` 16
        in toHex q ++ [digit r]

    digit n
        | n < 10    = toEnum (fromEnum '0' + n)
        | otherwise = toEnum (fromEnum 'a' + n - 10)

    padHash s = replicate (max 0 (8 - length s)) '0' ++ s
