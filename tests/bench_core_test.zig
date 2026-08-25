//! Tests for `bench/core.zig`. The policy tests drive it with plain numbers,
//! so they are clock-free; the `Side(csar)` section at the bottom runs the
//! adapter against the real library and clock, and only the A/A test (slow
//! tier) asserts anything about timing.

const std = @import("std");
const csar = @import("../src/root.zig");
const cases = @import("cases");
const helpers = @import("helpers.zig");
const test_options = @import("test_options");
const bc = @import("../bench/core.zig");

test "OutcomeTag is the library's Outcome vocabulary, name for name" {
    // core.zig stays solver-free, so it transcribes the tag names; this is
    // what keeps the transcription honest. A rename or new variant fails here
    // rather than being tallied as `errored` and dropped from timing.
    const lib = std.meta.fieldNames(std.meta.Tag(csar.Outcome));
    const ours = std.meta.fieldNames(bc.OutcomeTag);
    try std.testing.expectEqual(lib.len, ours.len);
    for (lib, ours) |a, b| try std.testing.expectEqualStrings(a, b);
}

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

test "differs: a NaN AR does not make a case differ from itself" {
    // `nan != nan`, so a naive comparison would flag identical rows as
    // differing — and would do it under --aa, breaking the harness check.
    const nan_ar: bc.Metrics = .{ .status = "did_not_converge", .iters = 9, .ar = std.math.nan(f64) };
    try std.testing.expect(!bc.differs(nan_ar, nan_ar));

    var other = nan_ar;
    other.ar = 1.0;
    try std.testing.expect(bc.differs(nan_ar, other));
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
    try std.testing.expect(bc.isOutcome("precision_floor"));
    try std.testing.expect(!bc.isOutcome("SingularMoment"));
}

test "passesFor: a slow unit is timed one pass at a time" {
    try std.testing.expectEqual(@as(u32, 1), bc.passesFor(bc.INTERVAL_TARGET_US));
    try std.testing.expectEqual(@as(u32, 1), bc.passesFor(bc.INTERVAL_TARGET_US * 10));
}

test "passesFor: a fast unit gets enough passes to reach the target" {
    // 100us target / 2us per pass = 50.
    try std.testing.expectEqual(@as(u32, 50), bc.passesFor(2.0));
    // Rounds up rather than down, so the interval always reaches the target.
    try std.testing.expectEqual(@as(u32, 34), bc.passesFor(3.0));
}

test "passesFor: clamped, and a useless probe asks for the longest interval" {
    try std.testing.expectEqual(bc.PASSES_MAX, bc.passesFor(1e-9));
    // Below clock resolution, or a failed probe: as many passes as allowed
    // rather than trusting a number that means nothing.
    try std.testing.expectEqual(bc.PASSES_MAX, bc.passesFor(0));
    try std.testing.expectEqual(bc.PASSES_MAX, bc.passesFor(-1));
    try std.testing.expectEqual(bc.PASSES_MAX, bc.passesFor(std.math.nan(f64)));
    try std.testing.expectEqual(bc.PASSES_MAX, bc.passesFor(std.math.inf(f64)));
}

test "calibrate: the passes come from the min of the probes" {
    // A contaminated first probe must not shrink the count for the whole
    // unit: that is why there are N_PROBE of them and the min is taken.
    var spiked: Fake = .{ .per_pass_us = 2.0, .spike_at = 1 };
    try std.testing.expectEqual(bc.passesFor(2.0), bc.calibrate(&spiked));
    try std.testing.expectEqual(bc.N_PROBE, spiked.calls);
}

test "Tally counts each outcome, and anything unrecognised as an error" {
    var t: bc.Tally = .{};
    t.add(.{ .status = "converged", .gap = 3e-8 });
    t.add(.{ .status = "converged", .gap = -1e-9 });
    t.add(.{ .status = "infeasible" });
    t.add(.{ .status = "did_not_converge", .gap = -5.0 }); // not converged: does not count
    t.add(.{ .status = "precision_floor", .gap = -2e-7 }); // nor this
    // An @errorName from a failed solve — the reason `status` is a string.
    t.add(.{ .status = "SingularMoment" });

    // min gap is over converged entries only, and keeps its sign.
    try std.testing.expectFmt("2 converged / 1 DNC / 1 floor / 1 infeasible / 1 errored / min gap -1.00e-9", "{f}", .{t});
}

test "Tally: min gap is inf when nothing converged" {
    var t: bc.Tally = .{};
    t.add(.{ .status = "infeasible" });
    try std.testing.expectFmt("0 converged / 0 DNC / 0 floor / 1 infeasible / 0 errored / min gap inf", "{f}", .{t});
}

test "GapShift: identical sides count as a row and do not move" {
    // What --aa sees on every row.
    var s: bc.GapShift = .{};
    s.add(0, converged, converged);
    try std.testing.expectFmt("max |Δgap| 0.00e0 over 1 rows", "{f}", .{s});
    try std.testing.expectEqual(@as(?usize, null), s.idx);
}

test "GapShift: the max is over rows the diff does not flag" {
    var s: bc.GapShift = .{};

    // Counted: same status/iters/AR, gaps 2e-9 apart.
    var moved = converged;
    moved.gap = 3e-9;
    s.add(7, converged, moved);

    // Not counted: flagged by `differs` (iters moved) — its gap belongs to
    // that row, however large.
    var flagged = converged;
    flagged.iters = 4;
    flagged.gap = 1.0;
    s.add(8, converged, flagged);

    // Not counted: not converged on both sides.
    var dnc = converged;
    dnc.status = "did_not_converge";
    dnc.gap = 1.0;
    s.add(9, converged, dnc);

    try std.testing.expectFmt("max |Δgap| 2.00e-9 over 1 rows", "{f}", .{s});
    // The row is reported by index; the caller owns the names.
    try std.testing.expectEqual(@as(?usize, 7), s.idx);
}

/// A scripted stand-in for "run `count` solves and report the elapsed µs".
/// Exact arithmetic, so the loop's own maths is assertable to the ulp.
const Fake = struct {
    per_pass_us: f64,
    calls: u32 = 0,
    last_count: u32 = 0,
    /// Rep index at which to return a contaminated sample; 0 = never.
    spike_at: u32 = 0,

    pub fn measure(self: *Fake, count: u32) f64 {
        self.calls += 1;
        self.last_count = count;
        const elapsed = self.per_pass_us * @as(f64, @floatFromInt(count));
        return if (self.calls == self.spike_at) elapsed * 50 else elapsed;
    }
};

fn run(a: *Fake, b: *Fake, passes: u32, cur_mult: u32) bc.Timing {
    var sc: [4]f64 = undefined;
    var sb: [4]f64 = undefined;
    return bc.pairedRun(a, b, passes, 1, cur_mult, &sc, &sb);
}

test "pairedRun: identical sides report 1.0 exactly" {
    var a: Fake = .{ .per_pass_us = 3.0 };
    var b: Fake = .{ .per_pass_us = 3.0 };
    const t = run(&a, &b, 10, 1);
    try std.testing.expectEqual(@as(f64, 1.0), t.ratio());
    try std.testing.expectEqual(@as(f64, 3.0), t.cur_us);
    // Passed through, not derived: the report prints it, and nothing else
    // would catch it picking up `cur_mult` on the way.
    try std.testing.expectEqual(@as(u32, 10), t.solves);
}

test "pairedRun: a multi-cell unit reports per solve, not per pass" {
    // A pass over a 1000-cell unit taking 4000us is 4us per solve.
    var a: Fake = .{ .per_pass_us = 4000.0 };
    var b: Fake = .{ .per_pass_us = 4000.0 };
    var sc: [4]f64 = undefined;
    var sb: [4]f64 = undefined;
    const t = bc.pairedRun(&a, &b, 1, 1000, 1, &sc, &sb);
    try std.testing.expectEqual(@as(f64, 4.0), t.cur_us);
    try std.testing.expectEqual(@as(u32, 1000), t.solves);
    try std.testing.expectEqual(@as(u32, 1), a.last_count);
}

test "pairedRun: passes divide out, so per-solve time is pass-independent" {
    var a: Fake = .{ .per_pass_us = 0.25 };
    var b: Fake = .{ .per_pass_us = 0.25 };
    const big = run(&a, &b, 400, 1);
    try std.testing.expectEqual(@as(u32, 400), a.last_count);
    const small = run(&a, &b, 1, 1);
    try std.testing.expectEqual(small.cur_us, big.cur_us);
}

test "pairedRun: the 2x injector multiplies solves but not the divisor" {
    // The positive control that keeps "no difference" from being vacuous: a
    // tool hardcoded to report 1.0 fails here.
    var a: Fake = .{ .per_pass_us = 1.0 };
    var b: Fake = .{ .per_pass_us = 1.0 };
    const t = run(&a, &b, 7, 2);
    try std.testing.expectEqual(@as(f64, 2.0), t.ratio());
    // 14 solves inside the interval, still divided by 7.
    try std.testing.expectEqual(@as(u32, 14), a.last_count);
    try std.testing.expectEqual(@as(u32, 7), b.last_count);
}

test "pairedRun: both sides are measured once per rep, interleaved" {
    var a: Fake = .{ .per_pass_us = 1.0 };
    var b: Fake = .{ .per_pass_us = 1.0 };
    _ = run(&a, &b, 1, 1);
    try std.testing.expectEqual(@as(u32, 4), a.calls);
    try std.testing.expectEqual(@as(u32, 4), b.calls);
}

test "pairedRun reduces with the min, so a slow rep cannot inflate the result" {
    // One contaminated rep among clean ones must not move the number: that is
    // the whole reason the statistic is a min.
    var a: Fake = .{ .per_pass_us = 2.0, .spike_at = 2 };
    var b: Fake = .{ .per_pass_us = 2.0 };
    const t = run(&a, &b, 3, 1);
    try std.testing.expectEqual(@as(f64, 1.0), t.ratio());
}

test "writeTiming renders the documented column shape" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try bc.writeTiming(&w, "hex", .{ .cur_us = 0.836, .base_us = 0.834, .solves = 115 });
    const row = w.buffered();
    try std.testing.expectEqualStrings(
        "  hex                       0.836      0.834    1.002     115\n",
        row,
    );
    // Header and rows are generated from the same widths; this catches it if
    // that ever stops being true.
    try std.testing.expectEqual(bc.timing_header.len, row.len - 1);
}

test "writeSkipped puts the reason where the numbers would be" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try bc.writeSkipped(&w, "a5_r23", "32 cells did not converge");
    try std.testing.expectEqualStrings("  a5_r23               skipped: 32 cells did not converge\n", w.buffered());
}

test "writeDiff shows both sides at full precision, with gap for context" {
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const a: bc.Metrics = .{ .status = "did_not_converge", .iters = 34, .ar = 1.05467581817604850, .gap = 3.2e-7 };
    const b: bc.Metrics = .{ .status = "converged", .iters = 0, .ar = 1.05467581817586240, .gap = 1.1e-9 };
    try bc.writeDiff(&w, "h3_r12_midLat", a, b);
    try std.testing.expectEqualStrings(
        "  h3_r12_midLat            cur=did_not_converge/34/1.05467581817604850/3.20e-7  base=converged/0/1.05467581817586240/1.10e-9\n",
        w.buffered(),
    );
}

test "writeDiff survives an aspect ratio that expands to hundreds of digits" {
    // `{d:.17}` is fixed-point, so floatMax renders 309 integer digits — twice.
    // No fixed row buffer sits between the formatter and the writer, so this is
    // an ordinary long line rather than a cliff that aborts the whole report.
    var buf: [2048]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const huge: bc.Metrics = .{ .status = "did_not_converge", .iters = 1, .ar = std.math.floatMax(f64) };
    try bc.writeDiff(&w, "pathological", huge, huge);
    try std.testing.expect(w.buffered().len > 650);
}

// ---------------------------------------------------------------------------
// Side(csar): the adapter, against the real library and real fixtures.
// ---------------------------------------------------------------------------

const Real = bc.Side(csar);

fn side(cells: []const []const [3]f64) Real {
    return .{ .gpa = std.testing.allocator, .io = std.testing.io, .cells = cells };
}

test "Side.tally reduces a unit's cells to the counts the report prints" {
    const t = side(&.{}).tally(&.{ helpers.casePoints("hex"), helpers.casePoints("np100"), helpers.casePoints("infeas_antipodal") });
    try std.testing.expectEqual(@as(u32, 2), t.converged);
    try std.testing.expectEqual(@as(u32, 1), t.infeasible);
    try std.testing.expectEqual(@as(u32, 0), t.errored);
}

test "Side.metrics: a converged outcome carries iters, AR and gap" {
    // np100 rather than hex: hex settles in the opening phase with zero
    // outer iterations, so it cannot show that iters is carried through.
    const m = side(&.{}).metrics(helpers.casePoints("np100"));
    try std.testing.expectEqualStrings("converged", m.status);
    try std.testing.expect(m.iters > 0);
    try std.testing.expect(m.gap <= bc.GAP_TOL);
    // Same answer the suite gates on, at the suite's tolerance.
    const expected = (cases.byName("np100") orelse unreachable).expected.converged.ar;
    try std.testing.expectApproxEqAbs(expected, m.ar, 1e-6);
}

test "Side.metrics: infeasible is a status and nothing else" {
    const m = side(&.{}).metrics(helpers.casePoints("infeas_antipodal"));
    try std.testing.expectEqualStrings("infeasible", m.status);
    try std.testing.expectEqual(@as(u32, 0), m.iters);
}

test "Side.metrics: did_not_converge still reports the iterate's AR" {
    // A tolerance below the f64 gap floor for this case (what --inject-tol
    // runs at), so the solver honestly gives up.
    var s = side(&.{});
    s.gap_tol = 1e-13;
    const m = s.metrics(helpers.casePoints("dnc_small_wide"));
    try std.testing.expectEqualStrings("did_not_converge", m.status);
    try std.testing.expect(m.iters > 0);
    try std.testing.expect(std.math.isFinite(m.ar) and m.ar > 1.0);
}

test "Side.metrics: a solve error becomes a status, not a crash" {
    // Invalid input rather than a #1/#2 repro, so this keeps reaching the
    // branch after #6 makes every valid input return an Outcome.
    const m = side(&.{}).metrics(&.{});
    try std.testing.expectEqualStrings("InsufficientPoints", m.status);
    try std.testing.expect(!bc.isOutcome(m.status));
}

test "the clock is sane: finite, non-negative, and monotone in the workload" {
    // `pairedRun` trusts `Io.Timestamp` blindly, and clock behaviour is the
    // one thing that varies per OS. The deterministic tests avoid clocks
    // entirely, so they cannot catch a platform where this fails.
    var s = side(&.{helpers.casePoints("hex")});
    bc.warmUp(&s);
    // The short interval is a min-of-5 so one pre-emption cannot inflate it
    // past the long one; the long one needs no such care — a spike there only
    // makes the assertion easier.
    var short = std.math.inf(f64);
    for (0..5) |_| short = @min(short, s.measure(1));
    const long = s.measure(20);
    try std.testing.expect(std.math.isFinite(short) and short >= 0);
    try std.testing.expect(long >= short);
}

test "A/A: the harness measures the same code against itself at ~1.0" {
    // Slow tier: it times real solves. It asserts a RATIO, so a loaded
    // runner, another arch, or kcov instrumenting every line slows both
    // sides alike and divides out. The failures A/A exists to catch are
    // systematic and large — a wrong divisor, batching off by one, an
    // interleave that favours a side, measuring the wrong side — and read as
    // 2x or 0.5x, so the bound is loose on purpose.
    //
    // Flake policy: if this ever fails on a healthy change, loosen the bound
    // or delete the test. Never wrap it in a retry.
    if (!test_options.slow) return error.SkipZigTest;
    var a = side(&.{helpers.casePoints("hex")});
    var b = side(&.{helpers.casePoints("hex")});
    bc.warmUp(&a);
    bc.warmUp(&b);
    const passes = bc.calibrate(&b);
    var sa: [20]f64 = undefined;
    var sb: [20]f64 = undefined;
    const t = bc.pairedRun(&a, &b, passes, 1, 1, &sa, &sb);
    try std.testing.expect(t.ratio() > 0.8 and t.ratio() < 1.25);
}
