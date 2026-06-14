{-# LANGUAGE TemplateHaskell #-}

-- | Single source of truth for the crate versions + features the Rust codegen
-- emits into a generated project's Cargo.toml. The specs live in the sibling
-- @crate-specs.toml@ (Cargo dependency-line syntax), embedded at compile time so
-- a version/feature is edited in ONE place and never drifts between the emitter
-- and @runtime-rust/Cargo.toml@.
--
-- GATING (which crate is pulled for which Sky feature) stays in @Emitter.hs@;
-- this module only owns the version+feature SPEC. @tokio@/@sqlx@ read their
-- version here via 'crateVersionFor' but build their feature list in the emitter
-- (it depends on usage).
--
-- Self-contained tiny parser (same convention as @Sky.Sky.Toml.Rust@) — no TOML
-- library dependency.
module Sky.Generate.Rust.Builder.CrateSpecs
    ( CrateSpec(..)
    , crateSpec
    , dependencySpecFor
    , cargoDependencyFor
    , crateVersionFor
    , crateSpecVersions
    ) where

import Data.Char (isSpace)
import Data.List (intercalate, isPrefixOf)
import Data.Maybe (mapMaybe)
import qualified Data.Map.Strict as Map
import Data.FileEmbed (embedStringFile)

-- | A crate's version + feature selection.
data CrateSpec = CrateSpec
    { csVersion         :: String
    , csDefaultFeatures :: Bool
    , csFeatures        :: [String]
    } deriving (Eq, Show)

-- | The embedded source of truth (package-root-relative, like the runtime embed).
specsRaw :: String
specsRaw = $(embedStringFile "src/Sky/Generate/Rust/Builder/crate-specs.toml")

-- | Parsed crate → spec map.
crateSpecs :: Map.Map String CrateSpec
crateSpecs = Map.fromList (mapMaybe parseLine (lines specsRaw))

-- | name → version, for crates whose feature list the emitter computes.
crateSpecVersions :: Map.Map String String
crateSpecVersions = Map.map csVersion crateSpecs

-- | Look up a crate spec; a missing crate is a codegen bug (a referenced crate
-- absent from the single source) — fail loudly at build time, not silently.
crateSpec :: String -> CrateSpec
crateSpec name =
    Map.findWithDefault
        (error ("CrateSpecs: crate-specs.toml has no entry for " ++ show name))
        name crateSpecs

-- | The Cargo dependency VALUE for a crate (the part after @name = @): a bare
-- @"version"@ string, or an inline @{ version = …, default-features = false,
-- features = [...] }@ table. Byte-identical to the strings the emitter used to
-- hard-code.
dependencySpecFor :: String -> String
dependencySpecFor = renderSpec . crateSpec

-- | A full @name = <value>@ dependency line.
cargoDependencyFor :: String -> String
cargoDependencyFor name = name ++ " = " ++ dependencySpecFor name

-- | Just the version (for tokio/sqlx, whose features are computed in the emitter).
crateVersionFor :: String -> String
crateVersionFor = csVersion . crateSpec

renderSpec :: CrateSpec -> String
renderSpec (CrateSpec ver df feats)
    | df && null feats = quote ver
    | otherwise =
        "{ version = " ++ quote ver
        ++ (if df then "" else ", default-features = false")
        ++ (if null feats then "" else ", features = [" ++ intercalate ", " (map quote feats) ++ "]")
        ++ " }"

-- ── tiny parser ───────────────────────────────────────────────────────────

-- | Parse a @name = <spec>@ line; skip blanks + @#@ comment lines.
parseLine :: String -> Maybe (String, CrateSpec)
parseLine raw =
    let s = trim raw
    in if null s || "#" `isPrefixOf` s
       then Nothing
       else case break (== '=') s of
            (nameRaw, '=':rest) ->
                let name = trim nameRaw
                in if null name then Nothing else Just (name, parseSpec (trim rest))
            _ -> Nothing

parseSpec :: String -> CrateSpec
parseSpec v
    | "{" `isPrefixOf` v =
        let inner = trim (dropEnd1 (drop 1 v))           -- strip the { }
            pairs = map parseKV (splitTopCommas inner)
            ver   = maybe "" stripQuotes (lookup "version" pairs)
            df    = maybe True (\x -> trim x /= "false") (lookup "default-features" pairs)
            feats = maybe [] parseFeatures (lookup "features" pairs)
        in CrateSpec ver df feats
    | otherwise = CrateSpec (stripQuotes v) True []      -- bare "version"

parseKV :: String -> (String, String)
parseKV kv = case break (== '=') kv of
    (k, '=':val) -> (trim k, trim val)
    (k, _)       -> (trim k, "")

-- | Split on top-level commas (not inside @[ ]@).
splitTopCommas :: String -> [String]
splitTopCommas = go 0 "" []
  where
    go :: Int -> String -> [String] -> String -> [String]
    go _ acc out [] = reverse (addAcc acc out)
    go depth acc out (c:cs)
        | c == '['            = go (depth + 1) (c:acc) out cs
        | c == ']'            = go (depth - 1) (c:acc) out cs
        | c == ',' && depth == 0 = go depth "" (addAcc acc out) cs
        | otherwise           = go depth (c:acc) out cs
    addAcc acc out = let t = trim (reverse acc) in if null t then out else t : out

parseFeatures :: String -> [String]
parseFeatures s =
    let inner = trim s
        body  = if "[" `isPrefixOf` inner then trim (dropEnd1 (drop 1 inner)) else inner
    in filter (not . null) (map stripQuotes (splitTopCommas body))

-- ── string helpers (self-contained, per the Sky.Sky.Toml.Rust convention) ──

quote :: String -> String
quote s = "\"" ++ s ++ "\""

trim :: String -> String
trim = f . f where f = reverse . dropWhile isSpace

stripQuotes :: String -> String
stripQuotes s = case trim s of
    ('"':rest) -> reverse (dropQuote (reverse rest))
    other      -> other
  where dropQuote ('"':r) = r
        dropQuote r        = r

dropEnd1 :: String -> String
dropEnd1 [] = []
dropEnd1 xs = init xs
