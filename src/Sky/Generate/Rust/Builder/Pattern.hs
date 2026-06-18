module Sky.Generate.Rust.Builder.Pattern
  ( bodyUsesList
  , hasStrPat
  , patBindingVars
  , isWildcard
  , patternToRustParam
  , patternToRustPattern
  , patternToRustArg
  ) where

import Data.List (intercalate)
import qualified Data.Set as Set
import qualified Sky.AST.Canonical as Can
import qualified Sky.Reporting.Annotation as Ann
import qualified Sky.Sky.ModuleName as ModuleName
import Sky.Generate.Rust.Builder.Naming (toCamelCase, rustSafeIdent, rustVariantName)

-- | Simple check: does the body match a parameter with list patterns (cons, list)?
bodyUsesList :: Can.Expr -> Bool
bodyUsesList (Ann.At _ e) = case e of
    Can.Case scrut branches ->
        any (\(Can.CaseBranch pat _) -> isListPat pat) branches
        || any (\(Can.CaseBranch _ body) -> bodyUsesList body) branches
    Can.Let _ body -> bodyUsesList body
    Can.LetRec _ body -> bodyUsesList body
    Can.LetDestruct _ _ body -> bodyUsesList body
    Can.If branches elseBranch -> any (\(_, t) -> bodyUsesList t) branches || bodyUsesList elseBranch
    _ -> False
  where
    isListPat (Ann.At _ p) = case p of
        Can.PCons _ _ -> True
        Can.PList _ -> True
        Can.PAlias pat _ -> isListPat pat
        _ -> False

-- | Does this top-level pattern match a string literal?
hasStrPat :: Can.Pattern -> Bool
hasStrPat (Ann.At _ p) = case p of
    Can.PStr _ -> True
    _ -> False

-- | Collect all (non-wildcard) variable names bound by a pattern.
-- For PCons head bindings these will be &T0; for tail bindings &[T0].
patBindingVars :: Can.Pattern -> [String]
patBindingVars (Ann.At _ pat) = case pat of
    Can.PVar n -> [n]
    Can.PCons a b -> patBindingVars a ++ patBindingVars b
    Can.PList items -> concatMap patBindingVars items
    Can.PAlias inner n -> n : patBindingVars inner
    Can.PTuple a b rest -> concatMap patBindingVars (a:b:rest)
    Can.PCtor{Can._p_args = args} -> concatMap (\(Can.PatternCtorArg _ _ p) -> patBindingVars p) args
    Can.PRecord fields -> fields
    _ -> []

isWildcard :: Can.Pattern -> Bool
isWildcard (Ann.At _ Can.PAnything) = True
isWildcard _ = False

patternToRustParam :: Can.Pattern -> String
patternToRustParam (Ann.At _ pat) = case pat of
    Can.PVar n -> rustSafeIdent n
    Can.PAnything -> "_"
    Can.PTuple a b rest ->
        "(" ++ intercalate ", " (map patternToRustParam (a:b:rest)) ++ ")"
    _ -> "_"

-- | Emit a Rust pattern syntax that destructures a value of the
-- corresponding Sky type. Used by `patternToRustArg` when a function
-- parameter is a non-trivial pattern (e.g. PCtor) and the body needs
-- the bound variables in scope.
patternToRustPattern :: Can.Pattern -> String
patternToRustPattern (Ann.At _ pat) = case pat of
    Can.PVar n        -> rustSafeIdent n
    Can.PAnything     -> "_"
    Can.PTuple a b rest ->
        "(" ++ intercalate ", " (map patternToRustPattern (a:b:rest)) ++ ")"
    Can.PCtor{Can._p_home = mod', Can._p_type = ty, Can._p_name = ctor, Can._p_args = args} ->
        let modName = ModuleName._name mod'
            modPrefix' = map (\c -> if c == '.' then '_' else c) modName
            enumName = toCamelCase (modPrefix' ++ "_" ++ ty)
            argStrs = map (\(Can.PatternCtorArg _ _ p) -> patternToRustPattern p) args
            argsRendered = if null argStrs then "" else "(" ++ intercalate ", " argStrs ++ ")"
        in enumName ++ "::" ++ rustVariantName ctor ++ argsRendered
    _ -> "_"

-- | Decompose a pattern function-argument into:
--   (rustParamName, prelude)
-- where `prelude` is a `let-else` statement to be prepended to the
-- function body, binding the pattern's variables in scope. Trivial
-- patterns (PVar / PAnything / PTuple) get an empty prelude — the
-- pattern itself is the rustParamName. Non-trivial patterns (PCtor)
-- get a synthesised `__pN` parameter and a destructure prelude.
--
-- Rust's `let <pattern> = <expr> else { unreachable!() };` accepts both
-- irrefutable and refutable patterns. When the pattern is provably
-- irrefutable (every ctor is the sole variant of its enum), the `else`
-- arm is dead and rustc fires `irrefutable_let_patterns`; we drop it to a
-- plain `let`. When the pattern is refutable — Sky (unlike Elm) ALLOWS a
-- refutable arg pattern, e.g. `f (Just x) = …` — the `else` is REQUIRED
-- (a refutable plain `let` is E0005), so we keep it; it stays dead by the
-- caller's exhaustiveness. `singleVarEnums` is the set of single-variant
-- Rust enum names (from builderTypes); an empty set conservatively keeps
-- every `else` (always compiles).
patternToRustArg :: Set.Set String -> Int -> Can.Pattern -> (String, String)
patternToRustArg _ _ pat@(Ann.At _ (Can.PVar _))       = (patternToRustParam pat, "")
patternToRustArg _ _ pat@(Ann.At _ Can.PAnything)      = (patternToRustParam pat, "")
patternToRustArg _ _ pat@(Ann.At _ (Can.PTuple _ _ _)) = (patternToRustParam pat, "")
patternToRustArg singleVarEnums idx pat =
    let paramName = "__p" ++ show idx
        rustPat = patternToRustPattern pat
        elseClause = if patternIsIrrefutable singleVarEnums pat
                     then ""
                     else " else { unreachable!() }"
        prelude = "let " ++ rustPat ++ " = " ++ paramName ++ elseClause ++ "; "
    in (paramName, prelude)

-- | A function-argument pattern is irrefutable iff every constructor in it is
-- the SOLE variant of its enum (the destructure can never fail) AND every
-- sub-pattern is itself irrefutable. Conservative by construction: a
-- multi-variant ctor, a literal, or an enum absent from the single-variant set
-- yields False — keeping the `else { unreachable!() }` guard (which always
-- compiles). Only a True result drops the else.
patternIsIrrefutable :: Set.Set String -> Can.Pattern -> Bool
patternIsIrrefutable singleVarEnums = go
  where
    go (Ann.At _ p) = case p of
        Can.PVar _          -> True
        Can.PAnything       -> True
        Can.PTuple a b rest -> all go (a : b : rest)
        Can.PCtor{Can._p_home = mod', Can._p_type = ty, Can._p_args = args} ->
            let modPrefix' = map (\c -> if c == '.' then '_' else c) (ModuleName._name mod')
                enumName    = toCamelCase (modPrefix' ++ "_" ++ ty)
            in Set.member enumName singleVarEnums
               && all (\(Can.PatternCtorArg _ _ sp) -> go sp) args
        _ -> False
