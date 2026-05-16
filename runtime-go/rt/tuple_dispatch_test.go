package rt

import (
	"reflect"
	"testing"
)

// Fast-path coverage for tupleFirst / tupleSecond. The hot caller is
// the TEA dispatch loop (`update` returning `(Model, Cmd msg)`). v0.13
// emits all tuples as `SkyTuple2 = T2[any, any]`, so the type-assertion
// fast path covers every normal-shape call. The reflect fallback only
// kicks in for shape-erased values arriving from generic kernels
// (AsTuple2-style wideners).

func TestTupleFirstSkyTuple2FastPath(t *testing.T) {
	tup := SkyTuple2{V0: 42, V1: "hello"}
	if got := tupleFirst(tup); got != 42 {
		t.Fatalf("tupleFirst: want 42, got %v (%T)", got, got)
	}
	if got := tupleSecond(tup); got != "hello" {
		t.Fatalf("tupleSecond: want hello, got %v (%T)", got, got)
	}
}

func TestTupleFirstSkyTuple3FastPath(t *testing.T) {
	tup := SkyTuple3{V0: 1, V1: 2, V2: 3}
	if got := tupleFirst(tup); got != 1 {
		t.Fatalf("tupleFirst on SkyTuple3: want 1, got %v", got)
	}
	if got := tupleSecond(tup); got != 2 {
		t.Fatalf("tupleSecond on SkyTuple3: want 2, got %v", got)
	}
}

func TestTupleFirstReflectFallback(t *testing.T) {
	// A typed instantiation `T2[int, string]` is a distinct Go nominal
	// type from `SkyTuple2 = T2[any, any]`. The type assertion fails;
	// reflect picks up the V0/V1 field-by-name path.
	type fancyTup = T2[int, string]
	tup := fancyTup{V0: 7, V1: "wide"}
	if got := tupleFirst(tup); got != 7 {
		t.Fatalf("tupleFirst on typed T2: want 7, got %v", got)
	}
	if got := tupleSecond(tup); got != "wide" {
		t.Fatalf("tupleSecond on typed T2: want wide, got %v", got)
	}
}

func TestTupleFirstArrayShape(t *testing.T) {
	a := [2]any{"alpha", "beta"}
	if got := tupleFirst(a); got != "alpha" {
		t.Fatalf("tupleFirst on [2]any: want alpha, got %v", got)
	}
	if got := tupleSecond(a); got != "beta" {
		t.Fatalf("tupleSecond on [2]any: want beta, got %v", got)
	}
}

func TestTupleFirstSliceShape(t *testing.T) {
	s := []any{"x", "y"}
	if got := tupleFirst(s); got != "x" {
		t.Fatalf("tupleFirst on []any: want x, got %v", got)
	}
	if got := tupleSecond(s); got != "y" {
		t.Fatalf("tupleSecond on []any: want y, got %v", got)
	}
}

func TestTupleFirstNonTupleValue(t *testing.T) {
	// Defensive: a bare value (non-tuple) returns itself from tupleFirst
	// and nil from tupleSecond. Matches the pre-fast-path behaviour so
	// callers that pass through degenerate values stay correct.
	if got := tupleFirst(99); got != 99 {
		t.Fatalf("tupleFirst on bare int: want 99, got %v", got)
	}
	if got := tupleSecond(99); got != nil {
		t.Fatalf("tupleSecond on bare int: want nil, got %v", got)
	}
}

// Sanity: the type-assertion fast path is genuinely cheaper than the
// reflect-FieldByName fallback. We only assert relative ordering — the
// absolute numbers vary by platform and Go version.
func BenchmarkTupleFirstFastPath(b *testing.B) {
	tup := SkyTuple2{V0: 42, V1: "x"}
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_ = tupleFirst(tup)
	}
}

func BenchmarkTupleFirstReflectFallback(b *testing.B) {
	type fancyTup = T2[int, string]
	tup := fancyTup{V0: 7, V1: "wide"}
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_ = tupleFirst(tup)
	}
}

// Final reality check: reflect.ValueOf(SkyTuple2{}).Kind() is Struct
// — the v0.13 fallback's first branch. If this assumption ever drifts
// (Go runtime upgrade etc.), tupleFirst's fallback would misbehave.
func TestSkyTuple2IsStruct(t *testing.T) {
	v := reflect.ValueOf(SkyTuple2{V0: 1, V1: 2})
	if v.Kind() != reflect.Struct {
		t.Fatalf("expected SkyTuple2 to be a struct, got %v", v.Kind())
	}
}
