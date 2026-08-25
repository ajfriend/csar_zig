const std = @import("std");

/// The pin, read from the manifest rather than copied into a second
/// constant, so the report header cannot name a baseline other than the one
/// the binary measures. The hash carries the version ("csar-X.Y.Z-...").
const BASELINE_HASH = @import("build.zig.zon").dependencies.csar_base.hash;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    // Forced, not `standardOptimizeOption`: as its own package this would
    // default to Debug, and the ROOT module's optimize mode governs codegen
    // for the whole compilation — so a Debug root would silently benchmark a
    // Debug solver on both sides.
    // `-Dcoverage=true` builds Debug, with LLVM, for the kcov gate (dev.md "Coverage").
    const coverage = b.option(bool, "coverage", "Build for the coverage gate (Debug)") orelse false;
    const optimize: std.builtin.OptimizeMode = if (coverage) .Debug else .ReleaseFast;

    const cur = b.dependency("csar_cur", .{ .target = target, .optimize = optimize });

    const options = b.addOptions();
    options.addOption([]const u8, "baseline", BASELINE_HASH);
    // The gate's binary covers one batch at one rep (ab.zig, `BATCHES`).
    options.addOption(bool, "coverage", coverage);

    // Resolved eagerly, so every step here fetches the baseline the first time
    // on a machine: 172 KB, then cached in zig's global cache.
    //
    // A lazy pin would skip it for `check`, but the invariant that would buy —
    // "`just ci` never touches the network" — was never true anyway: a first
    // run already fetches zig, kcov and uv's interpreter. What matters is no
    // fetch on *every* run, and the cache gives that. Laziness also makes a
    // missing baseline surface as "no step named 'ab'" rather than as a fetch.
    const base = b.dependency("csar_base", .{ .target = target, .optimize = optimize });

    const mod = b.createModule(.{
        .root_source_file = b.path("ab.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("cur", cur.module("csar"));
    mod.addImport("base", base.module("csar"));
    // Fixtures always come from the CURRENT tree, never the baseline's — both
    // sides ship their own `tests/`, and drawing them from different sides
    // would silently compare two different point sets.
    mod.addImport("cases", cur.module("cases"));
    mod.addOptions("build_options", options);

    // kcov reads only LLVM DWARF (dev.md "Two backends").
    const exe = b.addExecutable(.{ .name = "csar-ab", .root_module = mod, .use_llvm = if (coverage) true else null });
    // `zig build --build-file bench/build.zig install` → bench/zig-out/bin/csar-ab,
    // which the coverage gate runs under kcov.
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("ab", "A/B the working tree against the pinned baseline").dependOn(&run.step);

    // Compile-only, so the root `just check` keeps this package from rotting
    // the way examples/ once did — breaking silently until built. The
    // real binary, against the real baseline: if the pinned API drifts
    // from what `Side` expects, this is where it shows.
    b.step("check", "Compile the harness without running it").dependOn(&exe.step);
}
