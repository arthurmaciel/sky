package rt

// Regression test for adaptFuncValue's uncurried-to-curried path.
//
// Issue: 06-json's `Result.map3 Profile r1 r2 r3` panicked at runtime
// with `panic: reflect.Value.Call: call of nil function` because the
// Sky-side type sees `Profile : String -> Int -> Bool -> Profile_R`
// (curried), so the kernel emits a spec param `fn func(string)
// func(int) func(bool) any`.  But the auto-generated record ctor
// Profile is emitted as `func(string, int, bool) Profile_R` (Go's
// uncurried form).
//
// Coercing Profile to the curried target shape via
// `rt.Coerce[func(string) func(int) func(bool) any](Profile)` went
// through `adaptFuncValue`, which zero-padded the missing args at
// each curry step and called the 3-arg Profile too early — producing
// a Profile_R record where the spec was expecting a func, leading to
// the nil-function panic.
//
// Fix: `adaptFuncValueWithCapture` detects "fewer args than skyFn
// wants AND target's return is another func" and accumulates args
// across curry levels, only invoking skyFn once all args have been
// captured.

import "testing"

func TestAdaptFuncValue_UncurriedToCurried(t *testing.T) {
	// Source: 3-arg uncurried Go function (auto-generated ctor shape).
	uncurried := func(name string, age int, active bool) string {
		s := name + ":" + intToStr(age)
		if active {
			s += ":active"
		}
		return s
	}
	// Target: Sky-side curried view `string -> int -> bool -> string`.
	type CurriedFn = func(string) func(int) func(bool) string
	curried := Coerce[CurriedFn](uncurried)

	got := curried("alice")(30)(true)
	want := "alice:30:active"
	if got != want {
		t.Fatalf("uncurried→curried adapter: got %q, want %q", got, want)
	}

	got2 := curried("bob")(0)(false)
	want2 := "bob:0"
	if got2 != want2 {
		t.Fatalf("uncurried→curried adapter (no active): got %q, want %q",
			got2, want2)
	}
}

// Same shape but the target uses `any` returns, matching what the
// monomorphised spec actually emits (T_N → any defaulting on output
// positions the inference couldn't pin).
func TestAdaptFuncValue_UncurriedToCurriedAnyReturn(t *testing.T) {
	uncurried := func(name string, age int, active bool) any {
		return map[string]any{"name": name, "age": age, "active": active}
	}
	type CurriedFn = func(string) func(int) func(bool) any
	curried := Coerce[CurriedFn](uncurried)

	r := curried("eve")(42)(true)
	m, ok := r.(map[string]any)
	if !ok {
		t.Fatalf("expected map[string]any, got %T", r)
	}
	if m["name"] != "eve" || m["age"] != 42 || m["active"] != true {
		t.Fatalf("uncurried→curried any-return adapter: got %#v", m)
	}
}

// 2-arg uncurried → 2-level curried — the smallest case, still
// exercises the cross-level capture.
func TestAdaptFuncValue_TwoArgUncurriedToCurried(t *testing.T) {
	uncurried := func(s string, n int) string {
		return s + intToStr(n)
	}
	type CurriedFn = func(string) func(int) string
	curried := Coerce[CurriedFn](uncurried)

	got := curried("x")(5)
	want := "x5"
	if got != want {
		t.Fatalf("2-arg uncurried→curried adapter: got %q, want %q", got, want)
	}
}
