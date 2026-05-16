// stdlib_web.go — shared HTML-escaping helpers.
//
// v0.13 Layer 3: Std.Css / Std.Html / Std.Html.Attributes /
// Std.Html.Events were migrated from Go runtime kernels to
// fully-typed Sky source (sky-stdlib/Std/{Css,Html}.sky and
// sky-stdlib/Std/Html/{Attributes,Events}.sky). The element /
// attribute / event / CSS builders that used to live here are
// gone; only the two escaping primitives remain, because the
// Sky-source modules call them across the FFI boundary via
// `Ffi.callPure "htmlEscapeText"` / `"htmlEscapeAttr"` (the
// registry entries are in live.go's init()).
//
// Both delegate to the standard library's `html.EscapeString`,
// which escapes `& ' < > "` — the full set required to make a
// string safe in both element-text and double-quoted-attribute
// contexts. Never hand-roll escaping with strings.Replace: a
// missed character (or wrong order) is an XSS hole.
package rt

import "html"

func htmlEscapeText(s string) string {
	return html.EscapeString(s)
}

func htmlEscapeAttr(s string) string {
	return html.EscapeString(s)
}
