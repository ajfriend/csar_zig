//! Direct tests for the floor-survey driver's classification
//! (floor_survey.zig). The driver's own RUNS slices cover its corpus
//! paths; this covers the one path the corpus can never produce: an
//! infeasible outcome must fail the run loudly (the batches contract
//! makes it impossible, so reaching it means the run's population is
//! corrupt).

const std = @import("std");
const csar = @import("../src/root.zig");
const survey = @import("../floor_survey.zig");
const helpers = @import("helpers.zig");

test "cellRow: an infeasible outcome is a loud failure, never a row" {
    const allocator = std.testing.allocator;
    const pts = helpers.casePoints("infeas_antipodal");
    var outcome = try csar.solve(allocator, pts, .{});
    defer outcome.deinit();
    try std.testing.expect(std.meta.activeTag(outcome) == .infeasible);
    try std.testing.expectError(error.InfeasibleBatchCell, survey.cellRow(allocator, pts, &outcome));
}
