-- | Rust-target dependency parsing for sky.toml's ["rust.dependencies"]
-- section. Split out of Sky.Sky.Toml so the Go-relevant Toml code stays
-- byte-identical to upstream and merges cleanly.
--
-- This module is self-contained (it duplicates the tiny `trim`/`stripQuotes`
-- helpers rather than importing them from Sky.Sky.Toml) so the dependency is
-- strictly one-way: Sky.Sky.Toml imports Sky.Sky.Toml.Rust, never the reverse.
module Sky.Sky.Toml.Rust
    ( RustDepSpec(..)
    , parseRustDepSpec
    ) where

import Data.Char (isSpace)
import Data.List (isPrefixOf)
import Data.Maybe (mapMaybe)


-- | Rust dependency specification: crates.io version or git source.
data RustDepSpec = RustVersion { _rvVersion :: String, _rvFeatures :: [String] }
                 | RustGitDep
                     { _gitUrl    :: String
                     , _gitRev    :: Maybe String
                     , _gitBranch :: Maybe String
                     , _gitTag    :: Maybe String
                     , _gitFeatures :: [String]
                       -- ^ #100 Part B: user-declared sky.toml features, UNIONed at
                       -- codegen with the inspector's auto-discovered effective set.
                       -- A git-sourced FFI crate has feature-gated APIs too; the
                       -- generated Cargo.toml must enable them (else E0412/E0433…).
                     }
    deriving (Show, Eq)


-- | Parse a Rust dependency spec from a TOML value string.
-- Handles both simple version strings ("1.10.0") and inline tables
-- ({ git = "https://...", rev = "abc123" }).
parseRustDepSpec :: String -> RustDepSpec
parseRustDepSpec s
    | "{" `isPrefixOf` trim s = parseInlineTable (trim s)
    | otherwise               = RustVersion s []

-- | Parse a TOML inline table like: { git = "url", rev = "sha" } or
-- { version = "1.0", features = ["feat1", "feat2"] }.
parseInlineTable :: String -> RustDepSpec
parseInlineTable s =
    let inner = takeWhile (/= '}') (drop 1 (trim s))
        rawPairs = splitOn ',' inner
        kv = map (\(k, v) -> (trim k, stripQuotes (trim v)))
             (mapMaybe parseKeyValue rawPairs)
        gitUrl = lookup "git" kv
        rev    = lookup "rev" kv
        branch = lookup "branch" kv
        tag    = lookup "tag" kv
        version = lookup "version" kv
        featuresStr = lookup "features" kv
        features = case featuresStr of
            Just f | "[" `isPrefixOf` f ->
                let inner2 = takeWhile (/= ']') (drop 1 f)
                in map stripQuotes (splitOn ',' inner2)
            _ -> []
    in case gitUrl of
        Just url -> RustGitDep url rev branch tag features
        Nothing  -> case version of
            Just v  -> RustVersion v features
            Nothing -> RustVersion s []  -- fallback: treat as literal version

-- | Parse a single key=value pair. Returns Nothing on malformed input.
parseKeyValue :: String -> Maybe (String, String)
parseKeyValue s = case break (== '=') s of
    (k, '=' : v) -> Just (trim k, v)
    _            -> Nothing

-- | Split a string on a delimiter (not CSV-aware, fine for inline tables).
splitOn :: Char -> String -> [String]
splitOn _ [] = []
splitOn c s = case break (== c) s of
    (part, _ : rest) -> part : splitOn c (dropWhile isSpace rest)
    (part, [])       -> [part]

-- duplicated from Sky.Sky.Toml (kept there for the Go-side parsers) to keep
-- this module's dependency one-way.
trim :: String -> String
trim = reverse . dropWhile isSpace . reverse . dropWhile isSpace

stripQuotes :: String -> String
stripQuotes ('"' : rest) = case reverse rest of
    '"' : inner -> reverse inner
    _ -> rest
stripQuotes s = s
