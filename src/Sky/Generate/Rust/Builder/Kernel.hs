module Sky.Generate.Rust.Builder.Kernel
  ( kernelToRust
  , kernelSigPrefix
  , splitKernelName
  ) where

import Data.List (isPrefixOf)
import Sky.Generate.Rust.Builder.Naming (toSnakeCase)

-- | Split a Sky kernel-name like "Decimal_fromInt" into ("Decimal", "fromInt").
-- The FIRST underscore is the module/fn boundary; subsequent underscores
-- stay in the function name ("Decimal_toStringFixed" -> ("Decimal", "toStringFixed")).
-- Used by the Ffi.callPure peephole to feed kernelToRust.
splitKernelName :: String -> (String, String)
splitKernelName s = case break (== '_') s of
    (m, '_' : f) -> (m, f)
    (m, "")      -> (m, "")  -- malformed; kernelToRust returns the snake-cased default

-- | Normalise a kernel module name to the underscore prefix knownDefSig keys
-- on. Short names ("List") get the "Sky_Core_" prefix; dotted names
-- ("Sky.Core.List") just swap dots for underscores.
--
-- CONTRACT (load-bearing): this synthesis is only correct for modules whose
-- canonical prefix really is "Sky_Core_<short>" — today that is exactly the
-- set registered in knownDefSig (SigRegistry.hs): List / Maybe / Error /
-- Result / String. For any OTHER short name it produces the WRONG prefix
-- (e.g. JsonDec -> "Sky_Core_JsonDec" but the real module is
-- Sky_Core_Json_Decode; Log/Db/Auth/Cmd/… are Std_*, not Sky_Core_*). That is
-- harmless ONLY because those modules have no entry in knownDefSig, so the
-- mis-prefixed lookup returns Nothing anyway. If you ever register a sig for a
-- Std.* or Sky.Core.Json.* (etc.) module in knownDefSig, you MUST first teach
-- this function the correct short->canonical alias here, or its call sites
-- (ExprEmitter.hs) will silently miss the param strings and fall back to
-- untyped args.
kernelSigPrefix :: String -> String
kernelSigPrefix m
    | '.' `elem` m = map (\c -> if c == '.' then '_' else c) m
    | otherwise    = "Sky_Core_" ++ m

-- | Map a Sky kernel (module, name) pair to its Rust runtime function name.
-- This is the single source of truth for kernel-to-Rust routing.
kernelToRust :: String -> String -> String
kernelToRust mod name = case (mod, name) of
    -- List functions (Q3)
    ("List", "map") -> "list_map_consume"
    ("Sky.Core.List", "map") -> "list_map_consume"
    ("List", "foldl") -> "list_foldl"
    ("Sky.Core.List", "foldl") -> "list_foldl"
    ("List", "foldr") -> "list_foldr"
    ("Sky.Core.List", "foldr") -> "list_foldr"
    ("List", "range") -> "list_range"
    ("Sky.Core.List", "range") -> "list_range"
    ("List", "indexedMap") -> "list_indexed_map"
    ("Sky.Core.List", "indexedMap") -> "list_indexed_map"
    ("List", "concatMap") -> "list_concat_map"
    ("Sky.Core.List", "concatMap") -> "list_concat_map"
    ("List", "zip") -> "list_zip"
    ("Sky.Core.List", "zip") -> "list_zip"
    ("List", "filter") -> "list_filter"
    ("Sky.Core.List", "filter") -> "list_filter"
    ("List", "member") -> "list_member"
    ("Sky.Core.List", "member") -> "list_member"
    ("List", "any") -> "list_any"
    ("Sky.Core.List", "any") -> "list_any"
    ("List", "all") -> "list_all"
    ("Sky.Core.List", "all") -> "list_all"
    -- NOTE: sort/sortBy/sortWith are FUTURE-PROOFING — Sky.Core.List does not
    -- currently expose them, so these arms are unreachable today. Kept so the
    -- routes already exist when the stdlib surface lands; do not treat their
    -- presence as evidence the surface is exposed.
    ("List", "sort") -> "list_sort"
    ("Sky.Core.List", "sort") -> "list_sort"
    ("List", "sortBy") -> "list_sort_by"
    ("Sky.Core.List", "sortBy") -> "list_sort_by"
    ("List", "sortWith") -> "list_sort_with"
    ("Sky.Core.List", "sortWith") -> "list_sort_with"
    -- String kernel functions: route directly to runtime implementations
    ("String", "fromInt") -> "string_from_int"
    ("Sky.Core.String", "fromInt") -> "string_from_int"
    ("String", "fromFloat") -> "string_from_float"
    ("Sky.Core.String", "fromFloat") -> "string_from_float"
    ("String", "length") -> "string_length"
    ("Sky.Core.String", "length") -> "string_length"
    ("String", "isEmpty") -> "string_is_empty"
    ("Sky.Core.String", "isEmpty") -> "string_is_empty"
    ("String", "reverse") -> "string_reverse"
    ("Sky.Core.String", "reverse") -> "string_reverse"
    ("String", "append") -> "string_append"
    ("Sky.Core.String", "append") -> "string_append"
    ("String", "toInt") -> "string_to_int"
    ("Sky.Core.String", "toInt") -> "string_to_int"
    ("String", "toLower") -> "string_to_lower"
    ("Sky.Core.String", "toLower") -> "string_to_lower"
    ("String", "toUpper") -> "string_to_upper"
    ("Sky.Core.String", "toUpper") -> "string_to_upper"
    ("String", "trim") -> "string_trim"
    ("Sky.Core.String", "trim") -> "string_trim"
    ("String", "split") -> "string_split"
    ("Sky.Core.String", "split") -> "string_split"
    ("String", "join") -> "string_join"
    ("Sky.Core.String", "join") -> "string_join"
    -- Encoding (sub-A.1)
    ("Encoding", "base64Encode")        -> "base64_encode"
    ("Sky.Core.Encoding", "base64Encode") -> "base64_encode"
    ("Encoding", "base64Decode")        -> "base64_decode"
    ("Sky.Core.Encoding", "base64Decode") -> "base64_decode"
    ("Encoding", "urlEncode")           -> "url_encode"
    ("Sky.Core.Encoding", "urlEncode")  -> "url_encode"
    ("Encoding", "urlDecode")           -> "url_decode"
    ("Sky.Core.Encoding", "urlDecode")  -> "url_decode"
    -- Renamed (was hex_encode/hex_decode) to avoid colliding with
    -- user-FFI bindings to the `hex` crate (examples/rust/16-hex).
    ("Encoding", "hexEncode")           -> "encoding_hex_encode"
    ("Sky.Core.Encoding", "hexEncode")  -> "encoding_hex_encode"
    ("Encoding", "hexDecode")           -> "encoding_hex_decode"
    ("Sky.Core.Encoding", "hexDecode")  -> "encoding_hex_decode"
    -- Bytes (Sky.Core.Bytes — `type alias Bytes = String`, Latin-1 byte
    -- convention shared with encoding.rs). The five Ffi.kernel aliases
    -- (toHex/toString/fromHex/toBase64/fromBase64) had no routing entry, so
    -- the Stage-4 alias `toHex = Ffi.kernel "Bytes_toHex"` fell through to the
    -- snake-cased default `bytes_to_hex` (undefined → E0425) and the def-side
    -- emitted a `panic!` polyfill. `length` overrides the pure-Sky
    -- `string_length` delegation: a Latin-1 Bytes value's byte count is its
    -- char count (`s.chars().count()`), not its UTF-8 storage length
    -- (`s.len()`), which double-counts high bytes. The fromHex/fromBase64/
    -- toString decoders return SkyMaybe (monomorphic — no error generic), so
    -- no turbofish error-pin is needed (unlike encoding_hex_decode, which
    -- returns SkyResult<_, E>).
    ("Bytes", "toHex")                  -> "bytes_to_hex"
    ("Sky.Core.Bytes", "toHex")         -> "bytes_to_hex"
    ("Bytes", "toString")               -> "bytes_to_string"
    ("Sky.Core.Bytes", "toString")      -> "bytes_to_string"
    ("Bytes", "fromHex")                -> "bytes_from_hex"
    ("Sky.Core.Bytes", "fromHex")       -> "bytes_from_hex"
    ("Bytes", "toBase64")               -> "bytes_to_base64"
    ("Sky.Core.Bytes", "toBase64")      -> "bytes_to_base64"
    ("Bytes", "fromBase64")             -> "bytes_from_base64"
    ("Sky.Core.Bytes", "fromBase64")    -> "bytes_from_base64"
    ("Bytes", "length")                 -> "bytes_length"
    ("Sky.Core.Bytes", "length")        -> "bytes_length"
    -- Regex (sub-A.2)
    ("Regex", "match")              -> "regex_match"
    ("Sky.Core.Regex", "match")     -> "regex_match"
    ("Regex", "find")               -> "regex_find"
    ("Sky.Core.Regex", "find")      -> "regex_find"
    ("Regex", "findAll")            -> "regex_find_all"
    ("Sky.Core.Regex", "findAll")   -> "regex_find_all"
    ("Regex", "replace")            -> "regex_replace"
    ("Sky.Core.Regex", "replace")   -> "regex_replace"
    ("Regex", "split")              -> "regex_split"
    ("Sky.Core.Regex", "split")     -> "regex_split"
    -- Crypto completion (sub-A.3) — sha256 + random* already present
    ("Crypto", "sha512")                       -> "crypto_sha512"
    ("Sky.Core.Crypto", "sha512")              -> "crypto_sha512"
    ("Crypto", "sha1")                         -> "crypto_sha1"
    ("Sky.Core.Crypto", "sha1")                -> "crypto_sha1"
    ("Crypto", "md5")                          -> "crypto_md5"
    ("Sky.Core.Crypto", "md5")                 -> "crypto_md5"
    ("Crypto", "hmacSha256")                   -> "crypto_hmac_sha256"
    ("Sky.Core.Crypto", "hmacSha256")          -> "crypto_hmac_sha256"
    ("Crypto", "hmacSha512")                   -> "crypto_hmac_sha512"
    ("Sky.Core.Crypto", "hmacSha512")          -> "crypto_hmac_sha512"
    ("Crypto", "rsaSha256Sign")                -> "crypto_rsa_sha256_sign"
    ("Sky.Core.Crypto", "rsaSha256Sign")       -> "crypto_rsa_sha256_sign"
    ("Crypto", "rsaSha256Verify")              -> "crypto_rsa_sha256_verify"
    ("Sky.Core.Crypto", "rsaSha256Verify")     -> "crypto_rsa_sha256_verify"
    ("Crypto", "constantTimeEqual")            -> "crypto_constant_time_equal"
    ("Sky.Core.Crypto", "constantTimeEqual")   -> "crypto_constant_time_equal"
    -- v0.15.44 symmetric AEAD (sub-D)
    -- Sky.Core.Uuid (String surface; v0.15.x)
    ("Uuid", "v4")                             -> "uuid_v4"
    ("Sky.Core.Uuid", "v4")                    -> "uuid_v4"
    ("Uuid", "v7")                             -> "uuid_v7"
    ("Sky.Core.Uuid", "v7")                    -> "uuid_v7"
    ("Uuid", "parse")                          -> "uuid_parse"
    ("Sky.Core.Uuid", "parse")                 -> "uuid_parse"
    ("Crypto", "aesGcmEncrypt")                -> "crypto_aes_gcm_encrypt"
    ("Sky.Core.Crypto", "aesGcmEncrypt")       -> "crypto_aes_gcm_encrypt"
    ("Crypto", "aesGcmDecrypt")                -> "crypto_aes_gcm_decrypt"
    ("Sky.Core.Crypto", "aesGcmDecrypt")       -> "crypto_aes_gcm_decrypt"
    ("Crypto", "chacha20Encrypt")              -> "crypto_chacha20_encrypt"
    ("Sky.Core.Crypto", "chacha20Encrypt")     -> "crypto_chacha20_encrypt"
    ("Crypto", "chacha20Decrypt")              -> "crypto_chacha20_decrypt"
    ("Sky.Core.Crypto", "chacha20Decrypt")     -> "crypto_chacha20_decrypt"
    ("Crypto", "aesKeyFromPassword")           -> "crypto_aes_key_from_password"
    ("Sky.Core.Crypto", "aesKeyFromPassword")  -> "crypto_aes_key_from_password"
    ("Crypto", "chachaKeyFromPassword")        -> "crypto_chacha_key_from_password"
    ("Sky.Core.Crypto", "chachaKeyFromPassword") -> "crypto_chacha_key_from_password"
    -- Std.Time advanced (sub-A.5)
    -- INVARIANT: Time kernels are only ever referenced by their SHORT
    -- ("Time", …) key — stdlib lowers to short Time_* kernel names. A handful
    -- of arms below additionally carry the ("Sky.Core.Time", …) variant; that
    -- asymmetry is harmless given the invariant, but a hypothetical
    -- Can.VarKernel "Sky.Core.Time" "<fn>" for an arm without the qualified
    -- variant would fall to the default and snake-case to a non-existent
    -- runtime fn (E0425). Keep new Time arms keyed on the short name; only add
    -- the qualified variant if a dotted reference is actually emitted.
    ("Time", "inZone")            -> "time_in_zone"
    ("Time", "formatInZone")      -> "time_format_in_zone"
    -- formatISO8601 must be mapped: the default snake_case mangles the `ISO`
    -- acronym to `i_s_o8601` (one `_` per capital), which has no runtime fn.
    ("Time", "formatISO8601")     -> "time_format_iso8601"
    ("Sky.Core.Time", "formatISO8601") -> "time_format_iso8601"
    -- Time missing-five (go-parity kernel-gaps sweep 2026-06-15).
    -- addMillis / diffMillis are pure (no Task wrapper); format*/formatHTTP/
    -- formatRFC3339 are pure String-returning fns. ALL need explicit routing
    -- because the default toSnakeCase mangles acronyms: "formatHTTP" →
    -- "time_format_h_t_t_p", "formatRFC3339" → "time_format_r_f_c3339".
    ("Time", "addMillis")         -> "time_add_millis"
    ("Sky.Core.Time", "addMillis") -> "time_add_millis"
    ("Time", "diffMillis")        -> "time_diff_millis"
    ("Sky.Core.Time", "diffMillis") -> "time_diff_millis"
    ("Time", "format")            -> "time_format"
    ("Sky.Core.Time", "format")   -> "time_format"
    ("Time", "formatHTTP")        -> "time_format_http"
    ("Sky.Core.Time", "formatHTTP") -> "time_format_http"
    ("Time", "formatRFC3339")     -> "time_format_rfc3339"
    ("Sky.Core.Time", "formatRFC3339") -> "time_format_rfc3339"
    ("Time", "addDays")           -> "time_add_days"
    ("Time", "addHours")          -> "time_add_hours"
    ("Time", "addMinutes")        -> "time_add_minutes"
    ("Time", "addSeconds")        -> "time_add_seconds"
    ("Time", "addMonths")         -> "time_add_months"
    ("Time", "addYears")          -> "time_add_years"
    ("Time", "year")              -> "time_year"
    ("Time", "month")             -> "time_month"
    ("Time", "day")               -> "time_day"
    ("Time", "dayOfWeek")         -> "time_day_of_week"
    ("Time", "dayOfYear")         -> "time_day_of_year"
    ("Time", "weekOfYear")        -> "time_week_of_year"
    ("Time", "isWeekend")         -> "time_is_weekend"
    ("Time", "daysInMonth")       -> "time_days_in_month"
    ("Time", "isLeapYear")        -> "time_is_leap_year"
    ("Time", "startOfDay")        -> "time_start_of_day"
    ("Time", "endOfDay")          -> "time_end_of_day"
    ("Time", "startOfWeek")       -> "time_start_of_week"
    ("Time", "startOfMonth")      -> "time_start_of_month"
    ("Time", "endOfMonth")        -> "time_end_of_month"
    ("Time", "startOfYear")       -> "time_start_of_year"
    ("Time", "endOfYear")         -> "time_end_of_year"
    -- Std.Decimal (sub-A.6)
    ("Decimal", "fromString")     -> "decimal_from_string"
    ("Decimal", "fromInt")        -> "decimal_from_int"
    ("Decimal", "fromFloat")      -> "decimal_from_float"
    ("Decimal", "fromMinor")      -> "decimal_from_minor"
    ("Decimal", "zero")           -> "decimal_zero"
    ("Decimal", "one")            -> "decimal_one"
    ("Decimal", "oneHundred")     -> "decimal_one_hundred"
    ("Decimal", "toString")       -> "decimal_to_string"
    ("Decimal", "toStringFixed")  -> "decimal_to_string_fixed"
    ("Decimal", "toFloat")        -> "decimal_to_float"
    ("Decimal", "toInt")          -> "decimal_to_int"
    ("Decimal", "toMinor")        -> "decimal_to_minor"
    ("Decimal", "add")            -> "decimal_add"
    ("Decimal", "sub")            -> "decimal_sub"
    ("Decimal", "mul")            -> "decimal_mul"
    ("Decimal", "div")            -> "decimal_div"
    ("Decimal", "mod")            -> "decimal_mod"
    ("Decimal", "neg")            -> "decimal_neg"
    ("Decimal", "abs")            -> "decimal_abs"
    ("Decimal", "round")          -> "decimal_round"
    ("Decimal", "roundHalfUp")    -> "decimal_round_half_up"
    ("Decimal", "truncate")       -> "decimal_truncate"
    ("Decimal", "floor")          -> "decimal_floor"
    ("Decimal", "ceil")           -> "decimal_ceil"
    ("Decimal", "compare")        -> "decimal_compare"
    -- sub-A.8 T1 — Std.Decimal completion (15 kernels)
    ("Decimal", "eq")             -> "decimal_eq"
    ("Decimal", "neq")            -> "decimal_neq"
    ("Decimal", "lt")             -> "decimal_lt"
    ("Decimal", "lte")            -> "decimal_lte"
    ("Decimal", "gt")             -> "decimal_gt"
    ("Decimal", "gte")            -> "decimal_gte"
    ("Decimal", "min")            -> "decimal_min"
    ("Decimal", "max")            -> "decimal_max"
    ("Decimal", "isZero")         -> "decimal_is_zero"
    ("Decimal", "isPositive")     -> "decimal_is_positive"
    ("Decimal", "isNegative")     -> "decimal_is_negative"
    ("Decimal", "percentOf")      -> "decimal_percent_of"
    ("Decimal", "addPercent")     -> "decimal_add_percent"
    ("Decimal", "subPercent")     -> "decimal_sub_percent"
    ("Decimal", "formatWith")     -> "decimal_format_with"
    -- sub-A.8 T2 — Std.Money (11 kernels)
    ("Money", "format")               -> "money_format"
    ("Money", "formatWithCode")       -> "money_format_with_code"
    ("Money", "currencyName")         -> "money_currency_name"
    ("Money", "symbol")               -> "money_symbol"
    ("Money", "minorUnits")           -> "money_minor_units"
    ("Money", "isKnownCurrency")      -> "money_is_known_currency"
    ("Money", "setRate")              -> "money_set_rate"
    ("Money", "getRate")              -> "money_get_rate"
    ("Money", "hasRate")              -> "money_has_rate"
    ("Money", "clearRates")           -> "money_clear_rates"
    ("Money", "allocate")             -> "money_allocate"
    -- Sky.Core.Char (8 kernels). toLower/toUpper return a single-rune String
    -- (kernel shape Char -> String); toCode/fromCode are v0.16.7 #419.
    ("Char", "isAlpha")          -> "char_is_alpha"
    ("Sky.Core.Char", "isAlpha") -> "char_is_alpha"
    ("Char", "isDigit")          -> "char_is_digit"
    ("Sky.Core.Char", "isDigit") -> "char_is_digit"
    ("Char", "isLower")          -> "char_is_lower"
    ("Sky.Core.Char", "isLower") -> "char_is_lower"
    ("Char", "isUpper")          -> "char_is_upper"
    ("Sky.Core.Char", "isUpper") -> "char_is_upper"
    ("Char", "toLower")          -> "char_to_lower"
    ("Sky.Core.Char", "toLower") -> "char_to_lower"
    ("Char", "toUpper")          -> "char_to_upper"
    ("Sky.Core.Char", "toUpper") -> "char_to_upper"
    ("Char", "toCode")           -> "char_to_code"
    ("Sky.Core.Char", "toCode")  -> "char_to_code"
    ("Char", "fromCode")         -> "char_from_code"
    ("Sky.Core.Char", "fromCode") -> "char_from_code"
    -- sub-A.8 T3 — Sky.Core.Math: the explicitly-routed Math kernels below.
    -- The rest of the 36 Math entries (cbrt/hypot/exp/log/sin/cos/tan/atan2/
    -- trunc/…) are NOT listed here because they snake-case cleanly via the
    -- default arm (math_cbrt, math_atan2, …) and need no override.
    ("Math", "abs")             -> "math_abs"
    ("Sky.Core.Math", "abs")    -> "math_abs"
    ("Math", "min")             -> "math_min"
    ("Sky.Core.Math", "min")    -> "math_min"
    ("Math", "max")             -> "math_max"
    ("Sky.Core.Math", "max")    -> "math_max"
    ("Math", "sqrt")            -> "math_sqrt"
    ("Sky.Core.Math", "sqrt")   -> "math_sqrt"
    ("Math", "pow")             -> "math_pow"
    ("Sky.Core.Math", "pow")    -> "math_pow"
    ("Math", "floor")           -> "math_floor"
    ("Sky.Core.Math", "floor")  -> "math_floor"
    ("Math", "ceil")            -> "math_ceil"
    ("Sky.Core.Math", "ceil")   -> "math_ceil"
    ("Math", "round")           -> "math_round"
    ("Sky.Core.Math", "round")  -> "math_round"
    ("Math", "pi")              -> "math_pi"
    ("Sky.Core.Math", "pi")     -> "math_pi"
    ("Math", "e")               -> "math_e"
    ("Sky.Core.Math", "e")      -> "math_e"
    -- Math zero-arg constants — must be in the route table so codegen
    -- emits them as fn-calls `math_phi()` rather than bare value refs.
    ("Math", "phi")             -> "math_phi"
    ("Sky.Core.Math", "phi")    -> "math_phi"
    ("Math", "sqrt2")           -> "math_sqrt2"
    ("Sky.Core.Math", "sqrt2")  -> "math_sqrt2"
    ("Math", "inf")             -> "math_inf"
    ("Sky.Core.Math", "inf")    -> "math_inf"
    ("Math", "nan")             -> "math_nan"
    ("Sky.Core.Math", "nan")    -> "math_nan"
    -- Math two-arg functions whose snake_cased default name doesn't exist
    -- in the runtime (math.rs has math_mod / math_remainder).
    ("Math", "mod")             -> "math_mod"
    ("Sky.Core.Math", "mod")    -> "math_mod"
    ("Math", "remainder")       -> "math_remainder"
    ("Sky.Core.Math", "remainder") -> "math_remainder"
    -- sub-A.8 T4 — Std.Time advanced (7 kernels)
    ("Time", "diffSeconds")     -> "time_diff_seconds"
    ("Time", "diffMinutes")     -> "time_diff_minutes"
    ("Time", "diffHours")       -> "time_diff_hours"
    ("Time", "diffDays")        -> "time_diff_days"
    ("Time", "fromParts")       -> "time_from_parts"
    ("Time", "zoneOffset")      -> "time_zone_offset"
    ("Time", "zoneName")        -> "time_zone_name"
    -- sub-A.8 T5 — Sky.Core.Dict (6 kernels)
    ("Dict", "empty")           -> "dict_empty"
    ("Sky.Core.Dict", "empty")  -> "dict_empty"
    ("Dict", "insert")          -> "dict_insert"
    ("Sky.Core.Dict", "insert") -> "dict_insert"
    ("Dict", "get")             -> "dict_get"
    ("Sky.Core.Dict", "get")    -> "dict_get"
    ("Dict", "keys")            -> "dict_keys"
    ("Sky.Core.Dict", "keys")   -> "dict_keys"
    ("Dict", "remove")          -> "dict_remove"
    ("Sky.Core.Dict", "remove") -> "dict_remove"
    ("Dict", "member")          -> "dict_member"
    ("Sky.Core.Dict", "member") -> "dict_member"
    ("Dict", "fromList")        -> "dict_from_list"
    ("Sky.Core.Dict", "fromList") -> "dict_from_list"
    -- Dict missing-five (go-parity kernel-gaps sweep 2026-06-15)
    -- `size`/`isEmpty` snake-case fine (dict_size, dict_is_empty); `union`,
    -- `map`, `foldl` also snake-case fine. Listed explicitly for clarity +
    -- to ensure both the short and fully-qualified aliases are covered.
    ("Dict", "size")              -> "dict_size"
    ("Sky.Core.Dict", "size")     -> "dict_size"
    ("Dict", "isEmpty")           -> "dict_is_empty"
    ("Sky.Core.Dict", "isEmpty")  -> "dict_is_empty"
    ("Dict", "union")             -> "dict_union"
    ("Sky.Core.Dict", "union")    -> "dict_union"
    ("Dict", "map")               -> "dict_map"
    ("Sky.Core.Dict", "map")      -> "dict_map"
    ("Dict", "foldl")             -> "dict_foldl"
    ("Sky.Core.Dict", "foldl")    -> "dict_foldl"
    -- Sky.Core.Set — BTreeSet<A>-backed (go-parity kernel-gaps sweep 2026-06-16)
    ("Set", "empty")              -> "set_empty"
    ("Sky.Core.Set", "empty")     -> "set_empty"
    ("Set", "fromList")           -> "set_from_list"
    ("Sky.Core.Set", "fromList")  -> "set_from_list"
    ("Set", "insert")             -> "set_insert"
    ("Sky.Core.Set", "insert")    -> "set_insert"
    ("Set", "remove")             -> "set_remove"
    ("Sky.Core.Set", "remove")    -> "set_remove"
    ("Set", "member")             -> "set_member"
    ("Sky.Core.Set", "member")    -> "set_member"
    ("Set", "toList")             -> "set_to_list"
    ("Sky.Core.Set", "toList")    -> "set_to_list"
    ("Set", "size")               -> "set_size"
    ("Sky.Core.Set", "size")      -> "set_size"
    ("Set", "union")              -> "set_union"
    ("Sky.Core.Set", "union")     -> "set_union"
    ("Set", "intersect")          -> "set_intersect"
    ("Sky.Core.Set", "intersect") -> "set_intersect"
    ("Set", "diff")               -> "set_diff"
    ("Sky.Core.Set", "diff")      -> "set_diff"
    -- sub-A.8 T6 — Sky.Core.String additions (4 kernels)
    ("String", "replace")           -> "string_replace"
    ("Sky.Core.String", "replace")  -> "string_replace"
    ("String", "startsWith")        -> "string_starts_with"
    ("Sky.Core.String", "startsWith") -> "string_starts_with"
    ("String", "endsWith")          -> "string_ends_with"
    ("Sky.Core.String", "endsWith") -> "string_ends_with"
    ("String", "repeat")            -> "string_repeat"
    ("Sky.Core.String", "repeat")   -> "string_repeat"
    -- sub-A.8 T7 — Sky.Core.Basics + List (3 kernels)
    ("Basics", "modBy")               -> "basics_mod_by"
    ("Sky.Core.Basics", "modBy")      -> "basics_mod_by"
    ("Basics", "errorToString")       -> "basics_error_to_string"
    ("Sky.Core.Basics", "errorToString") -> "basics_error_to_string"
    ("List", "filterMap")             -> "list_filter_map"
    ("Sky.Core.List", "filterMap")    -> "list_filter_map"
    -- Json.Encode kernel functions: route to runtime implementations
    ("JsonEnc", "string") -> "json_enc_string"
    ("Sky.Core.Json.Encode", "string") -> "json_enc_string"
    ("JsonEnc", "int") -> "json_enc_int"
    ("Sky.Core.Json.Encode", "int") -> "json_enc_int"
    ("JsonEnc", "float") -> "json_enc_float"
    ("Sky.Core.Json.Encode", "float") -> "json_enc_float"
    ("JsonEnc", "bool") -> "json_enc_bool"
    ("Sky.Core.Json.Encode", "bool") -> "json_enc_bool"
    ("JsonEnc", "null") -> "json_enc_null"
    ("Sky.Core.Json.Encode", "null") -> "json_enc_null"
    ("JsonEnc", "encode") -> "json_enc_encode"
    ("Sky.Core.Json.Encode", "encode") -> "json_enc_encode"
    ("JsonEnc", "list") -> "json_enc_list"
    ("Sky.Core.Json.Encode", "list") -> "json_enc_list"
    ("JsonEnc", "object") -> "json_enc_object"
    ("Sky.Core.Json.Encode", "object") -> "json_enc_object"
    -- Json.Decode kernel functions: route to runtime implementations
    ("JsonDec", "string") -> "json_decode_string"
    ("Sky.Core.Json.Decode", "string") -> "json_decode_string"
    ("JsonDec", "int") -> "json_decode_int"
    ("Sky.Core.Json.Decode", "int") -> "json_decode_int"
    ("JsonDec", "float") -> "json_decode_float"
    ("Sky.Core.Json.Decode", "float") -> "json_decode_float"
    ("JsonDec", "bool") -> "json_decode_bool"
    ("Sky.Core.Json.Decode", "bool") -> "json_decode_bool"
    ("JsonDec", "null") -> "json_decode_null"
    ("Sky.Core.Json.Decode", "null") -> "json_decode_null"
    ("JsonDec", "field") -> "decode_field"
    ("Sky.Core.Json.Decode", "field") -> "decode_field"
    ("JsonDec", "at") -> "decode_at"
    ("Sky.Core.Json.Decode", "at") -> "decode_at"
    ("JsonDec", "list") -> "decode_list"
    ("Sky.Core.Json.Decode", "list") -> "decode_list"
    ("JsonDec", "map") -> "decode_map"
    ("Sky.Core.Json.Decode", "map") -> "decode_map"
    ("JsonDec", "andThen") -> "decode_and_then"
    ("Sky.Core.Json.Decode", "andThen") -> "decode_and_then"
    ("JsonDec", "succeed") -> "decode_succeed"
    ("Sky.Core.Json.Decode", "succeed") -> "decode_succeed"
    ("JsonDec", "fail") -> "decode_fail"
    ("Sky.Core.Json.Decode", "fail") -> "decode_fail"
    ("JsonDec", "decodeString") -> "decode_from_json_string"
    ("Sky.Core.Json.Decode", "decodeString") -> "decode_from_json_string"
    ("JsonDec", "oneOf") -> "decode_one_of"
    ("Sky.Core.Json.Decode", "oneOf") -> "decode_one_of"
    -- Std.Config — typed TOML/YAML/JSON decoders. The `Decoder a` is the same
    -- runtime representation as Json.Decode's (Decoder<E,T> over a serde_json
    -- Value), so the pure combinators route straight to the shared decode_* kernels
    -- (which already carry their turbofish entries). Only nullable + the format
    -- front-ends (String-first arg order) + loadFromFile live in config_decode.rs.
    ("Config", "string")  -> "json_decode_string"
    ("Std.Config", "string")  -> "json_decode_string"
    ("Config", "int")     -> "json_decode_int"
    ("Std.Config", "int")     -> "json_decode_int"
    ("Config", "float")   -> "json_decode_float"
    ("Std.Config", "float")   -> "json_decode_float"
    ("Config", "bool")    -> "json_decode_bool"
    ("Std.Config", "bool")    -> "json_decode_bool"
    ("Config", "field")   -> "decode_field"
    ("Std.Config", "field")   -> "decode_field"
    ("Config", "at")      -> "decode_at"
    ("Std.Config", "at")      -> "decode_at"
    ("Config", "list")    -> "decode_list"
    ("Std.Config", "list")    -> "decode_list"
    ("Config", "map")     -> "decode_map"
    ("Std.Config", "map")     -> "decode_map"
    ("Config", "andThen") -> "decode_and_then"
    ("Std.Config", "andThen") -> "decode_and_then"
    ("Config", "succeed") -> "decode_succeed"
    ("Std.Config", "succeed") -> "decode_succeed"
    ("Config", "fail")    -> "decode_fail"
    ("Std.Config", "fail")    -> "decode_fail"
    ("Config", "nullable")     -> "config_nullable"
    ("Std.Config", "nullable")     -> "config_nullable"
    ("Config", "decodeJson")   -> "config_decode_json"
    ("Std.Config", "decodeJson")   -> "config_decode_json"
    ("Config", "decodeToml")   -> "config_decode_toml"
    ("Std.Config", "decodeToml")   -> "config_decode_toml"
    ("Config", "decodeYaml")   -> "config_decode_yaml"
    ("Std.Config", "decodeYaml")   -> "config_decode_yaml"
    ("Config", "loadFromFile") -> "config_load_from_file"
    ("Std.Config", "loadFromFile") -> "config_load_from_file"
    -- Std.Trace — opt-in spans / events / attrs (output gated on SKY_TRACE).
    -- span runs + returns the wrapped task's result unchanged.
    ("Trace", "span") -> "trace_span"
    ("Std.Trace", "span") -> "trace_span"
    ("Trace", "event") -> "trace_event"
    ("Std.Trace", "event") -> "trace_event"
    ("Trace", "attr") -> "trace_attr"
    ("Std.Trace", "attr") -> "trace_attr"
    -- Task kernel functions: route to runtime implementations
    ("Task", "succeed") -> "task_succeed"
    ("Sky.Core.Task", "succeed") -> "task_succeed"
    ("Task", "map") -> "task_map"
    ("Sky.Core.Task", "map") -> "task_map"
    ("Task", "andThen") -> "task_and_then"
    ("Sky.Core.Task", "andThen") -> "task_and_then"
    ("Task", "mapError") -> "task_map_error"
    ("Sky.Core.Task", "mapError") -> "task_map_error"
    ("Task", "onError") -> "task_on_error"
    ("Sky.Core.Task", "onError") -> "task_on_error"
    -- Task.perform : Task e a -> Result e a (runs synchronously, keeps the
    -- value). That is task_run, not task_perform (which returns a Task<()> and
    -- drops the value). sub-D fix — surfaced by the retryWith test.
    ("Task", "perform") -> "task_run"
    ("Sky.Core.Task", "perform") -> "task_run"
    ("Task", "sequence") -> "task_sequence"
    ("Sky.Core.Task", "sequence") -> "task_sequence"
    ("Task", "run") -> "task_run"
    ("Sky.Core.Task", "run") -> "task_run"
    ("Task", "parallel") -> "task_parallel"
    ("Sky.Core.Task", "parallel") -> "task_parallel"
    ("Task", "lazy") -> "task_lazy"
    ("Task", "retryWith") -> "task_retry_with"  -- real retry loop; policy destructured at the call site (ExprEmitter)
    ("Sky.Core.Task", "retryWith") -> "task_retry_with"
    ("Sky.Core.Task", "lazy") -> "task_lazy"
    ("Task", "fail") -> "task_fail"
    ("Sky.Core.Task", "fail") -> "task_fail"
    ("Task", "fromResult") -> "task_from_result"
    ("Sky.Core.Task", "fromResult") -> "task_from_result"
    ("Task", "andThenResult") -> "task_and_then_result"
    ("Sky.Core.Task", "andThenResult") -> "task_and_then_result"
    -- Random missing-three (go-parity kernel-gaps sweep 2026-06-15).
    -- `choice` in Sky.Core.Random.sky is `Ffi.kernel "Random_choiceMaybe"`.
    -- `shuffle` and `weighted` snake-case fine but listed explicitly for
    -- robustness against future toSnakeCase changes to uppercase runs.
    ("Random", "choiceMaybe")         -> "random_choice_maybe"
    ("Sky.Core.Random", "choiceMaybe") -> "random_choice_maybe"
    -- `choice` in the stdlib calls the kernel `Random_choiceMaybe` directly,
    -- so we also map the logical name in case any call site uses it.
    ("Random", "shuffle")             -> "random_shuffle"
    ("Sky.Core.Random", "shuffle")    -> "random_shuffle"
    ("Random", "weighted")            -> "random_weighted"
    ("Sky.Core.Random", "weighted")   -> "random_weighted"
    -- System.getcwd : () -> Task Error String — backward-compat alias.
    -- Go: `System_getcwd` delegates to `System_cwd`. toSnakeCase would give
    -- `sky_core_system_getcwd` (wrong prefix), so we route explicitly.
    ("System", "getcwd")              -> "system_getcwd"
    ("Sky.Core.System", "getcwd")     -> "system_getcwd"
    -- Json.Decode.Pipeline
    ("JsonDecP", "required") -> "decode_pipeline_required"
    ("Sky.Core.Json.Decode.Pipeline", "required") -> "decode_pipeline_required"
    ("JsonDecP", "optional") -> "decode_pipeline_optional"
    ("Sky.Core.Json.Decode.Pipeline", "optional") -> "decode_pipeline_optional"
    -- JsonDecP.custom + requiredAt (go-parity kernel-gaps sweep 2026-06-15)
    ("JsonDecP", "custom") -> "decode_pipeline_custom"
    ("Sky.Core.Json.Decode.Pipeline", "custom") -> "decode_pipeline_custom"
    ("JsonDecP", "requiredAt") -> "decode_pipeline_required_at"
    ("Sky.Core.Json.Decode.Pipeline", "requiredAt") -> "decode_pipeline_required_at"
    -- Std.Db.Decode (DbDec) — go-parity kernel-gaps sweep 2026-06-16.
    -- The decoder TYPE + COMBINATORS are SHARED with JsonDec (one global
    -- `Decoder a`; combinators are source-agnostic) → map/andThen/andMap/
    -- map2-5/succeed/fail route to the shared decode_* runtime fns. The
    -- PRIMITIVES read a named DB column (rows arrive as JsonVal::Object of
    -- string/Null fields via row_to_json) and parse → db_decode_*.
    ("DbDec", "string")           -> "db_decode_string"
    ("Std.Db.Decode", "string")   -> "db_decode_string"
    ("DbDec", "int")              -> "db_decode_int"
    ("Std.Db.Decode", "int")      -> "db_decode_int"
    ("DbDec", "float")            -> "db_decode_float"
    ("Std.Db.Decode", "float")    -> "db_decode_float"
    ("DbDec", "bool")             -> "db_decode_bool"
    ("Std.Db.Decode", "bool")     -> "db_decode_bool"
    -- nullable / required / optional — unblocked by the {run, fields} Decoder
    -- redesign (the decoder carries the object fields it reads, so nullable can
    -- NULL-gate them; required/optional are applicative = field + and_map, no
    -- FnOnce wall). money stays UNROUTED (needs the Money-ADT codegen wrapper).
    ("DbDec", "nullable")         -> "db_decode_nullable"
    ("Std.Db.Decode", "nullable") -> "db_decode_nullable"
    -- required/optional are APPLICATIVE (db_decode_required = decode_and_map(fieldDec,
    -- accDec)) — NOT the json pipeline. In DbDec the column arg is doc-only (the
    -- field decoder `int "age"` already reads its column), so decode_pipeline_required
    -- would DOUBLE-EXTRACT the field and break `nullable (string col)` nesting.
    -- The succeed-ctor currying (curry4) — added to the curry detection for the
    -- Db.Decode module — lets the uncurried record ctor satisfy and_map's
    -- one-arg-at-a-time application.
    ("DbDec", "required")         -> "db_decode_required"
    ("Std.Db.Decode", "required") -> "db_decode_required"
    ("DbDec", "optional")         -> "db_decode_optional"
    ("Std.Db.Decode", "optional") -> "db_decode_optional"
    ("DbDec", "succeed")          -> "decode_succeed"
    ("Std.Db.Decode", "succeed")  -> "decode_succeed"
    ("DbDec", "fail")             -> "decode_fail"
    ("Std.Db.Decode", "fail")     -> "decode_fail"
    ("DbDec", "map")              -> "decode_map"
    ("Std.Db.Decode", "map")      -> "decode_map"
    ("DbDec", "andThen")          -> "decode_and_then"
    ("Std.Db.Decode", "andThen")  -> "decode_and_then"
    ("DbDec", "andMap")           -> "decode_and_map"
    ("Std.Db.Decode", "andMap")   -> "decode_and_map"
    ("DbDec", "map2")             -> "decode_map2"
    ("Std.Db.Decode", "map2")     -> "decode_map2"
    ("DbDec", "map3")             -> "decode_map3"
    ("Std.Db.Decode", "map3")     -> "decode_map3"
    ("DbDec", "map4")             -> "decode_map4"
    ("Std.Db.Decode", "map4")     -> "decode_map4"
    ("DbDec", "map5")             -> "decode_map5"
    ("Std.Db.Decode", "map5")     -> "decode_map5"
    -- JsonDec.index (go-parity kernel-gaps sweep 2026-06-15)
    ("JsonDec", "index") -> "decode_index"
    ("Sky.Core.Json.Decode", "index") -> "decode_index"
    -- JsonDec.map2 / map3 / map4
    ("JsonDec", "map2") -> "decode_map2"
    ("Sky.Core.Json.Decode", "map2") -> "decode_map2"
    ("JsonDec", "map3") -> "decode_map3"
    ("Sky.Core.Json.Decode", "map3") -> "decode_map3"
    ("JsonDec", "map4") -> "decode_map4"
    ("Sky.Core.Json.Decode", "map4") -> "decode_map4"
    -- Log kernel functions: route to runtime implementations
    ("Log", "println") -> "log_println"
    ("Std.Log", "println") -> "log_println"
    ("Log", "info") -> "log_info"
    ("Std.Log", "info") -> "log_info"
    ("Log", "debug") -> "log_debug"
    ("Std.Log", "debug") -> "log_debug"
    ("Log", "warn") -> "log_warn"
    ("Std.Log", "warn") -> "log_warn"
    ("Log", "error") -> "log_error"
    ("Std.Log", "error") -> "log_error"
    ("Log", "infoWith") -> "log_info_with"
    ("Std.Log", "infoWith") -> "log_info_with"
    ("Log", "debugWith") -> "log_debug_with"
    ("Std.Log", "debugWith") -> "log_debug_with"
    ("Log", "warnWith") -> "log_warn_with"
    ("Std.Log", "warnWith") -> "log_warn_with"
    ("Log", "errorWith") -> "log_error_with"
    ("Std.Log", "errorWith") -> "log_error_with"
    -- Db kernel functions: route to runtime implementations
    ("Db", "open") -> "db_open"
    ("Std.Db", "open") -> "db_open"
    ("Db", "connect") -> "db_connect"
    ("Std.Db", "connect") -> "db_connect"
    ("Db", "exec") -> "db_exec"
    ("Std.Db", "exec") -> "db_exec"
    ("Db", "execRaw") -> "db_exec_raw"
    ("Std.Db", "execRaw") -> "db_exec_raw"
    ("Db", "query") -> "db_query"
    ("Std.Db", "query") -> "db_query"
    ("Db", "getField") -> "db_get_field"
    ("Std.Db", "getField") -> "db_get_field"
    ("Db", "getString") -> "db_get_string"
    ("Std.Db", "getString") -> "db_get_string"
    ("Db", "getInt") -> "db_get_int"
    ("Std.Db", "getInt") -> "db_get_int"
    ("Db", "migrateApply") -> "db_migrate_apply"
    ("Std.Db", "migrateApply") -> "db_migrate_apply"
    -- sub-B: 12 missing Std.Db kernels (lifecycle + CRUD + search + tx)
    ("Db", "close")             -> "db_close"
    ("Std.Db", "close")         -> "db_close"
    ("Db", "getBool")           -> "db_get_bool"
    ("Std.Db", "getBool")       -> "db_get_bool"
    ("Db", "insertRow")         -> "db_insert_row"
    ("Std.Db", "insertRow")     -> "db_insert_row"
    ("Db", "getById")           -> "db_get_by_id"
    ("Std.Db", "getById")       -> "db_get_by_id"
    ("Db", "updateById")        -> "db_update_by_id"
    ("Std.Db", "updateById")    -> "db_update_by_id"
    ("Db", "deleteById")        -> "db_delete_by_id"
    ("Std.Db", "deleteById")    -> "db_delete_by_id"
    ("Db", "findOneByField")    -> "db_find_one_by_field"
    ("Std.Db", "findOneByField") -> "db_find_one_by_field"
    ("Db", "findManyByField")   -> "db_find_many_by_field"
    ("Std.Db", "findManyByField") -> "db_find_many_by_field"
    ("Db", "findByConditions")  -> "db_find_by_conditions"
    ("Std.Db", "findByConditions") -> "db_find_by_conditions"
    ("Db", "unsafeFindWhere")   -> "db_unsafe_find_where"
    ("Std.Db", "unsafeFindWhere") -> "db_unsafe_find_where"
    ("Db", "queryDecode")       -> "db_query_decode"
    ("Std.Db", "queryDecode")   -> "db_query_decode"
    ("Db", "getByIdDecode")     -> "db_get_by_id_decode"
    ("Std.Db", "getByIdDecode") -> "db_get_by_id_decode"
    ("Db", "withTransaction")   -> "db_with_transaction"
    ("Std.Db", "withTransaction") -> "db_with_transaction"
    -- Phase B: SQL-gen kernels (insertFields / updateFields / insertFieldsReturning).
    -- NOTE: these are intercepted FIRST by special-case arms in ExprEmitter.hs
    -- (`Can.Call (VarKernel "Db" "insertFields") …`) which emit the SqlParam
    -- conversion inline.  These Kernel.hs entries are here for completeness /
    -- partial-application fallback and must match the runtime fn names.
    ("Db", "insertFields")             -> "db_insert_fields"
    ("Std.Db", "insertFields")         -> "db_insert_fields"
    ("Db", "updateFields")             -> "db_update_fields"
    ("Std.Db", "updateFields")         -> "db_update_fields"
    ("Db", "insertFieldsReturning")    -> "db_insert_fields_returning"
    ("Std.Db", "insertFieldsReturning") -> "db_insert_fields_returning"
    -- Sub-C: Std.Auth — 6 pure crypto + 3 DB-touching kernels.
    ("Auth", "hashPassword")     -> "auth_hash_password"
    ("Std.Auth", "hashPassword") -> "auth_hash_password"
    ("Auth", "hashPasswordCost")     -> "auth_hash_password_cost"
    ("Std.Auth", "hashPasswordCost") -> "auth_hash_password_cost"
    ("Auth", "verifyPassword")     -> "auth_verify_password"
    ("Std.Auth", "verifyPassword") -> "auth_verify_password"
    ("Auth", "passwordStrength")     -> "auth_password_strength"
    ("Std.Auth", "passwordStrength") -> "auth_password_strength"
    ("Auth", "signToken")     -> "auth_sign_token"
    ("Std.Auth", "signToken") -> "auth_sign_token"
    ("Auth", "verifyToken")     -> "auth_verify_token"
    ("Std.Auth", "verifyToken") -> "auth_verify_token"
    ("Auth", "register")     -> "auth_register"
    ("Std.Auth", "register") -> "auth_register"
    ("Auth", "login")     -> "auth_login"
    ("Std.Auth", "login") -> "auth_login"
    ("Auth", "setRole")     -> "auth_set_role"
    ("Std.Auth", "setRole") -> "auth_set_role"
    -- Ffi.kernel: the codegen routes every call through the kernel dispatch,
    -- but the Rust target resolves Ffi.kernel calls directly during
    -- canonicalisation.  Any Ffi.kernel reference that reaches codegen is
    -- a polyfill call site — emit a diagnostic panic.
    -- Sub-E: TEA Cmd/Sub/Cli — map directly to the tea.rs kernels (don't rely on
    -- the Ffi.kernel-alias table, which mis-resolves in nested expr positions and
    -- would call the generated stdlib wrapper -> Ffi.kernel polyfill panic).
    ("Cmd", "none")     -> "cmd_none"
    ("Std.Cmd", "none") -> "cmd_none"
    ("Cmd", "batch")     -> "cmd_batch"
    ("Std.Cmd", "batch") -> "cmd_batch"
    ("Cmd", "perform")     -> "cmd_perform"
    ("Std.Cmd", "perform") -> "cmd_perform"
    ("Sub", "none")     -> "sub_none"
    ("Std.Sub", "none") -> "sub_none"
    ("Sub", "batch")     -> "sub_batch"
    ("Std.Sub", "batch") -> "sub_batch"
    ("Sub", "every")     -> "sub_every"
    ("Std.Sub", "every") -> "sub_every"
    ("Cmd", "publish")            -> "cmd_publish"
    ("Std.Cmd", "publish")        -> "cmd_publish"
    ("Cmd", "publishNoEcho")      -> "cmd_publish_no_echo"
    ("Std.Cmd", "publishNoEcho")  -> "cmd_publish_no_echo"
    ("Sub", "subscribeTopic")     -> "sub_subscribe_topic"
    ("Std.Sub", "subscribeTopic") -> "sub_subscribe_topic"
    ("PubSub", "publish")           -> "pubsub_publish"
    ("Std.PubSub", "publish")       -> "pubsub_publish"
    ("PubSub", "publishNoEcho")     -> "pubsub_publish_no_echo"
    ("Std.PubSub", "publishNoEcho") -> "pubsub_publish_no_echo"
    ("Cli", "program")     -> "cli_program"
    ("Std.Cli", "program") -> "cli_program"
    -- Sky.Http.Middleware + Sky.Http.RateLimit — map both the short kernel-module
    -- form and the fully-qualified Sky module to the runtime fns (robust against
    -- the alias-table resolution path).
    ("Middleware", "withCors")              -> "middleware_with_cors"
    ("Sky.Http.Middleware", "withCors")     -> "middleware_with_cors"
    ("Middleware", "withLogging")           -> "middleware_with_logging"
    ("Sky.Http.Middleware", "withLogging")  -> "middleware_with_logging"
    ("Middleware", "withBasicAuth")             -> "middleware_with_basic_auth"
    ("Sky.Http.Middleware", "withBasicAuth")    -> "middleware_with_basic_auth"
    ("Middleware", "withRateLimit")             -> "middleware_with_rate_limit"
    ("Sky.Http.Middleware", "withRateLimit")    -> "middleware_with_rate_limit"
    ("RateLimit", "allow")            -> "rate_limit_allow"
    ("Sky.Http.RateLimit", "allow")   -> "rate_limit_allow"
    -- Std.Live — P0 scaffold kernel (bridge + render path gate).
    ("Live", "renderStatic")     -> "live_render_static"
    ("Std.Live", "renderStatic") -> "live_render_static"
    ("Live", "app")              -> "live_app"
    ("Std.Live", "app")          -> "live_app"
    ("Ffi", "kernel") -> "ffi_kernel_polyfill"
    -- Ffi.callPure / callTask / toAny: the peephole rewriter in exprToRustInner
    -- handles the common case (literal kernel name + literal args list) by
    -- emitting a direct kernel call. Non-peephole-matched references land
    -- here and route to runtime polyfills: ffi_to_any_polyfill is compile-
    -- time identity; ffi_call_pure_polyfill / ffi_call_task_polyfill panic
    -- with an actionable message. See runtime-rust/src/sky_runtime/ffi_polyfills.rs.
    ("Ffi", "callPure") -> "ffi_call_pure_polyfill"
    ("Ffi", "callTask") -> "ffi_call_task_polyfill"
    ("Ffi", "call")     -> "ffi_call_pure_polyfill"  -- deprecated alias of callPure
    ("Ffi", "toAny")    -> "ffi_to_any_polyfill"
    -- Rust user-FFI kernel: snake_case the suffix, no panic stub.
    -- The wrapper function lives in a .skycache/ffi/rust/*_bindings.rs file
    -- that gets copied into sky-out/rust/src/ at codegen time.
    --
    -- LOAD-BEARING COUPLING: this default must stay byte-for-byte in step with
    -- Build/Rust/Ffi.hs:526 (toSnakeCase including the _from_<recvType>
    -- receiver-type disambiguation suffix). The suffix is already baked into
    -- `name` here before kernelToRust is reached, so we only snake_case it —
    -- but if the Ffi.hs naming convention changes, this arm must follow.
    _ | "Rust_" `isPrefixOf` mod ->
        toSnakeCase (drop 5 mod ++ "_" ++ name)
    _ -> toSnakeCase (map (\c -> if c == '.' then '_' else c) mod ++ "_" ++ name)
