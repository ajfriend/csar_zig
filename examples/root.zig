//! The entry point every example binary is built from. Each example's code
//! lives in its own file beside this one; this file only selects which one,
//! by the `example` build option `build.zig` sets per `ex-*` step.
//!
//! Why the examples are not their own root files: kcov on Linux cannot see a
//! zig module's root file (DWARF5 puts it at file index 0, which kcov's ELF
//! reader drops), so anything worth measuring must be an import. This root
//! holds nothing worth measuring. See dev.md "Coverage".
pub const main = switch (@import("build_options").example) {
    .basic => @import("basic.zig").main,
    .status => @import("status.zig").main,
    .cases => @import("cases.zig").main,
    .bench => @import("bench.zig").main,
};
