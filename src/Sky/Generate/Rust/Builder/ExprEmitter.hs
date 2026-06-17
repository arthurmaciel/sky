module Sky.Generate.Rust.Builder.ExprEmitter
    ( substVar
    , collectVarLocalsMulti
    , collectFreeVarLocalsMulti
    , collectVarLocals
    , collectLambdaCapturedVars
    , argToRustString
    , rustStringLit
    , rustCharLit
    , exprToRustString
    , EmptyKind(..)
    , emptyArgKind
    , isEmptyishArg
    , ParamSrc(..)
    , calleeParamStrings
    , rustTypeTokens
    , isRustTypeVarTok
    , isClosureParamStr
    , rustConcreteLowerToks
    , emitEmptyArg
    , isWildcardPat
    , isWildcardClosure
    , pinTaskCall
    , emitPinnedTask
    , peepholeArg
    , splitKernelName
    , exprToRustInner
    , taskExprInnerType
    , mainEntryTailReturnsTask
    , inferParamRustType
    , collectClosureDefs
    , canDefBody
    , taskInnerTypeStr
    , taskExprInnerTypeCall
    , emitDefaultCall
    , solveArgType
    , binopToRust
    , defToRustString
    , branchToRustString
    , branchToRustStringStrWrap
    , patternToMatchString
    , ctorArgToPattern
    , flattenCons
    , isBackendEntryApp
    ) where

import Data.List (intercalate, isSuffixOf, isPrefixOf, isInfixOf, sortBy, stripPrefix, minimumBy, nub)
import Data.Char (isUpper, isDigit)
import Numeric (showHex)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Sky.AST.Canonical as Can
import qualified Sky.Sky.ModuleName as ModuleName
import qualified Sky.Reporting.Annotation as Ann
import Sky.Generate.Rust.Builder.Types
    ( EmitCtx(..)
    , kernelsNeedingErrorPin
    , kernelsZeroArg
    , topLevelErrorPin
    )
import Sky.Generate.Rust.Builder.SigRegistry
    ( knownDefSig
    )
import Sky.Generate.Rust.Builder.TypeRenderer
    ( typeToRustString
    , rustifyExpectedType
    , formTargetRustType
    , extractParamTypes
    , extractReturnType
    , hasTypeVars
    , isEventArgType
    , flattenArrowType
    , resultIsTaskTy
    )
import Sky.Generate.Rust.Builder.Kernel
    ( kernelToRust
    , kernelSigPrefix
    , splitKernelName
    )
import Sky.Generate.Rust.Builder.Naming
    ( rustSafeIdent
    , kernelCtorToRust
    , rustFnName
    , toSnakeCase
    , toCamelCase
    )
import Sky.Generate.Rust.Builder.Pattern
    ( patternToRustParam
    , patBindingVars
    , hasStrPat
    , isWildcard
    )

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
                    Nothing -> let emitName = rustFnName (ecNameRenames ctx) modPrefix n
                               in if Set.member (modPrefix, n) (ecZeroArgDefs ctx) then emitName ++ "()" else emitName
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
               then "log_println(" ++ intercalate " ++ \" \" ++ " (map go args) ++ ")"
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
            -- Deferred-effect Part B, substVar path: a discarded `_ = <task call>`
            -- must RUN the effect (`task_run`), not bind+drop — with deferred
            -- effect kernels a bare `let _ = log_println(…)` constructs the future
            -- and drops it, so the effect never fires (this regressed `simple`'s
            -- `let _ = println …`, which reaches HERE because `tasks` is inlined by
            -- substVar). Non-task discards (`_ = List.map …`, `_ = someVar`) keep
            -- bind/drop. Mirrors the exprToRustInner Def-`"_"` arm.
            goDef (Can.Def (Ann.At _ "_") [] dBody)
              | isTaskProducingCall dBody
              , not (null (taskExprInnerType (ecSolvedTypes ctx) dBody)) =
                  "task_run::<SkyError, _>(" ++ go dBody ++ "); "
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

-- | The RHS body expression of a let-binding, across all Def variants — plain
-- (`let x = …`), type-annotated (`let x : T = …`, a TypedDef), and
-- destructuring (`let (a, b) = …`, a DestructDef). The var-counting traversals
-- only need the binding's RHS, so this unifies the three shapes and stops the
-- non-exhaustive crash on annotated/destructuring lets (e.g. 10-live-component).
canDefBody :: Can.Def -> Can.Expr
canDefBody (Can.Def _ _ b)          = b
canDefBody (Can.TypedDef _ _ _ b _) = b
canDefBody (Can.DestructDef _ e)    = e

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
        Can.Let def body ->
            -- A let-bound fn's params are bound in its own body, so a param use
            -- isn't an outer-var use (matches collectVarLocals / the free walker).
            let boundDef = foldr Set.insert bound (defParamVars def)
            in Map.unionWith (+) (go boundDef (canDefBody def)) (go bound body)
        Can.LetRec defs body ->
            let goDefs = foldl (\a d ->
                            let boundD = foldr Set.insert bound (defParamVars d)
                            in Map.unionWith (+) a (go boundD (canDefBody d))) Map.empty defs
            in Map.unionWith (+) (go bound body) goDefs
        Can.LetDestruct pat expr body ->
            Map.unionWith (+) (go bound expr) (go bound body)
        -- Sub-D: count the scrutinee too. A var used in a case scrutinee
        -- (e.g. `case f key of …`) AND again elsewhere must be marked multi-use
        -- so it gets cloned at the first use — otherwise it's moved and the
        -- second use fails (E0382). The scrutinee was previously ignored.
        -- Case ARMS are mutually exclusive: only one runs, so a var used once
        -- per arm is consumed at most once — take the MAX across arms, not the
        -- sum. (Summing over-counted and inserted spurious `.clone()`s, fatal
        -- for move-only types like SkyCmd/SkySub which aren't Clone → E0599.)
        -- The scrutinee is evaluated unconditionally, so it still SUMS with the
        -- per-arm max; a var used in the scrutinee AND an arm correctly counts 2
        -- (clone), and a var reused after the case is caught by the outer sum.
        Can.Case scrut branches ->
            let branchMax = foldl (\a (Can.CaseBranch _ b) ->
                                Map.unionWith max a (go bound b)) Map.empty branches
            in Map.unionWith (+) (go bound scrut) branchMax
        -- If/then/else: conditions evaluate unconditionally (sum, conservative —
        -- over-count is safe), bodies are exclusive (max).
        Can.If branches elseBranch ->
            let condSum  = foldl (\a (c, _) -> Map.unionWith (+) a (go bound c)) Map.empty branches
                bodyMax  = foldl (\a (_, t) -> Map.unionWith max a (go bound t)) (go bound elseBranch) branches
            in Map.unionWith (+) condSum bodyMax
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
        Can.Let def body ->
            -- Def bodies are counted in `bound` (the def's own name not yet in
            -- scope — matches the original non-recursive treatment); the let
            -- body sees the bound name(s). A let-bound fn's PARAMS are bound in
            -- its own body (so `let f a = …a…` doesn't count `a` as free).
            let bound' = foldr Set.insert bound (defLocalNames def)
                boundDef = foldr Set.insert bound (defParamVars def)
            in Map.unionsWith (+) (go bound' body : map (go boundDef) (defLocalBodies def))
        Can.LetRec defs body ->
            let bound' = foldl (\s d -> foldr Set.insert s (defLocalNames d)) bound defs
                goDefs = foldl (\a d ->
                            let boundD = foldr Set.insert bound' (defParamVars d)
                            in Map.unionsWith (+) (a : map (go boundD) (defLocalBodies d))) Map.empty defs
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
-- | Non-Clone capture fix (#52): vars from an enclosing scope that are FREE
-- INSIDE some `Can.Lambda` nested in the expression — i.e. genuinely CAPTURED
-- by a closure (and so subject to the per-closure `.clone()` capture-prelude),
-- as opposed to merely referenced at the top level (e.g. stored into a struct
-- field / enum payload, which does NOT clone). This is the precise gate for
-- Arc-wrapping a non-`Clone` `impl Fn` param: a `Std.Html.Events.onInput`
-- handler that's only STORED in `OnString(.., handler)` is NOT lambda-captured,
-- so it must keep its bare type (the existing `Arc::new(handler)` storage path).
collectLambdaCapturedVars :: Can.Expr -> Set.Set String
collectLambdaCapturedVars = go Set.empty
  where
    -- `bound` tracks names bound by ENCLOSING lambdas/lets; once we enter a
    -- lambda, every free var of its body (minus the lambda's own params and
    -- inner binders) is a capture.
    go :: Set.Set String -> Can.Expr -> Set.Set String
    go bound (Ann.At _ expr) = case expr of
        Can.Lambda ps lamBody ->
            let lamParams = Set.fromList (concatMap patBindingVars ps)
                -- Everything free in the lambda body (minus the lambda's own
                -- params) is captured from an enclosing scope.
                lamCaptures = Set.difference (collectVarLocals lamBody) lamParams
            in Set.union lamCaptures (go (Set.union bound lamParams) lamBody)
        Can.Call fn args -> foldl (\a e -> Set.union a (go bound e)) (go bound fn) args
        Can.Let def b ->
            let bound' = foldr Set.insert bound (defLocalNames def)
                boundDef = foldr Set.insert bound' (defParamVars def)
            in Set.union (go bound' b) (foldl (\a d -> Set.union a (go boundDef d)) Set.empty (defLocalBodies def))
        Can.LetRec defs b ->
            let bound' = foldl (\s d -> foldr Set.insert s (defLocalNames d)) bound defs
            in Set.union (go bound' b) (foldl (\a d -> let bD = foldr Set.insert bound' (defParamVars d) in foldl (\a2 e -> Set.union a2 (go bD e)) a (defLocalBodies d)) Set.empty defs)
        Can.LetDestruct pat e b ->
            let bound' = foldr Set.insert bound (patBindingVars pat)
            in Set.union (go bound e) (go bound' b)
        Can.Case s bs -> foldl (\a (Can.CaseBranch pat b) -> let bnd = foldr Set.insert bound (patBindingVars pat) in Set.union a (go bnd b)) (go bound s) bs
        Can.If brs el -> foldl (\a (c, t) -> Set.union a (Set.union (go bound c) (go bound t))) (go bound el) brs
        Can.Binop _ _ _ _ a b -> Set.union (go bound a) (go bound b)
        Can.Access r _ -> go bound r
        Can.Update _ r ups -> Set.union (go bound r) (foldl (\a (_, Can.FieldUpdate _ e) -> Set.union a (go bound e)) Set.empty (Map.toList ups))
        Can.Record fs -> foldl (\a (_, v) -> Set.union a (go bound v)) Set.empty (Map.toList fs)
        Can.List es -> foldl (\a e -> Set.union a (go bound e)) Set.empty es
        Can.Tuple a b rest -> foldl (\acc e -> Set.union acc (go bound e)) Set.empty (a:b:rest)
        Can.Negate e -> go bound e
        _ -> Set.empty

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
        -- A `let` binds a Def, which can be Def / TypedDef / DestructDef.
        -- Handle all three (TypedDef = `let x : T = …`, DestructDef =
        -- `let (a, b) = …`) — the original arm only matched plain Def and
        -- crashed non-exhaustively on the others (26-ui-showcase).
        Can.Let def body ->
            let bound' = foldr Set.insert bound (defLocalNames def)
                -- The Def's body sees its OWN params bound (a let-bound fn
                -- `let f a b = … a …` — a/b aren't captures of the enclosing
                -- closure). Mirror this in LetRec / the *Multi walkers below.
                boundDef = foldr Set.insert bound' (defParamVars def)
            in Set.union (go bound' body)
                         (foldl (\a d -> Set.union a (go boundDef d)) Set.empty (defLocalBodies def))
        Can.LetRec defs body ->
            let bound' = foldl (\s d -> foldr Set.insert s (defLocalNames d)) bound defs
                goDefs = foldl (\a d ->
                            let boundD = foldr Set.insert bound' (defParamVars d)
                            in foldl (\a2 e -> Set.union a2 (go boundD e)) a (defLocalBodies d)) Set.empty defs
            in Set.union (go bound' body) goDefs
        Can.LetDestruct pat expr body ->
            let bound' = foldr Set.insert bound (patBindingVars pat)
            in Set.union (go bound expr) (go bound' body)
        Can.Case scrut branches -> foldl (\a (Can.CaseBranch pat b) ->
            let bound' = foldr Set.insert bound (patBindingVars pat)
            in Set.union a (go bound' b)) (go bound scrut) branches
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

-- | The names a `let`-bound Def introduces into scope (across all three Def
-- shapes). Used by the free-variable / multi-use walkers so a `let x : T = …`
-- or `let (a, b) = …` is handled the same as a plain `let x = …`.
defLocalNames :: Can.Def -> [String]
defLocalNames (Can.Def (Ann.At _ n) _ _)          = [n]
defLocalNames (Can.TypedDef (Ann.At _ n) _ _ _ _) = [n]
defLocalNames (Can.DestructDef pat _)             = patBindingVars pat

-- | The body expression(s) of a `let`-bound Def (one per shape).
defLocalBodies :: Can.Def -> [Can.Expr]
defLocalBodies (Can.Def _ _ b)          = [b]
defLocalBodies (Can.TypedDef _ _ _ b _) = [b]
defLocalBodies (Can.DestructDef _ b)    = [b]

-- | The PARAMETER names a `let`-bound function Def binds in its OWN body
-- (`let formatOutput buildOutput runOutput = … buildOutput …`). The
-- free-variable / capture walkers must add these to `bound` before descending
-- into the Def body — otherwise the params read as free vars of the enclosing
-- closure and get hoisted into its `.clone()` capture-prelude, producing
-- `let buildOutput = buildOutput.clone();` at a scope where the name doesn't
-- exist (E0425). Mirrors `defLocalNames` (which only binds the Def's own name).
defParamVars :: Can.Def -> [String]
defParamVars (Can.Def _ ps _)          = concatMap patBindingVars ps
defParamVars (Can.TypedDef _ _ tps _ _) = concatMap (patBindingVars . fst) tps
defParamVars (Can.DestructDef _ _)     = []

-- | Is the expression `e` a bare reference to local var `name`?
isVarLocalRef :: String -> Can.Expr -> Bool
isVarLocalRef name (Ann.At _ (Can.VarLocal n)) = n == name
isVarLocalRef _ _                              = False

-- | Non-Clone capture fix (#52). Does the discarded RHS PRODUCE a fresh task
-- via a CALL (`process_run …`, a `|>` pipeline ending in one, an `if`/`case`
-- of such)? Only such expressions carry a generic error type the bare `let _ =`
-- can't pin (E0283). A bare `VarLocal` discard (`let _ = cleanup`) refers to an
-- already-typed binding (often itself the Arc-wrapped value), so it must NOT be
-- annotated `SkyTask<…>` — its real Rust type is whatever the binding holds.
isTaskProducingCall :: Can.Expr -> Bool
isTaskProducingCall (Ann.At _ e) = case e of
    Can.Call _ _          -> True
    Can.Binop "|>" _ _ _ _ r -> isTaskProducingCall r
    Can.Let _ b           -> isTaskProducingCall b
    Can.LetRec _ b        -> isTaskProducingCall b
    Can.LetDestruct _ _ b -> isTaskProducingCall b
    Can.If brs el         -> all (isTaskProducingCall . snd) brs && isTaskProducingCall el
    Can.Case _ bs         -> not (null bs) && all (\(Can.CaseBranch _ b) -> isTaskProducingCall b) bs
    _                     -> False

-- | Non-Clone capture fix (#52, Part B). Does EVERY free use of `name` in `e`
-- appear ONLY in DISCARD position — i.e. as the RHS of a `let _ = name`
-- (`Can.DestructDef PAnything (VarLocal name)`) or a `let _ = name`-shaped
-- ignored Def? A SkyTask (`Pin<Box<dyn Future>>`) is non-`Clone`, so when it's
-- captured by MULTIPLE sibling closures the per-closure `.clone()` prelude is
-- E0599. Arc-wrapping the binding makes the clone sound — but ONLY when the
-- task is merely DROPPED (never `.await`ed / passed positionally to a `task_*`
-- combinator that needs an owned `SkyTask`). The `let _ = cleanup` discard
-- pattern (Sky forces a Task value for effect, then throws it away) is exactly
-- that case. Any non-discard use (returned, andThen'd, etc.) → False, so the
-- binding is left un-wrapped (the existing move/clone path handles it). Returns
-- True for ZERO uses too (vacuously discarded — but the caller also gates on
-- "captured", so a zero-use binding never reaches the wrap).
allUsesDiscarded :: String -> Can.Expr -> Bool
allUsesDiscarded name = go
  where
    -- Once we descend past a binder that shadows `name`, inner uses belong to
    -- the shadow, so stop checking them (treat as discarded for our purposes).
    go (Ann.At _ e) = case e of
        Can.VarLocal n        -> n /= name   -- a BARE non-discard use of name → bad
        Can.Let def body
            -- `let _ = name in …` (DestructDef PAnything) — the discard we allow.
            | Can.DestructDef (Ann.At _ Can.PAnything) rhs <- def
            , isVarLocalRef name rhs
            -> go body
            -- `let _ = name in …` as a named Def whose name is "_" (ignored).
            | Can.Def (Ann.At _ "_") [] rhs <- def
            , isVarLocalRef name rhs
            -> go body
            | name `elem` defLocalNames def -> True   -- shadowed: stop
            | otherwise -> all go (defLocalBodies def) && go body
        Can.LetRec defs body
            | name `elem` concatMap defLocalNames defs -> True
            | otherwise -> all go (concatMap defLocalBodies defs) && go body
        Can.LetDestruct pat rhs body
            | isVarLocalRef name rhs, ignoredPat pat -> go body
            | name `elem` patBindingVars pat -> go rhs   -- shadowed in body
            | otherwise -> go rhs && go body
        Can.Lambda ps body
            | name `elem` concatMap patBindingVars ps -> True
            | otherwise -> go body
        Can.Call fn args      -> all go (fn : args)
        Can.Case s bs         -> go s && and [ b' | Can.CaseBranch p b <- bs
                                                   , let b' = name `elem` patBindingVars p || go b ]
        Can.If brs el         -> and [ go c && go t | (c, t) <- brs ] && go el
        Can.Binop _ _ _ _ a b -> go a && go b
        Can.Access r _        -> go r
        Can.Update _ r ups    -> go r && and [ go x | (_, Can.FieldUpdate _ x) <- Map.toList ups ]
        Can.Record fs         -> and [ go x | (_, x) <- Map.toList fs ]
        Can.List xs           -> all go xs
        Can.Tuple a b rest    -> all go (a : b : rest)
        Can.Negate x          -> go x
        _                     -> True
    ignoredPat (Ann.At _ Can.PAnything) = True
    ignoredPat _                        = False

-- | Helper: render a single function-call argument string, handling
-- lambda capture cloning and VarLocal ownership.
-- Clones every VarLocal argument by default (most Sky types implement Clone).
-- Exceptions: Task.run (Pin<Box<dyn Future>> which is not Clone).
argToRustString :: EmitCtx -> Bool -> Can.Expr -> String
argToRustString ctx noCloneFn (Ann.At _ a) = case a of
    Can.Lambda ps body ->
        let paramNames = Set.fromList (concatMap patBindingVars ps)
            captured = Set.toList (Set.difference (collectVarLocals body) paramNames)
            clones = concatMap (\v -> let v' = rustSafeIdent v in "let " ++ v' ++ " = " ++ v' ++ ".clone(); ") captured
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
            -- Clear ecForcedClosureParam for the BODY: it types only THIS
            -- closure's own param, not any nested closure inside the body.
            ctx' = ctx { ecCloneVars = allCloneVars, ecCopyVars = ecCopyVars ctx
                       , ecForcedClosureParam = Nothing, ecIndexedHofClosure = False
                       , ecBinaryHofClosure = False }
            annot = case ecPipeInnerType ctx of
                Just t | length ps == 1 -> ": " ++ t
                _ -> ""
            -- A HOF closure record param (`List.map (\j -> j.id …) jobs`) often
            -- can't be inferred by Rust from the sibling list arg → E0282.
            -- Resolve it to its struct via field-access usage when the pipe
            -- annotation doesn't already cover it.
            -- ecForcedClosureParam types the ELEMENT param, which is param 0 for
            -- every list HOF (filter/map: the only param; foldl/foldr: the
            -- element comes before the accumulator). Annotate index 0 only.
            annotPsIx i p@(Ann.At _ (Can.PVar pn))
                -- indexedMap's closure is Fn(i64, elem): index param first.
                | ecIndexedHofClosure ctx, i == (0 :: Int) = patternToRustParam p ++ ": i64"
                | ecIndexedHofClosure ctx, i == (1 :: Int), Just s <- ecForcedClosureParam ctx = patternToRustParam p ++ ": " ++ s
                -- sortWith comparator: BOTH params are the element type.
                | ecBinaryHofClosure ctx, i `elem` [0, 1 :: Int], Just s <- ecForcedClosureParam ctx = patternToRustParam p ++ ": " ++ s
                | i == (0 :: Int), Just s <- ecForcedClosureParam ctx = patternToRustParam p ++ ": " ++ s
                | not (null annot) = patternToRustParam p ++ annot
                | Just s <- inferRecordClosureParam ctx pn body = patternToRustParam p ++ ": " ++ s
                -- Last resort: the solver's per-region types at the param's use
                -- sites (globalRegionTypes). A `\buildOut -> combine buildOut …`
                -- closure passed to `task_and_then`/`task_map` has its param
                -- pinned to a concrete Sky type (here `String`) the solver
                -- already recorded, but no kernel-flow / forced-element / pipe
                -- annotation covers it → E0282. Concrete-only (no type vars), so
                -- a still-generic element stays bare for Rust to infer from the
                -- sibling collection arg (List.map/filter unchanged).
                | Just s <- inferParamRustTypeFromRegions ctx pn body = patternToRustParam p ++ ": " ++ s
            annotPsIx _ p = patternToRustParam p ++ annot
            psStr = intercalate ", " (zipWith annotPsIx [0..] ps)
            -- Each task-continuation closure's return inner type must come from
            -- ITS OWN body's task type, not the inherited ecPipeInnerType — that
            -- holds the OUTER piped chain's inner type (e.g. `()` at the final
            -- `… |> Task.run`) and propagates unchanged into every nested
            -- `Task.andThen (\_ -> taskReturningOtherType)`, mis-annotating the
            -- closure `-> SkyTask<()>` and failing `cargo build` (E0308) the
            -- moment a continuation's result inner type differs from the chain's.
            -- The gate below (which closures get the Task treatment) is
            -- UNCHANGED; only the inner TYPE is corrected, keeping the inherited
            -- value as the fallback when the body's task inner type can't be read.
            retInner = case ecPipeInnerType ctx of
                Just _ ->
                    let bodyTaskInner = taskExprInnerType (ecSolvedTypes ctx) body
                    -- Prefer the body's OWN task inner type. When it can't be read
                    -- — a POLYMORPHIC kernel like `Random.shuffle : List a ->
                    -- Task e (List a)`, whose inner type is neither in the
                    -- monomorphic table nor name-keyed in `solved` — OMIT the
                    -- annotation and let Rust infer it from the concrete
                    -- kernel-call body (E is already pinned by the enclosing
                    -- chain). NEVER fall back to the inherited outer-chain type:
                    -- it is the OUTER piped result (`()` at `… |> Task.run`) and
                    -- is wrong for any nested continuation returning another type.
                    in if null bodyTaskInner then Nothing else Just bodyTaskInner
                Nothing -> Nothing
            retAnnot = case retInner of
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

-- | #24 tenet 2: is this expression a backend-entry app constructor call
-- (`Live.app {…}` / `Tui.app {…}` / `Tui.program {…}` / `Webview.app {…}`)?
-- Each lowers to a `SkyTask<()>` driver future, so a `… |> Task.run` over one of
-- these has the future itself as the program entry — the Task.run is dropped and
-- the entry block_on's the future (subsumes the #56 top-level special-case and
-- makes a backend-dispatching `case` (24) unify as a `SkyTask<()>`). Cli.program
-- is intentionally EXCLUDED: it still runs inline via task_run (it is not in the
-- usesBackendApp set that drives `mainIsTask`), so its Task.run stays.
-- | Is this expression a reference to `Task.run`? It reaches codegen as a
-- Sky-source `Ffi.kernel "Task_run"` alias — i.e. `VarTopLevel "Sky.Core.Task"
-- "run"` — NOT a bare `VarKernel` (mirrors how `Webview.app` arrives). Match
-- both so the #24 tenet-2 drop fires on `App {…} |> Task.run`.
isTaskRunRef :: Can.Expr -> Bool
isTaskRunRef (Ann.At _ e) = case e of
    Can.VarKernel "Task" "run"  -> True
    Can.VarTopLevel m "run"     -> ModuleName._name m == "Sky.Core.Task"
    _                           -> False

isBackendEntryApp :: Can.Expr -> Bool
isBackendEntryApp (Ann.At _ e) = case e of
    Can.Call (Ann.At _ (Can.VarKernel "Live" "app"))    [Ann.At _ (Can.Record _)] -> True
    Can.Call (Ann.At _ (Can.VarKernel "Tui" "app"))     [Ann.At _ (Can.Record _)] -> True
    Can.Call (Ann.At _ (Can.VarKernel "Tui" "program")) [Ann.At _ (Can.Record _)] -> True
    Can.Call (Ann.At _ (Can.VarTopLevel m "app"))       [Ann.At _ (Can.Record _)]
        | ModuleName._name m == "Std.Webview" -> True
    _ -> False

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
data EmptyKind = EKList | EKNothing | EKDict | EKSet

emptyArgKind :: Can.Expr -> Maybe EmptyKind
emptyArgKind (Ann.At _ (Can.List [])) = Just EKList
emptyArgKind (Ann.At _ (Can.VarCtor _ _ "Maybe" "Nothing" _)) = Just EKNothing
-- `Dict.empty` as an ARG resolves its `HashMap<K,V>` from the callee's param
-- type (like `[]` / `Nothing` do), so a `Dict String ()` param pins
-- `::<String,()>` not the i64 default (35-composite-generics uniqueKeepingFirst).
emptyArgKind (Ann.At _ (Can.VarKernel m "empty")) | m == "Dict" || m == "Sky.Core.Dict" = Just EKDict
emptyArgKind (Ann.At _ (Can.VarTopLevel m "empty"))
    | let n = ModuleName._name m in n == "Dict" || "Sky.Core.Dict" `isSuffixOf` n = Just EKDict
-- `Set.empty` mirrors `Dict.empty`: as an ARG its `BTreeSet<A>` resolves from
-- the callee's param type, so a `Set String` param pins `::<String>`.
emptyArgKind (Ann.At _ (Can.VarKernel m "empty")) | m == "Set" || m == "Sky.Core.Set" = Just EKSet
emptyArgKind (Ann.At _ (Can.VarTopLevel m "empty"))
    | let n = ModuleName._name m in n == "Set" || "Sky.Core.Set" `isSuffixOf` n = Just EKSet
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
    -- A LOCAL let-bound closure (`guarded` / `wrap` / `cors` middleware wrappers)
    -- whose solved type is in scope: surface its param strings so a call-arg can
    -- tell its slot is a `Handler` (`Arc<dyn Fn>`). Only matters for the
    -- Handler-Arc-wrap; absence (Nothing) is the prior behaviour for every other
    -- local call.
    Ann.At _ (Can.VarLocal name) ->
        case Map.lookup name (ecSolvedTypes ctx) of
            Just ty -> let ps = extractParamTypes ty
                       in if null ps then Nothing
                          else Just (SrcInferred, map (typeToRustString (ecRecordMap ctx)) ps)
            Nothing -> Nothing
    _ -> Nothing

-- | G1 (call-arg): the callee's Can.Type parameter at position `i`, for a
-- top-level / local fn whose solved sig is in scope. Used to seed the region
-- type of a `Result` ctor ARG (`f (Ok x)`) so it constructs the callee's
-- concrete `Result E A` slot rather than defaulting the payload to i64.
-- Kernel callees are excluded: their param strings (knownDefSig) carry T0/T1
-- tokens, not the real Sky Can.Type, so there's nothing concrete to recover.
calleeParamCanTypeAt :: EmitCtx -> Can.Expr -> Int -> Maybe Can.Type
calleeParamCanTypeAt ctx fn i = case fn of
    Ann.At _ (Can.VarTopLevel _ name) -> fromSig name
    Ann.At _ (Can.VarLocal name)      -> fromSig name
    _                                 -> Nothing
  where
    fromSig name = do
        ty <- case Map.lookup name (ecModuleEnv ctx) of
                  Just t  -> Just t
                  Nothing -> Map.lookup name (ecSolvedTypes ctx)
        let ps = extractParamTypes ty
        if i < length ps then Just (ps !! i) else Nothing

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
            -- NOT a bare `dict_empty()`: with two type params and no constraint
            -- (e.g. `Dict.keys Dict.empty`, dict_keys<K,V> generic) Rust can't
            -- infer K (E0282). Fall back to the String/i64 default — the
            -- historical behaviour before EKDict (00-standard-libs).
            EKDict    -> "dict_empty::<String, i64>()"
            EKSet     -> "set_empty::<i64>()"
        -- An INFERRABLE empty form (no turbofish): used only when a DATA sibling
        -- pins the type param, so Rust resolves K/V from the other args of the
        -- SAME call (e.g. `dict_insert("email", creds.email, dict_empty())` —
        -- K=String from the key, V=String from the value). The hardcoded
        -- `<String, i64>` `bare` is WRONG for a `Dict String String`; this lets
        -- inference pick the real V. Lists/Maybes already infer bare.
        inferrable = case kind of
            EKList    -> "vec![]"
            EKNothing -> "SkyMaybe::Nothing"
            EKDict    -> "dict_empty()"
            EKSet     -> "set_empty()"
        defaultFiller = case kind of
            EKList    -> "Vec::<i64>::new()"
            EKNothing -> "SkyMaybe::<i64>::Nothing"
            EKDict    -> "dict_empty::<String, i64>()"
            EKSet     -> "set_empty::<i64>()"
        -- Insert the turbofish "::" before the first '<' of a concrete param.
        turbofish pt = case break (== '<') pt of
            (h, rest@('<' : _)) -> Just $ case kind of
                EKList    | "Vec" == h        -> h ++ "::" ++ rest ++ "::new()"
                EKNothing | "SkyMaybe" == h   -> h ++ "::" ++ rest ++ "::Nothing"
                EKDict    | "HashMap" == h     -> "dict_empty::" ++ rest ++ "()"
                EKSet     | "BTreeSet" == h     -> "set_empty::" ++ rest ++ "()"
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
                -- EVERY type var of the empty collection is pinned by a data
                -- sibling — only then is the turbofish-free `inferrable` form
                -- sound (Rust resolves ALL params from the call's other args, e.g.
                -- `dict_insert("k", v, dict_empty())` pins both K and V). When some
                -- vars are pinned but others are NOT (`dict_get("k", dict_empty())`
                -- pins K but leaves V free → E0283), the hardcoded-default `bare`
                -- is still required so the type is fully concrete.
                allVarsPinned = not (null vars) && all (`elem` dataSiblingToks) vars
            in if null vars
               then case turbofish pt of
                   Just s | not (null s) -> s
                   _ -> bare
               else if allVarsPinned then inferrable
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
        -- Render the discard closure through `argToRustString`, not bare
        -- `exprToRustString`: the closure is the FIRST arg of a `task_*`
        -- combinator (an `Fn`-shaped stored value that outlives this scope), so it
        -- must `move`-capture + clone its environment. The bare Lambda arm emits a
        -- BORROWING `|_| { … body.clone() … }` which fails E0373 when the body
        -- references an owned local (`server_json(body)` in rebuildHealth). The
        -- arg path's move+clone shape is the proven one (mirrors every other
        -- task-combinator closure arg).
        let closeStr = argToRustString ctx False closeExpr
            taskStr  = emitPinnedTask ctx solved taskExpr
            restStrs = map (exprToRustString ctx) rest
        in Just $ nameStr ++ "(" ++ intercalate ", " (closeStr : taskStr : restStrs) ++ ")"
    | otherwise = Nothing
pinTaskCall _ _ _ _ = Nothing

emitPinnedTask :: EmitCtx -> Map.Map String Can.Type -> Can.Expr -> String
emitPinnedTask ctx solved (Ann.At _ (Can.Call fnExpr taskArgs)) =
    let fnStr0 = exprToRustString ctx fnExpr
        -- exprToRustString may already append a static turbofish (e.g.
        -- task_fail's `::<_, i64>` from the turbofish map). Strip it so the
        -- `::<_, ()>` pin below doesn't emit a double turbofish
        -- (`task_fail::<_, i64>::<_, ()>`); the `()` success type is the
        -- context-specific one (the wildcard closure ignores the value).
        fnStr = dropTurbofish fnStr0
        argStrs = map (exprToRustString ctx) taskArgs
        rendered = intercalate ", " argStrs
        -- The `::<_, ()>` pin is ONLY sound for a callee whose FIRST TWO generic
        -- params ARE the Task `<E, A>` (error, success) — i.e. the `task_*`
        -- combinators (`task_fail` / `task_succeed`). A generic kernel that
        -- merely RETURNS a Task but whose own type params are something else
        -- (`cache_put<K, V> -> Task<E, ()>`, `db_*<row>`) would have `<_, ()>`
        -- bind its FIRST params (K=infer, V=()) — wrong (E0308: V is the cache
        -- VALUE, not the task's success unit). Such kernels already carry a
        -- concrete success type in their runtime sig, so no pin is needed: emit
        -- them unchanged and let inference settle the unit success.
        isTaskCombinator = "task_" `isPrefixOf` fnStr
    in if isTaskCombinator
       then fnStr ++ "::<_, ()>(" ++ rendered ++ ")"
       else fnStr ++ "(" ++ rendered ++ ")"
emitPinnedTask ctx _ other = exprToRustString ctx other  -- fallback: no pin

-- | Truncate a callee string at its first `::<` turbofish (qualified paths use
-- `::` but never `::<`, so this only strips a turbofish, not a path segment).
dropTurbofish :: String -> String
dropTurbofish (a:b:c:rest) | [a,b,c] == "::<" = []           -- stop at turbofish
                           | otherwise        = a : dropTurbofish (b:c:rest)
dropTurbofish s = s

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
            pinE n
                | n == "task_fail" = n ++ taskFailPin ctx
                | n == "dict_empty" = n ++ dictEmptyPin ctx
                | n == "set_empty" = n ++ setEmptyPin ctx
                | otherwise = case Map.lookup n kernelsNeedingErrorPin of
                    Just suffix -> n ++ suffix
                    Nothing     -> n
            -- sub-A.11: zero-arg kernels (decode_*/json_decode_*, dict_empty, math_pi/e)
            -- returning a value (Decoder, HashMap, f64) reached via the
            -- "then" branch — append () to call them. Turbofish goes
            -- BEFORE the (), e.g. json_decode_int::<SkyError>().
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
                            -- Use the collision-renamed name for the actual
                            -- emission (kernel discrimination above stays on the
                            -- default `fnName`).
                            emitName = rustFnName (ecNameRenames ctx) modPrefix name
                        in if Set.member (modPrefix, name) (ecZeroArgDefs ctx) then emitName ++ pin ++ "()" else emitName ++ pin
    Can.VarKernel mod name ->
        let fnName = kernelToRust mod name
            -- sub-A.10 C4 + sub-A.11: per-kernel turbofish (E pinning + arity).
            tf = case Map.lookup fnName kernelsNeedingErrorPin of
                Just _ | fnName == "task_fail"  -> taskFailPin ctx
                Just _ | fnName == "dict_empty" -> dictEmptyPin ctx
                Just _ | fnName == "set_empty"  -> setEmptyPin ctx
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
        -- A phantom-polymorphic ADT nullary ctor (StdUiElement::Empty) can't
        -- infer its type param (E0282); turbofish it from the enclosing fn's
        -- return type when that type's head matches this ctor's type
        -- (`none : Element msg` body `Empty` -> `StdUiElement::<msg>::Empty`).
        -- typeToRustString renders TVars verbatim (`msg`), which the enclosing
        -- fn declares as a generic, so the name is in scope.
        | Just (Can.TType _ tyN tyArgs) <- ecEnclosingRet ctx
        , tyN == typeName, not (null tyArgs)
        , let rustArgs = map (typeToRustString (ecRecordMap ctx)) tyArgs
        -- ONLY when every arg is a DECLARED generic of the enclosing fn. A
        -- return-type TVar that isn't declared — a monomorphised `a`, a
        -- synthesised `_a_inst171` (subset-record machinery) — is not in scope,
        -- and `::<a>` is then E0412. A concrete tyArg likewise isn't a declared
        -- generic, so it's skipped — Rust infers the param from the return type.
        , not (null rustArgs), all (`elem` ecGenParams ctx) rustArgs
        , (tPart, _:_:vPart) <- break (== ':') (kernelCtorToRust modName typeName ctorName) ->
            tPart ++ "::<" ++ intercalate ", " rustArgs ++ ">::" ++ vPart
        | otherwise -> kernelCtorToRust modName typeName ctorName
    Can.Chr [c] -> rustCharLit c
    Can.Chr s -> rustStringLit s
    Can.Str s -> rustStringLit s ++ ".to_string()"
    -- An Int literal whose region the solver typed as Float (Sky's numeric-
    -- literal polymorphism: `Css.pct 100` where `pct : Float -> Length`) must
    -- emit as f64 — Rust does NOT coerce an i64 literal to f64 (E0308). Gate on
    -- the region's expected type so ordinary Int literals stay i64.
    Can.Int i
        | Just (Can.TType _ "Float" []) <- ecExpectedType ctx -> show i ++ "_f64"
        | otherwise -> show i
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
        | op == "|>", isTaskRunRef b, isBackendEntryApp a ->
            -- #24 tenet 2: `App {…} |> Task.run` — the backend driver future IS
            -- the program entry. Drop Task.run so the future is returned as a
            -- SkyTask (block_on'd by the entry / unified across a dispatching
            -- `case`), not executed inline via task_run.
            exprToRustString ctx a
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
        in "|" ++ intercalate ", " (map (annotClosureParam ctx body) params) ++ "| { " ++ exprToRustString ctx' body ++ " }"
    -- Ffi.callPure / Ffi.callTask peephole — literal kernel name + literal args
    -- list -> direct kernel call. Splits "Decimal_fromInt" -> ("Decimal",
    -- "fromInt"), looks up kernelToRust, emits the resolved kernel name with the
    -- args spliced inline.
    -- Ffi.toAny inside a matched args list collapses to identity (see peepholeArg).
    -- The deprecated Ffi.call alias gets the same treatment.
    -- callPure resolves to a pure/sync kernel; callTask resolves to a kernel
    -- that ALREADY returns a SkyTask (e.g. time_now : (()) -> SkyTask<E,i64>,
    -- file_write_file : (..) -> SkyTask<E,()>). The emission is identical — the
    -- resolved kernel's own return type carries the Task-ness, so NO extra
    -- ok_res/Task lift is applied (and none was applied on the callPure path
    -- either; the arm is a bare call). Double-wrapping a Task kernel's result
    -- would mistype the SkyTask, so the shared bare-call shape is exactly right.
    -- Non-matched shapes (variable kernel name, non-literal args list) fall
    -- through to the existing Can.Call arm, which routes to the polyfill via
    -- kernelToRust's "Ffi.callPure" / "Ffi.callTask" -> *_polyfill arm (the
    -- genuinely-dynamic no-reflection boundary).
    Can.Call (Ann.At _ (Can.VarKernel "Ffi" fnName))
             [Ann.At _ (Can.Str kernelName), Ann.At _ (Can.List argExprs)]
        | fnName == "callPure" || fnName == "call" || fnName == "callTask" ->
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
            -- Clear ecInResultCtorArg for the PAYLOAD: the flag scopes to THIS
            -- ctor only; a nested ctor inside the payload must judge itself afresh.
            "SkyResult::<" ++ rustErr ++ ", " ++ rustOk ++ ">::"
                ++ ctorName ++ "(" ++ exprToRustString (ctx { ecInResultCtorArg = False }) innerArg ++ ")"
    -- G1: the region carries no concrete expected type (a free Ok payload), so
    -- the concrete-both-sides arm above missed. Before defaulting the payload to
    -- i64, recover the real Result<E, A> from the ENCLOSING fn's return type —
    -- but ONLY when that return is itself a concrete `Result E A` AND we are not
    -- currently emitting a call ARGUMENT (`ecInResultCtorArg`). A ctor in a
    -- `Result`-returning body's TAIL/arm constructs exactly that type, so the
    -- enclosing return is the right turbofish (mirrors the Maybe-Nothing
    -- `ecEnclosingRet` recovery ~1014). A ctor that is a call ARGUMENT does NOT
    -- construct the enclosing return — its type is the CALLEE's param slot, which
    -- emitArg seeds precisely when concrete; when the callee param is polymorphic
    -- the arg must stay at the i64/inference default, NOT the enclosing return
    -- (that mis-pins `idResult (Ok n)` inside `wrap : Int -> Result Error String`
    -- to `String` though `n : Int`). emitArg sets `ecInResultCtorArg` so this arm
    -- declines for every Result-ctor call arg.
    --
    -- STRICT GATING (correctness-critical — never over-pin):
    --   * not (ecInGenericFn ctx)         — same as the i64 arm; inside a generic
    --       fn Rust infers from the sig and a turbofish would clobber it.
    --   * not (ecInResultCtorArg ctx)     — never fire for a CALL ARGUMENT ctor
    --       (its type is the callee's param, not the enclosing return).
    --   * ecExpectedType absent OR a Result whose payload is free — i.e. we are
    --       genuinely DEFAULTING (the concrete arm did not fire). A Task-shaped
    --       expected type is EXCLUDED so a `Result` ctor inside a Task-returning
    --       body is never pinned to the Task's payload.
    --   * ecEnclosingRet is a concrete `Result E A` (NOT Task — a Result ctor
    --       never builds a Task's value slot). A polymorphic enclosing return
    --       (the passthrough `Result Error a`) also fails this guard, so we keep
    --       the i64 default rather than pin a polymorphic fn.
    Can.Call (Ann.At _ (Can.VarCtor _ _ "Result" ctorName _)) [innerArg]
        | (ctorName == "Ok" || ctorName == "Err")
        , not (ecInGenericFn ctx)
        , not (ecInResultCtorArg ctx)
        , expectedIsFreeResultOrAbsent (ecExpectedType ctx)
        , Just (errTy, okTy) <- enclosingResultPayload (ecEnclosingRet ctx)
        , Just rustErr <- rustifyExpectedType (ecRecordMap ctx) errTy
        , Just rustOk  <- rustifyExpectedType (ecRecordMap ctx) okTy ->
            "SkyResult::<" ++ rustErr ++ ", " ++ rustOk ++ ">::"
                ++ ctorName ++ "(" ++ exprToRustString (ctx { ecInResultCtorArg = False }) innerArg ++ ")"
    -- monomorphic fn, type not fully concrete -> default the unconstrained
    -- side. Err carries Sky's Error idiom (Cardinal Rule 1); the Ok side is
    -- phantom so i64 is a safe filler. Inside a GENERIC fn this arm does not
    -- match, so control falls through to the generic Can.Call path below, where
    -- Rust infers from the signature.
    Can.Call (Ann.At _ (Can.VarCtor _ _ "Result" ctorName _)) [innerArg]
        | (ctorName == "Ok" || ctorName == "Err")
        , not (ecInGenericFn ctx) ->
            "SkyResult::<SkyError, i64>::" ++ ctorName
                ++ "(" ++ exprToRustString (ctx { ecInResultCtorArg = False }) innerArg ++ ")"  -- default (Task 8: stderr warning)
    -- Partially-applied CONSTRUCTOR used as a function value (the canonical TEA
    -- `Cmd.perform task (JobDone jid)` where `JobDone : Int -> Result Error
    -- String -> Msg` — `JobDone jid` is the `Result -> Msg` toMsg). The codegen
    -- otherwise emits `MainMsg::JobDone(jid)` — 1 arg to a 2-arg variant → E0061.
    -- Synthesise a move closure capturing the supplied args and taking the rest.
    Can.Call (Ann.At _ (Can.VarCtor _ mn tn cn _)) args
        | Just fieldTys <- Map.lookup cn (ecCtorFieldTypes ctx)
        , length args < length fieldTys ->
            let ctorName  = kernelCtorToRust mn tn cn
                provided  = map (argToRustString ctx False) args
                nMissing  = length fieldTys - length args
                extras    = [ "__pa" ++ show k | k <- [1 .. nMissing] ]
            in "(move |" ++ intercalate ", " extras ++ "| " ++ ctorName
               ++ "(" ++ intercalate ", " (provided ++ extras) ++ "))"
    -- #24 tenet 2 (prefix form): `Task.run (App {…})` — same as the `|>` arm,
    -- the backend driver future is the entry; drop Task.run.
    Can.Call taskRunFn [appArg]
        | isTaskRunRef taskRunFn, isBackendEntryApp appArg ->
            exprToRustString ctx appArg
    -- Sub-E: Cli.program { init, update, view, subscriptions, onLine } — the cfg
    -- is an anonymous record the runtime can't name, so splice its fields into
    -- the generic cli_program(init, update, view, subs, onLine) directly.
    Can.Call (Ann.At _ (Can.VarKernel "Cli" "program")) [Ann.At _ (Can.Record fields)] ->
        let fld n = case Map.lookup n fields of
                Just e  -> exprToRustString ctx e
                Nothing -> "/* Cli.program: missing field " ++ n ++ " */"
        in "cli_program(" ++ intercalate ", "
               (map fld ["init", "update", "view", "subscriptions", "onLine"]) ++ ")"
    -- Sky.Tui — Tui.program { init, update, view, subscriptions, onKey } — like
    -- Cli.program, but the runtime `tui_app` takes onKey as Fn(String, String) ->
    -- Msg (raw key kind+value), so wrap the user's `onKey : KeyEvent -> Msg` in a
    -- closure that builds the `KeyEvent { kind, value }` record (its Rust struct
    -- name comes from onKey's solved param type). view returns a String here.
    Can.Call (Ann.At _ (Can.VarKernel "Tui" "program")) [Ann.At _ (Can.Record fields)] ->
        let fld n = case Map.lookup n fields of
                Just e  -> exprToRustString ctx e
                Nothing -> "/* Tui.program: missing field " ++ n ++ " */"
            keyEventTy = case Map.lookup "onKey" (ecSolvedTypes ctx) of
                Just ty -> case extractParamTypes ty of
                    (k : _) -> typeToRustString (ecRecordMap ctx) k
                    []      -> "/* Tui.program: onKey param type */"
                Nothing -> "/* Tui.program: onKey type */"
            onKeyWrapper = "{ let __ok = " ++ fld "onKey"
                ++ "; move |kind: String, value: String| __ok(" ++ keyEventTy
                ++ " { kind, value }) }"
        in "tui_app(" ++ intercalate ", "
               [fld "init", fld "update", fld "view", fld "subscriptions", onKeyWrapper] ++ ")"
    -- Sky.Tui — Tui.app { init, update, view, subscriptions, onKey } — the
    -- Std.Ui Element backend. `view : model -> Element msg` returns a BARE Element
    -- (the shared structured tree, now a runtime type — `sky_runtime::ui::Element`).
    -- The driver `tui_app_ui` takes `Element<Msg>` directly and walks the typed
    -- attributes to ANSI cells (`tui::layout::element_to_cells`, Go parity) — NO
    -- `Ui.layout`, no Html, no CSS. Because the Tui path never touches the Std.Ui
    -- → Html render chain, there is nothing for whole-program DCE to prune, so the
    -- earlier `Dce` cross-module-seed concern is gone (the redesign dissolved it).
    -- The onKey wrapper is identical to Tui.program's.
    Can.Call (Ann.At _ (Can.VarKernel "Tui" "app")) [Ann.At _ (Can.Record fields)] ->
        let fld n = case Map.lookup n fields of
                Just e  -> exprToRustString ctx e
                Nothing -> "/* Tui.app: missing field " ++ n ++ " */"
            keyEventTy = case Map.lookup "onKey" (ecSolvedTypes ctx) of
                Just ty -> case extractParamTypes ty of
                    (k : _) -> typeToRustString (ecRecordMap ctx) k
                    []      -> "/* Tui.app: onKey param type */"
                Nothing -> "/* Tui.app: onKey type */"
            onKeyWrapper = "{ let __ok = " ++ fld "onKey"
                ++ "; move |kind: String, value: String| __ok(" ++ keyEventTy
                ++ " { kind, value }) }"
        in "tui_app_ui(" ++ intercalate ", "
               [fld "init", fld "update", fld "view", fld "subscriptions", onKeyWrapper] ++ ")"
    -- Sky.Webview — Webview.app { init, update, view, subscriptions, window } —
    -- native desktop TEA backend. Same `view : Model -> any` shape as Tui.app, so
    -- the view wraps in `Ui.layout` to yield `Html`. The `window` field is a
    -- `{ title, size }` record literal, converted to the runtime's
    -- `WebviewWindowCfg`. Cross-platform: the stub `webview_app` returns a
    -- graceful Err where the system webview libs are absent (Go-parity with
    -- webview_stub.go); the real wry/tao backend lives behind the webview feature.
    Can.Call (Ann.At _ (Can.VarTopLevel wvMod "app")) [Ann.At _ (Can.Record fields)]
        | ModuleName._name wvMod == "Std.Webview" ->
        let fld n = case Map.lookup n fields of
                Just e  -> exprToRustString ctx e
                Nothing -> "/* Webview.app: missing field " ++ n ++ " */"
            windowExpr = case Map.lookup "window" fields of
                Just (Ann.At _ (Can.Record wfields)) ->
                    let wf n = case Map.lookup n wfields of
                            Just e  -> exprToRustString ctx e
                            Nothing -> "/* Webview.app: window missing " ++ n ++ " */"
                    in "WebviewWindowCfg { title: " ++ wf "title" ++ ", size: " ++ wf "size" ++ " }"
                _ -> "/* Webview.app: window must be a record literal */"
        in "webview_app(" ++ intercalate ", "
               [fld "init", fld "update", fld "view", fld "subscriptions", windowExpr] ++ ")"
    -- Live.app { init, update, view, subscriptions, routes, notFound } —
    -- record-splice like Cli.program. P3: branch on whether the Model record
    -- carries a `page` field.
    --   * No `page` field (counter / form — single-page): emit `live_app` with
    --     the four TEA callbacks; routes/notFound dropped. Byte-identical to P1.
    --   * Has `page` field: emit `live_app_routed` with the route table, the
    --     notFound page, and a generated `set_page` closure that writes the
    --     matched Page into `model.page`. The runtime route_resolver does the
    --     match-and-inject on every GET (Go parity).
    Can.Call (Ann.At _ (Can.VarKernel "Live" "app")) [Ann.At _ (Can.Record fields)] ->
        let fld n = case Map.lookup n fields of
                Just e  -> exprToRustString ctx e
                Nothing -> "/* Live.app: missing field " ++ n ++ " */"
            -- #24 tenet 4 (Option A): the `init` arg must satisfy live_app's
            -- `FInit: Fn(LiveReq) -> …` bound. A req-reading init (∈
            -- ecLiveReqInitFns) already has param 0 pinned to LiveReq, so pass it
            -- straight through. A NON-req init keeps a natural param (`()` / a
            -- free generic) so the SAME init can also feed `Tui.app` (`Fn(())`);
            -- here we adapt it to live_app by discarding the request:
            -- `move |_r: LiveReq| init(())`. The closure forces the param to `()`,
            -- which fits both a `()` annotation and a free-generic param.
            liveInitArg = case Map.lookup "init" fields of
                Just initE@(Ann.At _ initInner) ->
                    let iname = case initInner of
                            Can.VarTopLevel _ n -> n
                            Can.VarLocal n      -> n
                            _                   -> ""
                        base = exprToRustString ctx initE
                    in if Set.member iname (ecLiveReqInitFns ctx)
                       then base
                       else "{ let __sky_init = " ++ base
                              ++ "; move |_r: sky_runtime::LiveReq| __sky_init(()) }"
                Nothing -> "/* Live.app: missing field init */"
            rm = ecRecordMap ctx
            -- Recover Model from view's solver type: `view : Model -> Html Msg`.
            mModelTy = case Map.lookup "view" (ecSolvedTypes ctx) of
                Just ty -> case extractParamTypes ty of
                    (m : _) -> Just m
                    []      -> Nothing
                Nothing -> Nothing
            -- Resolve a type to its record-field map (peel the alias wrapper).
            recordFieldsOf ty = case ty of
                Can.TRecord fs _        -> Just fs
                Can.TAlias _ _ _ (Can.Hoisted inner) -> recordFieldsOf inner
                Can.TAlias _ _ _ (Can.Filled inner)  -> recordFieldsOf inner
                _                       -> Nothing
            mModelFields = mModelTy >>= recordFieldsOf
            mPageFieldTy = mModelFields >>= Map.lookup "page"
            -- P5-T4b: the runtime's live_app / live_app_routed take two trailing
            -- store-config string args (kind, path) — choose_store builds the
            -- backend (empty kind -> memory). Drawn from `[live] store` /
            -- `storePath`; `show` quotes/escapes them into Rust string literals.
            (storeKind0, storePath0) = ecLiveStore ctx
            storeKindLit = show storeKind0 ++ ".to_string()"
            storePathLit = show storePath0 ++ ".to_string()"
        in case (mModelTy, mPageFieldTy) of
            (Just modelTy, Just (Can.FieldType _ pageTy)) ->
                -- Routing mode.
                let modelRustTy = typeToRustString rm modelTy
                    pageRustTy = typeToRustString rm pageTy
                    routesStr = case Map.lookup "routes" fields of
                        Just (Ann.At _ (Can.List elems)) ->
                            "vec![" ++ intercalate ", " (map (exprToRustString ctx) elems) ++ "]"
                        Just other -> exprToRustString ctx other
                        Nothing    -> "vec![]"
                    notFoundStr = fld "notFound"
                    setPage = "move |__page: " ++ pageRustTy ++ ", __model: " ++ modelRustTy
                                ++ "| " ++ modelRustTy ++ " { page: __page, ..__model }"
                in "live_app_routed::<SkyError, _, _, _, _, _, _, _, _>(" ++ intercalate ", "
                       ([liveInitArg, fld "update", fld "view", fld "subscriptions",
                         routesStr, notFoundStr, setPage, storeKindLit, storePathLit]) ++ ")"
            _ ->
                -- Single-page mode (no page field): four TEA callbacks; pin E.
                "live_app::<SkyError, _, _, _, _, _, _>(" ++ intercalate ", "
                    ([liveInitArg] ++ map fld ["update", "view", "subscriptions"] ++ [storeKindLit, storePathLit]) ++ ")"
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
    -- Sky.Live: `EventAttr (Event msg)` and `OnRaw String any` bridge to the
    -- runtime html::Attribute / html::Event enums. OnRaw's payload is the
    -- heterogeneous `any` handler (from `on` / `onSubmit`); the runtime field is
    -- `Arc<dyn Any + Send + Sync>`, so type-erase the generated handler arg with
    -- Arc::new(...). OnMsg/OnString/OnBool need no wrap (value / fn-pointer).
    Can.Call ctorFn@(Ann.At _ (Can.VarCtor _ _ "Event" "OnRaw" _)) [nameArg, handlerArg] ->
        exprToRustString ctx ctorFn ++ "(" ++ exprToRustString ctx nameArg
            ++ ", std::sync::Arc::new(" ++ exprToRustString ctx handlerArg ++ "))"
    -- `Event::OnString`/`OnBool` carry `Arc<dyn Fn(..) -> M + Send + Sync>` (the
    -- handler may be a CAPTURING closure — `onChange = \s -> toMsg (parse s)` in
    -- a faithful Sky.Live app, exactly as Go allows). Both a capturing lambda AND
    -- a bare ctor/fn ref (`onChange = UpdateRemarks`) must Arc-wrap to match the
    -- field: a lambda boxes into the trait object; a bare fn coerces into
    -- `Arc::new`. `wrapStoredFn True` handles both (it Arc-wraps a lambda with
    -- pre-cloned captures, and Arc-wraps a fn-region non-lambda). Non-fn handler
    -- shapes (a partially-applied `Msg`-returning expr that is itself the fn) also
    -- flow through wrapStoredFn's fallback unchanged when the region isn't a fn.
    Can.Call ctorFn@(Ann.At _ (Can.VarCtor _ _ "Event" ev _)) [nameArg, handlerArg]
        | ev == "OnString" || ev == "OnBool" ->
            -- `wrapNonLambda=False, targetIsArcFn=True`: the html::Event field IS
            -- `Arc<dyn Fn>`, so Arc-wrap a CAPTURING lambda (its own arm) or a bare
            -- fn ITEM (the event-cb arm, now gated on `targetIsArcFn`) — but NOT a
            -- `VarLocal` that already holds the Arc-typed callback (the stdlib
            -- chain's `OnString "input" handler`, where `handler : Arc<dyn Fn>`).
            -- `wrapNonLambda=True` here would re-wrap that VarLocal via the
            -- `wrapNonLambda && isFnRegion` path → `Arc<Arc<dyn Fn>>`; keeping it
            -- False but `targetIsArcFn=True` wraps only fn ITEMS (never VarLocal).
            exprToRustString ctx ctorFn ++ "(" ++ exprToRustString ctx nameArg
                ++ ", " ++ wrapStoredFn False True ctx handlerArg (exprToRustString ctx handlerArg) ++ ")"
    -- P2-T4: `Ev.onSubmit handler` call-site peephole. `Std.Html.Events.onSubmit`
    -- is a .sky stdlib fn `onSubmit handler = EventAttr (OnRaw "submit" handler)`
    -- whose body type-erases the handler to `any` — so the concrete form-record
    -- type `T` is invisible at the OnRaw arm above. `T` is ONLY known HERE, at the
    -- call site. So we INLINE the call straight to `Event::OnForm("submit", ...)`,
    -- bypassing the stdlib fn + the OnRaw path entirely. The OnForm closure decodes
    -- the wire FormData into `T` via decode_form::<T> and dispatches the Msg; a
    -- malformed/incomplete form decodes to Err -> `.ok()` -> None -> no Msg.
    -- P3-T3: `Live.route pattern ctor` lowers to a `route::Route::new`. The
    -- ctor is a Page constructor; the captured `:param` strings (in pattern
    -- order) are applied to it in the build closure. The ctor arity N is read
    -- from the ctor arg's solver type (looked up in ecRegionTypes): N==0 is a
    -- nullary page value (captured + cloned per build); N>=1 applies the
    -- params positionally. `Route::new` takes `&str`, so the pattern (a Sky
    -- string literal → `"…".to_string()`) is borrowed with `&(…)`.
    Can.Call (Ann.At _ (Can.VarKernel "Live" "route")) [patternArg, ctorArg@(Ann.At hregion _)] ->
        let patternStr = exprToRustString ctx patternArg
            ctorStr = exprToRustString ctx ctorArg
            ctorArity = case Map.lookup hregion (ecRegionTypes ctx) of
                Just ty -> length (extractParamTypes ty)
                Nothing -> 0
            closure =
                if ctorArity == 0
                    then "{ let __c = " ++ ctorStr ++ "; move |_p: Vec<String>| __c.clone() }"
                    else "move |__p: Vec<String>| " ++ ctorStr ++ "("
                            ++ intercalate ", " ["__p[" ++ show i ++ "].clone()" | i <- [0 .. ctorArity - 1]]
                            ++ ")"
        in "route::Route::new(&(" ++ patternStr ++ "), " ++ closure ++ ")"
    Can.Call (Ann.At _ (Can.VarTopLevel mdl "onSubmit")) [handlerArg@(Ann.At hregion _)]
        | ModuleName._name mdl == "Std.Html.Events" ->
            let handlerStr = exprToRustString ctx handlerArg
                mHandlerTy = Map.lookup hregion (ecRegionTypes ctx)
            in case formTargetRustType (ecRecordMap ctx) mHandlerTy of
                Just rustT ->
                    -- record-handler case: `onSubmit DoSignIn` where
                    -- `DoSignIn : Creds -> Msg`. Decode wire form -> Creds -> Msg.
                    "Attribute::EventAttr(Event::OnForm(\"submit\".to_string(), "
                        ++ "std::sync::Arc::new({ let __h = " ++ handlerStr ++ "; "
                        ++ "move |fd| sky_runtime::decode_form_or_warn::<" ++ rustT
                        ++ ">(fd).map(|t| __h(t)) })))"
                Nothing ->
                    -- bare-Msg case: `onSubmit SomeMsg`. Ignore the form payload;
                    -- always dispatch the (Clone) Msg.
                    "Attribute::EventAttr(Event::OnForm(\"submit\".to_string(), "
                        ++ "std::sync::Arc::new({ let __m = " ++ handlerStr ++ "; "
                        ++ "move |_fd| Some(__m.clone()) })))"
    -- `Std.Ui.onSubmit handler` (= `AttrEvent (Event.onSubmit handler)`). Same
    -- call-site inline as Events.onSubmit, but the form type `T` is known HERE
    -- (`Ui.onSubmit DoSignIn`) not inside Ui.onSubmit's `a -> Attribute b` body
    -- where the handler is a generic param — so the OnRaw/`any` path emits a
    -- broken `Some(a)` against the OnForm `Option<b>` slot, and the generic
    -- bound on `a` (PartialEq/Debug) rejects a fn item. Inline + wrap in the
    -- Std.Ui Attribute's AttrEvent; the generic Ui.onSubmit body then DCEs out.
    Can.Call (Ann.At _ (Can.VarTopLevel mdl "onSubmit")) [handlerArg@(Ann.At hregion _)]
        | ModuleName._name mdl == "Std.Ui" ->
            let handlerStr = exprToRustString ctx handlerArg
                mHandlerTy = Map.lookup hregion (ecRegionTypes ctx)
                inner = case formTargetRustType (ecRecordMap ctx) mHandlerTy of
                    Just rustT ->
                        "Attribute::EventAttr(Event::OnForm(\"submit\".to_string(), "
                            ++ "std::sync::Arc::new({ let __h = " ++ handlerStr ++ "; "
                            ++ "move |fd| sky_runtime::decode_form_or_warn::<" ++ rustT
                            ++ ">(fd).map(|t| __h(t)) })))"
                    Nothing ->
                        "Attribute::EventAttr(Event::OnForm(\"submit\".to_string(), "
                            ++ "std::sync::Arc::new({ let __m = " ++ handlerStr ++ "; "
                            ++ "move |_fd| Some(__m.clone()) })))"
            in "StdUiAttribute::AttrEvent(" ++ inner ++ ")"
    -- ─── Db.insertFields / Db.updateFields / Db.insertFieldsReturning ─────────
    --
    -- These kernels receive `List (String, SqlField)` (and for updateFields,
    -- `List (String, SqlValue)` for WHERE cols) where `SqlField` / `SqlValue`
    -- are per-project GENERATED Rust enums (`StdDbSqlField`, `StdDbSqlValue`).
    -- The runtime functions (`db_insert_fields` etc.) take `Vec<(String, Option<SqlParam>)>`
    -- where `SqlParam` IS a runtime-nameable enum.  Codegen converts inline.
    --
    -- Inline conversion helpers (always emitted as closures to avoid naming
    -- the generated enums in the runtime):
    --
    --   sql_value_to_param  : StdDbSqlValue → SqlParam
    --   sql_field_to_option : StdDbSqlField → Option<SqlParam>
    --   fields_to_vec       : List (String, SqlField) → Vec<(String, Option<SqlParam>)>
    --   where_to_vec        : List (String, SqlValue) → Vec<(String, SqlParam)>
    --
    -- Security: table / column name validation is in the RUNTIME (`valid_sql_ident`);
    -- values are positionally bound, never interpolated — same guarantee as Go.
    -- Totality: SqlParam is exhaustive; `SqlNull` → SqlParam::Null; no panic.
    --
    -- SqlMoney serialisation matches Go's `sqlMoneyToString`:
    --   `"ISO_CODE AMOUNT"` TEXT — the inverse of `db_decode_money`.
    --   Currency enum variants USD/EUR/… have their Sky name as the code;
    --   CurrencyRaw carries the raw code string.
    -- VarKernel form (accessed directly as a kernel)
    Can.Call (Ann.At _ (Can.VarKernel modDb "insertFields")) [connArg, tableArg, fieldsArg]
        | modDb == "Db" || modDb == "Std.Db" ->
            "db_insert_fields("
                ++ exprToRustString ctx connArg ++ ", "
                ++ exprToRustString ctx tableArg ++ ", "
                ++ sqlFieldsToVec ctx fieldsArg ++ ")"
    Can.Call (Ann.At _ (Can.VarKernel modDb "updateFields")) [connArg, tableArg, whereArg, fieldsArg]
        | modDb == "Db" || modDb == "Std.Db" ->
            "db_update_fields("
                ++ exprToRustString ctx connArg ++ ", "
                ++ exprToRustString ctx tableArg ++ ", "
                ++ sqlWhereToVec ctx whereArg ++ ", "
                ++ sqlFieldsToVec ctx fieldsArg ++ ")"
    Can.Call (Ann.At _ (Can.VarKernel modDb "insertFieldsReturning")) [connArg, tableArg, fieldsArg, projArg, decArg]
        | modDb == "Db" || modDb == "Std.Db" ->
            "db_insert_fields_returning("
                ++ exprToRustString ctx connArg ++ ", "
                ++ exprToRustString ctx tableArg ++ ", "
                ++ sqlFieldsToVec ctx fieldsArg ++ ", "
                ++ exprToRustString ctx projArg ++ ", "
                ++ exprToRustString ctx decArg ++ ")"
    -- VarTopLevel form (accessed via `import Std.Db as Db` — Ffi.kernel alias
    -- resolves to VarTopLevel after canonicalisation, not VarKernel)
    Can.Call (Ann.At _ (Can.VarTopLevel mdlDb "insertFields")) [connArg, tableArg, fieldsArg]
        | let mn = ModuleName._name mdlDb in mn == "Std.Db" || mn == "Db" ->
            "db_insert_fields("
                ++ exprToRustString ctx connArg ++ ", "
                ++ exprToRustString ctx tableArg ++ ", "
                ++ sqlFieldsToVec ctx fieldsArg ++ ")"
    Can.Call (Ann.At _ (Can.VarTopLevel mdlDb "updateFields")) [connArg, tableArg, whereArg, fieldsArg]
        | let mn = ModuleName._name mdlDb in mn == "Std.Db" || mn == "Db" ->
            "db_update_fields("
                ++ exprToRustString ctx connArg ++ ", "
                ++ exprToRustString ctx tableArg ++ ", "
                ++ sqlWhereToVec ctx whereArg ++ ", "
                ++ sqlFieldsToVec ctx fieldsArg ++ ")"
    Can.Call (Ann.At _ (Can.VarTopLevel mdlDb "insertFieldsReturning")) [connArg, tableArg, fieldsArg, projArg, decArg]
        | let mn = ModuleName._name mdlDb in mn == "Std.Db" || mn == "Db" ->
            "db_insert_fields_returning("
                ++ exprToRustString ctx connArg ++ ", "
                ++ exprToRustString ctx tableArg ++ ", "
                ++ sqlFieldsToVec ctx fieldsArg ++ ", "
                ++ exprToRustString ctx projArg ++ ", "
                ++ exprToRustString ctx decArg ++ ")"
    -- DbDec.money col — the runtime `db_decode_money` decodes the "CODE AMOUNT"
    -- column into a `(Decimal, String)` pair; the GENERATED `Money` ADT can only
    -- be NAMED at the codegen boundary, so wrap the pair into
    -- `StdMoneyMoney::Money(amount, CurrencyRaw(code))` via the shared decode_map.
    -- CurrencyRaw(code) needs no code→enum table and round-trips (sqlValueMatchArms
    -- reads CurrencyRaw back to the code). Both VarKernel + VarTopLevel forms.
    Can.Call (Ann.At _ (Can.VarKernel mdlMD "money")) [colArg]
        | mdlMD == "DbDec" || mdlMD == "Std.Db.Decode" -> dbDecMoneyWrap ctx colArg
    Can.Call (Ann.At _ (Can.VarTopLevel mdlMD "money")) [colArg]
        | let mn = ModuleName._name mdlMD in mn == "DbDec" || mn == "Std.Db.Decode" ->
            dbDecMoneyWrap ctx colArg
    Can.Call fn args ->
        let calleeRendered = exprToRustString ctx fn
            -- Does this call's own region resolve to an effectful arrow
            -- (`… -> Task …`)? That's the `Handler` shape — a value flowing into
            -- an `Arc<dyn Fn>` slot (typeToRustString / paramTypeToRust render
            -- Task-arrows that way). A partial-app residual that lands here must
            -- be Arc-wrapped to match.
            -- Arc-wrap when this partial application's RESIDUAL is a `Handler`
            -- (`… -> Task …`): the callee's fully-applied result is a `Task`, so a
            -- short application yields a `… -> Task …` value (`handleRegister cfg
            -- db`, `rateLimit … h`). Such a value flows into an `Arc<dyn Fn>` slot
            -- — a middleware-wrapping closure's `Arc` param OR (after unsizing) a
            -- `server_api` arg. The bare `move` closure is wrapped to `Arc::new(…)`
            -- (an `Arc<{concrete closure}>`); the runtime's `IntoServerHandler` has
            -- an `Arc<F: Fn>` impl so that form registers, and it unsizes to
            -- `Arc<dyn Fn>` at a concrete Handler param. The list-HOF partial-app
            -- shape (`validateTime now : String -> Result …`, non-Task result) is
            -- never wrapped. The ecExpectedType fallback covers a Handler arg whose
            -- value is not a partial app (a bare local ref handled elsewhere).
            calleeResultIsTask = case fn of
                Ann.At _ (Can.VarTopLevel _ fnName) ->
                    maybe False (resultIsTaskTy . extractReturnType) (Map.lookup fnName (ecSolvedTypes ctx))
                Ann.At _ (Can.VarLocal fnName) ->
                    maybe False (resultIsTaskTy . extractReturnType) (Map.lookup fnName (ecSolvedTypes ctx))
                _ -> False
            regionIsTaskArrow = calleeResultIsTask
                            || case ecExpectedType ctx of
                                   Just rt@(Can.TLambda _ _) -> resultIsTaskTy (snd (flattenArrowType rt))
                                   _                         -> False
            -- Arc-wrap a `move` closure rendered string, pre-cloning its captured
            -- outer vars so the Arc owns them (`'static`); mirrors wrapStoredFn's
            -- Lambda arm. `caps` are already cloned at-use inside the closure, so
            -- the prelude only needs to keep the OUTER value alive.
            arcWrapClosure caps s =
                let preClones = concatMap (\v -> "let " ++ rustSafeIdent v ++ " = " ++ rustSafeIdent v ++ ".clone(); ") caps
                in if null caps
                   then "std::sync::Arc::new(" ++ s ++ ")"
                   else "{ " ++ preClones ++ "std::sync::Arc::new(" ++ s ++ ") }"
            -- A call whose callee is a record FIELD access (`rec.field args`) is
            -- calling a function-typed field. Rust parses `rec.field(args)` as a
            -- method call (E0599 — no such method). Sky records have no methods, so
            -- the field is a stored closure: parenthesise to a field call,
            -- `(rec.field)(args)`. (The console's StateStore callback record.)
            calleeName = case fn of
                Ann.At _ (Can.Access _ _) -> "(" ++ calleeRendered ++ ")"
                _ -> calleeRendered
            -- sub-A.12 F2: detect partial application (Sky source has currying;
            -- Rust doesn't). If the callee is a top-level fn with known arity > supplied,
            -- wrap the residual args in a `move |..| f(supplied.., residual..)` closure.
            -- Arity from the solved sig; falls back to the sibling def's param
            -- count (ecSiblingFns) when the flat solvedTypes map misses it — a
            -- same-module partial app `viewAlertRow model` whose 2-arity isn't
            -- in solvedTypes was otherwise emitted as a direct 1-arg call
            -- (E0061 + "expected Fn closure, found Html"; 17-skymon).
            siblingArity nm = maybe 0 (length . fst) (Map.lookup nm (ecSiblingFns ctx))
            calleeArity = case fn of
                -- The siblingArity fallback is keyed on the BARE name, so it must
                -- only fire for a TRUE same-module sibling — a QUALIFIED
                -- cross-module call (`Decimal.fromString` from Std.Money, whose
                -- own `fromString` has a different arity) would otherwise collide
                -- and wrongly partial-apply (00-standard-libs regression). Require
                -- the VarTopLevel's module == the current module.
                Ann.At _ (Can.VarTopLevel m fnName) ->
                    case Map.lookup fnName (ecSolvedTypes ctx) of
                        Just ty | n <- length (extractParamTypes ty), n > 0 -> n
                        _ | ModuleName._name m == ecCurrentModule ctx -> siblingArity fnName
                        _ -> 0
                Ann.At _ (Can.VarLocal fnName) -> siblingArity fnName
                _ -> 0
            isPartialApp = calleeArity > length args && not (null args)
            -- arity of the constructor/function handed to `succeed` (multi-arg
            -- lambda, or a top-level ctor/fn ref) so it can be curried into the
            -- single-arg-per-field pipeline chain. Lazy: only forced when args ≠ [].
            succeedArgArity = case head args of
                Ann.At _ (Can.Lambda ps _) | length ps > 1 -> Just (length ps)
                Ann.At _ (Can.VarTopLevel _ fnName) ->
                    case Map.lookup fnName (ecSolvedTypes ctx) of
                        Just ty | let n = length (extractParamTypes ty), n > 1 -> Just n
                        _ -> case Map.lookup fnName (ecCtorArity ctx) of
                            Just n | n > 1 -> Just n
                            _ -> Nothing
                _ -> Nothing
            succeedArity = case fn of
                Ann.At _ (Can.VarKernel _ name) | name == "succeed", not (null args) -> succeedArgArity
                -- Json.Decode.Pipeline base `succeed f` lowers as a VarTopLevel
                -- kernel alias (decode_succeed), not a VarKernel, so match it
                -- too — otherwise a multi-field record ctor stays a raw N-ary
                -- closure the single-arg pipeline can't apply (35-composite).
                -- Both the JSON pipeline (Sky.Core.Json.Decode.Pipeline) and the
                -- DB decoder (Std.Db.Decode) lower `succeed Ctor` to decode_succeed
                -- and feed it a `decode_pipeline_required` chain that applies one arg at
                -- a time — so a multi-arg record ctor MUST be curried (curryN) for
                -- both. Match either decode module's `succeed`.
                Ann.At _ (Can.VarTopLevel m name)
                    | name == "succeed"
                    , "Json.Decode" `isInfixOf` ModuleName._name m
                      || "Db.Decode" `isInfixOf` ModuleName._name m
                    , not (null args) -> succeedArgArity
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
                   -- The supplied args are CAPTURED into a `move` Fn closure
                   -- (list HOFs call it per element), so each non-Copy captured
                   -- var must clone at use or the first call moves it out (E0507
                   -- on `canViewMonitor session` partial-applied into a filter).
                   capturedSupplied = Set.unions (map collectVarLocals args)
                   ctxS = ctx { ecCloneVars = Set.union (ecCloneVars ctx) capturedSupplied }
                   -- The callee's solved param types, used to detect a supplied
                   -- arg whose param slot is an effectful `Handler` (`… -> Task …`,
                   -- rendered `impl Fn` by paramTypeToRust). A supplied VALUE of
                   -- that param can be an `Arc<dyn Fn>` (it came from a
                   -- `Handler`-typed binding) — which does NOT satisfy `impl Fn`.
                   -- Re-dispatch it through a fresh plain closure `{ let __h =
                   -- v.clone(); move |a| __h(a) }`: that closure satisfies `impl
                   -- Fn` (and any `IntoServerHandler` / fn-pointer slot too), so the
                   -- conversion is universally safe. Non-Handler args are emitted
                   -- byte-identically.
                   calleeParamTys = case fn of
                       Ann.At _ (Can.VarTopLevel _ fnName) ->
                           maybe [] extractParamTypes (Map.lookup fnName (ecSolvedTypes ctx))
                       Ann.At _ (Can.VarLocal fnName) ->
                           maybe [] extractParamTypes (Map.lookup fnName (ecSolvedTypes ctx))
                       _ -> []
                   paramTyAt i = if i < length calleeParamTys then Just (calleeParamTys !! i) else Nothing
                   isHandlerParam i = case paramTyAt i of
                       Just pt@(Can.TLambda _ _) -> resultIsTaskTy (snd (flattenArrowType pt))
                       _ -> False
                   redispatch pt rendered =
                       let (ps, _) = flattenArrowType pt
                           lamArgs = ["__h" ++ show k | k <- [1 .. length ps]]
                       in "{ let __hcb = " ++ rendered ++ "; move |" ++ intercalate ", " lamArgs
                          ++ "| __hcb(" ++ intercalate ", " lamArgs ++ ") }"
                   suppliedStrs =
                       [ case (isHandlerParam i, paramTyAt i) of
                             (True, Just pt) -> redispatch pt (exprToRustString ctxS a)
                             _               -> exprToRustString ctxS a
                       | (i, a) <- zip [0..] args ]
                   -- The closure `move`-captures those vars, so the OUTER value
                   -- would be moved away and unusable afterwards (E0382 on
                   -- `List.map (viewAlertRow model) …` where model is used again
                   -- for the list arg). Capture CLONES via a `{ let v = v.clone();
                   -- … }` prelude so the original survives; uses inside still
                   -- clone (ecCloneVars) since the Fn closure runs per element.
                   capturedList = Set.toList capturedSupplied
                   clonePrelude = concatMap (\v -> let v' = rustSafeIdent v in "let " ++ v' ++ " = " ++ v' ++ ".clone(); ") capturedList
                   theClosure = "(move |" ++ intercalate ", " freshParams ++ "| "
                                ++ calleeName ++ "(" ++ intercalate ", " (suppliedStrs ++ freshParams) ++ "))"
                   -- A partial application whose RESIDUAL type is an effectful
                   -- arrow (`Request -> Task Error Response` — a `Handler`) flows
                   -- into a `Handler`-typed slot, which renders as
                   -- `Arc<dyn Fn>` (typeToRustString / paramTypeToRust). The bare
                   -- `move` closure is NOT an Arc, so wrap it. Gated on the call's
                   -- region resolving to a Task-returning arrow, so non-Handler
                   -- partial apps (the list-HOF `validateTime now` shape, whose
                   -- residual is `String -> Result …`) are byte-identical.
                   wrapArc s = if regionIsTaskArrow then arcWrapClosure capturedList s else s
               in if null capturedList then wrapArc theClosure
                  else if regionIsTaskArrow then wrapArc theClosure
                  else "{ " ++ clonePrelude ++ theClosure ++ " }"
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
                    "log_println(" ++ intercalate " ++ \" \" ++ " (map (\a -> exprToRustString ctx a) args) ++ ")"
                -- A task_and_then continuation's param type is the inner type of
                -- the TASK arg (its input), not the inherited ecPipeInnerType
                -- (the outer `… |> Task.run` chain result, constant down the
                -- whole chain). Reset ecPipeInnerType to the task arg's inner type
                -- for BOTH the wildcard (pinTaskCall) and non-wildcard
                -- (emitDefaultCall) paths so the closure's `move |x: T|` param —
                -- and, via the body-driven retInner, its return — are annotated
                -- against the right type. When the prior task is POLYMORPHIC
                -- (inner = "" → Nothing), the param is left bare for Rust to infer
                -- from the task_and_then signature. Closes the cargo-build hole
                -- (E0308/E0631) where an andThen chain that changes its inner type
                -- mis-annotated every continuation as `()`.
                cname | cname == "task_and_then" ->
                    -- A task_and_then continuation's param AND return types are
                    -- inferred by Rust from the task_and_then signature and the
                    -- (typed) task arg — there is no reliable STATIC way to
                    -- compute an andThen chain's result inner type here (it is the
                    -- last continuation's body type; the table hardcodes
                    -- "andThen" -> "String" and the piped form yields the FIRST
                    -- task's type). Carrying the inherited ecPipeInnerType (the
                    -- outer `… |> Task.run` chain result, e.g. `()`) into the
                    -- continuation mis-annotated `move |x: ()|` whenever the
                    -- continuation's input type differed from the chain result,
                    -- breaking cargo build (E0308 / E0631). Clear it so the
                    -- closure param/return stay bare and Rust infers them.
                    -- pinTaskCall still pins the wildcard + polymorphic-task
                    -- phantom success type.
                    let ctxC = ctx { ecPipeInnerType = Nothing }
                    in case pinTaskCall ctxC cname args (ecSolvedTypes ctxC) of
                        Just pinned -> pinned
                        Nothing -> emitDefaultCall ctxC fn calleeName args
                -- task_on_error / task_map_error: the handler's closure param is
                -- the ERROR type (inferred from the combinator's signature), NOT
                -- the inherited ecPipeInnerType (the chain's success inner type,
                -- e.g. `Db`) — carrying it mis-typed `move |e: Db|`. Clear it so
                -- Rust infers the error param from the signature.
                cname | cname `elem` ["task_on_error", "task_map_error"] ->
                    let ctxC = ctx { ecPipeInnerType = Nothing }
                    in case pinTaskCall ctxC cname args (ecSolvedTypes ctxC) of
                        Just pinned -> pinned
                        Nothing -> emitDefaultCall ctxC fn calleeName args
                cname | "decode_and_then" `isPrefixOf` cname, [contArg, decArg] <- args ->
                    -- Sky's `andThen : (a -> Decoder b) -> Decoder a -> Decoder b`
                    -- puts the continuation FIRST, but the runtime kernel is
                    -- `decode_and_then(decoder, f)`. Emit decoder-first so Rust
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
            -- Discarded Task as a `let _ = TaskExpr` (a DestructDef PAnything OR a
            -- plain Def whose binder is "_"). Sky auto-forces these — the effect
            -- MUST fire in program order. With deferred effect kernels the effect
            -- lives inside the future, so a bind/drop never runs it; RUN it via
            -- `task_run` (block_on) instead. Gated on a task-PRODUCING-CALL RHS
            -- with a determinable inner type, so a non-Task discard (`let _ =
            -- List.map (\… -> println …) …`, whose `taskExprInnerType` is empty)
            -- stays bind/drop and is NEVER run — the Sky/Test.sky summary-only
            -- contract (a discarded `List (Task ())` produces no output). Mirrors
            -- the Can.LetDestruct arm below.
            Can.DestructDef (Ann.At _ Can.PAnything) expr
                | isTaskProducingCall expr
                , not (null (taskExprInnerType (ecSolvedTypes ctx) expr)) ->
                    "{ task_run::<SkyError, _>(" ++ exprToRustString ctx expr
                        ++ "); " ++ exprToRustString ctx body ++ " }"
            Can.Def (Ann.At _ "_") [] taskBody
                | isTaskProducingCall taskBody
                , not (null (taskExprInnerType (ecSolvedTypes ctx) taskBody)) ->
                    "{ task_run::<SkyError, _>(" ++ exprToRustString ctx taskBody
                        ++ "); " ++ exprToRustString ctx body ++ " }"
            -- Non-Clone capture fix (#52, Part B): a `let`-bound SkyTask
            -- (`Pin<Box<dyn Future>>`, non-`Clone`) captured by MULTIPLE sibling
            -- closures (each `.clone()`s its capture for ownership) is E0599.
            -- When every use is a DISCARD (`let _ = task` — Sky forces a Task
            -- value for effect then throws it away; the classic `cleanup`
            -- pattern), Arc-wrap the binding so the prelude's `.clone()` is a
            -- sound `Arc::clone` and the drop is a ref-count decrement. Gated on
            -- (a) SkyTask-typed body, (b) used ≥2 times (so it IS multi-consumed
            -- — a single use moves fine, no wrap needed), (c) all uses discarded
            -- (so the future is never `.await`ed / passed to a `task_*`
            -- combinator that needs an owned `SkyTask`). Outside this gate the
            -- existing move/clone path is byte-identical.
            Can.Def (Ann.At _ name) [] taskBody
                | not (null (taskExprInnerType (ecSolvedTypes ctx) taskBody))
                , Just c <- Map.lookup name (collectVarLocalsMulti body), c >= 2
                , allUsesDiscarded name body ->
                    -- Bind the SkyTask UNCHANGED first (so any type inference
                    -- inside its body — e.g. a discarded `let _ = process_run …`
                    -- whose error type `E` is pinned only by this `SkyTask<…>`
                    -- binding context — is preserved), THEN shadow it with an
                    -- `Arc<Mutex<SkyTask>>`. `Arc<SkyTask>` alone is NOT `Send`
                    -- (needs inner `Send + Sync`; `SkyTask = Pin<Box<dyn Future
                    -- + Send>>` is `Send` only). The combinator closures are
                    -- `Send`, so `Mutex<T>: Sync` (when `T: Send`) lifts the
                    -- whole `Arc<Mutex<…>>` to `Send + Sync`. The value is never
                    -- locked/awaited — only dropped — a zero-cost ownership shim.
                    let n' = rustSafeIdent name
                        inner = taskExprInnerType (ecSolvedTypes ctx) taskBody
                        -- Annotate the SkyTask binding with its concrete type so
                        -- the runtime's `SkyTask<A>` alias pins `E = SkyError`.
                        -- Without it, a discarded `let _ = process_run …` inside
                        -- the body has a free `E: From<String>` (many impls →
                        -- E0283), since the Arc<Mutex> shadow erases the only
                        -- downstream type constraint.
                        tyAnnot = ": SkyTask<" ++ inner ++ ">"
                        bind = "let " ++ n' ++ tyAnnot ++ " = " ++ exprToRustString ctx taskBody ++ "; "
                        wrap = "let " ++ n' ++ " = std::sync::Arc::new(std::sync::Mutex::new(" ++ n' ++ ")); "
                    in "{ " ++ bind ++ wrap ++ exprToRustString ctx body ++ " }"
            -- A `let`-bound LAMBDA whose binding type is an effectful `Handler`
            -- (`… -> Task …`) is referenced as a value that flows into an
            -- `Arc<dyn Fn>` slot (e.g. `todosByMethod` passed to a
            -- middleware-wrapping closure's `Arc` param). A bare `move` closure is
            -- not an `Arc`, so bind it pre-boxed: `let f = Arc::new(move |…| …)`.
            -- The `Arc` is `Clone`, so each downstream use (`guarded(f)`,
            -- `server_api(spec, f)`) still works; `IntoServerHandler`'s Arc impl
            -- accepts it at the runtime boundary. Gated tightly on the binding's
            -- solved type being a Task-returning arrow, so ordinary let-bound
            -- closures (pure callbacks, non-Handler arrows) are byte-identical.
            -- Block-wrap: a `let` is a statement, invalid in expression
            -- position (e.g. a call arg `f(let x = …; body)`). `{ … }` is a
            -- valid expression everywhere, so wrapping is universally safe.
            _ -> "{ let " ++ defToRustString ctx def ++ "; " ++ exprToRustString ctx body ++ " }"
    Can.LetRec defs body ->
        "{ let mut " ++ intercalate "; let mut " (map (defToRustString ctx) defs) ++ "; " ++ exprToRustString ctx body ++ " }"
    Can.LetDestruct pat expr body ->
        -- Clone captured locals used ≥ 2 times so each use gets its own copy.
        let counts = collectVarLocalsMulti expr
            multi = [ v | (v, c) <- Map.toList counts, c >= 2 ]
            clones = concatMap (\v -> let v' = rustSafeIdent v in "let " ++ v' ++ " = " ++ v' ++ ".clone(); ") multi
            hasClone = not (null multi)
            exprStr = case expr of
                Ann.At _ (Can.Lambda ps lambdaBody)
                    | null ps || all isWildcard ps ->
                        let inner = "(move || { " ++ exprToRustString ctx lambdaBody ++ " })()"
                        in if not hasClone then inner else "{ " ++ clones ++ inner ++ " }"
                Ann.At _ (Can.Lambda ps lambdaBody) ->
                    let paramNames = Set.fromList [ n | Ann.At _ p <- ps, let n = case p of Can.PVar s -> s; _ -> "_" ]
                        innerCapt = Set.toList (Set.difference (collectVarLocals lambdaBody) paramNames)
                        innerClones = concatMap (\v -> let v' = rustSafeIdent v in "let " ++ v' ++ " = " ++ v' ++ ".clone(); ") innerCapt
                        psStr = intercalate ", " (map patternToRustParam ps)
                        inner = "move |" ++ psStr ++ "| { " ++ exprToRustString ctx lambdaBody ++ " }"
                    in if null innerCapt && not hasClone then inner
                       else "{ " ++ clones ++ innerClones ++ inner ++ " }"
                _ -> if not hasClone then exprToRustString ctx expr
                     else "{ " ++ clones ++ exprToRustString ctx expr ++ " }"
            -- Discarded Task (`let _ = println … / process_run …`) — Sky's
            -- "auto-force `let _ = TaskExpr`" semantics: the side effect MUST
            -- fire when the binding is reached, in program order (Go runs it via
            -- `rt.AnyTaskRun`). A bare `let _: SkyTask<…> = …` only CONSTRUCTS the
            -- future and drops it — with deferred effect kernels (the effect now
            -- lives inside the future body) that means the effect NEVER fires.
            -- So RUN it synchronously via `task_run` (`block_on`). The success
            -- value is discarded; `::<SkyError, _>` pins the error type (the same
            -- pin the wildcard annotation used to provide) and infers `A`. Gated
            -- on a PAnything pattern over a task-PRODUCING-CALL whose inner type
            -- is determinable — a non-Task discard (`let _ = List.map (…)`, where
            -- `taskExprInnerType` is empty) keeps the bind/drop path so a
            -- discarded `List (Task ())` is NEVER run (the Sky/Test.sky
            -- summary-only contract). A bare `VarLocal` discard (`let _ =
            -- cleanup`, the #52 Arc-wrapped pattern) is not a producing call, so
            -- it also stays bind/drop.
            isDiscardTask = case pat of
                Ann.At _ Can.PAnything ->
                    isTaskProducingCall expr
                    && not (null (taskExprInnerType (ecSolvedTypes ctx) expr))
                _ -> False
            patStr = patternToMatchString (ecRecordMap ctx) pat
        in if isDiscardTask
           then "task_run::<SkyError, _>(" ++ exprStr ++ "); " ++ exprToRustString ctx body
           else "let " ++ patStr ++ " = " ++ exprStr ++ "; " ++ exprToRustString ctx body
    Can.Case scrut branches ->
        let scrutStr = exprToRustString ctx scrut
            -- Detect slice patterns → wrap with .as_slice()
            hasCons = any (\(Can.CaseBranch pat _) -> hasConsP pat) branches
            -- Detect string literal patterns → wrap with .as_str() so &str patterns compile
            hasStr  = any (\(Can.CaseBranch pat _) -> hasStrPat pat) branches
            -- A cons/list pattern can sit INSIDE a tuple scrutinee
            -- (`case (offsets, flags) of (i :: ix, b :: bs) -> …`). A slice
            -- pattern only matches a slice, so each tuple ELEMENT carrying a
            -- cons pattern in any branch must be `.as_slice()`-wrapped on its
            -- own — wrapping the whole tuple would be a type error. Top-level
            -- cons keeps the simple whole-scrutinee wrap above.
            tupleConsPositions = case scrut of
                Ann.At _ (Can.Tuple a b rest) ->
                    let n = 2 + length rest
                    in [ i | i <- [0 .. n - 1]
                           , any (\(Can.CaseBranch pat _) -> tupleElemHasCons i pat) branches ]
                _ -> []
            wrapped
                | hasCons, Ann.At _ (Can.Tuple a b rest) <- scrut, not (null tupleConsPositions) =
                    let elems = a : b : rest
                        wrapElem i e = let s = exprToRustString ctx e
                                       in if i `elem` tupleConsPositions
                                          then "(" ++ s ++ ").as_slice()" else s
                    in "(" ++ intercalate ", " (zipWith wrapElem [0..] elems) ++ ")"
                | hasCons   = "(" ++ scrutStr ++ ").as_slice()"
                | hasStr    = scrutStr ++ ".as_str()"
                | otherwise = scrutStr
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
            -- Recurse into tuple elements so a cons/list pattern nested in a
            -- tuple scrutinee still triggers the slice-wrap path (the element
            -- wrap is decided per-position by tupleConsPositions).
            Can.PTuple a b rest -> any hasConsP (a : b : rest)
            _ -> False
        -- Does the i-th element of a tuple branch pattern carry a cons/list
        -- pattern (directly or through an alias)? Non-tuple / out-of-range
        -- patterns (e.g. the `_` catch-all) answer False.
        tupleElemHasCons i (Ann.At _ p) = case p of
            Can.PTuple a b rest ->
                let elems = a : b : rest
                in i < length elems && elemIsCons (elems !! i)
            Can.PAlias pat _ -> tupleElemHasCons i pat
            _ -> False
        elemIsCons (Ann.At _ p) = case p of
            Can.PCons _ _ -> True
            Can.PList _ -> True
            Can.PAlias pat _ -> elemIsCons pat
            _ -> False
    Can.Accessor field -> "|_record| _record." ++ field
    Can.Access record (Ann.At _ field) -> 
        exprToRustString ctx record ++ "." ++ field
    Can.Update (Ann.At _ _field) record updates ->
        let sorted = sortBy (\(_, Can.FieldUpdate r1 _) (_, Can.FieldUpdate r2 _) -> compare (Ann._line (Ann._start r1)) (Ann._line (Ann._start r2))) (Map.toList updates)
            -- Resolve the updated record's struct so each field VALUE can be
            -- emitted with its declared type as the expected type (seeded by
            -- inserting it at the value's region — exprToRustString reads
            -- ecRegionTypes). Lets an empty collection / literal in an update
            -- (`{ model | configInput = Dict.empty }`) turbofish correctly.
            recFields = updateRecordFields ctx (map fst sorted)
            emitUpd (f, Can.FieldUpdate _ expr@(Ann.At vr _)) =
                let ctxF = case Map.lookup f recFields of
                        Just ft -> ctx { ecRegionTypes = Map.insert vr ft (ecRegionTypes ctx) }
                        Nothing -> ctx
                -- `__rec`, not `result`: a user binding named `result` in the
                -- update VALUE (`{ model | gameStatus = result }`) would be
                -- shadowed by the temp and read back the half-built record
                -- (16-skychess `result.gameStatus = result.clone()`).
                in "__rec." ++ f ++ " = " ++ wrapStoredFn True False ctxF expr (exprToRustString ctxF expr)
        in "{ let mut __rec = " ++ exprToRustString ctx record ++ "; " ++
        intercalate "; " (map emitUpd sorted) ++
        "; __rec }"
    Can.Record fields ->
        let key = intercalate "," (Map.keys fields)
        in case Map.lookup key (ecRecordMap ctx) of
            Just structName ->
                -- An Anon struct gives each field a generic type param the
                -- consumer pins (often a plain `fn(..)` pointer), so a non-lambda
                -- fn ref must NOT be Arc-wrapped; a named-alias struct's callback
                -- fields are `Arc<dyn Fn>`, so it must.
                let wrapNL = not ("Anon" `isPrefixOf` structName)
                in structName ++ " { " ++ intercalate ", " (map (\(k, v) ->
                    k ++ ": " ++ wrapStoredFn wrapNL False ctx v (exprToRustString ctx v)) (Map.toList fields)) ++ " }"
            Nothing ->
                "{ " ++ intercalate ", " (map (\(k, v) -> k ++ ": " ++ wrapStoredFn False False ctx v (exprToRustString ctx v)) (Map.toList fields)) ++ " }"
    Can.Unit -> "()"
    Can.Tuple a b rest -> 
        "(" ++ intercalate ", " (map (exprToRustString ctx) (a:b:rest)) ++ ")"

-- | Does the entry `main`'s body emit a `sky_main` that RETURNS a `SkyTask<…>`
-- (vs a `SkyResult`/`()`)? Drives whether the entry must `block_on(sky_main())`.
--
-- The body TAIL's task-ness is the sound signal — but a `|> Task.run` (or
-- `Task.perform` / `Task.sequence`) at the tail CONSUMES the task and returns a
-- `SkyResult`, so such a tail is NOT a Task even though its left operand is.
-- `taskExprInnerType` only inspects a pipe's LEFT operand, so it wrongly reports
-- `Cli.program {} |> Task.run` as a Task (20-cli-counter). This predicate walks
-- to the tail through let-chains and gates the pipe on its RIGHT operand.
mainEntryTailReturnsTask :: Map.Map String Can.Type -> Can.Expr -> Bool
mainEntryTailReturnsTask solved = go
  where
    go (Ann.At _ e) = case e of
        -- Walk to the tail of let-chains / case / if.
        Can.Let _ b           -> go b
        Can.LetRec _ b        -> go b
        Can.LetDestruct _ _ b -> go b
        -- A pipe whose RIGHT side runs/consumes the task (Task.run / perform /
        -- sequence) collapses to a Result — NOT a Task tail.
        Can.Binop "|>" _ _ _ _ r
            | pipeCollapsesTask r -> False
            | otherwise           -> not (null (taskExprInnerType solved (Ann.At Ann.one e)))
        -- Case / if: a Task tail iff EVERY branch is a Task tail.
        Can.Case _ branches ->
            not (null branches) && all (\(Can.CaseBranch _ b) -> go b) branches
        Can.If branches elseB ->
            all (go . snd) branches && go elseB
        _ -> not (null (taskExprInnerType solved (Ann.At Ann.one e)))
    -- Right operand of the FINAL `|>` collapses the task to a Result/unit.
    pipeCollapsesTask (Ann.At _ r) = case r of
        Can.VarKernel "Task" fn          -> fn `elem` ["run", "perform", "sequence"]
        Can.VarTopLevel m fn
            | ModuleName._name m == "Sky.Core.Task" -> fn `elem` ["run", "perform", "sequence"]
        _ -> False

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
    Can.If branches elseExpr ->
        -- Symmetric to Can.Case: if every branch body AND the else are Task
        -- expressions, the whole `if` is a Task — so it must NOT be re-wrapped
        -- in `task_succeed` (which would nest SkyTask<SkyTask<_>>). Closes the
        -- "Task-valued if/case branch at main fails to lower" codegen gap.
        let innerTypes = map (taskExprInnerType solved) (map snd branches ++ [elseExpr])
        in if not (null innerTypes) && all (not . null) innerTypes
           then head innerTypes
           else ""
    Can.VarTopLevel mod name ->
        -- Look up the solved type of this VarTopLevel and extract Task inner type
        case Map.lookup name solved of
            Just ty -> let ret = extractReturnType ty in taskInnerTypeStr ret
            Nothing -> ""
    -- A `let … in <task-tail>` (`let _ = effect in Task.succeed x`) IS a Task —
    -- its type is the tail's. Peel through let chains so the #52 SkyTask
    -- Arc-wrap gate (and any Task-return inference) sees the real tail type.
    Can.Let _ b           -> taskExprInnerType solved b
    Can.LetRec _ b        -> taskExprInnerType solved b
    Can.LetDestruct _ _ b -> taskExprInnerType solved b
    _ -> ""

-- | Extract the inner type string from a Sky type (task or not).
-- If the type is Task e a, return the Rust string of a.
-- Otherwise return "" (not a Task expression).
taskInnerTypeStr :: Can.Type -> String
taskInnerTypeStr (Can.TType _ "Task" [_, a]) = typeToRustString Map.empty a
taskInnerTypeStr _                           = ""

-- | Body-driven param monomorphisation. A user wrapper over a polymorphic
-- stdlib kernel (e.g. `Lib.Db.exec queryStr args = … Db.exec conn queryStr args`)
-- inherits a TVAR param (`args : List a`, `row`) because the kernel's Sky sig is
-- polymorphic (`Db.exec : … List a …`, `Db.getField : String -> row -> String`).
-- The concrete-only param gate then rejects the whole sig and the body-analysis
-- fallback emits `String`, but the runtime kernel is MONOMORPHIC (db_exec wants
-- `Vec<String>`, dict_get wants `HashMap<String,String>`) → E0308 at every call.
-- This recovers the concrete type by finding the first call in the body where
-- the param is a direct argument and reading the callee kernel's known Rust type
-- at that position. Symmetric to taskExprInnerType (return inference).
inferParamRustType :: EmitCtx -> String -> Can.Expr -> Maybe String
inferParamRustType ctx pname = go
  where
    go (Ann.At _ e) = case e of
      Can.Call callee args ->
        let mkn = calleeKernelName ctx callee
            -- param is a DIRECT arg → callee's arg type at that position
            direct = case mkn of
              Just kn -> firstJustL [ kernelArgRustType kn i
                                    | (i, Ann.At _ (Can.VarLocal v)) <- zip [0 :: Int ..] args
                                    , v == pname ]
              Nothing -> Nothing
            -- DIRECT arg of a generated stdlib fn (not a kernel) with a known
            -- arg type — e.g. `sky_core_error_to_string(e)` → `e : SkyError`.
            genDirect = case emittedCalleeName callee of
              Just en -> firstJustL [ genFnArgType en i
                                    | (i, Ann.At _ (Can.VarLocal v)) <- zip [0 :: Int ..] args
                                    , v == pname ]
              Nothing -> Nothing
            -- param is an ELEMENT of a `vec![…]` arg to a kernel taking a
            -- known Vec type (`db_exec(db, sql, vec![…, ts])`, `log_*_with`).
            -- Infer from the ELEMENT's own solver region type — NOT the kernel's
            -- `Vec<String>`: db params are heterogeneous and get `format!`'d to
            -- String at the call site, so `ts`'s actual type is `Int` (from
            -- Time.now), and annotating it `String` mismatched the caller
            -- (E0308). The element region carries the unified Sky element type
            -- (i64 for the int list, String for the token list).
            vecElem = case mkn of
              Just kn -> firstJustL
                [ Just (typeToRustString (ecRecordMap ctx) t)
                | (i, Ann.At _ (Can.List elems)) <- zip [0 :: Int ..] args
                , Just _ <- [kernelArgRustType kn i]
                , Ann.At eregion (Can.VarLocal v) <- elems, v == pname
                , Just t <- [Map.lookup eregion (ecRegionTypes ctx)]
                , not (hasTypeVars t) ]
              Nothing -> Nothing
            -- param flows into a USER closure call (`writeAll db = … insertRow
            -- db …`): recursively infer the target closure's param at that
            -- position. Delete the target from the def map first to break cycles.
            userClosure = case callee of
              Ann.At _ (Can.VarLocal lname) ->
                case Map.lookup lname (ecClosureDefs ctx) of
                  Just (cparams, cbody) -> firstJustL
                    [ inferParamRustType (ctx { ecClosureDefs = Map.delete lname (ecClosureDefs ctx) }) cpn cbody
                    | (j, Ann.At _ (Can.VarLocal v)) <- zip [0 :: Int ..] args, v == pname
                    , j < length cparams, Ann.At _ (Can.PVar cpn) <- [cparams !! j] ]
                  Nothing -> Nothing
              _ -> Nothing
            -- param flows into a SIBLING top-level fn call (`execOrLog … = exec q
            -- args`): recursively infer that fn's param at the same position.
            -- Guard with `mkn == Nothing` (callee is NOT a kernel): the collision
            -- to avoid is a QUALIFIED cross-module call to a kernel-mapped fn of
            -- the same bare name (`Db.exec` from Lib.Db, whose own `exec` is a
            -- sibling — db_exec is a kernel so mkn=Just, excluded → 12-skyvote
            -- stays correct). A genuine sibling user-fn call is never a kernel.
            -- The candidate must also be in ecSiblingFns (this module's defs).
            -- Cycle-broken via Map.delete.
            siblingName = case (mkn, callee) of
              (Nothing, Ann.At _ (Can.VarTopLevel _ sname)) -> Just sname
              (Nothing, Ann.At _ (Can.VarLocal sname))      -> Just sname
              _                                             -> Nothing
            siblingFn = case siblingName of
              Just sname -> case Map.lookup sname (ecSiblingFns ctx) of
                  Just (sparams, sbody) -> firstJustL
                    [ inferParamRustType (ctx { ecSiblingFns = Map.delete sname (ecSiblingFns ctx) }) spn sbody
                    | (j, Ann.At _ (Can.VarLocal v)) <- zip [0 :: Int ..] args, v == pname
                    , j < length sparams, Ann.At _ (Can.PVar spn) <- [sparams !! j] ]
                  Nothing -> Nothing
              Nothing -> Nothing
        in direct `orElseM` genDirect `orElseM` vecElem `orElseM` userClosure `orElseM` siblingFn `orElseM` firstJustL (map go (callee : args))
      Can.Lambda _ b              -> go b
      Can.Let d b                 -> go (canDefBody d) `orElseM` go b
      Can.LetRec ds b             -> firstJustL (map (go . canDefBody) ds) `orElseM` go b
      Can.LetDestruct _ x b       -> go x `orElseM` go b
      Can.Case s bs               -> go s `orElseM` firstJustL [ go b | Can.CaseBranch _ b <- bs ]
      Can.If brs el               -> firstJustL ([ go c `orElseM` go t | (c, t) <- brs ] ++ [go el])
      -- `pname` compared (`==`/`/=`) against a record field (`r.traceId ==
      -- tid`) takes that field's type. The field name resolves structurally
      -- across ecStructFields; a unique non-typevar type wins. Closes a scalar
      -- closure param with no field accesses of its own + no HOF flow (the
      -- console's `keepTrace = \tid -> … r.traceId == tid …`, E0282).
      Can.Binop op _ _ _ a b
        | op == "==" || op == "/=" ->
            fieldCmpType a b `orElseM` fieldCmpType b a `orElseM` (go a `orElseM` go b)
      Can.Binop _ _ _ _ a b       -> go a `orElseM` go b
      Can.Access r _              -> go r
      Can.Update _ r ups          -> go r `orElseM` firstJustL [ go x | (_, Can.FieldUpdate _ x) <- Map.toList ups ]
      Can.Record fs               -> firstJustL [ go x | (_, x) <- Map.toList fs ]
      Can.List xs                 -> firstJustL (map go xs)
      Can.Tuple a b rest          -> firstJustL (map go (a : b : rest))
      Can.Negate x                -> go x
      _                           -> Nothing
    orElseM (Just x) _ = Just x
    orElseM Nothing  y = y
    firstJustL = foldr orElseM Nothing
    -- `lhs` is `VarLocal pname` and `rhs` is a field access `_.field`: resolve
    -- `field`'s type across every struct; a unique non-typevar type is pname's.
    fieldCmpType (Ann.At _ (Can.VarLocal v)) (Ann.At _ (Can.Access _ (Ann.At _ field)))
        | v == pname =
            case nub [ typeToRustString (ecRecordMap ctx) t
                     | fm <- Map.elems (ecStructFields ctx)
                     , Just t <- [Map.lookup field fm], not (hasTypeVars t) ] of
                [single] -> Just single
                _        -> Nothing
    fieldCmpType _ _ = Nothing

-- | Resolve a call's callee expression to its runtime kernel snake_case name
-- (the same resolution exprToRustString does for VarTopLevel / VarKernel).
calleeKernelName :: EmitCtx -> Can.Expr -> Maybe String
calleeKernelName ctx (Ann.At _ e) = case e of
    Can.VarTopLevel mod name ->
        let modName = ModuleName._name mod
            fnName  = toSnakeCase (map (\c -> if c == '.' then '_' else c) modName ++ "_" ++ name)
            kName   = kernelToRust modName name
        in if fnName /= kName && not ("ffi_kernel" `isPrefixOf` kName)
           then Just kName
           else case Map.lookup (modName, name) (ecKernelAliases ctx) of
                    Just (kMod, kFn) -> Just (kernelToRust kMod kFn)
                    Nothing          -> Nothing
    Can.VarKernel mod name -> Just (kernelToRust mod name)
    _ -> Nothing

-- | The CONCRETE Rust type a monomorphic runtime kernel expects at arg `i`,
-- for the kernels that user wrappers commonly call with a Sky-polymorphic
-- (`List a` / `row`) param. Keep narrow: only positions whose runtime type is
-- fixed regardless of Sky's loose sig. db_exec/db_query bind params positionally
-- as Vec<String>; the dict_* kernels key on String and (for getField's row use)
-- carry String values.
kernelArgRustType :: String -> Int -> Maybe String
kernelArgRustType "db_exec"     0 = Just "Db"
kernelArgRustType "db_query"    0 = Just "Db"
kernelArgRustType "db_exec_raw" 0 = Just "Db"
kernelArgRustType "db_exec"     2 = Just "Vec<String>"
kernelArgRustType "db_query"    2 = Just "Vec<String>"
-- Log.*With : String -> List a -> Task is polymorphic in the attr element; the
-- runtime is generic over it (`Vec<A>`), so the attrs list is emitted with its
-- own inferred element type — no `Vec<String>` coercion (which mis-`format!`'d
-- a `List (String, String)` key/value attrs list through a non-Display tuple,
-- E0277 in routes_auth / routes_todos). Intentionally NOT mapped here.
kernelArgRustType "dict_get"    1 = Just "HashMap<String, String>"
kernelArgRustType "dict_member" 1 = Just "HashMap<String, String>"
kernelArgRustType "dict_remove" 1 = Just "HashMap<String, String>"
-- Db.getField/getString/getInt/getBool : String -> row -> a, where the runtime
-- `row` is a HashMap<String, String> (a query result row). A thin Lib.Database
-- wrapper (`getField f row = Db.getField f row`) inherits a polymorphic `row`
-- param that defaults to String without this; the kernel call then mismatches
-- (17-skymon's mass E0308). Arg index 1 is the row in every getter.
kernelArgRustType "db_get_field"  1 = Just "HashMap<String, String>"
kernelArgRustType "db_get_string" 1 = Just "HashMap<String, String>"
kernelArgRustType "db_get_int"    1 = Just "HashMap<String, String>"
kernelArgRustType "db_get_bool"   1 = Just "HashMap<String, String>"
kernelArgRustType "dict_keys"   0 = Just "HashMap<String, String>"
kernelArgRustType "dict_values" 0 = Just "HashMap<String, String>"
-- Std.Css length/number constructors take f64 (Sky `Float`). An Int literal arg
-- (`Css.pct 100`) must coerce — see emitArg's f64 branch.
kernelArgRustType n 0
    | n `elem` [ "std_css_pct", "std_css_em", "std_css_rem", "std_css_ch"
               , "std_css_num", "std_css_opacity", "std_css_scale", "std_css_deg"
               , "std_css_sec" ] = Just "f64"
kernelArgRustType _             _ = Nothing

-- | The turbofish for `task_fail : err -> Task err a`. Its success type `a` is
-- phantom (a failing task yields no value), so it's unconstrained when the
-- result is discarded → E0283, hence the `i64` default. But when `a` IS
-- constrained — a GENERIC fn's own param (`Task Error a`), or a monomorphic fn
-- whose return type is known (`Task Error String`) — pinning `i64` MISMATCHES
-- it (E0271/E0308). Resolve `a` from the expected return type: drop the pin in
-- a generic fn (let Rust infer the param), pin the concrete success type when
-- the region's expected type is a known `Task _ a`, else default `i64`.
-- | Wrap a record-field VALUE in `std::sync::Arc::new(..)` when it is a
-- function-typed value — a lambda literal, or a value whose solver region type
-- is a function type (a `cb` param / top-level fn ref). Mirrors
-- `fieldTypeToRust`: a stored-callback field renders as
-- `Arc<dyn Fn(..) -> .. + Send + Sync>`, so the assigned closure / fn-pointer /
-- param must be Arc-wrapped to match (closes 33-websocket-echo's 4× E0308 where
-- `withOnX` stored an `impl Fn` into a callback field). A bare `fn` pointer
-- coerces into `Arc::new` fine; a capturing `impl Fn` boxes into the trait
-- object. Non-function values pass through unchanged, so non-callback fields
-- (and every building example, none of which store functions in records) are
-- byte-identical.
-- The Bool is `wrapNonLambda`: a record UPDATE always targets the original
-- struct's field type, which for a callback field is `Arc<dyn Fn>` — so even a
-- non-lambda fn ref (`withOnConnect onConnect`, a named top-level fn) must be
-- Arc-wrapped (33-websocket-echo). A record LITERAL of an ANON struct, by
-- contrast, has generic per-field type params that the consumer pins — when
-- that pin is a plain `fn(..)` pointer (Std.Ui.Input's onChange), Arc-wrapping a
-- fn-pointer param mismatches (26-ui-showcase). A capturing LAMBDA always needs
-- the Arc<dyn Fn> box regardless of position, so it is wrapped either way.
-- | Names a `Can.Def` binds (for free-var analysis).
defBindingVars :: Can.Def -> [String]
defBindingVars (Can.Def (Ann.At _ n) _ _)          = [n]
defBindingVars (Can.TypedDef (Ann.At _ n) _ _ _ _) = [n]
defBindingVars (Can.DestructDef pat _)             = patBindingVars pat

-- | Free outer `VarLocal`s referenced in a lambda body — i.e. captures: not the
-- lambda's own params, nor bound by inner lambdas / lets / case patterns. Used to
-- pre-clone captures when a capturing closure is stored into an `Arc<dyn Fn +
-- 'static>` field (each sibling field needs its own owned copy).
closureCaptures :: [Can.Pattern] -> Can.Expr -> [String]
closureCaptures params body =
    Set.toList (go (Set.fromList (concatMap patBindingVars params)) body)
  where
    go bnd (Ann.At _ e) = case e of
        Can.VarLocal n -> if n `Set.member` bnd then Set.empty else Set.singleton n
        Can.Lambda ps b -> go (foldr Set.insert bnd (concatMap patBindingVars ps)) b
        Can.Let def b ->
            let bnd' = foldr Set.insert bnd (defBindingVars def)
            in Set.union (go bnd' (canDefBody def)) (go bnd' b)
        Can.LetRec defs b ->
            let bnd' = foldr Set.insert bnd (concatMap defBindingVars defs)
            in Set.union (Set.unions (map (go bnd' . canDefBody) defs)) (go bnd' b)
        Can.LetDestruct pat e0 b ->
            let bnd' = foldr Set.insert bnd (patBindingVars pat)
            in Set.union (go bnd e0) (go bnd' b)
        Can.Case scrut branches ->
            Set.union (go bnd scrut)
                (Set.unions [ go (foldr Set.insert bnd (patBindingVars p)) b
                            | Can.CaseBranch p b <- branches ])
        Can.Call f as -> Set.union (go bnd f) (Set.unions (map (go bnd) as))
        Can.Binop _ _ _ _ a b -> Set.union (go bnd a) (go bnd b)
        Can.If brs els ->
            Set.union (go bnd els)
                (Set.unions [ Set.union (go bnd c) (go bnd t) | (c, t) <- brs ])
        Can.Access r _ -> go bnd r
        Can.Negate a -> go bnd a
        Can.Tuple a b cs -> Set.unions (go bnd a : go bnd b : map (go bnd) cs)
        Can.List es -> Set.unions (map (go bnd) es)
        Can.Record fs -> Set.unions (map (go bnd) (Map.elems fs))
        Can.Update (Ann.At _ n) r fs ->
            Set.unions ((if n `Set.member` bnd then Set.empty else Set.singleton n)
                        : go bnd r : [ go bnd fe | Can.FieldUpdate _ fe <- Map.elems fs ])
        _ -> Set.empty

-- | `targetIsArcFn` (2nd Bool) is set ONLY by a call site whose destination
-- slot is KNOWN to be `Arc<dyn Fn>` regardless of the value's region type — i.e.
-- the `Event::OnString`/`OnBool` ctor arms, whose html::Event field is a
-- hard-coded `Arc<dyn Fn>`. It is the target-slot-is-Arc signal the event-cb
-- arm needs but cannot read from the value region (the value is monomorphic).
-- A named-alias struct field carries the same guarantee via `wrapNonLambda`
-- (its function-typed field renders `Arc<dyn Fn>` — fieldTypeToRust). An Anon
-- struct field passes BOTH False: its field is a pinned generic that may be a
-- bare `fn` pointer, so a bare fn item must NOT be Arc-wrapped (B#1 — the wrap
-- into a bare-`fn` slot is an `E0308 expected fn pointer, found Arc<..>`).
wrapStoredFn :: Bool -> Bool -> EmitCtx -> Can.Expr -> String -> String
wrapStoredFn wrapNonLambda targetIsArcFn ctx (Ann.At region e) rendered = case e of
    -- A CAPTURING lambda stored into an `Arc<dyn Fn + 'static>` field must OWN its
    -- captures (a borrow can't outlive the call). Emit a `move` closure and
    -- pre-clone each free outer var, so sibling callback fields each get their own
    -- copy (the console's StateStore: 11 closures all capturing `parent` — E0597).
    Can.Lambda params body ->
        let caps = closureCaptures params body
            preClones = concatMap
                (\v -> "let " ++ rustSafeIdent v ++ " = " ++ rustSafeIdent v ++ ".clone(); ") caps
            arc = "std::sync::Arc::new(move " ++ rendered ++ ")"
        in if null caps then arc else "{ " ++ preClones ++ arc ++ " }"
    -- An EVENT-callback field (`onChange : String -> msg` / `onCheck : Bool ->
    -- msg`) is ALWAYS `Arc<dyn Fn>` (typeToRustString renders the arrow that way
    -- — same shape in a named-alias struct and an Anon struct's pinned generic),
    -- so a bare ctor / fn ITEM (`onChange = UpdateEditTitle`) must Arc-wrap even
    -- in an Anon struct where `wrapNonLambda = False`. A capturing lambda is
    -- already wrapped by the Lambda arm above. CRUCIALLY a `VarLocal` whose value
    -- is ALREADY the Arc-typed callback (the stdlib chain's `handler` param in
    -- `OnString "input" handler`) must NOT be re-wrapped — that would nest
    -- `Arc<Arc<dyn Fn>>`. So gate on the expr being a fn ITEM (ctor / top-level
    -- ref), which is what coerces from `fn` into `Arc::new`.
    --
    -- B#1 gate: an EVENT callback is `(String|Bool) -> <Msg>` where the result
    -- is the app message type (a user ADT). Its Std.Ui/Std.Html slot —
    -- a named-alias field, an Anon-cfg field consumed by `std_ui_input_*`
    -- (`onChange : String -> msg`), or the `Event::On*` ctor — is `Arc<dyn Fn>`,
    -- so a bare fn item must Arc-wrap. The discriminator is the RESULT type, not
    -- the wrapper kind: a non-event `(String|Bool) -> <primitive>` field
    -- (`scorer : String -> Int`) renders a bare `fn` slot (typeToRustString only
    -- emits Arc when the result is the polymorphic msg var), so wrapping a fn
    -- item there emits `Arc::new(item)` into a bare-`fn` slot → `E0308` (B#1).
    -- `targetIsArcFn` is kept as an explicit guarantee for the `Event::On*` ctor
    -- arm even though its result is already a Msg.
    _ | isEventCallbackRegion, isFnItem -> "std::sync::Arc::new(" ++ rendered ++ ")"
    _ | wrapNonLambda, isFnRegion -> "std::sync::Arc::new(" ++ rendered ++ ")"
    _ -> rendered
  where
    isFnRegion = case Map.lookup region (ecRegionTypes ctx) of
        Just (Can.TLambda _ _) -> True
        _                      -> False
    -- The VALUE region is MONOMORPHIC here (`UpdateEditTitle : String ->
    -- StateMsg`), so the FIELD's `String -> msg` TVar result has been pinned to
    -- the concrete Msg ADT. We gate on arg = `String`/`Bool` AND result NOT a
    -- concrete PRIMITIVE (Int/Float/Bool/String/Char/() — a non-event handler
    -- like `scorer : String -> Int` whose slot is a bare `fn`, not `Arc<dyn Fn>`
    -- — B#1). The remaining shape — concrete-arg, ADT-result — is exactly the
    -- event handler the Arc-typed field expects. `targetIsArcFn` (set only by the
    -- `Event::On*` ctor) forces the wrap even if a future Msg type were named
    -- like a primitive. Combined with `isFnItem` (a bare ctor / top-level fn ref,
    -- never an already-Arc `VarLocal`), this can't over-wrap.
    isEventCallbackRegion = case Map.lookup region (ecRegionTypes ctx) of
        Just (Can.TLambda arg res) ->
            isEventArgType arg && (targetIsArcFn || not (isPrimitiveResultType res))
        _ -> False
    -- A bare fn ITEM (an enum ctor used as `String -> msg`, or a top-level fn
    -- ref) coerces into `Arc::new`; a `VarLocal` already holds the Arc value.
    isFnItem = case e of
        Can.VarCtor{}     -> True
        Can.VarTopLevel{} -> True
        _                 -> False

-- | A concrete scalar/leaf type a non-event `(String|Bool) -> _` handler can
-- return (`scorer : String -> Int`). When the result of a concrete-arg function
-- is one of these, the field is NOT a Std.Ui/Std.Html event-callback slot
-- (which always returns the polymorphic msg ADT → `Arc<dyn Fn>`); it renders a
-- bare `fn`, so the value must NOT be Arc-wrapped (B#1). Conservatively scoped:
-- only the primitive leaves, so an app `Msg` ADT result still counts as an event
-- callback and gets the Arc wrap (skyshop `onChange : String -> StateMsg`).
isPrimitiveResultType :: Can.Type -> Bool
isPrimitiveResultType (Can.TType _ n []) =
    n `elem` ["Int", "Float", "Bool", "String", "Char"]
isPrimitiveResultType (Can.TType _ "Unit" []) = True
isPrimitiveResultType _ = False

-- | The Rust element type of a list expression, from its solved region type
-- (`List a` -> typeToRustString a). Used to type a list-HOF closure's param
-- (`List.filter (\m -> …) xs` -> m : <elem of xs>). Nothing when the region
-- type is absent or not a concrete List.
-- | The accumulator type `b` of a fold function `f : a -> b -> b` — its 2nd
-- parameter type, used to type a foldl/foldr empty INIT. Named fold fns only
-- (sig from solvedTypes — same lookup calleeArity/succeedArity use); a lambda
-- fold fn returns Nothing so the init keeps emitEmptyArg's default.
foldAccTypeOf :: EmitCtx -> Can.Expr -> Maybe Can.Type
foldAccTypeOf ctx fn = case fn of
    Ann.At _ (Can.VarTopLevel _ nm) -> accOf nm
    Ann.At _ (Can.VarLocal nm)      -> accOf nm
    -- An inline fold fn `\elem acc -> body`: `body` returns `b` (foldl is
    -- `b -> b`), so the body's solved region type IS the accumulator type — e.g.
    -- `\r acc -> Dict.insert k () acc` gives `Dict String ()` so the empty init
    -- pins `::<String, ()>` not the `::<String, i64>` default.
    Ann.At _ (Can.Lambda _ (Ann.At br _)) ->
        case Map.lookup br (ecRegionTypes ctx) of
            Just t | not (hasTypeVars t) -> Just t
            _                            -> Nothing
    _                               -> Nothing
  where
    -- ecModuleEnv (the CURRENT module's sigs) FIRST — a same-module fold helper
    -- (insertByBucketName) is often absent from the flat solvedTypes; this also
    -- avoids the bare-name cross-module collision the flat map has. Falls back
    -- to the flat map for an imported fold fn.
    accOf nm = case Map.lookup nm (ecModuleEnv ctx) of
        Just ty -> fromSig ty
        Nothing -> case Map.lookup nm (ecSolvedTypes ctx) of
            Just ty -> fromSig ty
            Nothing -> Nothing
    fromSig ty = let ps = extractParamTypes ty
                 in if length ps >= 2 then Just (ps !! 1) else Nothing

-- | G1 gate: is the region's expected type ABSENT, or a Result whose payload
-- still carries free type vars? Only then is the Ok/Err ctor genuinely being
-- DEFAULTED (the concrete-both-sides arm did not fire). A concrete, or a
-- Task-shaped, or any non-Result expected type returns False — we must not
-- override it. Excluding Task is load-bearing: a `Result` ctor inside a
-- Task-returning body (`main : Task Error ()`) must NOT be pinned to the Task's
-- value slot, which would mis-pin an arbitrary nested `Ok 41` arg to `()`.
expectedIsFreeResultOrAbsent :: Maybe Can.Type -> Bool
expectedIsFreeResultOrAbsent Nothing = True
expectedIsFreeResultOrAbsent (Just (Can.TType _ "Result" args)) = any hasTypeVars args
expectedIsFreeResultOrAbsent (Just _) = False

-- | G1 recovery: the (errType, okType) pair to turbofish a defaulted Ok/Err
-- ctor, recovered from the enclosing fn's return type. Fires ONLY when that
-- return is a CONCRETE `Result E A` — both slots free of type vars. NOT Task: a
-- Result ctor never constructs a Task's value slot, so recovering from a
-- `Task E A` enclosing return would pin the wrong type (e.g. main's
-- `Task Error ()` → `()`). A polymorphic enclosing return (`Result Error a`)
-- returns Nothing so the caller keeps the i64 default and never over-pins a
-- genuinely polymorphic function.
enclosingResultPayload :: Maybe Can.Type -> Maybe (Can.Type, Can.Type)
enclosingResultPayload (Just (Can.TType _ "Result" [errTy, okTy]))
    | not (hasTypeVars errTy), not (hasTypeVars okTy) = Just (errTy, okTy)
enclosingResultPayload _ = Nothing

listElemRustType :: EmitCtx -> Can.Expr -> Maybe String
listElemRustType ctx (Ann.At region inner) =
    case Map.lookup region (ecRegionTypes ctx) of
        Just (Can.TType _ "List" [elemTy]) | not (hasTypeVars elemTy) ->
            Just (typeToRustString (ecRecordMap ctx) elemTy)
        -- The region type is often absent for a `record.field` list arg. Resolve
        -- it from ecStructFields: across every struct, find fields named `field`
        -- whose type is `List e`; if they all agree on `e`, use it.
        _ -> case inner of
            Can.Access _ (Ann.At _ field) ->
                let elems = nub
                        [ typeToRustString (ecRecordMap ctx) e
                        | fm <- Map.elems (ecStructFields ctx)
                        , Just (Can.TType _ "List" [e]) <- [Map.lookup field fm]
                        , not (hasTypeVars e) ]
                in case elems of
                    [single] -> Just single
                    _        -> Nothing
            -- The list arg is a CALL (`distinct_trace_ids(rows) : List String`),
            -- so its region type is often absent. Resolve the callee's declared
            -- return type from the env and peel `List e` off it — lets a HOF
            -- closure over a fn-returned list infer its element param (the
            -- console's `\tid -> …` filtered over `distinctTraceIds rows`, E0282).
            Can.Call (Ann.At _ callee) callArgs ->
                case calleeRetName callee >>= \n -> Map.lookup n (ecSolvedTypes ctx) of
                    Just ty -> case peelArrowsN (length callArgs) ty of
                        Can.TType _ "List" [e] | not (hasTypeVars e) ->
                            Just (typeToRustString (ecRecordMap ctx) e)
                        _ -> Nothing
                    Nothing -> Nothing
            _ -> Nothing
  where
    calleeRetName (Can.VarTopLevel _ n) = Just n
    calleeRetName (Can.VarLocal n)      = Just n
    calleeRetName _                     = Nothing
    peelArrowsN :: Int -> Can.Type -> Can.Type
    peelArrowsN 0 t                 = t
    peelArrowsN k (Can.TLambda _ r) = peelArrowsN (k - 1) r
    peelArrowsN _ t                 = t

-- | Resolve the field-name -> declared-type map for the struct an update
-- targets (`{ record | f = … }`). The record subexpr's solved region type is
-- often absent for a bare param ref (`model`), so instead find the struct in
-- ecStructFields whose field set is a SUPERSET of the updated field names —
-- preferring the tightest fit (fewest extra fields). Mirrors the record
-- bestMatch in TypeRenderer. Returns empty when nothing matches (the update
-- then keeps today's no-expected-type emission).
updateRecordFields :: EmitCtx -> [String] -> Map.Map String Can.Type
updateRecordFields ctx updFieldNames
    | null updFieldNames = Map.empty
    | otherwise =
        let want = Set.fromList updFieldNames
            candidates =
                [ (Map.size fm - Set.size want, fm)
                | (_, fm) <- Map.toList (ecStructFields ctx)
                , want `Set.isSubsetOf` Map.keysSet fm ]
        in case candidates of
            [] -> Map.empty
            _  -> snd (minimumBy (\(a,_) (b,_) -> compare a b) candidates)

-- | Value-type turbofish for `dict_empty` (`Dict.empty : Dict k v ->
-- HashMap<String, V>`). The default `::<i64>` (Types.kernelsNeedingErrorPin)
-- mistypes an empty dict whose VALUE is anything else — e.g. a record field
-- `configInput : Dict String String` initialised to `Dict.empty` rendered as
-- `dict_empty::<i64>()` => HashMap<String,i64> ≠ HashMap<String,String>
-- (17-skymon). When the wrapping region's solved type is a concrete
-- `Dict _ v`, pin V; otherwise keep the i64 default.
dictEmptyPin :: EmitCtx -> String
dictEmptyPin ctx = case ecExpectedType ctx of
    -- dict_empty is now generic over BOTH key and value (HashMap<K, V>), so
    -- pin both from a concrete `Dict k v` expected type. Default to a
    -- String-keyed i64-valued dict (the historical String-key shape) when the
    -- context is absent — an empty dict in a typed slot almost always carries
    -- its region type, so the default rarely fires.
    Just (Can.TType _ "Dict" [k, v]) | not (hasTypeVars k), not (hasTypeVars v) ->
        "::<" ++ typeToRustString (ecRecordMap ctx) k ++ ", " ++ typeToRustString (ecRecordMap ctx) v ++ ">"
    _ -> "::<String, i64>"

-- | Value-type turbofish for `set_empty` (`Set.empty : Set a -> BTreeSet<A>`).
-- Pins A from a concrete `Set a` expected type; otherwise the i64 default
-- (kernelsNeedingErrorPin) — an empty set in a typed slot almost always
-- carries its region type, so the default rarely fires. Mirrors dictEmptyPin.
setEmptyPin :: EmitCtx -> String
setEmptyPin ctx = case ecExpectedType ctx of
    Just (Can.TType _ "Set" [a]) | not (hasTypeVars a) ->
        "::<" ++ typeToRustString (ecRecordMap ctx) a ++ ">"
    _ -> "::<i64>"

taskFailPin :: EmitCtx -> String
taskFailPin ctx
    | ecInGenericFn ctx = ""
    | otherwise = case ecExpectedType ctx of
        Just (Can.TType _ "Task" [_, a]) | not (hasTypeVars a) ->
            "::<_, " ++ typeToRustString (ecRecordMap ctx) a ++ ">"
        -- No concrete expected type: fall back to the enclosing function's
        -- own Task return element (sleepThenFail : Task Error a, where the
        -- helper's sig stays polymorphic but the call-site resolved a=String
        -- onto the rendered SkyTask<String> signature). Beats the i64 default.
        _ -> case ecReturnElem ctx of
            Just elemTy | elemTy /= "i64" -> "::<_, " ++ elemTy ++ ">"
            _ -> "::<_, i64>"

-- | The emitted Rust name of a call's callee, for GENERATED stdlib functions
-- (which aren't kernels, so calleeKernelName returns Nothing). A VarTopLevel
-- emits as `toSnakeCase(mod_name)` — e.g. Sky.Core.Error.toString →
-- "sky_core_error_to_string".
emittedCalleeName :: Can.Expr -> Maybe String
emittedCalleeName (Ann.At _ (Can.VarTopLevel mod nm)) =
    Just (toSnakeCase (map (\c -> if c == '.' then '_' else c) (ModuleName._name mod) ++ "_" ++ nm))
emittedCalleeName _ = Nothing

-- | Arg type of a generated stdlib function with a fixed monomorphic param,
-- for closure-param inference (`sky_core_error_to_string(e)` → `e : SkyError`).
genFnArgType :: String -> Int -> Maybe String
genFnArgType "sky_core_error_to_string" 0 = Just "SkyError"
genFnArgType _ _ = Nothing

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
       else -- `snakeName == kName` only means kernelToRust used the default
            -- snake-case mangling — a kernel whose Rust name happens to equal
            -- the default (e.g. `Process.run` → `sky_core_process_run`) still
            -- has a known Task inner type. Try the solved type FIRST, then fall
            -- back to the VarKernel inner-type table (harmless "" if unknown).
            let fromSolved = case Map.lookup name solved of
                                 Just ty -> taskInnerTypeStr (extractReturnType ty)
                                 Nothing -> ""
                fromKernel = taskExprInnerTypeCall solved (Ann.At fakeSpan (Can.VarKernel rawMod name)) args
            -- The flat `solved` map keys on the bare fn name, so a cross-module
            -- `run` collides; its non-Task return extracts to "". Prefer the
            -- solved type ONLY when it actually yields a Task inner type, else
            -- fall back to the VarKernel inner-type table.
            in if not (null fromSolved) then fromSolved else fromKernel
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
        | "Trace" `isSuffixOf` modName || modName == "Trace" = case fnName of
            -- span : String -> Task e a -> Task e a — inner type is the wrapped
            -- task's. event / attr are Task Error () — inner is ().
            "span" -> case args of
                [_, task] -> taskExprInnerType solved task
                _ -> ""
            "event" -> "()"
            "attr"  -> "()"
            _ -> ""
        | "Db" `isSuffixOf` modName || modName == "Db" = case fnName of
            "query"    -> "Vec<HashMap<String, String>>"
            "exec"     -> "()"
            "execRaw"  -> "()"
            "connect"  -> "Db"
            "getField" -> "String"
            "getString" -> "String"
            "getInt"   -> "i64"
            -- Row-CRUD kernels have FIXED success types (the runtime fns are
            -- `SkyTask<E, _>` — ONE generic param). Listing them here makes
            -- taskExprInnerType non-empty so the `::<_, ()>` task-pin (which
            -- assumes a 2-generic-param `<E, A>` shape) does NOT fire on them
            -- — a stray `db_insert_row::<_, ()>` is E0107 against `<E>`.
            "insertRow"       -> "i64"
            "deleteById"      -> "i64"
            "updateById"      -> "i64"
            "insertFields"    -> "i64"
            "updateFields"    -> "i64"
            "getById"         -> "SkyMaybe<HashMap<String, String>>"
            "findOneByField"  -> "SkyMaybe<HashMap<String, String>>"
            "findManyByField" -> "Vec<HashMap<String, String>>"
            "findByConditions" -> "Vec<HashMap<String, String>>"
            "unsafeFindWhere" -> "Vec<HashMap<String, String>>"
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
        | "Process" `isSuffixOf` modName || modName == "Process" = case fnName of
            "run" -> "String"   -- Process.run : … -> Task Error String
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
        -- (`decode_list::<SkyError, _>`), so the bare name is a prefix, not a
        -- suffix. `list` takes `impl Fn() -> Decoder`, so its decoder arg is
        -- wrapped in a `||` factory closure below. (Suffix-matching silently
        -- skipped the wrap once the turbofish was added — list never re-runs its
        -- element decoder otherwise.)
        isListDec = "decode_list" `isPrefixOf` calleeName
        -- Sub-A.13: empty-collection args (`[]`, `Nothing`) carry no element
        -- type for Rust to infer. Resolve each from the callee's param types:
        -- concrete -> turbofish, var-shared-with-sibling -> bare, var-only-here
        -- -> default filler, unknown callee -> bare. Non-empty args keep the
        -- normal clone-aware emit.
        paramStrs = calleeParamStrings ctx fn (length args)
        -- Constructor arg positions whose field type IS the enum being
        -- constructed (direct self-recursion → boxed in the enum def, see
        -- TypeEmitter.boxIfRecursive). Those args must be wrapped in Box::new.
        -- Same predicate as the type side: the field renders to the enum's own
        -- Rust name (the `kernelCtorToRust`-produced `Type::Variant` head).
        ctorBoxedPositions = case fn of
            Ann.At _ (Can.VarCtor _ _ _ cn _)
                | Just fieldTys <- Map.lookup cn (ecCtorFieldTypes ctx) ->
                    let typeRust = takeWhile (/= ':') calleeName
                    in [ i | (i, t) <- zip [0 :: Int ..] fieldTys
                           , typeToRustString (ecRecordMap ctx) t == typeRust ]
            _ -> []
        -- A param typed `Arc<dyn Fn(String) -> ..>` / `Arc<dyn Fn(Bool) -> ..>`
        -- is an event-callback slot (the `String -> msg` / `Bool -> msg` handler
        -- shape — see typeToRustString). A bare fn ITEM passed there (`f
        -- MainMsg::Edit`, a ctor used as the handler) must Arc-wrap — a fn item
        -- coerces into `Arc::new` but not implicitly into `Arc<dyn Fn>`. A
        -- lambda / an already-Arc local arg is handled by the normal path.
        isEventCbParam i = paramTypeIsEventCb i || (i == 0 && calleeIsEventHelper)
        -- An event callback is `(String|Bool) -> msg` — result is the app MSG
        -- ADT, NEVER a `SkyTask`. Exclude Task-returning `(String|Bool) -> Task`
        -- params: those render the same `Arc<dyn Fn(String) -> …>` shape (via
        -- typeToRustString's Task-arrow arm) but are EFFECTFUL HOF callbacks
        -- (`forEachChunk`'s `\chunk -> emit chunk writer`) whose runtime slot is
        -- `impl Fn`, not Arc — Arc-wrapping their lambda arg there is E0277
        -- (32-sse-relay). The event-cb arm only fires for the genuine msg-result
        -- shape.
        paramTypeIsEventCb i = case paramStrs of
            Just (_, ps) -> case drop i ps of
                (p:_) -> ("std::sync::Arc<dyn Fn(String)" `isPrefixOf` p
                          || "std::sync::Arc<dyn Fn(Bool)" `isPrefixOf` p)
                         && not ("-> SkyTask<" `isInfixOf` p)
                _     -> False
            Nothing -> False
        -- The Std.Ui / Std.Html event-helper functions take a single
        -- `(String -> msg)` / `(Bool -> msg)` callback (now an `Arc<dyn Fn>`
        -- param) and build `Event::OnString`/`OnBool`. Their solved sig isn't
        -- always in `ecSolvedTypes` at the call site (stdlib fns), so name-match
        -- the lowered callee directly as a backstop to the param-type check.
        calleeIsEventHelper = takeWhile (/= ':') calleeName `elem`
            [ "std_ui_on_input", "std_ui_on_change", "std_ui_on_check"
            , "std_html_events_on_input", "std_html_events_on_change"
            , "std_html_events_on_check", "std_html_events_on_key_down"
            , "std_html_events_on_key_up", "std_html_events_on_key_press"
            , "std_html_events_on_file", "std_html_events_on_image" ]
        isBareFnItemArg (Ann.At _ (Can.VarCtor{}))     = True
        isBareFnItemArg (Ann.At _ (Can.VarTopLevel{})) = True
        isBareFnItemArg _                              = False
        -- A param typed `Arc<dyn Fn(..) -> SkyTask<..> ..>` is a `Handler` slot
        -- (an effectful route handler — see typeToRustString's Task-arrow arm). A
        -- BARE Handler value passed there (a `let`-bound handler function
        -- `todosByMethod` flowing into a middleware-wrapper closure `guarded
        -- todosByMethod`, or a top-level handler ref) is rendered as a plain
        -- closure / fn item, which does NOT coerce to the `Arc<dyn Fn>` slot.
        -- Arc-wrap it (the `Arc<concrete>` unsizes to `Arc<dyn Fn>` at the typed
        -- param). Distinct from the event-cb arm (`Arc<dyn Fn(String|Bool) ->
        -- msg>`): here the RESULT is a `SkyTask`, never a bare msg.
        -- ONLY a LOCAL let-bound closure (a middleware-wrapper `guarded` /
        -- `wrap` / `cors`) genuinely renders its `Handler` param as `Arc<dyn Fn>`.
        -- A kernel / runtime HOF whose `Handler`-shaped param is `impl Fn` (e.g.
        -- `task_on_error`'s `e -> Task e2 a`) must NOT trigger the Arc-wrap — its
        -- `paramStrs` is reconstructed via `typeToRustString` (which renders
        -- Task-arrows as Arc), so it would falsely match. Gate on the callee being
        -- a local closure so only the real Arc-param consumers fire.
        calleeIsLocalClosure = case fn of
            Ann.At _ (Can.VarLocal cn) -> Map.member cn (ecClosureDefs ctx)
            _                          -> False
        isHandlerArcParam i = calleeIsLocalClosure && case paramStrs of
            Just (_, ps) -> case drop i ps of
                (p:_) -> "std::sync::Arc<dyn Fn(" `isPrefixOf` p
                         && "-> SkyTask<" `isInfixOf` p
                         && not ("std::sync::Arc<dyn Fn(String)" `isPrefixOf` p)
                         && not ("std::sync::Arc<dyn Fn(Bool)" `isPrefixOf` p)
                _     -> False
            Nothing -> False
        -- A bare Handler VALUE that is NOT already an `Arc<dyn Fn>`: a top-level
        -- handler fn ref, OR a `let`-bound LOCAL function (in ecClosureDefs —
        -- `let todosByMethod req = …`, rendered as a plain `move |req| …`). A
        -- closure PARAMETER named like a handler (`h` in `guarded h = …`) is
        -- ALREADY `Arc<dyn Fn>` (its slot rendered that way) and must NOT be
        -- re-wrapped (`Arc<Arc<dyn Fn>>`); it is a VarLocal but NOT in
        -- ecClosureDefs, so the membership test excludes it.
        isBareHandlerArg (Ann.At _ (Can.VarTopLevel{}))  = True
        isBareHandlerArg (Ann.At _ (Can.VarLocal lname)) = Map.member lname (ecClosureDefs ctx)
        isBareHandlerArg _                               = False
        -- B#2: a CAPTURING lambda passed DIRECTLY to an event helper
        -- (`Ev.onInput (\s -> Typed (model.prefix ++ s))`) targets an
        -- `Arc<dyn Fn(String) -> Msg + Send + Sync>` param. `argToRustString`
        -- already renders it as a `move |..| {..}` capture-cloning closure, but
        -- it is NEVER Arc-wrapped → `E0308 expected Arc<..>, found closure`. Wrap
        -- the rendered closure in `Arc::new` (same target as a bare fn item).
        isEventCbLambdaArg (Ann.At _ (Can.Lambda{})) = True
        isEventCbLambdaArg _                         = False
        -- A `Result` Ok/Err ctor used as a call argument (`f (Ok x)`), the form
        -- whose region the solver often leaves free → i64-defaulted payload.
        isResultCtorArg (Ann.At _ (Can.Call (Ann.At _ (Can.VarCtor _ _ "Result" cn _)) [_])) =
            cn == "Ok" || cn == "Err"
        isResultCtorArg _ = False
        emitArg i a
            | isHandlerArcParam i, isBareHandlerArg a
                              = "std::sync::Arc::new(" ++ argToRustString ctx noCloneFn a ++ ")"
            | isEventCbParam i, isBareFnItemArg a || isEventCbLambdaArg a
                              = "std::sync::Arc::new(" ++ argToRustString ctx noCloneFn a ++ ")"
            | i `elem` ctorBoxedPositions
                              = "Box::new(" ++ argToRustString ctx noCloneFn a ++ ")"
            -- G1 (call-arg): a `Result` ctor ARG (`f (Ok x)` / `f (Err e)`)
            -- whose own region the solver left free defaults the payload to i64
            -- (the ctor's fallback arm). When the callee's param slot at this
            -- position is a CONCRETE `Result E A`, seed it at the arg's region so
            -- the ctor's concrete-both-sides arm constructs the right type — same
            -- mechanism as the foldl-init seed below. Concrete-only (no free vars)
            -- so a genuinely polymorphic callee param stays bare for Rust to infer.
            | isResultCtorArg a
            , Just slotTy <- calleeParamCanTypeAt ctx fn i
            , Can.TType _ "Result" _ <- slotTy
            , not (hasTypeVars slotTy)
            , Ann.At ar _ <- a
                              = exprToRustString (ctx { ecRegionTypes = Map.insert ar slotTy (ecRegionTypes ctx) }) a
            -- A Result ctor arg we could NOT precisely seed (callee param is
            -- polymorphic / unknown): mark it so the ctor's ecEnclosingRet
            -- recovery arm declines (a call-arg ctor's type is the callee's slot,
            -- never the enclosing return), keeping the sound i64/inference default.
            | isResultCtorArg a
                              = argToRustString (ctx { ecInResultCtorArg = True }) noCloneFn a
            -- foldl/foldr INIT (arg 1) is the accumulator `b`, whose type is the
            -- fold FUNCTION's 2nd parameter type (`f : a -> b -> b`). An empty
            -- `Dict.empty` / `[]` accumulator can't infer `b` from the generic
            -- foldl param (emitEmptyArg then defaults it wrongly —
            -- HashMap<String,i64> for a `Dict Int (List Row)` grouping). Seed `b`
            -- — read off the fold fn's signature, always available unlike the
            -- call-site expected type — at the init's region so dictEmptyPin /
            -- the empty-literal turbofish read it. 35-composite-generics.
            | i == 1, bareCallee `elem` ["list_foldl", "list_foldr"]
            , Just accTy <- foldAccTypeOf ctx (head args), not (hasTypeVars accTy)
            , Ann.At ar _ <- a
                              = exprToRustString (ctx { ecRegionTypes = Map.insert ar accTy (ecRegionTypes ctx) }) a
            | isEmptyishArg a = emitEmptyArg ctx paramStrs i a
            -- An Int literal passed where the callee wants f64 (Sky's numeric-
            -- literal coercion: `Css.pct 100` → `std_css_pct(n: f64)`) must emit
            -- as f64 — Rust does NOT coerce an i64 literal (E0308).
            | Ann.At _ (Can.Int n) <- a
            , kernelArgRustType (takeWhile (/= ':') calleeName) i == Just "f64"
                              = show n ++ "_f64"
            -- A `vec![…]` passed where the callee wants `Vec<String>` (e.g.
            -- `Db.exec … [ok, failed, total, ts]` → db_exec arg2) must coerce
            -- each non-String element — Sky's `List a` DB params allow Ints, but
            -- the runtime kernel is monomorphic `Vec<String>` (E0308 otherwise).
            | Ann.At _ (Can.List elems) <- a
            , kernelArgRustType (takeWhile (/= ':') calleeName) i == Just "Vec<String>"
                              = "vec![" ++ intercalate ", " (map coerceElemToString elems) ++ "]"
            -- A closure ARG of a list HOF (`List.filter (\m -> m.id == …) xs`)
            -- gets its single param typed from the LIST arg's element type, not
            -- the ambiguous field-match (3 structs share `id` → wrong ADT).
            | i == 0, isListHofClosurePos
            , Ann.At _ (Can.Lambda _ _) <- a
            , Just et <- listElemRustType ctx (last args)
                              -- Also clear ecPipeInnerType: a list-HOF element
                              -- closure (`List.map (\r -> r.tx.account) rows`)
                              -- is NOT a Task-pipe closure, so the outer pipe's
                              -- Task type must not leak in as a `-> SkyTask<…>`
                              -- return annotation on a plain-value closure
                              -- (report.rs `r.tx.account : String` annotated Task).
                              = argToRustString (ctx { ecForcedClosureParam = Just et, ecPipeInnerType = Nothing
                                                     , ecIndexedHofClosure = bareCallee == "list_indexed_map"
                                                     , ecBinaryHofClosure = bareCallee `elem` ["list_sort_with", "sky_core_list_sort_with"] }) noCloneFn a
            | otherwise       = argToRustString ctx noCloneFn a
        bareCallee = takeWhile (/= ':') calleeName
        -- list HOFs whose FIRST arg is the element-consuming closure and whose
        -- LAST arg is the list (map/filter/find/any/all/concatMap/indexedMap/
        -- partition). foldl/foldr put the list last too but their closure is
        -- 2-arg (acc, elem) — excluded (the single-param guard skips them anyway).
        isListHofClosurePos = bareCallee `elem`
            [ "list_map", "list_filter", "list_find", "list_any", "list_all"
            , "list_concat_map", "list_indexed_map", "list_partition"
            , "list_map_consume", "list_take_while", "list_drop_while"
            -- sortBy: key fn `(a -> comparable)` is 1-param (the element).
            -- sortWith: comparator `(a -> a -> Int)` is 2-param; BOTH params
            -- are the ELEMENT type. `ecForcedClosureParam` (set at the
            -- emit-arg site below) carries that element type; the
            -- `ecBinaryHofClosure` flag makes annotPsIx apply it to param 0
            -- AND param 1 (vs the default param-0-only).
            , "list_sort_by", "sky_core_list_sort_by"
            , "list_sort_with", "sky_core_list_sort_with"
            -- foldl/foldr: 2-param closure (element, acc); param 0 is the element
            -- (annotPsIx types only index 0), element type from the list (last arg).
            , "list_foldl", "list_foldr"
            -- The pure-Sky stdlib forms (`List.find`/`map`/… resolved to the
            -- recursive `sky_core_list_*` def, not the kernel) share the exact
            -- (closure, …, list) arg shape. Without these, an ambiguous-field
            -- closure (`\s -> s.name == name` over a Vec<StateServiceStat>, where
            -- `name` is also a field of StateMetricRow) mis-resolves via the
            -- field-set fallback (console Overview, E0308).
            , "sky_core_list_map", "sky_core_list_filter", "sky_core_list_find"
            , "sky_core_list_any", "sky_core_list_all", "sky_core_list_concat_map"
            , "sky_core_list_take_while", "sky_core_list_drop_while"
            , "sky_core_list_foldl", "sky_core_list_foldr" ]
            && not (null args)
        -- Coerce a db-param list element to String uniformly via `format!`.
        -- Sky's `List a` DB params are heterogeneous (Int/String/Bool — the Go
        -- runtime boxes as `any`), and a List ELEMENT's region carries the
        -- UNIFIED element type, not the element's own, so a per-type wrap
        -- mis-fires (wrapped a String `ts` in string_from_int). `format!("{}",
        -- x)` is Display-based: identity for String, decimal for Int/Float,
        -- "true"/"false" for Bool — correct for every scalar db param.
        coerceElemToString e =
            "format!(\"{}\", " ++ argToRustString ctx noCloneFn e ++ ")"
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
        -- A call whose callee is a record FIELD access (`rec.field`) calls a
        -- function-typed field; Rust reads `rec.field(args)` as a method call
        -- (E0599). Sky records have no methods, so parenthesise the field access:
        -- `(rec.field)(args)`. (The console's StateStore callback record.)
        callee = case fn of
            Ann.At _ (Can.Access _ _) -> "(" ++ exprToRustString ctx fn ++ ")"
            _ -> exprToRustString ctx fn
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
    -- A unit literal is `()` — e.g. `Task.succeed ()` has inner type `()`. The
    -- prior `_ -> "String"` default mis-typed it as `String` (a `task_succeed(())`
    -- annotated `SkyTask<String>` then E0308'd). Narrow + unambiguously correct.
    Ann.At _ Can.Unit      -> "()"
    -- A list literal is unambiguously a Vec — drives `++` to Vec-concat even
    -- when the other operand is an opaque field access (e.g. the stdlib's
    -- `msg.attachments ++ [ att ]` on a bridged-struct List field, where the
    -- access side resolves to "String" and would otherwise pick format!).
    Ann.At _ (Can.List _)  -> "Vec<_>"
    -- An `if`/`case` expression has its branches' type. `++` over a chain of
    -- `if cond then [x] else []` (the console's LogsTab `levels` filter) must
    -- see those branches as Vec, else both operands fall to the "String"
    -- default and the outer `++` mis-emits format! over Vec<String> (E0308).
    -- Probe every branch; first Vec wins (matches ++'s list preference).
    Ann.At _ (Can.If brs el) ->
        let tys = solveArgType solvedMap el : map (solveArgType solvedMap . snd) brs
        in case filter ("Vec<" `isPrefixOf`) tys of
             (v:_) -> v
             []    -> case tys of { (t:_) -> t; [] -> "String" }
    Ann.At _ (Can.Case _ branches) ->
        let tys = [ solveArgType solvedMap b | Can.CaseBranch _ b <- branches ]
        in case filter ("Vec<" `isPrefixOf`) tys of
             (v:_) -> v
             []    -> case tys of { (t:_) -> t; [] -> "String" }
    Ann.At _ (Can.VarLocal name) ->
        case Map.lookup name solvedMap of
            Just ty -> typeToRustString Map.empty ty
            Nothing -> "String"
    Ann.At _ (Can.Binop op _ _ _ a b) ->
        case op of
            "+" -> "i64"; "-" -> "i64"; "*" -> "i64"
            "/" -> "i64"; "//" -> "i64"; "%" -> "i64"
            -- `++` is polymorphic (String OR List). Recurse into both operands
            -- so a nested list-append chain (`xs ++ ys ++ zs`) stays a Vec even
            -- when an intermediate operand is itself a `++` — the previous
            -- hardcoded "String" made the outer `++` fall back to format!
            -- (Std.Ui.Chart's gridLines ++ axesNodes ++ seriesPaths).
            "++" -> let ta = solveArgType solvedMap a
                        tb = solveArgType solvedMap b
                    in if "Vec<" `isPrefixOf` ta then ta
                       else if "Vec<" `isPrefixOf` tb then tb
                       else "String"
            "&&" -> "bool"; "||" -> "bool"
            "==" -> "bool"; "/=" -> "bool"
            _ -> solveArgType solvedMap a
    -- A call's type is the callee's return type. Resolve it from the env
    -- (`_stEnv` carries top-level fn types by name), peeling exactly as many
    -- arrows as args supplied. Lets `++` see that a Vec-returning helper call
    -- (`implicitFillIfHoisted layoutAttrs : List (Attribute msg)`) is a list,
    -- not the "String" default → Vec-append instead of format!.
    Ann.At _ (Can.Call (Ann.At _ callee) callArgs) ->
        case calleeNm callee >>= \n -> Map.lookup n solvedMap of
            Just ty -> typeToRustString Map.empty (peelArrows (length callArgs) ty)
            Nothing -> "String"
    _ -> "String"
  where
    calleeNm (Can.VarTopLevel _ n) = Just n
    calleeNm (Can.VarLocal n)      = Just n
    calleeNm _                     = Nothing
    peelArrows :: Int -> Can.Type -> Can.Type
    peelArrows 0 t                      = t
    peelArrows k (Can.TLambda _ r)      = peelArrows (k - 1) r
    peelArrows _ t                      = t

-- | Collect every let-bound closure DEFINITION (a Def with >=1 param) anywhere
-- in a function body, as `name -> (params, body)`. Feeds ecClosureDefs so
-- inferParamRustType can resolve a param flowing into a local closure.
collectClosureDefs :: Can.Expr -> Map.Map String ([Can.Pattern], Can.Expr)
collectClosureDefs top = Map.fromList (go top)
  where
    ent (Can.Def (Ann.At _ n) ps b) | not (null ps) = [(n, (ps, b))]
    ent _ = []
    go (Ann.At _ e) = case e of
      Can.Let def rest        -> ent def ++ go (canDefBody def) ++ go rest
      Can.LetRec defs rest    -> concatMap ent defs ++ concatMap (go . canDefBody) defs ++ go rest
      Can.LetDestruct _ x b   -> go x ++ go b
      Can.Lambda _ b          -> go b
      Can.Call f as           -> go f ++ concatMap go as
      Can.Case s bs           -> go s ++ concatMap (\(Can.CaseBranch _ b) -> go b) bs
      Can.If brs el           -> concatMap (\(c, t) -> go c ++ go t) brs ++ go el
      Can.Binop _ _ _ _ a b   -> go a ++ go b
      Can.Access r _          -> go r
      Can.Update _ r ups      -> go r ++ concatMap (\(_, Can.FieldUpdate _ x) -> go x) (Map.toList ups)
      Can.Record fs           -> concatMap (go . snd) (Map.toList fs)
      Can.List xs             -> concatMap go xs
      Can.Tuple a b rest      -> concatMap go (a : b : rest)
      Can.Negate x            -> go x
      _                       -> []

-- | Collect field names accessed (`j.f`) or record-updated (`{ j | f = … }`) on
-- a closure param, to resolve a HOF-closure record param to its struct (Rust
-- can't always infer a closure param from a sibling list arg → E0282).
closureParamFields :: String -> Can.Expr -> Set.Set String
closureParamFields pname = go
  where
    goU (Can.FieldUpdate _ x) = go x
    go (Ann.At _ e) = case e of
      Can.Access (Ann.At _ (Can.VarLocal v)) f | v == pname -> Set.singleton (Ann.toValue f)
      Can.Access r _            -> go r
      Can.Update _ (Ann.At _ (Can.VarLocal v)) ups | v == pname ->
          Set.union (Set.fromList (Map.keys ups)) (Set.unions (map (goU . snd) (Map.toList ups)))
      Can.Update _ r ups        -> Set.union (go r) (Set.unions (map (goU . snd) (Map.toList ups)))
      Can.Call f as             -> Set.unions (go f : map go as)
      Can.Lambda _ b            -> go b
      Can.Let d b               -> Set.union (go (canDefBody d)) (go b)
      Can.LetRec ds b           -> Set.unions (go b : map (go . canDefBody) ds)
      Can.LetDestruct _ x b     -> Set.union (go x) (go b)
      Can.Case s bs             -> Set.unions (go s : [ go b | Can.CaseBranch _ b <- bs ])
      Can.If brs el             -> Set.unions (go el : concat [ [go c, go t] | (c, t) <- brs ])
      Can.Binop _ _ _ _ a b     -> Set.union (go a) (go b)
      Can.Record fs             -> Set.unions (map (go . snd) (Map.toList fs))
      Can.List xs               -> Set.unions (map go xs)
      Can.Tuple a b rest        -> Set.unions (map go (a : b : rest))
      Can.Negate x              -> go x
      _                         -> Set.empty

-- | Resolve a closure record param to its struct via field-name superset match.
inferRecordClosureParam :: EmitCtx -> String -> Can.Expr -> Maybe String
inferRecordClosureParam ctx pname body =
    let fields = closureParamFields pname body
    in if Set.null fields then Nothing else matchStructByFieldsE (ecRecordMap ctx) fields

-- | Struct (recordMap value) with the FEWEST extra fields whose set is a
-- SUPERSET of `fieldSet`. (Duplicate of ModuleEmitter.matchStructByFields, kept
-- here to avoid a cross-module dependency.)
matchStructByFieldsE :: Map.Map String String -> Set.Set String -> Maybe String
matchStructByFieldsE recordMap fieldSet
    | Set.null fieldSet = Nothing
    | otherwise =
        let best = foldr (\(k, nm) acc ->
                     let kSet   = Set.fromList (words (map (\c -> if c == ',' then ' ' else c) k))
                         extras = Set.size kSet - Set.size fieldSet
                     in if fieldSet `Set.isSubsetOf` kSet && extras >= 0
                        then case acc of
                               Nothing                  -> Just (extras, nm)
                               Just (e, _) | extras < e -> Just (extras, nm)
                               _                        -> acc
                        else acc) Nothing (Map.toList recordMap)
        in case best of
             Just (_, nm) | not ("Anon" `isPrefixOf` nm) -> Just nm
             _ -> Nothing

-- | Annotate a closure PVar param from BODY-DRIVEN inference (inferParamRustType
-- scans the body for the kernel the param flows into). Closes E0282 for
-- let-bound closures Rust can't infer (`let insertRow = \db ts -> db_exec(db,
-- sql, vec![…, ts])` → `|db: Db, ts: String|`). The region-type approach failed
-- (solver records expression, not pattern, regions). HOF args route through
-- argToRustString, so List.map/filter closures don't reach here and stay bare.
annotClosureParam :: EmitCtx -> Can.Expr -> Can.Pattern -> String
annotClosureParam ctx body p@(Ann.At _ (Can.PVar pn)) =
    -- Body-driven kernel-flow inference first; then the field-set struct match
    -- (a let-bound closure stored + called later — `let matches = \r -> …r.name…
    -- r.traceId…` — never flows into a HOF, so only its field accesses identify
    -- the record: {name,traceId} → StateTraceRow. Console TracesTab, E0282).
    case inferParamRustType ctx pn body of
        Just t  -> patternToRustParam p ++ ": " ++ t
        Nothing -> case inferRecordClosureParam ctx pn body of
            Just s  -> patternToRustParam p ++ ": " ++ s
            -- Last resort: the solver's per-region types. A let-bound closure
            -- whose param is a plain scalar (`formatOutput buildOutput runOutput
            -- = … String.trim buildOutput …`) gives Rust no way to infer the
            -- param when the closure is stored then called later (E0282), and the
            -- kernel-flow / record heuristics above only cover params that reach
            -- a known kernel arg or a record field. The HM solver already pinned
            -- every USE-site expression region to a concrete type; reading the
            -- param's own use-site regions (NOT its pattern region — the solver
            -- keys on expression, not pattern, regions) recovers `String`/`i64`/…
            -- Narrow by construction: only fires when the type is fully concrete
            -- (no type vars) so we never pin a generic/`impl Fn` param.
            Nothing -> case inferParamRustTypeFromRegions ctx pn body of
                Just t  -> patternToRustParam p ++ ": " ++ t
                Nothing -> patternToRustParam p
annotClosureParam _ _ p = patternToRustParam p

-- | Recover a closure param's Rust type from the solver's per-region type map by
-- reading the type pinned at the param's USE sites in the body. The solver
-- (globalRegionTypes) records types keyed by EXPRESSION region, so the param's
-- own binding-pattern region has no entry — but every `VarLocal pname` use is an
-- expression with a region the solver pinned. The first use whose type is fully
-- concrete (`hasTypeVars` False) yields the annotation. Concrete-only is the
-- soundness gate: a still-generic param (a bare type var, or an `impl Fn` HOF
-- callback) carries type vars at its use sites and is correctly left un-annotated
-- so Rust infers it. This is the general form of the `vecElem` region trick that
-- already resolves heterogeneous db-param list elements.
inferParamRustTypeFromRegions :: EmitCtx -> String -> Can.Expr -> Maybe String
inferParamRustTypeFromRegions ctx pname = firstJust . go
  where
    firstJust = foldr (\x acc -> case x of Just _ -> x; Nothing -> acc) Nothing
    useType region = case Map.lookup region (ecRegionTypes ctx) of
      Just t | not (hasTypeVars t) -> Just (typeToRustString (ecRecordMap ctx) t)
      _                            -> Nothing
    -- Stop descending into any sub-scope that REBINDS `pname` — a shadowed use
    -- belongs to the inner binding, not this param, so its region type would
    -- mis-annotate ours. (In well-typed Sky a clash would still pin a concrete
    -- type rustc validates, but skipping it keeps the inference honest.)
    shadows names = pname `elem` names
    go (Ann.At region e) =
      (case e of
         Can.VarLocal v | v == pname -> [useType region]
         _                           -> [])
      ++ children e
    children e = case e of
      Can.Call fn args        -> concatMap go (fn : args)
      Can.Lambda ps b
        | shadows (concatMap patBindingVars ps) -> []
        | otherwise                             -> go b
      Can.Let d b ->
        let dBodies = if shadows (defParamVars d) then [] else concatMap go (defLocalBodies d)
            bRest   = if shadows (defLocalNames d) then [] else go b
        in dBodies ++ bRest
      Can.LetRec ds b ->
        let names   = concatMap defLocalNames ds
            dBodies = [ x | d <- ds, not (shadows (defParamVars d))
                          , body <- defLocalBodies d, x <- go body ]
            bRest   = if shadows names then [] else go b
        in dBodies ++ bRest
      Can.LetDestruct pat x b
        | shadows (patBindingVars pat) -> go x
        | otherwise                    -> go x ++ go b
      Can.Case s bs           -> go s ++ concat [ go b | Can.CaseBranch p b <- bs
                                                       , not (shadows (patBindingVars p)) ]
      Can.If brs el           -> concat [ go c ++ go t | (c, t) <- brs ] ++ go el
      Can.Binop _ _ _ _ a b   -> go a ++ go b
      Can.Access r _          -> go r
      Can.Update _ r ups      -> go r ++ concat [ go x | (_, Can.FieldUpdate _ x) <- Map.toList ups ]
      Can.Record fs           -> concat [ go x | (_, x) <- Map.toList fs ]
      Can.List xs             -> concatMap go xs
      Can.Tuple a b rest      -> concatMap go (a : b : rest)
      Can.Negate x            -> go x
      _                       -> []

binopToRust :: String -> String
binopToRust op = case op of
    "+" -> "+"
    "-" -> "-"
    "*" -> "*"
    "/" -> "/"
    -- Sky's integer-division operator `//`. Emitting it verbatim is a
    -- catastrophe: `//` starts a Rust line comment, silently commenting out
    -- the rest of the (single-line) function body — every trailing `}` closer
    -- vanishes and rustc reports an unclosed delimiter. Rust `/` on i64
    -- operands IS integer division (truncates toward zero), matching Sky `//`
    -- and Go's int `/`.
    "//" -> "/"
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
        clones = concatMap (\v -> let v' = rustSafeIdent v in "let " ++ v' ++ " = " ++ v' ++ ".clone(); ") multi
        -- Discarded task (`let _ = process_run …` lowers to a Def named "_"):
        -- annotate the wildcard with `: SkyTask<inner>` so the kernel's generic
        -- `E: From<String>` pins to `SkyError` (else E0283 with >1 impl). Only
        -- for a literal "_" binder over a task-typed body whose inner type is
        -- known. See the sibling notes in the LetDestruct / DestructDef arms.
        discardAnnot
            | name == "_"
            , isTaskProducingCall body          -- a CALL, not a var ref
            , inner <- taskExprInnerType (ecSolvedTypes ctx) body
            , not (null inner) = ": SkyTask<" ++ inner ++ ">"
            | otherwise = ""
    in case body of
        Ann.At _ (Can.Lambda [] lambdaBody) ->
            let inner = "|| { " ++ exprToRustString ctx lambdaBody ++ " }"
            in name ++ " = " ++ if null multi then inner else "{ " ++ clones ++ inner ++ " }"
        _ ->
            let inner = exprToRustString ctx body
            in name ++ discardAnnot ++ " = " ++ if null multi then inner else "{ " ++ clones ++ inner ++ " }"
-- Multi-arg Def: closure binding. Params body-driven-annotated (a let-bound
-- closure gives Rust no way to infer them → E0282). Emitted as a `move` closure
-- with captured outer vars cloned first — a let-bound closure that ESCAPES
-- (passed into a Task pipeline, e.g. `readAll` capturing `selectRecent`) must
-- own its captures or Rust rejects it (E0373). Mirrors argToRustString's
-- proven move+clone pattern. No captures → plain (non-move) is fine.
defToRustString ctx (Can.Def (Ann.At _ name) params body) =
    let paramNames = Set.fromList (concatMap patBindingVars params)
        captured   = Set.toList (Set.difference (collectVarLocals body) paramNames)
        clones     = concatMap (\v -> let v' = rustSafeIdent v in "let " ++ v' ++ " = " ++ v' ++ ".clone(); ") captured
        innerMulti = [ v | (v, c) <- Map.toList (collectVarLocalsMulti body), c >= 2 ]
        ctx'       = ctx { ecCloneVars = Set.unions
                             [ Set.fromList innerMulti
                             , Set.difference (ecCloneVars ctx) paramNames
                             , Set.fromList captured ] }
        psStr      = intercalate ", " (map (annotClosureParam ctx body) params)
        closure    = "move |" ++ psStr ++ "| { " ++ exprToRustString ctx' body ++ " }"
    in name ++ " = " ++ if null captured then closure else "{ " ++ clones ++ closure ++ " }"
-- Destructuring binding: `let (a, b) = expr` / `let { f } = expr`. When a
-- destructuring let reaches the Can.Let path (rather than Can.LetDestruct), its
-- DestructDef lands here. Render the pattern via patternToMatchString and mirror
-- LetDestruct's clone-prelude so the caller emits `let (a, b) = expr;`. Without
-- this arm the catchall stubbed `_ = unimplemented()` and dropped the bindings —
-- every `let (a, _) = f x` then referenced the unbound names (E0425/E0423).
-- Discarded task (`let _ = process_run …`): a kernel like `process_run` is
-- generic over its error type (`E: Send + From<String>`), and a bare `_ =`
-- discard gives Rust no downstream constraint to pin `E` — with >1 `From<String>`
-- impl in scope this is E0283 ("cannot infer type"). Annotate the wildcard with
-- the concrete `SkyTask<inner>` (the runtime alias fixes `E = SkyError`) so the
-- discarded effect type-checks. Only fires when the RHS is task-typed AND its
-- inner type is determinable; everything else falls through unchanged. (This
-- also unblocks the #52 cleanup pattern, whose body discards such a task.)
defToRustString ctx (Can.DestructDef (Ann.At _ Can.PAnything) expr)
    | isTaskProducingCall expr
    , inner <- taskExprInnerType (ecSolvedTypes ctx) expr
    , not (null inner) =
        -- Caller prepends `let `, so emit only `_: SkyTask<…> = rhs`.
        "_: SkyTask<" ++ inner ++ "> = " ++ exprToRustString ctx expr
defToRustString ctx (Can.DestructDef pat expr) =
    let counts = collectVarLocalsMulti expr
        multi  = [ v | (v, c) <- Map.toList counts, c >= 2 ]
        clones = concatMap (\v -> let v' = rustSafeIdent v in "let " ++ v' ++ " = " ++ v' ++ ".clone(); ") multi
        exprStr = if null multi then exprToRustString ctx expr
                  else "{ " ++ clones ++ exprToRustString ctx expr ++ " }"
    in patternToMatchString (ecRecordMap ctx) pat ++ " = " ++ exprStr
defToRustString _ctx _ = "_ = unimplemented()"

-- | Does a pattern contain a string-literal sub-pattern anywhere?
hasStrAnywhere :: Can.Pattern -> Bool
hasStrAnywhere (Ann.At _ p) = case p of
    Can.PStr _            -> True
    Can.PTuple a b rest   -> any hasStrAnywhere (a : b : rest)
    Can.PCtor{Can._p_args = args} -> any (\(Can.PatternCtorArg _ _ pp) -> hasStrAnywhere pp) args
    Can.PCons a b         -> hasStrAnywhere a || hasStrAnywhere b
    Can.PList items       -> any hasStrAnywhere items
    Can.PAlias inner _    -> hasStrAnywhere inner
    _                     -> False

-- | Render a match pattern, replacing every string-literal leaf with a fresh
-- binder and returning `binder.as_str() == literal` guards. Rust can't match a
-- `String` value against a `&str` literal pattern; when the literal is NESTED
-- inside a tuple/ctor the scrutinee-level `.as_str()` wrap (top-level PStr
-- path) can't apply, so we bind + guard instead. The Int threads a counter for
-- unique binder names.
renderPatGuarded :: Map.Map String String -> Int -> Can.Pattern -> (String, [String], Int)
renderPatGuarded recMap n0 (Ann.At _ pat) = case pat of
    Can.PStr s ->
        let v = "__sg" ++ show n0
        in (v, [v ++ ".as_str() == " ++ show s], n0 + 1)
    Can.PVar nm    -> (rustSafeIdent nm, [], n0)
    Can.PAnything  -> ("_", [], n0)
    Can.PInt i     -> (show i, [], n0)
    Can.PBool b    -> (if b then "true" else "false", [], n0)
    Can.PChr c     -> ("'" ++ c ++ "'", [], n0)
    Can.PUnit      -> ("()", [], n0)
    Can.PTuple a b rest ->
        let (n', parts, gss) = goSubs n0 (a : b : rest)
        in ("(" ++ intercalate ", " parts ++ ")", gss, n')
    Can.PCtor{Can._p_home = home, Can._p_type = ty, Can._p_name = name, Can._p_args = args} ->
        let (n', parts, gss) = goSubs n0 [ p | Can.PatternCtorArg _ _ p <- args ]
            fullName = kernelCtorToRust home ty name
        in (fullName ++ (if null parts then "" else "(" ++ intercalate ", " parts ++ ")"), gss, n')
    _ -> (patternToMatchString recMap (Ann.At (error "renderPatGuarded: region unused") pat), [], n0)
  where
    goSubs k []       = (k, [], [])
    goSubs k (p : ps) =
        let (s, gs, k')      = renderPatGuarded recMap k p
            (k'', ss, gsRest) = goSubs k' ps
        in (k'', s : ss, gs ++ gsRest)

branchToRustString :: EmitCtx -> Can.CaseBranch -> String
branchToRustString ctx (Can.CaseBranch pat body) =
    let -- Nested string-literal patterns (inside a tuple/ctor) can't use the
        -- scrutinee `.as_str()` wrap; render them as binder + guard. A bare
        -- top-level PStr is handled by the as_str path, so skip it here.
        nestedStr = case pat of
            Ann.At _ (Can.PStr _) -> False
            _                     -> hasStrAnywhere pat
        (patStr, guardSuffix)
            | nestedStr =
                let (s, gs, _) = renderPatGuarded (ecRecordMap ctx) 0 pat
                in (s, if null gs then "" else " if " ++ intercalate " && " gs)
            | otherwise = (patternToMatchString (ecRecordMap ctx) pat, "")
        -- Zero-arg top-level functions used as case values must be called.
        bodyExpr = case body of
            Ann.At _ (Can.VarTopLevel mod name) ->
                let modStr = ModuleName._name mod
                    modPfx = if null modStr then "" else map (\c -> if c == '.' then '_' else c) modStr
                in rustFnName (ecNameRenames ctx) modPfx name ++ "()"
            _ -> exprToRustString ctx body
        -- Slice patterns bind references (&T for head, &[T] for tail).
        -- Inject .clone() / .to_vec() so the body sees owned values. A cons/list
        -- pattern can sit at the top level OR nested inside a tuple scrutinee
        -- (`case (offsets, flags) of (i :: ix, b :: bs) -> …`); each cons-bearing
        -- tuple element gets `.as_slice()`-wrapped (Can.Case path above), so its
        -- head/tail binders are references too and need the same owning prelude.
        -- `consPrefix` walks the pattern (recursing through tuples) emitting a
        -- `let v = v.clone();` per head binder and `let v = v.to_vec();` per tail
        -- binder. The PCtor box-deref stays a top-level-only concern.
        consPrefix = goCons pat
          where
            goCons (Ann.At _ p) = case p of
                Can.PCons headPat tailPat ->
                    concatMap (\v -> let v' = rustSafeIdent v in "let " ++ v' ++ " = " ++ v' ++ ".clone(); ") (patBindingVars headPat)
                    ++ concatMap (\v -> let v' = rustSafeIdent v in "let " ++ v' ++ " = " ++ v' ++ ".to_vec(); ") (patBindingVars tailPat)
                Can.PList items ->
                    concatMap (\v -> let v' = rustSafeIdent v in "let " ++ v' ++ " = " ++ v' ++ ".clone(); ") (concatMap patBindingVars items)
                Can.PTuple a b rest -> concatMap goCons (a : b : rest)
                Can.PAlias inner _  -> goCons inner
                _ -> ""
        prefix = case pat of
            Ann.At _ (Can.PCons _ _) -> consPrefix
            Ann.At _ (Can.PList _)   -> consPrefix
            Ann.At _ (Can.PTuple _ _ _) -> consPrefix
            -- A constructor field that is self-recursive is boxed in the enum
            -- (TypeEmitter.boxIfRecursive); the match binds it as Box<Self>, so a
            -- deref `let inner = *inner;` moves the owned value out for the body
            -- (which uses it as Self, e.g. `std_ui_is_fill_length(inner)`).
            Ann.At _ (Can.PCtor{Can._p_name = _ctor, Can._p_args = ctorArgs})
                | let pTypeRust = takeWhile (/= ':') patStr
                , let fieldTys = ctorPatFieldTypes
                , boxedVars <- [ v | (i, Can.PatternCtorArg _ _ argPat) <- zip [0 :: Int ..] ctorArgs
                                   , i < length fieldTys
                                   , typeToRustString (ecRecordMap ctx) (fieldTys !! i) == pTypeRust
                                   , not (null pTypeRust)
                                   , v <- patBindingVars argPat ]
                , not (null boxedVars) ->
                    concatMap (\v -> let v' = rustSafeIdent v in "let " ++ v' ++ " = *" ++ v' ++ "; ") boxedVars
            _ -> ""
        ctorPatFieldTypes = case pat of
            Ann.At _ (Can.PCtor{Can._p_name = c}) -> Map.findWithDefault [] c (ecCtorFieldTypes ctx)
            _ -> []
        armHead = patStr ++ guardSuffix
    in if null prefix && not ("let " `isPrefixOf` bodyExpr) && not ("if " `isPrefixOf` bodyExpr)
       then armHead ++ " => " ++ bodyExpr
       else armHead ++ " => { " ++ prefix ++ bodyExpr ++ " }"

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

-- ─── Sql ADT → SqlParam codegen helpers ──────────────────────────────────────
--
-- These emit INLINE Rust closures that convert the per-project GENERATED enums
-- `StdDbSqlValue` / `StdDbSqlField` into the runtime-nameable `SqlParam`.
-- All conversion code is emitted at the call site; the runtime has no knowledge
-- of the generated enum names.
--
-- The emitted Rust is:
--   sqlValueToParam(v): match v { StdDbSqlValue::SqlString(s) => SqlParam::Text(s), … }
--   sqlFieldsToVec(e) : <e>.into_iter().map(|(col, sf)| (col, match sf { … })).collect()
--   sqlWhereToVec(e)  : <e>.into_iter().map(|(col, sv)| (col, sql_value_to_param(sv))).collect()

-- | Emit the body of a `match StdDbSqlValue` → SqlParam conversion.
-- Money is serialised as "ISO_CODE AMOUNT" matching Go's sqlMoneyToString /
-- the inverse of db_decode_money.  Every SqlValue variant is handled — total.
sqlValueMatchArms :: String
sqlValueMatchArms = unlines
    [ "StdDbSqlValue::SqlString(s) => SqlParam::Text(s),"
    , "StdDbSqlValue::SqlInt(i) => SqlParam::Int(i),"
    , "StdDbSqlValue::SqlFloat(f) => SqlParam::Float(f),"
    , "StdDbSqlValue::SqlBool(b) => SqlParam::Bool(b),"
    , "StdDbSqlValue::SqlBytes(s) => SqlParam::Bytes(s.into_bytes()),"
    -- Decimal doesn't impl Display; use the runtime helper `decimal_to_string`.
    , "StdDbSqlValue::SqlDecimal(d) => SqlParam::Text(decimal_to_string(d)),"
    , "StdDbSqlValue::SqlTime(ms) => SqlParam::Int(ms),"
    -- Money: serialise as "ISO_CODE AMOUNT" matching Go's sqlMoneyToString.
    -- `amount` is a Decimal (no Display); use decimal_to_string.
    -- Currency enum Debug name = Sky ctor name = ISO code (e.g. "Usd" vs "USD"):
    -- Go stores the Sky ctor name too, so the round-trip is consistent.
    , "StdDbSqlValue::SqlMoney(m) => { let money_str = match m {"
    , "    StdMoneyMoney::Money(amount, currency) => {"
    , "        let code = match &currency {"
    , "            StdMoneyCurrency::CurrencyRaw(s) => s.clone(),"
    , "            c => format!(\"{:?}\", c)"
    , "        };"
    , "        format!(\"{} {}\", code, decimal_to_string(amount))"
    , "    }"
    , "}; SqlParam::Text(money_str) },"
    , "StdDbSqlValue::SqlNull(_) => SqlParam::Null,"
    ]

-- | Emit a Rust expression that converts a Sky `List (String, SqlField)` argument
-- (the `fields` param of insertFields / updateFields) into
-- `Vec<(String, Option<SqlParam>)>`.
-- `None` = OmitField (column dropped from SQL).
-- `Some(SqlParam::…)` = SetField(value).
-- | `DbDec.money col` — wrap the runtime `db_decode_money` decoder (yields a
-- `(Decimal, ISO-code)` pair) into a `Decoder<Money>` by mapping the pair into
-- the GENERATED `StdMoneyMoney::Money(amount, StdMoneyCurrency::CurrencyRaw(code))`
-- via the shared `decode_map`. The closure param type is left to Rust to infer
-- from `db_decode_money`'s `Decoder<(Decimal, String)>` return.
dbDecMoneyWrap :: EmitCtx -> Can.Expr -> String
dbDecMoneyWrap ctx colArg =
    "decode_map(|__m| StdMoneyMoney::Money(__m.0, StdMoneyCurrency::CurrencyRaw(__m.1)), db_decode_money("
        ++ exprToRustString ctx colArg ++ "))"

sqlFieldsToVec :: EmitCtx -> Can.Expr -> String
sqlFieldsToVec ctx e =
    let inner = exprToRustString ctx e
        arms = "StdDbSqlField::SetField(v) => Some(match v { " ++ sqlValueMatchArms ++ " }),"
            ++ "StdDbSqlField::OmitField => None,"
    in inner ++ ".into_iter().map(|(col, sf)| (col, match sf { " ++ arms ++ " })).collect::<Vec<_>>()"

-- | Emit a Rust expression that converts a Sky `List (String, SqlValue)` argument
-- (the `whereCols` param of updateFields) into `Vec<(String, SqlParam)>`.
sqlWhereToVec :: EmitCtx -> Can.Expr -> String
sqlWhereToVec ctx e =
    let inner = exprToRustString ctx e
        arms = sqlValueMatchArms
    in inner ++ ".into_iter().map(|(col, sv)| (col, match sv { " ++ arms ++ " })).collect::<Vec<_>>()"
