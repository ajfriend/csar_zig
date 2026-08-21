//! `just lint`: zlinter's `no_unused` over every zig directory in the tree —
//! the check coverage cannot make, since zig never compiles an unreferenced
//! declaration (dev.md "Coverage").
//!
//! Its own package, like `bench/`, rather than a step in the root build.zig:
//! zlinter's builder walks its include directories at configure time, which a
//! consumer's copy of the package cannot satisfy (dev.md "Packaging").
const std = @import("std");
const zlinter = @import("zlinter");

pub fn build(b: *std.Build) void {
    const lint_step = b.step("lint", "Every declaration is referenced (zlinter no_unused)");
    lint_step.dependOn(step: {
        // Debug, not zlinter's ReleaseSafe default: the lint itself takes
        // milliseconds, and a ReleaseSafe compile of zlinter plus its zls
        // dependency dominates a cold build.
        var builder = zlinter.builder(b, .{ .optimize = .Debug });
        // Relative to THIS build root: zlinter resolves include paths
        // against it and runs with it as cwd. (A path it cannot open is a
        // warning, not an error — the `lint` recipe checks for it.)
        builder.addPaths(.{ .include = &.{
            b.path("../src"),
            b.path("../tests"),
            b.path("../cases"),
            b.path("../examples"),
            b.path("../bench"),
            b.path("."),
        } });
        builder.addRule(.{ .builtin = .no_unused }, .{ .container_declaration = .@"error" });
        break :step builder.build();
    });
}
