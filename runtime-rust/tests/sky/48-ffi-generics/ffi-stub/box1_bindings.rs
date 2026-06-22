// Wall #2 hand-stub: the box1 crate's FFI surface is ENTIRELY generic, so the
// non-generic bindings file is empty (every wrapper is build-synthesised into
// sky_ffi_generics.rs from the kernel.json `generic` blocks). The preamble
// mirrors a real inspector-emitted _bindings.rs so the module still compiles.
#![allow(unused_imports, unused_mut, dead_code)]
use crate::*;
use std::collections::HashMap;
