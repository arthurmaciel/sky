// Sky Runtime — module that gets copied into generated projects
// Builder.hs emits `mod sky_runtime; use sky_runtime::*;` instead
// of duplicating these definitions inline.

pub mod core;
pub use core::*;
