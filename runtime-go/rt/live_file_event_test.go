package rt

// Wire-level pin for the file / image upload events. The renderer
// must emit `data-sky-ev-sky-file="<MsgName>"` (NOT the legacy
// `sky-file="..."`) so the embedded JS file-driver picks it up via
// the data-attribute convention. The leading `sky-` on the eventPair
// name is the marker that triggers the data-attribute branch in
// renderVNode.
//
// v0.13: the `onFile` / `onImage` constructors themselves now live in
// the Sky-source Std.Html.Events module; this test pins the *renderer*
// half of the contract (the still-in-Go renderVNode path), so it
// builds the eventPair directly — `eventPair{name:"sky-file", …}` is
// exactly the shape the Sky-side constructor produces over the FFI.

import (
	"strings"
	"testing"
)

func TestEvent_onFile_RendersDataAttribute(t *testing.T) {
	// msgDisplayName extracts the constructor name from the function's
	// runtime name — typically `pkg.Msg_<Name>` from typed codegen. We
	// give the test func that exact shape so the test pins the rendered
	// attribute value end-to-end.
	avatarSelected := Msg_AvatarSelected
	ev := eventPair{name: "sky-file", msg: avatarSelected}

	tree := velement("input", []any{ev}, nil)
	assignSkyIDs(&tree, "r")
	html := renderVNode(tree, map[string]any{})

	if !strings.Contains(html, `data-sky-ev-sky-file="AvatarSelected"`) {
		t.Errorf("rendered HTML missing data-sky-ev-sky-file attr; got:\n%s", html)
	}
	// Must NOT emit as `sky-file=...` — the JS bind loop addEventListener's
	// on `sky-<event>` attrs and there is no real DOM `sky-file` event,
	// so the wrong shape would silently never fire.
	if strings.Contains(html, ` sky-file=`) {
		t.Errorf("rendered HTML wrongly emitted as sky-file= shape; got:\n%s", html)
	}
}

// Test fixtures — function names mirror what typed codegen emits
// (`Msg_<ConstructorName>`) so msgDisplayName picks up the right name.
func Msg_AvatarSelected(s any) any { _ = s; return nil }
func Msg_AvatarUploaded(s any) any { _ = s; return nil }

func TestEvent_onImage_RendersDataAttribute(t *testing.T) {
	avatarUploaded := Msg_AvatarUploaded
	ev := eventPair{name: "sky-image", msg: avatarUploaded}

	tree := velement("input", []any{ev}, nil)
	assignSkyIDs(&tree, "r")
	html := renderVNode(tree, map[string]any{})

	if !strings.Contains(html, `data-sky-ev-sky-image="AvatarUploaded"`) {
		t.Errorf("rendered HTML missing data-sky-ev-sky-image attr; got:\n%s", html)
	}
}
