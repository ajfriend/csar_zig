const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    // Forced, not `standardOptimizeOption`: as its own package this would
    // default to Debug, and the ROOT module's optimize mode governs codegen
    // for the whole compilation — so a Debug root would silently benchmark a
    // Debug solver on both sides. `build.zig` forces this for ex-bench too.
    const optimize: std.builtin.OptimizeMode = .ReleaseFast;

    const cur = b.dependency("csar_cur", .{ .target = target, .optimize = optimize });

    const mod = b.createModule(.{
        .root_source_file = b.path("ab.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("cur", cur.module("csar"));
    // Fixtures always come from the CURRENT tree, never the baseline's — both
    // sides ship their own `tests/`, and drawing them from different sides
    // would silently compare two different point sets.
    mod.addImport("cases", cur.module("cases"));

    // The baseline is lazy: `check` builds without it, `ab` needs it.
    if (b.lazyDependency("csar_base", .{ .target = target, .optimize = optimize })) |base| {
        mod.addImport("base", base.module("csar"));

        const exe = b.addExecutable(.{ .name = "csar-ab", .root_module = mod });
        const run = b.addRunArtifact(exe);
        if (b.args) |args| run.addArgs(args);
        b.step("ab", "A/B the working tree against the pinned baseline").dependOn(&run.step);
    }

    // Compile-only, so the root `just check` keeps this package from rotting
    // the way examples/ did before #12. Uses a stub for the baseline import so
    // it needs no fetch.
    const check_mod = b.createModule(.{
        .root_source_file = b.path("ab.zig"),
        .target = target,
        .optimize = optimize,
    });
    check_mod.addImport("cur", cur.module("csar"));
    check_mod.addImport("cases", cur.module("cases"));
    check_mod.addImport("base", cur.module("csar"));
    const check_exe = b.addExecutable(.{ .name = "csar-ab-check", .root_module = check_mod });
    b.step("check", "Compile the harness without running or fetching the baseline")
        .dependOn(&check_exe.step);
}
