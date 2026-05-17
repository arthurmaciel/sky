package rt

import (
	"testing"
)

// Regression fence for the skyshop Firebase auth panic:
// `interface conversion: interface {} is map[string]string, not
// map[string]interface {}`.
//
// Root cause was typed-codegen emitting `any(claims).(map[string]any)`
// when claims was statically `map[string]string` (returned by
// rt.AsMapT[string] in Lib_Auth_verifyToken). Direct assertion fails
// because the two generic instantiations are distinct Go nominal types.
// Fix: route through rt.AsMapAny which widens via reflect.

func TestAsMapAnyFromMapStringString(t *testing.T) {
	src := map[string]string{
		"email": "user@example.com",
		"name":  "Alice",
		"uid":   "abc123",
	}
	out := AsMapAny(src)
	if len(out) != 3 {
		t.Fatalf("expected 3 entries, got %d", len(out))
	}
	if out["email"] != "user@example.com" {
		t.Fatalf("email: got %v", out["email"])
	}
	if out["name"] != "Alice" {
		t.Fatalf("name: got %v", out["name"])
	}
}

func TestAsMapAnyIdentityOnAlreadyMapAny(t *testing.T) {
	src := map[string]any{"k": 1, "v": "hello"}
	out := AsMapAny(src)
	if len(out) != 2 {
		t.Fatalf("expected 2, got %d", len(out))
	}
	if out["k"] != 1 || out["v"] != "hello" {
		t.Fatalf("wrong values: %+v", out)
	}
}

func TestAsMapAnyNilSafe(t *testing.T) {
	if AsMapAny(nil) != nil {
		t.Fatal("expected nil for nil input")
	}
	// Non-map input returns nil (mirrors AsListAny behaviour).
	if AsMapAny(42) != nil {
		t.Fatal("expected nil for non-map input")
	}
}

func TestAsMapAnyFromMapStringInt(t *testing.T) {
	src := map[string]int{"a": 1, "b": 2}
	out := AsMapAny(src)
	if len(out) != 2 || out["a"] != 1 || out["b"] != 2 {
		t.Fatalf("wrong: %+v", out)
	}
}

func TestAsMapAnyDoesNotPanicOnTypedSource(t *testing.T) {
	// Skyshop reproducer: claims arrives as map[string]string and is
	// passed to a Sky helper expecting `Dict String a` (map[string]any
	// in codegen). Pre-fix this panicked; post-fix it widens cleanly.
	defer func() {
		if r := recover(); r != nil {
			t.Fatalf("unexpected panic: %v", r)
		}
	}()
	claims := map[string]string{"email": "x@y.com"}
	out := AsMapAny(claims)
	_ = out["email"]
}
