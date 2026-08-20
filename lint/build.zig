//! `just lint`: zlinter's `no_unused` over every zig directory in the tree —
//! the check coverage cannot make, since zig never compiles an unreferenced
//! declaration (dev.md "Coverage").
//!
//! Its own package, like `bench/`, rather than a step in the root build.zig:
//! zlinter's builder walks its include directories at configure time, and a
//! consumer's copy of the package has no `tests/` to walk — and a lazy
//! dependency that `build()` always asks for is fetched by every consumer
//! anyway. `just consumer-smoke` caught both.
const std = @import("std");
const zlinter = @import("zlinter");

pub fn build(b: *std.Build) void {
    const lint_step = b.step("lint", "Every declaration is referenced (zlinter no_unused)");
    lint_step.dependOn(step: {
        var builder = zlinter.builder(b, .{});
        // Relative to THIS build root: zlinter resolves include paths
        // against it and runs with it as cwd. A path it cannot open is a
        // warning and an empty lint, not an error — so `just lint` checks
        // the output for that warning.
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
