//! Benchmarking policy: how many solves go in a timed interval, how samples
//! reduce to a statistic, what counts as a difference — and `Side`, the
//! default adapter from a library version to the numbers the policy consumes.
//!
//! The policy functions take plain numbers and know nothing about the solver
//! or the clock, which is what lets `tests/` verify them to the ulp with a
//! scripted stand-in. `Side` is the one piece that reads a clock and calls a
//! solver; it is generic over the library, so the suite instantiates it
//! against the current one and covers every branch on real fixtures. The
//! parts of the methodology that are properties of one *binary* are in
//! `ab.zig`.

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
// This is about quantization, not bias — see "The instrument" below.
// ---------------------------------------------------------------------------

/// ~2400x the 42ns clock seen on aarch64-macos.
pub const BATCH_TARGET_US: f64 = 100.0;

/// Upper bound, so a pathologically fast case cannot spin unboundedly. Also
/// where a useless probe lands — see `batchFor`.
pub const BATCH_MAX: u32 = 4096;

/// Single-solve probes taken before choosing a batch; the min is used. One
/// probe would let a single contaminated read set the batch for every timed
/// interval of that case (seen: `ha_12` flipping 2 -> 2 -> 1 across launches).
/// The min of a few is the same statistic the reps use, for the same reason.
pub const N_PROBE: u32 = 3;

/// Choose the batch for `side`, which must already be warmed up so the probes
/// measure warm solves.
pub fn calibrate(side: anytype) u32 {
    var probes: [N_PROBE]f64 = undefined;
    for (&probes) |*p| p.* = side.measure(1);
    return batchFor(std.mem.min(f64, &probes));
}

/// Untimed solves before a side's timed reps — see "Warm-up" above.
pub fn warmUp(side: anytype) void {
    _ = side.measure(N_WARMUP);
}

/// Solves per timed interval: enough that the interval dwarfs the clock, one
/// when the case is already slow enough.
pub fn batchFor(probe_us: f64) u32 {
    // A non-positive or non-finite probe means the case timed below the
    // clock's resolution, or the probe failed. Either way the interval wants
    // to be as long as we allow, not as short. (Not reachable on any clock
    // seen so far; the branch is a guard at an API boundary.)
    if (!std.math.isFinite(probe_us) or probe_us <= 0) return BATCH_MAX;
    const n = @ceil(BATCH_TARGET_US / probe_us);
    return @intFromFloat(std.math.clamp(n, 1, @as(f64, BATCH_MAX)));
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
// Both sides are measured inside the same rep, so the two sample sets are
// drawn under the same thermal state, scheduler pressure and CPU frequency
// rather than minutes apart. That is what licenses reporting a *ratio*: the
// shared conditions are common to both sides and divide out, which is why the
// ratio travels between machines when the absolute microseconds do not.
//
// Note the reduction is min-of-cur over min-of-base, not a per-rep difference:
// interleaving equalises the conditions the samples come from, it does not
// pair them up arithmetically.
// ---------------------------------------------------------------------------

/// Interleave both sides rep by rep, reduce each to its min, and pair them.
///
/// `cur` and `base` are anything exposing `fn measure(self: *Self, count: u32)
/// f64` — a `Side` each in `ab.zig`, a scripted fake in the tests.
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
        // alternating. `--aa` is what would expose a bias from that — see
        // ab.zig, "The check", which owns that measurement and names the host
        // it was taken on.
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

/// The solver outcomes, as `Metrics.status` spells them. Declared once so
/// `isOutcome` and `Tally.add` cannot disagree about what counts as an error.
///
/// A transcription of the library's `Outcome` tag names, not the enum itself:
/// this module stays solver-free so the tests can drive it without one.
/// `tests/bench_core_test.zig` asserts the transcription matches the real
/// union's tags, and `Side.metrics` below builds every status with `@tagName`
/// over a switch that is exhaustive on that union — so the two vocabularies
/// cannot drift apart without a test or compile failure.
pub const OutcomeTag = enum { converged, infeasible, did_not_converge };

pub fn isOutcome(status: []const u8) bool {
    return std.meta.stringToEnum(OutcomeTag, status) != null;
}

/// One side's result for one case. `status` carries an `@errorName` when
/// `solve` failed, which is why it is a string rather than the outcome enum:
/// an error on one side only is a difference worth reporting, not a reason to
/// abort (see `Side.metrics`).
///
/// `ar` is not necessarily finite: an uncertified DNC iterate can divide two
/// singular values that are both zero. `differs` and `formatDiff` both handle
/// that; nothing else here reads it.
pub const Metrics = struct {
    status: []const u8,
    iters: u32 = 0,
    ar: f64 = 0,
    gap: f64 = 0,
};

/// Running count of outcomes on one side.
///
/// Aggregate, not per-case: a report that says N cases differ makes you read N
/// rows to learn which *direction* things moved. This says it in one line.
///
/// Whole-corpus, not per-family: a per-family convergence rate is #19's, and
/// the DGGS families here are four cells each — too few for a percentage to
/// mean anything.
pub const Tally = struct {
    converged: u32 = 0,
    did_not_converge: u32 = 0,
    infeasible: u32 = 0,
    errored: u32 = 0,

    pub fn add(self: *Tally, m: Metrics) void {
        // Anything `OutcomeTag` does not name is an @errorName from a failed
        // solve. A new solver outcome cannot land here silently: the test
        // that pins `OutcomeTag` to the real union fails first (see there).
        const tag = std.meta.stringToEnum(OutcomeTag, m.status) orelse {
            self.errored += 1;
            return;
        };
        switch (tag) {
            .converged => self.converged += 1,
            .infeasible => self.infeasible += 1,
            .did_not_converge => self.did_not_converge += 1,
        }
    }

    /// zig's `{f}` formatting hook.
    pub fn format(self: Tally, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d} converged / {d} DNC / {d} infeasible / {d} errored", .{
            self.converged, self.did_not_converge, self.infeasible, self.errored,
        });
    }
};

/// The deterministic-diff predicate: the tool's contract, consumed by #5, #6
/// and #9 as "an empty deterministic diff".
///
/// AR is compared **bit-for-bit**, not within a tolerance. The commit gate already
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
    // Bit comparison, not `!=`: exactness is the point (see above), but
    // `nan != nan` would flag a case as differing from itself — visibly
    // identical rows, and it would fire under `--aa`, breaking the one check
    // that validates the harness. An uncertified DNC iterate can produce a NaN
    // ratio. (Bitwise also separates +0 from -0, and one NaN payload from
    // another; neither is reachable for a ratio of singular values.)
    if (@as(u64, @bitCast(a.ar)) != @as(u64, @bitCast(b.ar))) return true;
    return false;
}

/// Column widths for the timing table, defined once: `timing_header` and
/// `formatTiming` are both generated from them, so those two cannot disagree.
/// (`formatDiff` below is a different shape and sets its own.)
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
///
/// Straight to the writer, with no row-sized buffer in between: `{d:.17}` in
/// `writeDiff` is fixed-point, so a large aspect ratio expands its whole
/// integer part (309 digits at floatMax). Any fixed row buffer is a cliff, and
/// one row overflowing would abort the report rather than print one bad line.
pub fn writeTiming(w: *std.Io.Writer, name: []const u8, t: Timing) std.Io.Writer.Error!void {
    try w.print(row_fmt ++ "\n", .{ name, t.cur_us, t.base_us, t.ratio(), t.batch });
}

/// One deterministic-diff row, printed only for cases that differ. `gap` rides
/// along as context: it never triggers a row (see `differs`), but when one
/// fires — a case flipping to did_not_converge, say — how far the certificate
/// moved is the first thing worth seeing.
///
/// Fixed-point rather than scientific so the two aspect ratios line up digit
/// for digit: reading *where* they diverge is the point of the row.
pub fn writeDiff(w: *std.Io.Writer, name: []const u8, a: Metrics, b: Metrics) std.Io.Writer.Error!void {
    try w.print(
        "  {s:<22} cur={s}/{d}/{d:.17}/{e:.2}  base={s}/{d}/{d:.17}/{e:.2}\n",
        .{ name, a.status, a.iters, a.ar, a.gap, b.status, b.iters, b.ar, b.gap },
    );
}

// ---------------------------------------------------------------------------
// The instrument, and the default adapter
//
// A monotonic clock (`Io.Timestamp`, `.awake`), read once on each side of a
// timed interval. Two properties matter, both per-machine: its resolution
// (42ns on aarch64-macos, the 24MHz timebase) and the cost of a read (tens of
// ns). Both reads sit INSIDE the measured interval, so their cost is charged
// to the solve — but identically on both sides, so it is common-mode and
// cancels in a ratio. Resolution does not cancel, which is what batching is
// for.
// ---------------------------------------------------------------------------

/// Matches the tolerance the test suite runs at, so a report is comparable to
/// what `just ci` gates on.
pub const GAP_TOL = 1e-6;

/// One side of a comparison: a library version bound to an allocator, a clock,
/// and the options it solves under. Exposes `metrics` and `measure`.
///
/// This is the *default* adapter, for when both versions share an API.
/// Anything with the same two methods can stand in for a side — which is how
/// a baseline with a different API gets shimmed, in `ab.zig`, without touching
/// this module. Such a shim is dead once the pin moves past the change.
pub fn Side(comptime lib: type) type {
    return struct {
        const Self = @This();

        gpa: std.mem.Allocator,
        io: std.Io,
        pts: []const [3]f64 = &.{},
        gap_tol: f64 = GAP_TOL,

        /// Returns `lib.SolveOptions`, not any one version's — the two
        /// versions have distinct types of the same name.
        ///
        /// Every solver option is pinned explicitly, including ones that match
        /// today's defaults. The two sides are different library versions: if
        /// a default ever changed between them, an unpinned option would make
        /// them solve different configurations and the difference would
        /// masquerade as a solver change — precisely what this tool exists to
        /// detect.
        fn opts(self: Self) lib.SolveOptions {
            return .{
                .gap_tol = self.gap_tol,
                .n_hull = 10,
                .coplanarity_tol = 1e-12,
                .max_outer = 100,
                // `.trust`, not `.auto`: `.auto` is an alias each version is
                // free to re-point.
                .method = .trust,
            };
        }

        /// Solve once and reduce to comparable metrics. Errors are reported,
        /// not propagated: `solve` can still return one on a valid input
        /// (#1, #2), and a case that errors on one side only is precisely a
        /// difference worth seeing. Dying here would hide it.
        pub fn metrics(self: Self, pts: []const [3]f64) Metrics {
            var o = lib.solve(self.gpa, pts, self.opts()) catch |e| {
                return .{ .status = @errorName(e) };
            };
            defer o.deinit();
            // @tagName, not a literal: this switch is exhaustive over the real
            // union, so a new outcome variant is a compile error HERE, and the
            // status it produces is the library's own spelling — which the
            // suite pins `OutcomeTag` to.
            const status = @tagName(o);
            return switch (o) {
                .converged => |c| .{
                    .status = status,
                    .iters = c.diag.totalIters(),
                    .ar = c.aspectRatio(),
                    .gap = c.gap,
                },
                .infeasible => .{ .status = status },
                .did_not_converge => |p| .{
                    .status = status,
                    .iters = p.diag.totalIters(),
                    .ar = p.sigma[2] / p.sigma[1],
                    .gap = p.gap,
                },
            };
        }

        /// The timed interval: run `count` solves on `pts`, return the
        /// elapsed microseconds. What every policy loop (`warmUp`,
        /// `calibrate`, `pairedRun`) consumes, and the only place in the
        /// harness a clock is read.
        pub fn measure(self: *Self, count: u32) f64 {
            const t0 = std.Io.Timestamp.now(self.io, .awake);
            for (0..count) |_| {
                // A solve that fails is skipped, which shortens a *timed*
                // interval and reports a fast, meaningless µs. Callers only
                // time cases that `metrics` already reported as an outcome.
                var o = lib.solve(self.gpa, self.pts, self.opts()) catch continue;
                o.deinit();
            }
            const t1 = std.Io.Timestamp.now(self.io, .awake);
            return @as(f64, @floatFromInt(t0.durationTo(t1).nanoseconds)) / 1000.0;
        }
    };
}
