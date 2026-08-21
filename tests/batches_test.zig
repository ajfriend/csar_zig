//! The batch fixtures' pins: for every batch in `cases.batches`, tally the
//! cells under the corpus pin (`bc.Side(csar)`, the reduction `csar-ab`
//! prints) and check `errored == 0` and `converged >= converged_at_least`.
//! One-sided by design — see `cases/batches.zig`. A failure prints the
//! batch's full tally, which is how a pin is measured on each backend.

const std = @import("std");
const csar = @import("../src/root.zig");
const cases = @import("cases");
const helpers = @import("helpers.zig");
const bc = @import("../bench/core.zig");

fn checkBatch(name: []const u8, tally: bc.Tally, pin: u32) !void {
    if (tally.errored != 0 or tally.converged < pin) {
        helpers.diagPrint("batch {s}: {f}; pinned converged >= {d}\n", .{ name, tally, pin });
        return error.BatchPinViolated;
    }
}

test "batches: no errors, converged count at or above the pin" {
    const side: bc.Side(csar) = .{ .gpa = std.testing.allocator, .io = std.testing.io };
    for (cases.batches.all) |entry| {
        var tally = bc.Tally{};
        for (entry.batch.cells) |cell| tally.add(side.metrics(cell));
        try checkBatch(entry.name, tally, entry.batch.converged_at_least);
    }
}

test "checkBatch: both failure arms" {
    helpers.quiet_diagnostics = true;
    defer helpers.quiet_diagnostics = false;
    try std.testing.expectError(error.BatchPinViolated, checkBatch("x", .{ .converged = 3 }, 4));
    try std.testing.expectError(error.BatchPinViolated, checkBatch("x", .{ .converged = 4, .errored = 1 }, 4));
    try checkBatch("x", .{ .converged = 4 }, 4);
}
