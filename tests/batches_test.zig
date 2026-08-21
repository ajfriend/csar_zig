//! The batch contract: every cell of every batch in `cases.batches`
//! converges at the corpus pin — the precondition for the batches' real
//! job, timing (#37): a non-converging cell would time `max_outer`, not
//! the solver. Tallied through `bc.Side(csar)`, the reduction `csar-ab`
//! prints, so a failure prints the whole tally and names the batch. A
//! cell that stops converging is a regression signal (CLAUDE.md), not a
//! number to bump; see `cases/batches.zig`.

const std = @import("std");
const csar = @import("../src/root.zig");
const cases = @import("cases");
const helpers = @import("helpers.zig");
const bc = @import("../bench/core.zig");

fn checkBatch(name: []const u8, tally: bc.Tally, n_cells: usize) !void {
    if (tally.converged != n_cells) {
        helpers.diagPrint("batch {s}: {f}; expected all {d} converged\n", .{ name, tally, n_cells });
        return error.BatchCellDidNotConverge;
    }
}

test "batches: every cell converges" {
    const side: bc.Side(csar) = .{ .gpa = std.testing.allocator, .io = std.testing.io };
    for (cases.batches.all) |entry| {
        var tally = bc.Tally{};
        for (entry.batch.cells) |cell| tally.add(side.metrics(cell));
        try checkBatch(entry.name, tally, entry.batch.cells.len);
    }
}

test "checkBatch: the failure arm" {
    helpers.quiet_diagnostics = true;
    defer helpers.quiet_diagnostics = false;
    try std.testing.expectError(error.BatchCellDidNotConverge, checkBatch("x", .{ .converged = 3, .did_not_converge = 1 }, 4));
    try checkBatch("x", .{ .converged = 4 }, 4);
}
