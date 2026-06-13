{-# LANGUAGE TemplateHaskell #-}

-- | The bundled Sky Console mini-app (`sky-bundled/console/`) embedded into the
-- sky binary at TH compile time, for the **Rust backend's pre-built console
-- child** (epic A). On a user's first `sky build --target rust` of a Sky.Live
-- app, `Sky.Build.Rust.Console.ensureConsoleBinary` materialises these files
-- into a version-keyed cache dir, runs `sky build --target rust` on them once,
-- and caches the resulting binary — the Live runtime's reverse-proxy then
-- spawns it (`live/console_proxy.rs`).
--
-- The Go backend does NOT use this: its console is pre-generated Go committed at
-- `runtime-go/rt/console_app/` and compiled in-process with the user binary
-- (the v0.16.0 change that removed the original `Sky.Build.EmbeddedConsole`).
-- The Rust backend can't compile two Sky programs into one crate, so it goes
-- back to a separate process — hence this module is resurrected, Rust-only.
--
-- The walk reuses `embedDirRecursive`'s filter, which now excludes `sky-out/` +
-- `.skycache/` + `.skydeps/`, so only `sky.toml` + `src/*.sky` ship (never the
-- 27 MB built binary or generated Rust tree).
module Sky.Build.EmbeddedConsole
    ( embeddedConsoleApp
    ) where

import Data.ByteString (ByteString)
import Sky.Build.EmbedDirTH (embedDirRecursive)

-- re-embed marker: 2026-06-13 A1 — embed sky-bundled/console (sky.toml + src/)
-- for the Rust pre-built console child. Touch this comment to force cabal's TH
-- splice to re-walk the console source after a console edit.
embeddedConsoleApp :: [(FilePath, ByteString)]
embeddedConsoleApp = $(embedDirRecursive "sky-bundled/console")
