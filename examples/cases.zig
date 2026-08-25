//! Run one or all bundled cases through the solver.
//!
//! Pass arguments after `--`:
//!   zig build ex-cases -- hex      # run a single named case
//!   zig build ex-cases -- --all    # iterate the whole manifest
//!   zig build ex-cases             # no args: print usage + known cases
//!
//! Demonstrates how to reach into the bundled `cases` module from
//! user code: `cases.byName(...)` for a single lookup, `cases.all`
//! to iterate the full manifest.

const std = @import("std");
const csar = @import("csar");
const cases = @import("cases");

pub fn main(init: std.process.Init) !void {
    // init.gpa: leak-checked DebugAllocator in Debug builds.
    const allocator = init.gpa;

    const argv = try init.minimal.args.toSlice(init.arena.allocator());

    if (argv.len != 2) {
        printUsage(argv[0]);
        return;
    }
    const arg = argv[1];
    if (std.mem.eql(u8, arg, "--all")) {
        try runAll(allocator);
    } else {
        try runOne(allocator, arg);
    }
}

fn printUsage(prog: []const u8) void {
    std.debug.print("usage: {s} <case-name> | --all\n", .{prog});
    std.debug.print("\nknown cases:\n", .{});
    for (cases.all) |entry| std.debug.print("  {s}\n", .{entry.name});
}

fn runOne(allocator: std.mem.Allocator, name: []const u8) !void {
    const case = cases.byName(name) orelse {
        std.debug.print("unknown case: {s}\n", .{name});
        std.debug.print("use --all to see what's available.\n", .{});
        return error.UnknownCase;
    };
    std.debug.print("{s}: {s} ({d} points)\n", .{ name, case.description, case.points.len });
    try report(allocator, name, case.points);
}

fn runAll(allocator: std.mem.Allocator) !void {
    for (cases.all) |entry| try report(allocator, entry.name, entry.case.points);
}

/// One line per case: the outcome tag and the one number that matters for it.
fn report(allocator: std.mem.Allocator, name: []const u8, points: []const [3]f64) !void {
    var outcome = try csar.solve(allocator, points, .{});
    defer outcome.deinit();
    switch (outcome) {
        .converged => |c| std.debug.print("{s:22}  converged  AR={d:.6}  gap={e:.3}  iters={d}\n", .{
            name, c.aspectRatio(), c.gap, c.diag.totalIters(),
        }),
        .infeasible => |i| std.debug.print("{s:22}  infeasible  residual={e:.3}  active={d}\n", .{
            name, i.residual, i.cert.indices.len,
        }),
        .did_not_converge, .precision_floor => |p| std.debug.print("{s:22}  {s}  gap={e:.3}  iters={d}\n", .{ name, @tagName(outcome), p.gap, p.diag.totalIters() }),
    }
}
