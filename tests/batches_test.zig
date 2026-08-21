//! The batch contract (`cases/batches.zig`): every cell of every batch
//! converges. Tallied through `bc.Side(csar)`, the reduction `csar-ab`
//! prints, so a failure prints the whole tally and names the batch.
//! Slow tier: 8000 Debug solves (~4.5 s) guarding a gate property, not
//! something the inner loop iterates against.

const std = @import("std");
const csar = @import("../src/root.zig");
const cases = @import("cases");
const helpers = @import("helpers.zig");
const test_options = @import("test_options");
const bc = @import("../bench/core.zig");

fn checkBatch(name: []const u8, tally: bc.Tally, n_cells: usize) !void {
    if (tally.converged != n_cells) {
        helpers.diagPrint("batch {s}: {f}; expected all {d} converged\n", .{ name, tally, n_cells });
        return error.BatchCellDidNotConverge;
    }
}

test "batches: every cell converges" {
    if (!test_options.slow) return error.SkipZigTest;
    const side: bc.Side(csar) = .{ .gpa = std.testing.allocator, .io = std.testing.io };
    for (cases.batches.all) |entry| {
        try checkBatch(entry.name, side.tally(entry.batch.cells), entry.batch.cells.len);
    }
}

test "checkBatch: the failure arm" {
    helpers.quiet_diagnostics = true;
    defer helpers.quiet_diagnostics = false;
    try std.testing.expectError(error.BatchCellDidNotConverge, checkBatch("x", .{ .converged = 3, .did_not_converge = 1 }, 4));
    try checkBatch("x", .{ .converged = 4 }, 4);
}
