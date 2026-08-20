//! Root for the test target. Lives at the repo root so the test
//! module's filesystem-import scope covers both `src/` (for the
//! library under test) and `tests/` (for the test files
//! themselves). Nothing else lives here.

const std = @import("std");

test {
    _ = @import("tests/all.zig");
    // Force every pub declaration of the library through analysis, so a
    // dead one lands in the coverage line table and fails the gate rather
    // than being silently skipped by lazy analysis (dev.md "Coverage").
    comptime refAllDeclsRecursive(@import("src/root.zig"));
}

/// `std.testing.refAllDecls`, recursing into the types it finds (std's
/// own is one level deep, which references a type without analysing the
/// declarations inside it).
fn refAllDeclsRecursive(comptime T: type) void {
    inline for (comptime std.meta.declarations(T)) |decl| {
        const D = @field(T, decl.name);
        if (@TypeOf(D) == type) {
            switch (@typeInfo(D)) {
                .@"struct", .@"enum", .@"union", .@"opaque" => refAllDeclsRecursive(D),
                else => {},
            }
        }
        _ = &D;
    }
}
