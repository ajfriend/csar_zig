const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The one dependency: qmath (first-party), transcendental routing
    // for src/. Rationale, codegen equivalence, pin-bump: dev.md
    // "Packaging".
    const qmath_mod = b.dependency("qmath", .{
        .target = target,
        .optimize = optimize,
    }).module("qmath");

    const csar_mod = b.addModule("csar", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    csar_mod.addImport("qmath", qmath_mod);

    // The fixture corpus (cases/zon/*.zon) + its comptime manifest, which sits
    // beside the .zon files so it can `@import` them without crossing
    // module-path boundaries. Exported for path dependents (bench/); not in
    // `.paths`, so not available to tarball consumers (dev.md "Packaging").
    const cases_mod = b.addModule("cases", .{
        .root_source_file = b.path("cases/cases.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .name = "csar",
        .root_module = csar_mod,
        .linkage = .static,
    });
    b.installArtifact(lib);

    // Two-tier test target. The `slow` build option (`-Dslow=true`)
    // toggles whether the long-running randomized stress tests are
    // included. `just test` builds without it (fast subset, sub-
    // second); `just test-slow` builds with it (full suite + coverage
    // gate). Slow tests check `test_options.slow` and skip themselves
    // when it's false.
    const slow = b.option(bool, "slow", "Include slow randomized stress tests in the test binary") orelse false;
    // `-Dcoverage=true` builds for the kcov gate: it forces the LLVM
    // backend (kcov reads only its DWARF) for every executable; Debug
    // comes from the default optimize mode, which the gate leaves alone
    // (line coverage of an optimized binary is unreliable). Normal
    // builds are untouched. See dev.md "Coverage".
    const coverage = b.option(bool, "coverage", "Build for the coverage gate (Debug everywhere)") orelse false;
    const test_options = b.addOptions();
    test_options.addOption(bool, "slow", slow);

    // Test runner roots at `test_root.zig` at the repo root, so the
    // test module's filesystem-import scope covers BOTH `src/` (for
    // the library under test, reached via `@import("../src/foo.zig")`
    // from test files) AND `tests/` (the test files themselves).
    // This lets tests reach internals like `acceptBUpdate` directly,
    // without re-exporting them through the public API.
    const test_mod = b.createModule(.{
        .root_source_file = b.path("test_root.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addImport("cases", cases_mod);
    test_mod.addImport("qmath", qmath_mod);
    test_mod.addOptions("test_options", test_options);
    // Backend selection for the test binary. Default LLVM because the
    // kcov coverage gate reads only LLVM-emitted DWARF; `-Dllvm=false`
    // selects the self-hosted backend. Policy and per-target support:
    // dev.md "Two backends".
    const use_llvm = b.option(bool, "llvm", "Use the LLVM backend for the test binary (default true; kcov requires it)") orelse true;
    const tests = b.addTest(.{ .name = "csar-test", .root_module = test_mod, .use_llvm = use_llvm });
    const run_tests = b.addRunArtifact(tests);
    run_tests.setCwd(b.path(""));
    const test_step = b.step("test", "Run csar tests");
    test_step.dependOn(&run_tests.step);

    // `zig build install-coverage -Dcoverage=true -Dslow=true`: the test
    // binary plus every example, installed for scripts/coverage_gate.py
    // to run under kcov (which must be the process runner — hence
    // installed, not `zig build test`). bench/build.zig installs csar-ab.
    const install_coverage_step = b.step("install-coverage", "Install the test binary and every example for the coverage gate");
    install_coverage_step.dependOn(&b.addInstallArtifact(tests, .{}).step);

    // `zig build check`: compile every executable (library, examples,
    // survey execs) WITHOUT running anything — `just check` and its CI
    // job. Run steps only compile their exe when invoked, so
    // without this, toolchain churn in examples/scripts is invisible
    // to CI.
    const check_step = b.step("check", "Compile the library and every executable without running");
    check_step.dependOn(&lib.step);

    // Examples. Single-file runnable programs. Step name matches the
    // example's filename (examples/<stem>.zig → `zig build ex-<stem>`).
    // `ex-cases` accepts pass-through args after `--`: `zig build
    // ex-cases -- hex` or `-- --all`.
    const ex = .{ .b = b, .check = check_step, .install = install_coverage_step, .csar = csar_mod, .cases = cases_mod, .target = target, .optimize = optimize, .coverage = coverage };
    addExample(ex, "basic", "Run examples/basic.zig (happy-path only)");
    addExample(ex, "status", "Run examples/status.zig (every Outcome variant)");
    addExample(ex, "cases", "Run examples/cases.zig (run a named case or --all)");

    // US-states aspect-ratio example (see scripts/states/). Standalone
    // exec, not an example: lives under scripts/, force-built ReleaseFast,
    // and uses CWD-relative paths so it must be launched from the repo root.
    const states_aspect_mod = b.createModule(.{
        .root_source_file = b.path("scripts/states/states.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    states_aspect_mod.addImport("csar", csar_mod);
    const states_aspect_exe = b.addExecutable(.{
        .name = "csar-states-aspect",
        .root_module = states_aspect_mod,
    });
    const run_states_aspect = b.addRunArtifact(states_aspect_exe);
    run_states_aspect.setCwd(b.path(""));
    const states_aspect_step = b.step("states-aspect", "Run scripts/states/states.zig over data/states.json");
    states_aspect_step.dependOn(&run_states_aspect.step);
    check_step.dependOn(&states_aspect_exe.step);

    // Top-100-countries aspect-ratio example (see scripts/countries/). Same
    // standalone-exec pattern as the states example above.
    const countries_aspect_mod = b.createModule(.{
        .root_source_file = b.path("scripts/countries/countries.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    countries_aspect_mod.addImport("csar", csar_mod);
    const countries_aspect_exe = b.addExecutable(.{
        .name = "csar-countries-aspect",
        .root_module = countries_aspect_mod,
    });
    const run_countries_aspect = b.addRunArtifact(countries_aspect_exe);
    run_countries_aspect.setCwd(b.path(""));
    const countries_aspect_step = b.step("countries-aspect", "Run scripts/countries/countries.zig over data/countries.json");
    countries_aspect_step.dependOn(&run_countries_aspect.step);
    check_step.dependOn(&countries_aspect_exe.step);

    // The floor survey (floor_survey.zig, at the repo root so its module
    // spans src/ — the header explains): the oracle over the batches at
    // tight tolerances. Coverage-gated (installed + RUNS slices), so it
    // takes the standard optimize mode; pass -Doptimize=ReleaseFast for
    // the full measurement. Args after `--` per the header.
    const floor_mod = b.createModule(.{
        .root_source_file = b.path("floor_survey.zig"),
        .target = target,
        .optimize = optimize,
    });
    floor_mod.addImport("cases", cases_mod);
    floor_mod.addImport("qmath", qmath_mod);
    const floor_exe = b.addExecutable(.{
        .name = "csar-floor-survey",
        .root_module = floor_mod,
        // kcov reads only LLVM DWARF (dev.md "Two backends").
        .use_llvm = if (coverage) true else null,
    });
    const run_floor = b.addRunArtifact(floor_exe);
    run_floor.setCwd(b.path(""));
    if (b.args) |args| run_floor.addArgs(args);
    const floor_step = b.step("floor-survey", "Run floor_survey.zig (oracle over the batches at tight gap_tol)");
    floor_step.dependOn(&run_floor.step);
    check_step.dependOn(&floor_exe.step);
    install_coverage_step.dependOn(&b.addInstallArtifact(floor_exe, .{}).step);
}

fn addExample(
    ex: anytype,
    stem: []const u8,
    description: []const u8,
) void {
    const b: *std.Build = ex.b;
    const mod = b.createModule(.{
        .root_source_file = b.path(b.fmt("examples/{s}.zig", .{stem})),
        .target = ex.target,
        .optimize = ex.optimize,
    });
    mod.addImport("csar", ex.csar);
    mod.addImport("cases", ex.cases);
    const exe = b.addExecutable(.{
        .name = b.fmt("csar-ex-{s}", .{stem}),
        .root_module = mod,
        // kcov reads only LLVM DWARF (dev.md "Two backends").
        .use_llvm = if (ex.coverage) true else null,
    });
    const run = b.addRunArtifact(exe);
    // Pass through any args after `--` on the `zig build` command.
    // Only `ex-cases` uses them today; the others ignore the arg slice.
    if (b.args) |args| run.addArgs(args);
    const step = b.step(b.fmt("ex-{s}", .{stem}), description);
    step.dependOn(&run.step);
    ex.check.dependOn(&exe.step);
    ex.install.dependOn(&b.addInstallArtifact(exe, .{}).step);
}
