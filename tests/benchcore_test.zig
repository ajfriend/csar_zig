//! Tests for the benchmarking methodology (`benchcore.zig`).
//!
//! These are deterministic: every input is a plain number, so nothing here
//! depends on a clock, a machine, or how busy the runner is. That is the point
//! of the split — the policy that decides whether a regression exists is
//! verified without timing flakiness, while the mechanics that read the clock
//! stay in `bench/ab.zig`.

const std = @import("std");
const bc = @import("benchcore.zig");

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

    other = converged;
    other.ar = 1.5000000000000002; // one ulp
    try std.testing.expect(bc.differs(converged, other));
}

test "differs: AR is compared exactly, not within the suite's 1e-6" {
    // The commit gate accepts AR drift below 1e-6; the A/B must not, or it
    // cannot cover the gap the gate leaves.
    var nudged = converged;
    nudged.ar = converged.ar + 1e-9;
    try std.testing.expect(bc.differs(converged, nudged));
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
    // Below clock resolution or a failed probe: batch as hard as allowed
    // rather than trusting a number that means nothing.
    try std.testing.expectEqual(bc.BATCH_MAX, bc.batchFor(0));
    try std.testing.expectEqual(bc.BATCH_MAX, bc.batchFor(-1));
    try std.testing.expectEqual(bc.BATCH_MAX, bc.batchFor(std.math.nan(f64)));
    try std.testing.expectEqual(bc.BATCH_MAX, bc.batchFor(std.math.inf(f64)));
}

test "perSolve divides the interval by the batch" {
    try std.testing.expectEqual(@as(f64, 4.0), bc.perSolve(100.0, 25));
    try std.testing.expectEqual(@as(f64, 100.0), bc.perSolve(100.0, 1));
}

test "minOf returns the minimum" {
    var samples = [_]f64{ 5.0, 2.0, 9.0, 2.5 };
    try std.testing.expectEqual(@as(f64, 2.0), bc.minOf(&samples));
}

test "Timing.ratio" {
    const t: bc.Timing = .{ .cur_us = 2.0, .base_us = 1.0, .batch = 1 };
    try std.testing.expectEqual(@as(f64, 2.0), t.ratio());
}

/// A scripted stand-in for "run `count` solves and report the elapsed µs".
/// Exact arithmetic, so the loop's own maths is assertable to the ulp.
const Fake = struct {
    per_solve_us: f64,
    calls: u32 = 0,
    last_count: u32 = 0,

    fn measure(ctx: *anyopaque, count: u32) f64 {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        self.last_count = count;
        return self.per_solve_us * @as(f64, @floatFromInt(count));
    }
};

test "pairedRun: identical sides report 1.0 exactly" {
    var a: Fake = .{ .per_solve_us = 3.0 };
    var b: Fake = .{ .per_solve_us = 3.0 };
    var sc: [8]f64 = undefined;
    var sb: [8]f64 = undefined;
    const t = bc.pairedRun(Fake.measure, &a, Fake.measure, &b, 10, 1, 8, &sc, &sb);
    try std.testing.expectEqual(@as(f64, 1.0), t.ratio());
    try std.testing.expectEqual(@as(f64, 3.0), t.cur_us);
    try std.testing.expectEqual(@as(u32, 10), t.batch);
}

test "pairedRun: batching divides out, so per-solve time is batch-independent" {
    var a: Fake = .{ .per_solve_us = 0.25 };
    var b: Fake = .{ .per_solve_us = 0.25 };
    var sc: [4]f64 = undefined;
    var sb: [4]f64 = undefined;
    const big = bc.pairedRun(Fake.measure, &a, Fake.measure, &b, 400, 1, 4, &sc, &sb);
    try std.testing.expectEqual(@as(u32, 400), a.last_count);
    const small = bc.pairedRun(Fake.measure, &a, Fake.measure, &b, 1, 1, 4, &sc, &sb);
    try std.testing.expectEqual(small.cur_us, big.cur_us);
}

test "pairedRun: the 2x injector multiplies solves but not the divisor" {
    // This is the positive control that keeps "no difference" from being
    // vacuous: a tool hardcoded to report 1.0 fails here.
    var a: Fake = .{ .per_solve_us = 1.0 };
    var b: Fake = .{ .per_solve_us = 1.0 };
    var sc: [4]f64 = undefined;
    var sb: [4]f64 = undefined;
    const t = bc.pairedRun(Fake.measure, &a, Fake.measure, &b, 7, 2, 4, &sc, &sb);
    try std.testing.expectEqual(@as(f64, 2.0), t.ratio());
    // 14 solves inside the interval, still divided by 7.
    try std.testing.expectEqual(@as(u32, 14), a.last_count);
    try std.testing.expectEqual(@as(u32, 7), b.last_count);
}

test "pairedRun: both sides are measured once per rep, interleaved" {
    var a: Fake = .{ .per_solve_us = 1.0 };
    var b: Fake = .{ .per_solve_us = 1.0 };
    var sc: [5]f64 = undefined;
    var sb: [5]f64 = undefined;
    _ = bc.pairedRun(Fake.measure, &a, Fake.measure, &b, 1, 1, 5, &sc, &sb);
    try std.testing.expectEqual(@as(u32, 5), a.calls);
    try std.testing.expectEqual(@as(u32, 5), b.calls);
}

test "pairedRun reduces with the min, so a slow rep cannot inflate the result" {
    // One contaminated rep among clean ones must not move the number: that is
    // the whole reason the statistic is a min.
    const Spiky = struct {
        n: u32 = 0,
        fn measure(ctx: *anyopaque, count: u32) f64 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.n += 1;
            const base: f64 = 2.0 * @as(f64, @floatFromInt(count));
            return if (self.n == 2) base * 50 else base;
        }
    };
    var a: Spiky = .{};
    var b: Fake = .{ .per_solve_us = 2.0 };
    var sc: [4]f64 = undefined;
    var sb: [4]f64 = undefined;
    const t = bc.pairedRun(Spiky.measure, &a, Fake.measure, &b, 3, 1, 4, &sc, &sb);
    try std.testing.expectEqual(@as(f64, 1.0), t.ratio());
}

test "formatTiming renders the documented column shape" {
    var buf: [256]u8 = undefined;
    const row = try bc.formatTiming(&buf, "hex", .{ .cur_us = 0.836, .base_us = 0.834, .batch = 115 });
    try std.testing.expectEqualStrings(
        "  hex                       0.836      0.834    1.002     115",
        row,
    );
    // The header must line the columns up with the rows beneath it.
    try std.testing.expectEqual(bc.timing_header.len, row.len);
}

test "formatDiff shows both sides at full precision" {
    var buf: [256]u8 = undefined;
    const a: bc.Metrics = .{ .status = "did_not_converge", .iters = 34, .ar = 1.05467581817604850 };
    const b: bc.Metrics = .{ .status = "converged", .iters = 0, .ar = 1.05467581817586240 };
    const row = try bc.formatDiff(&buf, "h3_r12_midLat", a, b);
    try std.testing.expectEqualStrings(
        "  h3_r12_midLat             cur=did_not_converge/34/1.05467581817604850  base=converged/0/1.05467581817586240",
        row,
    );
}
