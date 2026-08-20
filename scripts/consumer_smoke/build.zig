//! A consumer of the published package, as small as one can be: depends on
//! `csar` and calls `solve`. `just consumer-smoke` copies this directory to a
//! scratch location, `zig fetch`es the working tree into it — which packs the
//! tree through `build.zig.zon`'s `.paths`, exactly as a release tarball is —
//! and builds. It is the only check that exercises what a consumer receives
//! rather than the working tree (#17 automates the tag-time version).
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const csar = b.dependency("csar", .{ .target = target, .optimize = optimize });
    const mod = b.createModule(.{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("csar", csar.module("csar"));
    const exe = b.addExecutable(.{ .name = "consumer", .root_module = mod });
    b.step("run", "Solve one cell through the fetched package").dependOn(&b.addRunArtifact(exe).step);
}
