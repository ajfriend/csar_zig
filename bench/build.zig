const std = @import("std");

/// The baseline this harness measures against, for the report header. Keep in
/// sync with `csar_base`'s URL in build.zig.zon — they are two halves of one
/// decision, and a report that names the wrong baseline is worse than one that
/// names none.
const BASELINE_REF = "v0.2.0";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    // Forced, not `standardOptimizeOption`: as its own package this would
    // default to Debug, and the ROOT module's optimize mode governs codegen
    // for the whole compilation — so a Debug root would silently benchmark a
    // Debug solver on both sides. `build.zig` forces this for ex-bench too.
    const optimize: std.builtin.OptimizeMode = .ReleaseFast;

    const cur = b.dependency("csar_cur", .{ .target = target, .optimize = optimize });

    const options = b.addOptions();
    options.addOption([]const u8, "baseline", BASELINE_REF);

    // Resolved eagerly. A lazy pin plus a gate would keep `just check` off the
    // network, but that costs a manifest flag, a build option and a justfile
    // flag to save one 172 KB fetch that zig then caches forever — and it makes
    // a missing baseline surface as "no step named 'ab'" instead of a fetch.
    const base = b.dependency("csar_base", .{ .target = target, .optimize = optimize });
    const mod = abModule(b, target, optimize, cur, base.module("csar"), options);
    const exe = b.addExecutable(.{ .name = "csar-ab", .root_module = mod });
    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("ab", "A/B the working tree against the pinned baseline").dependOn(&run.step);

    // Compile-only, so the root `just check` keeps this package from rotting
    // the way examples/ did before #12.
    //
    // It stubs the baseline with the current library, so what it compiles is
    // the A/A shape: it cannot catch baseline-API drift, the one failure a
    // compile-only step most looks like it should catch. Absorbing such drift
    // is `Side`'s job (#23), and `just ab` is what proves it.
    const check_mod = abModule(b, target, optimize, cur, cur.module("csar"), options);
    const check_exe = b.addExecutable(.{ .name = "csar-ab-check", .root_module = check_mod });
    b.step("check", "Compile the harness without running or fetching the baseline")
        .dependOn(&check_exe.step);
}

/// Both executables are built from identical wiring, differing only in what
/// `base` resolves to — factored so a fifth import cannot land in one and not
/// the other.
fn abModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    cur: *std.Build.Dependency,
    base_csar: *std.Build.Module,
    options: *std.Build.Step.Options,
) *std.Build.Module {
    const mod = b.createModule(.{
        .root_source_file = b.path("ab.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("cur", cur.module("csar"));
    mod.addImport("base", base_csar);
    // Fixtures always come from the CURRENT tree, never the baseline's — both
    // sides ship their own `tests/`, and drawing them from different sides
    // would silently compare two different point sets.
    mod.addImport("cases", cur.module("cases"));
    mod.addOptions("build_options", options);
    return mod;
}
