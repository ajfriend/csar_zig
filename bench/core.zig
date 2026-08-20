//! Benchmarking policy: how many solves go in a timed interval, how samples
//! reduce to a statistic, and what counts as a difference.
//!
//! Knows nothing about the solver, the clock, or the two library versions —
//! everything here takes plain numbers, which is what lets `tests/` verify it
//! without timing flakiness. The mechanics that read a clock and call a solver
//! live in `ab.zig`, alongside the parts of the methodology that are properties
//! of *one binary and one clock* rather than of these constants.

const std = @import("std");

// ---------------------------------------------------------------------------
// Warm-up
//
// Untimed solves before each side's timed reps, so those reps see warm caches
// and a settled allocator. This is per-*iteration* warm-up only; the
// per-*process* effect is handled by the harness being a single binary at all
// (see ab.zig, "No process isolation").
// ---------------------------------------------------------------------------

pub const N_WARMUP: u32 = 5;

// ---------------------------------------------------------------------------
// Reps
//
// A floor for the min to settle against, not a sample size: nothing here
// computes a variance, a confidence interval, or a significance test. The
// report is read by a human against the `--aa` floor.
// ---------------------------------------------------------------------------

pub const N_REPS: usize = 100;

// ---------------------------------------------------------------------------
// Batching
//
// A solve near the clock's resolution cannot be timed individually: `hex` at
// ~0.8us against a 42ns clock is ~19 quanta, so ~5% granularity on exactly the
// hot-path cell CLAUDE.md says to protect. Each timed interval therefore spans
// however many solves it takes to reach BATCH_TARGET_US, calibrated per case
// from a probe so it adapts to the machine rather than encoding one.
//
// This is about quantization, not bias: the cost of the two clock reads is
// common-mode across an A/B pair and cancels in the ratio regardless.
// ---------------------------------------------------------------------------

/// ~2400x the 42ns clock seen on aarch64-macos.
pub const BATCH_TARGET_US: f64 = 100.0;

/// Upper bound, so a pathologically fast case cannot spin unboundedly. Also
/// where a useless probe lands — see `batchFor`.
pub const BATCH_MAX: u32 = 4096;

/// Solves per timed interval: enough that the interval dwarfs the clock, one
/// when the case is already slow enough.
pub fn batchFor(probe_us: f64) u32 {
    // A non-positive or non-finite probe means the case timed below the
    // clock's resolution, or the probe failed. Either way the interval wants
    // to be as long as we allow, not as short. (Not reachable on any clock
    // seen so far; the branch is a guard at an API boundary.)
    if (!std.math.isFinite(probe_us) or probe_us <= 0) return BATCH_MAX;
    const n = @ceil(BATCH_TARGET_US / probe_us);
    if (n <= 1) return 1;
    if (n >= @as(f64, BATCH_MAX)) return BATCH_MAX;
    return @intFromFloat(n);
}

// ---------------------------------------------------------------------------
// The statistic: the minimum
//
// Timing noise is one-sided contamination — interrupts, migrations and
// contention can only add time, never remove it — so the minimum is a robust
// estimator of the uncontaminated cost, while the mean and median estimate
// something else: the machine's typical state during this particular run.
//
// That holds only while the contamination is sparse and memoryless. A process
// that is *always* present (a busy machine, a thermal cap) contaminates the
// minimum too, and the min will report the contaminated cost without flagging
// it. `--aa` is the check that the assumption held.
//
// With batching this is min-of-batch-means: jitter is averaged within a batch
// rather than rejected by the min, which is the price of measuring a sub-us
// case at all.
// ---------------------------------------------------------------------------

/// A timing comparison for one case.
pub const Timing = struct {
    cur_us: f64,
    base_us: f64,
    batch: u32,

    pub fn ratio(self: Timing) f64 {
        return self.cur_us / self.base_us;
    }
};

// ---------------------------------------------------------------------------
// Pairing
//
// Both sides are measured inside the same rep, making each rep a matched pair
// drawn under the same thermal state, scheduler pressure and CPU frequency —
// not two independent samples taken minutes apart. Pairing is what licenses
// reporting a *ratio*: the shared conditions divide out of it, which is why
// the ratio travels between machines when the absolute microseconds do not.
// ---------------------------------------------------------------------------

/// Interleave both sides rep by rep, reduce each to its min, and pair them.
///
/// `cur` and `base` are anything exposing `fn measure(self: *Self, count: u32)
/// f64` — one library version each in `ab.zig`, a scripted fake in the tests.
///
/// Both sides use the SAME batch, so the comparison stays like-for-like.
/// `cur_mult` is the injector: it multiplies how many solves the current side
/// performs inside its interval, but never the divisor, so the reported
/// per-solve time scales by exactly that factor. That is the whole mechanism
/// behind `--inject-2x`.
///
/// Scratch buffers are caller-provided, so this allocates nothing; their
/// length is the rep count.
pub fn pairedRun(
    cur: anytype,
    base: anytype,
    batch: u32,
    cur_mult: u32,
    scratch_cur: []f64,
    scratch_base: []f64,
) Timing {
    std.debug.assert(scratch_cur.len > 0);
    std.debug.assert(scratch_cur.len == scratch_base.len);
    const divisor: f64 = @floatFromInt(batch);
    for (0..scratch_cur.len) |r| {
        // Order within a rep is fixed (current, then baseline) rather than
        // alternating. `--aa` is what would expose a bias from that, and it
        // reports 1.000 on every case today.
        scratch_cur[r] = cur.measure(batch * cur_mult) / divisor;
        scratch_base[r] = base.measure(batch) / divisor;
    }
    return .{
        .cur_us = std.mem.min(f64, scratch_cur),
        .base_us = std.mem.min(f64, scratch_base),
        .batch = batch,
    };
}

// ---------------------------------------------------------------------------
// Comparison and rendering
// ---------------------------------------------------------------------------

/// One side's result for one case. `status` carries an `@errorName` when
/// `solve` failed, which is why it is a string rather than the outcome enum:
/// an error on one side only is a difference worth reporting, not a reason to
/// abort (see `ab.zig`).
pub const Metrics = struct {
    status: []const u8,
    iters: u32 = 0,
    ar: f64 = 0,
    gap: f64 = 0,
};

/// Running count of outcomes on one side.
///
/// Aggregate, not per-case: a report that says 27 cases differ makes you read
/// 27 rows to learn which *direction* things moved. This says it in one line.
///
/// Deliberately a whole-corpus tally rather than a per-family convergence
/// rate. That metric is #19's, and it is blocked on the corpus rather than on
/// code: the `dggs` fixtures are five families of four cells, so a "percentage"
/// there can only be 0/25/50/75/100.
pub const Tally = struct {
    converged: u32 = 0,
    infeasible: u32 = 0,
    did_not_converge: u32 = 0,
    errored: u32 = 0,

    pub fn add(self: *Tally, m: Metrics) void {
        if (std.mem.eql(u8, m.status, "converged")) {
            self.converged += 1;
        } else if (std.mem.eql(u8, m.status, "infeasible")) {
            self.infeasible += 1;
        } else if (std.mem.eql(u8, m.status, "did_not_converge")) {
            self.did_not_converge += 1;
        } else {
            self.errored += 1;
        }
    }

    pub fn format(self: Tally, buf: []u8) ![]const u8 {
        return std.fmt.bufPrint(
            buf,
            "{d} converged / {d} DNC / {d} infeasible / {d} errored",
            .{ self.converged, self.did_not_converge, self.infeasible, self.errored },
        );
    }
};

/// The deterministic-diff predicate: the tool's contract, consumed by #5, #6
/// and #9 as "an empty deterministic diff".
///
/// AR is compared **exactly**, not within a tolerance. The commit gate already
/// checks AR within 1e-6 (`tests/cases/cases_test.zig`); comparing exactly here
/// is what makes the A/B cover the gap that leaves — a change that shifts a
/// result in the 12th digit is invisible to the suite and visible here.
///
/// `gap` is deliberately NOT compared: it is a certified bound rather than a
/// value the solver aims at, so it moves with iterate order without meaning a
/// behavioural change. It is printed on rows that differ for other reasons.
pub fn differs(a: Metrics, b: Metrics) bool {
    if (!std.mem.eql(u8, a.status, b.status)) return true;
    if (a.iters != b.iters) return true;
    if (a.ar != b.ar) return true;
    return false;
}

pub fn isOutcome(status: []const u8) bool {
    return std.mem.eql(u8, status, "converged") or
        std.mem.eql(u8, status, "infeasible") or
        std.mem.eql(u8, status, "did_not_converge");
}

/// Column widths, defined once: both format strings below are generated from
/// them, so the header and the rows cannot disagree.
const w_name = 20;
const w_time = 10;
const w_ratio = 8;
const w_batch = 7;

/// Left-aligned names, right-aligned numbers — explicit, because zig's default
/// string alignment is right and a column of right-aligned names reads badly.
const header_fmt = std.fmt.comptimePrint(
    "  {{s:<{d}}} {{s:>{d}}} {{s:>{d}}} {{s:>{d}}} {{s:>{d}}}",
    .{ w_name, w_time, w_time, w_ratio, w_batch },
);
const row_fmt = std.fmt.comptimePrint(
    "  {{s:<{d}}} {{d:>{d}.3}} {{d:>{d}.3}} {{d:>{d}.3}} {{d:>{d}}}",
    .{ w_name, w_time, w_time, w_ratio, w_batch },
);

pub const timing_header = std.fmt.comptimePrint(
    header_fmt,
    .{ "case", "cur", "base", "ratio", "batch" },
);

/// One timing row. Rendered here rather than at the call site so the output
/// shape is a testable string rather than something checked by eye.
pub fn formatTiming(buf: []u8, name: []const u8, t: Timing) ![]const u8 {
    return std.fmt.bufPrint(buf, row_fmt, .{ name, t.cur_us, t.base_us, t.ratio(), t.batch });
}

/// One deterministic-diff row, printed only for cases that differ. `gap` rides
/// along as context: it never triggers a row (see `differs`), but when one
/// fires — a case flipping to did_not_converge, say — how far the certificate
/// moved is the first thing worth seeing.
pub fn formatDiff(buf: []u8, name: []const u8, a: Metrics, b: Metrics) ![]const u8 {
    return std.fmt.bufPrint(
        buf,
        "  {s:<22} cur={s}/{d}/{d:.17}/{e:.2}  base={s}/{d}/{d:.17}/{e:.2}",
        .{ name, a.status, a.iters, a.ar, a.gap, b.status, b.iters, b.ar, b.gap },
    );
}
