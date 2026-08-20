//! The smallest consumer of the published package: depends on `csar` and
//! compiles `examples/basic.zig` against it — the documented minimal example,
//! which the package itself no longer ships. Driven by `run.sh`; see dev.md
//! "Packaging".
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
