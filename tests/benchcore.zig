//! Benchmarking methodology, extracted so it can be tested and covered.
//!
//! This module is the *policy* half of the A/B harness: how many solves go in
//! a timed interval, how samples reduce to a statistic, what counts as a
//! difference, and how a row is rendered. It deliberately knows nothing about
//! the solver, the clock, or the two library versions — everything here takes
//! plain numbers, which is what makes it testable without timing flakiness.
//!
//! The *mechanics* half — importing two library versions, reading the clock,
//! shimming an API difference — lives in `bench/ab.zig`, which is as thin as
//! this split allows.
//!
//! The reasoning behind each policy (why min, why batching, why pairing, and
//! what the design does not cover) is documented in `bench/ab.zig`'s header.
//! Read that before changing a constant here.

const std = @import("std");

/// Timed intervals are grown to at least this long, so clock granularity stops
/// being a factor. ~2400x the 42ns clock seen on aarch64-macos.
pub const BATCH_TARGET_US: f64 = 100.0;

/// Untimed solves before each side's timed reps — warm caches and settle the
/// allocator. Per-iteration only; the per-process effect is handled by the
/// harness being one binary at all.
pub const N_WARMUP: u32 = 5;

/// Timed reps per side per case. A floor for the min to settle against, not a
/// sample size for a statistic — nothing here computes a confidence interval.
pub const N_REPS: usize = 100;

/// Upper bound on solves per interval, so a pathologically fast case (or a
/// bogus probe) cannot spin for an unbounded time.
pub const BATCH_MAX: u32 = 4096;

/// One side's result for one case. `iters`, `ar` and `gap` are only meaningful
/// for the outcomes that carry them; `status` disambiguates, and also carries
/// an error name when `solve` failed (see ab.zig — an error on one side only
/// is a difference worth reporting, not a reason to abort).
pub const Metrics = struct {
    status: []const u8,
    iters: u32 = 0,
    ar: f64 = 0,
    gap: f64 = 0,
};

/// The deterministic-diff predicate: the tool's contract, consumed by #5, #6
/// and #9 as "an empty deterministic diff".
///
/// AR is compared **exactly**, not within a tolerance. The commit gate already
/// checks AR within 1e-6 (`tests/cases/cases_test.zig`); comparing exactly
/// here is what makes the A/B cover the gap that leaves — a change that shifts
/// a result in the 12th digit is invisible to the suite and visible here.
///
/// `gap` is deliberately NOT compared: it is a certified bound rather than a
/// value the solver aims at, so it moves with iterate order without meaning a
/// behavioural change. It is reported for context.
pub fn differs(a: Metrics, b: Metrics) bool {
    if (!std.mem.eql(u8, a.status, b.status)) return true;
    if (a.iters != b.iters) return true;
    if (a.ar != b.ar) return true;
    return false;
}

/// True when a status names a solver outcome rather than an error.
pub fn isOutcome(status: []const u8) bool {
    return std.mem.eql(u8, status, "converged") or
        std.mem.eql(u8, status, "infeasible") or
        std.mem.eql(u8, status, "did_not_converge");
}

/// Solves per timed interval: enough that the interval dwarfs the clock, one
/// when the case is already slow enough. Calibrated from a probe measurement,
/// so it adapts to the machine rather than encoding one.
pub fn batchFor(probe_us: f64) u32 {
    // A non-positive or non-finite probe means the case timed below the
    // clock's resolution, or the probe failed. Either way the interval needs
    // to be as long as we allow, not as short.
    if (!std.math.isFinite(probe_us) or probe_us <= 0) return BATCH_MAX;
    const n = @ceil(BATCH_TARGET_US / probe_us);
    if (n <= 1) return 1;
    if (n >= @as(f64, BATCH_MAX)) return BATCH_MAX;
    return @intFromFloat(n);
}

/// Per-solve time from an interval covering `divisor` solves.
///
/// `divisor` is the un-injected batch size: under the 2x injector the interval
/// holds twice the solves but is still divided by this, so the reported
/// per-solve time doubles. That is the injector's whole mechanism.
pub fn perSolve(total_us: f64, divisor: u32) f64 {
    std.debug.assert(divisor > 0);
    return total_us / @as(f64, @floatFromInt(divisor));
}

fn ascending(_: void, a: f64, b: f64) bool {
    return a < b;
}

/// The statistic: the minimum. Sorts `samples` in place.
pub fn minOf(samples: []f64) f64 {
    std.debug.assert(samples.len > 0);
    std.mem.sort(f64, samples, {}, ascending);
    return samples[0];
}

/// A timing comparison for one case.
pub const Timing = struct {
    cur_us: f64,
    base_us: f64,
    batch: u32,

    pub fn ratio(self: Timing) f64 {
        return self.cur_us / self.base_us;
    }
};

/// Signature of a callback that runs `count` solves and returns the elapsed
/// microseconds. `ab.zig` supplies one bound to each library version; tests
/// supply a scripted fake.
pub const MeasureFn = *const fn (ctx: *anyopaque, count: u32) f64;

/// The paired measurement: interleave both sides rep by rep, reduce each to
/// its min, and pair them into a ratio.
///
/// Both sides use the SAME batch size, so the comparison stays like-for-like;
/// `cur_mult` is the injector, multiplying only how many solves the current
/// side performs inside its interval, never the divisor.
///
/// `scratch_cur` and `scratch_base` must each hold at least `reps` samples;
/// they are caller-provided so this stays allocation-free.
pub fn pairedRun(
    measure_cur: MeasureFn,
    ctx_cur: *anyopaque,
    measure_base: MeasureFn,
    ctx_base: *anyopaque,
    batch: u32,
    cur_mult: u32,
    reps: usize,
    scratch_cur: []f64,
    scratch_base: []f64,
) Timing {
    std.debug.assert(reps > 0);
    std.debug.assert(scratch_cur.len >= reps and scratch_base.len >= reps);
    for (0..reps) |r| {
        // Interleaved within the rep: both sides see the same thermal and
        // scheduler state. Order is fixed (current first); `--aa` is what
        // would expose a bias from that.
        scratch_cur[r] = perSolve(measure_cur(ctx_cur, batch * cur_mult), batch);
        scratch_base[r] = perSolve(measure_base(ctx_base, batch), batch);
    }
    return .{
        .cur_us = minOf(scratch_cur[0..reps]),
        .base_us = minOf(scratch_base[0..reps]),
        .batch = batch,
    };
}

/// Column header for `formatTiming`. Built from the same widths as the rows,
/// so the two cannot drift apart.
pub const timing_header = std.fmt.comptimePrint(
    timing_fmt,
    .{ "case", "cur", "base", "ratio", "batch" },
);

/// Left-aligned names, right-aligned numbers — explicit, because zig's default
/// string alignment is right and a column of right-aligned names reads badly.
const timing_fmt = "  {s:<20} {s:>10} {s:>10} {s:>8} {s:>7}";

/// One timing row. Rendered here rather than at the call site so the output
/// shape is a testable string rather than something checked by eye.
pub fn formatTiming(buf: []u8, name: []const u8, t: Timing) ![]const u8 {
    return std.fmt.bufPrint(buf, "  {s:<20} {d:>10.3} {d:>10.3} {d:>8.3} {d:>7}", .{
        name, t.cur_us, t.base_us, t.ratio(), t.batch,
    });
}

/// One deterministic-diff row, printed only for cases that differ.
pub fn formatDiff(buf: []u8, name: []const u8, a: Metrics, b: Metrics) ![]const u8 {
    return std.fmt.bufPrint(buf, "  {s:<24}  cur={s}/{d}/{d:.17}  base={s}/{d}/{d:.17}", .{
        name, a.status, a.iters, a.ar, b.status, b.iters, b.ar,
    });
}
