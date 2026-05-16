package rt

import "fmt"

// Test-only VNode construction helpers.
//
// Before v0.13 these lived in live.go and backed the Go `Html_*`
// element kernels. v0.13 migrated Std.Html to Sky source, so
// production VNode trees are now built by HtmlToVNode straight from
// the Sky `Html` ADT — `velement` / `attrPair` no longer have any
// production caller. They remain useful for the renderer / diff /
// protocol tests, which need to hand-assemble VNode trees, so they
// live here as shared test infrastructure (visible to every
// `_test.go` file in package rt).

// attrPair is a plain key/value attribute. An empty key is the
// "no-op" sentinel (a False-valued boolean attribute renders nothing).
type attrPair struct{ key, val string }

// velement builds an element VNode from heterogeneous attr / child
// lists, mirroring the shape the old Html_* kernels accepted.
func velement(tag string, attrs []any, children []any) VNode {
	node := VNode{
		Kind:   "element",
		Tag:    tag,
		Attrs:  map[string]string{},
		Events: map[string]any{},
	}
	for _, a := range attrs {
		switch v := a.(type) {
		case attrPair:
			if v.key == "" {
				continue
			}
			node.Attrs[v.key] = v.val
		case eventPair:
			node.Events[v.name] = v.msg
		case SkyTuple2:
			node.Attrs[fmt.Sprintf("%v", v.V0)] = fmt.Sprintf("%v", v.V1)
		}
	}
	for _, c := range children {
		switch v := c.(type) {
		case VNode:
			node.Children = append(node.Children, v)
		case string:
			node.Children = append(node.Children, vtext(v))
		}
	}
	return node
}
