package rt

import (
	"testing"
)

// #158 — Db.query result → typed-function panic class. The runtime
// shape of a Db row is `map[string]any` (heterogeneous columns: int
// id, string name, []byte hash). Sky's HM type-checker may type the
// row as a record alias `Foo_R` at the call boundary. Before the
// map→struct path landed in rt.Coerce, `rt.Coerce[Foo_R](dbRow)`
// panicked with `expected Foo_R, got map[string]interface{}` even
// though every field was recoverable by name.
//
// The fix is defensive: when source is `map[string]any` AND target is
// a struct with exported fields keyed by name, build T field-by-field
// using narrowReflectValue so nested container types round-trip too.

type userRow struct {
	ID    int
	Name  string
	Email string
}

func TestCoerceMapToStructHappyPath(t *testing.T) {
	// Source from Db.query: map[string]any with mixed types
	dbRow := map[string]any{
		"id":    int(7),
		"name":  "alice",
		"email": "alice@example.com",
	}

	out := Coerce[userRow](dbRow)
	if out.ID != 7 {
		t.Fatalf("ID: want 7, got %d", out.ID)
	}
	if out.Name != "alice" {
		t.Fatalf("Name: want alice, got %q", out.Name)
	}
	if out.Email != "alice@example.com" {
		t.Fatalf("Email: want alice@example.com, got %q", out.Email)
	}
}

func TestCoerceMapToStructPascalCaseKeys(t *testing.T) {
	// Some sources (Firestore document.Data, JSON.Unmarshal with
	// case-insensitive field matching) emit PascalCase keys. The
	// narrowing handles both lowercase-first and PascalCase forms.
	dbRow := map[string]any{
		"ID":    int(42),
		"Name":  "bob",
		"Email": "bob@example.com",
	}

	out := Coerce[userRow](dbRow)
	if out.ID != 42 {
		t.Fatalf("ID: want 42, got %d", out.ID)
	}
	if out.Name != "bob" {
		t.Fatalf("Name: want bob, got %q", out.Name)
	}
}

func TestCoerceMapToStructPartialFields(t *testing.T) {
	// SELECT id, name FROM users — email column missing. Result
	// should be zero-valued for the missing field, not a panic.
	dbRow := map[string]any{
		"id":   int(3),
		"name": "carol",
	}

	out := Coerce[userRow](dbRow)
	if out.ID != 3 {
		t.Fatalf("ID: want 3, got %d", out.ID)
	}
	if out.Name != "carol" {
		t.Fatalf("Name: want carol, got %q", out.Name)
	}
	if out.Email != "" {
		t.Fatalf("Email: want empty, got %q", out.Email)
	}
}

func TestCoerceMapToStructNumericWidening(t *testing.T) {
	// SQLite drivers commonly return INTEGER columns as int64; the
	// row map's "id" value is int64 even when the Go field is int.
	// narrowReflectValue handles numeric widening within the safe
	// subset (int64 → int when no precision is lost).
	dbRow := map[string]any{
		"id":   int64(99),
		"name": "dana",
	}

	out := Coerce[userRow](dbRow)
	if out.ID != 99 {
		t.Fatalf("ID: want 99, got %d", out.ID)
	}
}

// Nested container case: a record holds a typed map field. The DB
// driver returns the nested map as map[string]any, but the field's
// Go type is map[string]string.
type userWithMeta struct {
	ID   int
	Meta map[string]string
}

func TestCoerceMapToStructNestedMapField(t *testing.T) {
	row := map[string]any{
		"id": int(1),
		"meta": map[string]any{
			"role":  "admin",
			"plan":  "pro",
			"theme": "dark",
		},
	}

	out := Coerce[userWithMeta](row)
	if out.ID != 1 {
		t.Fatalf("ID: want 1, got %d", out.ID)
	}
	if out.Meta == nil {
		t.Fatalf("Meta: expected populated map, got nil")
	}
	if out.Meta["role"] != "admin" {
		t.Fatalf("Meta[role]: want admin, got %q", out.Meta["role"])
	}
	if len(out.Meta) != 3 {
		t.Fatalf("Meta: expected 3 entries, got %d", len(out.Meta))
	}
}

// Test confirms the previous panic class is closed: passing a
// map[string]any source where the target is a struct no longer
// panics with the cryptic "expected Foo_R, got map[string]..." msg.
func TestCoerceMapToStructDoesNotPanic(t *testing.T) {
	defer func() {
		if r := recover(); r != nil {
			t.Fatalf("expected no panic, got %v", r)
		}
	}()
	dbRow := map[string]any{"id": 1, "name": "test", "email": "t@x"}
	_ = Coerce[userRow](dbRow)
}
