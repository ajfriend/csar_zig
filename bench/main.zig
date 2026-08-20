//! The harness binary's root. The harness is `ab.zig`, imported rather than
//! built directly: kcov on Linux cannot see a zig module's root file (DWARF5
//! file index 0), so the root holds nothing worth measuring. See dev.md
//! "Coverage".
pub const main = @import("ab.zig").main;
