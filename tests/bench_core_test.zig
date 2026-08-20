//! Tests for the benchmarking policy (`bench/core.zig`). Every input is a
//! plain number, so nothing here depends on a clock or on how busy the machine
//! is — which is the point of keeping the policy separate from the mechanics.

const std = @import("std");
const bc = @import("../bench/core.zig");

const converged: bc.Metrics = .{ .status = "converged", .iters = 3, .ar = 1.5, .gap = 1e-9 };

test "differs: identical metrics do not differ" {
    try std.testing.expect(!bc.differs(converged, converged));
}

test "differs: status, iteration count, and AR each trip it" {
    var other = converged;
    other.status = "did_not_converge";
    try std.testing.expect(bc.differs(converged, other));

    other = converged;
    other.iters = 4;
    try std.testing.expect(bc.differs(converged, other));

    // One ulp. The commit gate accepts AR drift below 1e-6, so the A/B has to
    // compare exactly or it cannot cover the gap the gate leaves.
    other = converged;
    other.ar = 1.5000000000000002;
    try std.testing.expect(bc.differs(converged, other));
}

test "differs: gap is reported but not compared" {
    // gap is a certified bound, not a target: it moves with iterate order
    // without indicating a behavioural change.
    var other = converged;
    other.gap = converged.gap * 100;
    try std.testing.expect(!bc.differs(converged, other));
}

test "isOutcome separates solver outcomes from error names" {
    try std.testing.expect(bc.isOutcome("converged"));
    try std.testing.expect(bc.isOutcome("infeasible"));
    try std.testing.expect(bc.isOutcome("did_not_converge"));
    try std.testing.expect(!bc.isOutcome("NegativeDualityGap"));
}

test "batchFor: a slow case is timed one solve at a time" {
    try std.testing.expectEqual(@as(u32, 1), bc.batchFor(bc.BATCH_TARGET_US));
    try std.testing.expectEqual(@as(u32, 1), bc.batchFor(bc.BATCH_TARGET_US * 10));
}

test "batchFor: a fast case is batched to the target" {
    // 100us target / 2us per solve = 50.
    try std.testing.expectEqual(@as(u32, 50), bc.batchFor(2.0));
    // Rounds up rather than down, so the interval always reaches the target.
    try std.testing.expectEqual(@as(u32, 34), bc.batchFor(3.0));
}

test "batchFor: clamped, and a useless probe asks for the longest interval" {
    try std.testing.expectEqual(bc.BATCH_MAX, bc.batchFor(1e-9));
    // Below clock resolution, or a failed probe: batch as hard as allowed
    // rather than trusting a number that means nothing.
    try std.testing.expectEqual(bc.BATCH_MAX, bc.batchFor(0));
    try std.testing.expectEqual(bc.BATCH_MAX, bc.batchFor(-1));
    try std.testing.expectEqual(bc.BATCH_MAX, bc.batchFor(std.math.nan(f64)));
    try std.testing.expectEqual(bc.BATCH_MAX, bc.batchFor(std.math.inf(f64)));
}

test "Tally counts each outcome, and anything unrecognised as an error" {
    var t: bc.Tally = .{};
    t.add(.{ .status = "converged" });
    t.add(.{ .status = "converged" });
    t.add(.{ .status = "infeasible" });
    t.add(.{ .status = "did_not_converge" });
    // An @errorName from a failed solve — the reason `status` is a string.
    t.add(.{ .status = "NegativeDualityGap" });

    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "2 converged / 1 DNC / 1 infeasible / 1 errored",
        try t.format(&buf),
    );
}

/// A scripted stand-in for "run `count` solves and report the elapsed µs".
/// Exact arithmetic, so the loop's own maths is assertable to the ulp.
const Fake = struct {
    per_solve_us: f64,
    calls: u32 = 0,
    last_count: u32 = 0,
    /// Rep index at which to return a contaminated sample; 0 = never.
    spike_at: u32 = 0,

    pub fn measure(self: *Fake, count: u32) f64 {
        self.calls += 1;
        self.last_count = count;
        const elapsed = self.per_solve_us * @as(f64, @floatFromInt(count));
        return if (self.calls == self.spike_at) elapsed * 50 else elapsed;
    }
};

fn run(a: *Fake, b: *Fake, batch: u32, cur_mult: u32) bc.Timing {
    var sc: [4]f64 = undefined;
    var sb: [4]f64 = undefined;
    return bc.pairedRun(a, b, batch, cur_mult, &sc, &sb);
}

test "pairedRun: identical sides report 1.0 exactly" {
    var a: Fake = .{ .per_solve_us = 3.0 };
    var b: Fake = .{ .per_solve_us = 3.0 };
    const t = run(&a, &b, 10, 1);
    try std.testing.expectEqual(@as(f64, 1.0), t.ratio());
    try std.testing.expectEqual(@as(f64, 3.0), t.cur_us);
    try std.testing.expectEqual(@as(u32, 10), t.batch);
}

test "pairedRun: batching divides out, so per-solve time is batch-independent" {
    var a: Fake = .{ .per_solve_us = 0.25 };
    var b: Fake = .{ .per_solve_us = 0.25 };
    const big = run(&a, &b, 400, 1);
    try std.testing.expectEqual(@as(u32, 400), a.last_count);
    const small = run(&a, &b, 1, 1);
    try std.testing.expectEqual(small.cur_us, big.cur_us);
}

test "pairedRun: the 2x injector multiplies solves but not the divisor" {
    // The positive control that keeps "no difference" from being vacuous: a
    // tool hardcoded to report 1.0 fails here.
    var a: Fake = .{ .per_solve_us = 1.0 };
    var b: Fake = .{ .per_solve_us = 1.0 };
    const t = run(&a, &b, 7, 2);
    try std.testing.expectEqual(@as(f64, 2.0), t.ratio());
    // 14 solves inside the interval, still divided by 7.
    try std.testing.expectEqual(@as(u32, 14), a.last_count);
    try std.testing.expectEqual(@as(u32, 7), b.last_count);
}

test "pairedRun: both sides are measured once per rep, interleaved" {
    var a: Fake = .{ .per_solve_us = 1.0 };
    var b: Fake = .{ .per_solve_us = 1.0 };
    _ = run(&a, &b, 1, 1);
    try std.testing.expectEqual(@as(u32, 4), a.calls);
    try std.testing.expectEqual(@as(u32, 4), b.calls);
}

test "pairedRun reduces with the min, so a slow rep cannot inflate the result" {
    // One contaminated rep among clean ones must not move the number: that is
    // the whole reason the statistic is a min.
    var a: Fake = .{ .per_solve_us = 2.0, .spike_at = 2 };
    var b: Fake = .{ .per_solve_us = 2.0 };
    const t = run(&a, &b, 3, 1);
    try std.testing.expectEqual(@as(f64, 1.0), t.ratio());
}

test "formatTiming renders the documented column shape" {
    var buf: [256]u8 = undefined;
    const row = try bc.formatTiming(&buf, "hex", .{ .cur_us = 0.836, .base_us = 0.834, .batch = 115 });
    try std.testing.expectEqualStrings(
        "  hex                       0.836      0.834    1.002     115",
        row,
    );
    // Header and rows are generated from the same widths; this catches it if
    // that ever stops being true.
    try std.testing.expectEqual(bc.timing_header.len, row.len);
}

test "formatDiff shows both sides at full precision, with gap for context" {
    var buf: [256]u8 = undefined;
    const a: bc.Metrics = .{ .status = "did_not_converge", .iters = 34, .ar = 1.05467581817604850, .gap = 3.2e-7 };
    const b: bc.Metrics = .{ .status = "converged", .iters = 0, .ar = 1.05467581817586240, .gap = 1.1e-9 };
    const row = try bc.formatDiff(&buf, "h3_r12_midLat", a, b);
    try std.testing.expectEqualStrings(
        "  h3_r12_midLat          cur=did_not_converge/34/1.05467581817604850/3.20e-7  base=converged/0/1.05467581817586240/1.10e-9",
        row,
    );
}
