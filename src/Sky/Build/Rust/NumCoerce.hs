-- | Leaf module: SCALAR numeric coercion at the Sky↔Rust FFI boundary.
--
-- Self-contained (no process / IO / Aeson deps) so the leaf codegen modules
-- 'Sky.Build.Rust.FfiCall' and 'Sky.Build.Rust.FfiInstance' can import it
-- WITHOUT pulling the process-laden 'Sky.Build.Rust.Ffi' — which would also be
-- an import CYCLE (@Ffi → FfiInstance → FfiCall@, so @FfiCall → Ffi@ is illegal).
--
-- 'Sky.Build.Rust.Ffi' re-exports 'numSaturate' for existing call sites + unit
-- tests, and its 'Sky.Build.Rust.Ffi.translateRustRet' scalar tail delegates to
-- 'numWidenScalar' so there is exactly ONE source of the scalar widening
-- (the B8 "one saturating helper" invariant).
module Sky.Build.Rust.NumCoerce
    ( numSaturate        -- :: String -> String -> String  (PARAM: Sky i64/f64 → foreign width, saturating)
    , numWidenScalar     -- :: String -> Maybe (String, String -> String)  (RETURN: foreign width → Sky carrier)
    , numCarrier         -- :: String -> Maybe String  (foreign numeric width → Sky carrier "i64"/"f64")
    , isNumericRust      -- :: String -> Bool
    ) where


-- | Every Rust numeric primitive width.
isNumericRust :: String -> Bool
isNumericRust t = t `elem`
    [ "i8", "i16", "i32", "i64", "i128"
    , "u8", "u16", "u32", "u64", "u128"
    , "isize", "usize", "f32", "f64" ]


-- | The Sky CARRIER type a foreign numeric width travels as across the FFI
-- boundary: every integer width is carried as Sky @Int@ (@i64@), every float as
-- Sky @Float@ (@f64@). @Nothing@ for a non-numeric type (the caller leaves it
-- alone). This is the wrapper PARAM type for a numeric arg — the runtime always
-- supplies the carrier, and the call site narrows to the foreign width via
-- 'numSaturate'.
numCarrier :: String -> Maybe String
numCarrier w
    | w `elem` ["f32", "f64"] = Just "f64"
    | isNumericRust w         = Just "i64"
    | otherwise              = Nothing


-- | Coerce a Sky scalar (@i64@ for @Int@, @f64@ for @Float@) INTO a foreign
-- numeric param of the target Rust width, SATURATING — clamps the value into the
-- target's representable range, TOTAL, no panic, no silent wraparound (CLAUDE.md
-- "no silent numeric coercion"). The single source of every SCALAR numeric
-- param/field/ctor-arg cast: 'Sky.Build.Rust.Ffi'\'s @argCall@ (method args),
-- @setValExpr@ (field setters), @ctorArgOwned@ (enum ctors) — each top-level +
-- its @Option\<numeric\>@ arm — and (\#95) the projected/UFCS generic-wrapper
-- call site all route here. (A @Vec\<numeric\>@ element write in a setter/ctor
-- also routes here per-element for an int→int-narrowing element (\#94); a
-- FLOAT-source element keeps Rust\'s already-saturating @as@.) @e@ must be a
-- side-effect-free expr (a bound local) — the @isize@ arm evaluates it more than
-- once.
--
-- Platform-correctness BY CONSTRUCTION: @usize@/@isize@ are platform-width, so
-- they route through @try_from@ (a bare @as@ would truncate on 32-bit, which CI —
-- all 64-bit — can never catch). @unwrap_or@/@unwrap_or_else@ are clippy-clean
-- (no unwrap/expect/panic).
numSaturate :: String -> String -> String
numSaturate raw e = case raw of
    "f32"   -> par ++ " as f32"                              -- precision-lossy, total
    "f64"   -> e                                             -- identity
    "i64"   -> e                                             -- identity
    -- signed narrowing: clamp into [MIN, MAX] of the target, then a lossless `as`.
    t | t `elem` ["i8", "i16", "i32"]
            -> par ++ ".clamp(" ++ t ++ "::MIN as i64, " ++ t ++ "::MAX as i64) as " ++ t
    -- unsigned narrowing: clamp into [0, MAX], then a lossless `as`.
      | t `elem` ["u8", "u16", "u32"]
            -> par ++ ".clamp(0, " ++ t ++ "::MAX as i64) as " ++ t
    -- u64: every non-negative i64 fits u64; negatives saturate to 0.
      | t == "u64"  -> par ++ ".max(0) as u64"
    -- u128 / i128: WIDER than i64. i128 is a pure sign-preserving widen; u128
    -- saturates negatives to 0 (a bare `as u128` would sign-extend -1 to ~3.4e38).
      | t == "i128" -> par ++ " as i128"
      | t == "u128" -> par ++ ".max(0) as u128"
    -- usize / isize: PLATFORM-WIDTH → try_from (32-bit-correct by construction).
      | t == "usize"
            -> "usize::try_from(" ++ par ++ ".max(0)).unwrap_or(usize::MAX)"
      | t == "isize"
            -> "isize::try_from(" ++ e ++ ").unwrap_or_else(|_| if "
               ++ par ++ " < 0 { isize::MIN } else { isize::MAX })"
      | otherwise -> par ++ " as " ++ raw                    -- unreachable; total fallback
  where
    par = "(" ++ e ++ ")"


-- | SCALAR numeric RETURN widening: a foreign scalar of width @raw@ widened to
-- its Sky carrier (@i64@/@f64@), TOTAL + saturating for widths that exceed i64.
-- @Just (carrier, coerce)@ for any numeric scalar (@i64@/@f64@ → an identity-
-- shaped @as@); @Nothing@ for a non-numeric type (the caller leaves the return
-- unchanged). This is the SCALAR subset of
-- 'Sky.Build.Rust.Ffi.translateRustRet', which delegates here so the widening
-- has one source. Byte-identical to the historical inline arms.
numWidenScalar :: String -> Maybe (String, String -> String)
numWidenScalar raw
    -- Lossless: every value fits in i64 after widening (isize ≤ i64).
    | raw `elem` ["i8", "i16", "i32", "i64", "u8", "u16", "u32", "isize"]
        = Just ("i64", \e -> "(" ++ e ++ ") as i64")
    -- Unsigned wider-than-or-equal i64 range: a bare `as i64` would sign-flip
    -- (u64::MAX as i64 == -1). Saturate via min into i64::MAX, total.
    | raw `elem` ["u64", "usize", "u128"]
        = Just ("i64", \e -> "(" ++ e ++ ").min(i64::MAX as " ++ raw ++ ") as i64")
    -- Signed wide: try_from, saturate to i64::MIN / i64::MAX on overflow.
    | raw == "i128"
        = Just ("i64", \e -> "i64::try_from(" ++ e
                             ++ ").unwrap_or(if (" ++ e ++ ") < 0 { i64::MIN } else { i64::MAX })")
    | raw `elem` ["f32", "f64"]
        = Just ("f64", \e -> "(" ++ e ++ ") as f64")
    | otherwise = Nothing
