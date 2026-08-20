//! A/B harness: measures the working tree against a pinned baseline, both
//! compiled into THIS binary.
//!
//!   zig build ab                 # A/B: current vs pinned baseline
//!   zig build ab -- --aa         # calibration: current vs current
//!   zig build ab -- --inject-2x  # self-test: current side solves twice
//!   zig build ab -- --inject-tol # self-test: current side runs a tight gap_tol
//!
//! The report is meant to be pasted into a PR. Nothing is written to disk.
//!
//! ## Benchmarking methodology
//!
//! Each choice below removes a specific way a solver comparison can lie.
//! Change them together with the reasoning, not individually.
//!
//! ### The instrument
//!
//! A monotonic clock (`Io.Timestamp`, `.awake`), read once on each side of a
//! timed interval. Two properties matter and both are per-machine: its
//! resolution (42ns on aarch64-macos, the 24MHz timebase) and the cost of a
//! read (tens of ns). Both reads sit INSIDE the measured interval, so their
//! cost is charged to the solve — but identically on both sides, so it is
//! common-mode and cancels in a ratio. Resolution does not cancel, which is
//! what batching below is for.
//!
//! ### The design
//!
//! **No process isolation, deliberately.** Both versions live in one binary.
//! That inverts the usual harness default — JVM harnesses fork a fresh process
//! per variant — but their reason does not apply here: the JIT builds a
//! profile as it runs, so two implementations in one process contaminate each
//! other's compilation, and isolation is the only fix. Zig is AOT-compiled;
//! both versions are machine code before main() starts and there is no profile
//! to pollute. So we get pairing without the hazard that forces forking there.
//!
//! Co-location is also positively wanted here: a freshly built binary's first
//! *launch* runs 2-5x slow, and that penalty survives an in-process warm-up
//! and a min-over-reps, so a two-process A/B can invent a small-cell
//! regression outright. It did, while A/B-ing the 0.16 bump. Sharing one
//! process means both sides pay the launch cost, the allocator, and the clock,
//! and all of it divides out.
//!
//! **Warm-up iterations.** N_WARMUP untimed solves per case per side, so the
//! timed reps see warm caches and a settled allocator. Per-*iteration* only —
//! the per-*process* effect above is handled by the single-binary design, not
//! here.
//!
//! **Batch fast cases.** A solve near the clock's resolution cannot be timed
//! individually: `hex` at ~0.8us against a 42ns clock is ~19 quanta, ~5%
//! granularity. Each timed interval therefore spans however many solves it
//! takes to reach BATCH_TARGET_US, calibrated per case from one probe solve so
//! it adapts to the machine rather than encoding this one.
//!
//! **Paired: interleave at rep granularity.** Both sides are measured inside
//! the same rep, making each rep a matched pair drawn under the same thermal
//! state, scheduler pressure, and CPU frequency — not two independent samples
//! taken minutes apart. Pairing is what licenses reporting a *ratio*: shared
//! conditions divide out of it, which is why the ratio travels between
//! machines when the absolute microseconds do not. The order within a rep is
//! fixed (current, then baseline) rather than alternating; `--aa` is what
//! would expose a bias from that, and it reports 1.000 on every case today.
//!
//! ### The statistic
//!
//! **The min, not the mean or median.** Timing noise is one-sided
//! contamination: interrupts, migrations, and contention can only add time,
//! never remove it. The minimum is therefore a robust estimator of the
//! uncontaminated cost, while the mean and median estimate something else —
//! the machine's typical state during this particular run. For batched cases
//! it is min-of-batch-means: jitter is averaged within a batch rather than
//! rejected by the min, which is the price of measuring a sub-us case at all.
//!
//! That argument holds only while the noise is sparse and memoryless — a
//! contaminating process that is *always* present (a busy machine, a thermal
//! cap) contaminates the minimum too, and the min will quietly report the
//! contaminated cost rather than flagging it. Criterion and JMH take the other
//! branch here, reporting means with confidence intervals; the min is chosen
//! because this harness compares two co-located versions rather than reporting
//! an absolute cost, and `--aa` is the check that the assumption held.
//!
//! N_REPS is a floor for that min to settle against, not a sample size. There
//! is deliberately no outlier rejection, no variance estimate, and no
//! significance test — the report is read by a human against the `--aa` floor,
//! and #18 decides whether anything ever gates on it.
//!
//! ### The check
//!
//! **`--aa` validates everything above.** Running a version against itself
//! must yield 1.000; whatever it misses by is that run's noise floor, and no
//! A/B difference smaller than that means anything. It is the only check that
//! catches bias in the harness rather than in the solver, so read it first.
//! Measured on aarch64-macos: ~0.3% on the smallest case, ~0.1% elsewhere,
//! stable across launches.
//!
//! ### Known residual bias: code layout
//!
//! The two versions occupy different addresses in one binary, and their
//! relative layout is fixed at link time. Cache-set and alignment luck can
//! therefore favour one side systematically — and unlike everything above,
//! that bias is invisible to more reps, more launches, and even a rebuild,
//! since the build is deterministic. As the Stabilizer paper puts it, a single
//! binary is one sample from the space of layouts *regardless of the number of
//! runs*; layout effects have been measured large enough elsewhere to swamp
//! the difference between -O2 and -O3.
//!
//! `--aa` cannot currently see it either: identical pins dedupe to one module,
//! so A/A compares one copy against itself and shares layout by construction.
//! Measuring it needs two distinct copies of the *same* commit — two pins that
//! hash differently — tracked in #22. Until then, treat an A/B
//! difference near the noise floor as unproven, and prefer a change that shows
//! up across several cases over one that moves a single case slightly.
//!
//! This matters less here than in the literature's examples: the solver is
//! small, hot, and branch-light, so it is likely far less layout-sensitive
//! than the SPEC-scale programs those results come from. Likely, not measured.

const std = @import("std");
const cur = @import("cur");
const base = @import("base");
const cases = @import("cases");

/// Timing selection: examples spanning the regimes (sub-µs hot path, mid-size,
/// hard/wide, infeasible). Deliberately NOT a curated corpus — #19 decides
/// what a report should highlight. Deterministic metrics run over everything.
const TIMING_CASES = [_][]const u8{ "hex", "np100", "ha_12", "near_collinear" };

/// Untimed solves before each side's timed reps — warm caches and settle the
/// allocator. Per-iteration only; the per-process effect is handled by having
/// one binary at all. See "Benchmarking methodology" above.
const N_WARMUP = 5;
/// Timed reps per side per case. A floor for the min to settle against, not a
/// sample size for a statistic — nothing here computes a confidence interval.
const N_REPS = 100;
/// Timed intervals are grown to at least this long, so clock granularity
/// stops being a factor. ~2400x the 42ns clock seen on aarch64-macos.
const BATCH_TARGET_US = 100.0;
/// Matches the tolerance the test suite runs at, so a report is comparable to
/// what `just ci` gates on.
const GAP_TOL = 1e-6;
/// Tight enough to push borderline cases off the f64 gap floor, for --inject-tol.
const INJECT_GAP_TOL = 1e-13;

const Opts = struct {
    aa: bool = false,
    inject_2x: bool = false,
    inject_tol: bool = false,
};

/// What we compare. `iters` and `ar`/`gap` are only meaningful for the
/// outcomes that carry them; `status` disambiguates.
const Metrics = struct {
    status: []const u8,
    iters: u32,
    ar: f64,
    gap: f64,
};

fn solveOnce(
    comptime lib: type,
    gpa: std.mem.Allocator,
    pts: []const [3]f64,
    gap_tol: f64,
) Metrics {
    // Errors are reported, not propagated: `solve` can still return one on a
    // valid input (#1, #2), and a case that errors on one side but not the
    // other is precisely a deterministic difference worth seeing. Dying here
    // would hide it.
    var o = lib.solve(gpa, pts, .{ .gap_tol = gap_tol, .coplanarity_tol = 1e-12 }) catch |e| {
        return .{ .status = @errorName(e), .iters = 0, .ar = 0, .gap = 0 };
    };
    defer o.deinit();
    return switch (o) {
        .converged => |c| .{
            .status = "converged",
            .iters = c.diag.totalIters(),
            .ar = c.aspectRatio(),
            .gap = c.gap,
        },
        .infeasible => .{ .status = "infeasible", .iters = 0, .ar = 0, .gap = 0 },
        .did_not_converge => |p| .{
            .status = "did_not_converge",
            .iters = p.diag.totalIters(),
            .ar = p.sigma[2] / p.sigma[1],
            .gap = p.gap,
        },
    };
}

fn cmpF64(_: void, a: f64, b: f64) bool {
    return a < b;
}

fn isOutcome(status: []const u8) bool {
    return std.mem.eql(u8, status, "converged") or
        std.mem.eql(u8, status, "infeasible") or
        std.mem.eql(u8, status, "did_not_converge");
}

/// Time `batch` solves as one interval and record µs per solve, dividing by
/// `divisor`.
///
/// Batching is what makes a fast case measurable rather than a special case.
/// A single `hex` solve is ~0.8µs against a 42ns clock — ~19 quanta, so ~5%
/// granularity, which shows up as ratio noise on exactly the hot-path cell
/// CLAUDE.md says to protect. Timing a batch of them puts the interval far
/// above the clock's resolution and the ratio becomes readable.
///
/// `batch` and `divisor` differ only under the 2x injector: the interval then
/// holds twice the solves but is still divided by the un-injected count, so
/// the reported per-solve time doubles, which is the point.
///
/// Note the statistic: with batching this is min-of-batch-means, not
/// min-of-single-solves — jitter is averaged within a batch rather than
/// rejected by the min.
fn timeSide(
    comptime lib: type,
    gpa: std.mem.Allocator,
    io: std.Io,
    pts: []const [3]f64,
    gap_tol: f64,
    batch: u32,
    divisor: u32,
    out: []f64,
    rep: usize,
) void {
    const t0 = std.Io.Timestamp.now(io, .awake);
    for (0..batch) |_| {
        var o = lib.solve(gpa, pts, .{ .gap_tol = gap_tol, .coplanarity_tol = 1e-12 }) catch continue;
        o.deinit();
    }
    const t1 = std.Io.Timestamp.now(io, .awake);
    const total_us = @as(f64, @floatFromInt(t0.durationTo(t1).nanoseconds)) / 1000.0;
    out[rep] = total_us / @as(f64, @floatFromInt(divisor));
}

/// Solves per timed interval: enough that the interval dwarfs the clock, one
/// when the case is already slow enough. Calibrated per case from a single
/// timed solve, so it adapts to the machine rather than encoding one.
fn batchFor(t_single_us: f64) u32 {
    if (t_single_us <= 0) return 1;
    const n = @ceil(BATCH_TARGET_US / t_single_us);
    if (n <= 1) return 1;
    if (n >= 4096) return 4096;
    return @intFromFloat(n);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var opts = Opts{};
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    for (argv[1..]) |a| {
        if (std.mem.eql(u8, a, "--aa")) opts.aa = true;
        if (std.mem.eql(u8, a, "--inject-2x")) opts.inject_2x = true;
        if (std.mem.eql(u8, a, "--inject-tol")) opts.inject_tol = true;
    }

    var buf: [8192]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    const out = &w.interface;

    // Self-describing: a local report and a CI report must be comparable, and
    // the invariant that travels between machines is the ratio, not the µs.
    const mode = if (opts.aa) "A/A (current vs current)" else "A/B (current vs pinned baseline)";
    try out.print("csar A/B report\n", .{});
    try out.print("  mode      : {s}\n", .{mode});
    try out.print("  host      : {s}-{s}\n", .{ @tagName(@import("builtin").cpu.arch), @tagName(@import("builtin").os.tag) });
    try out.print("  zig       : {s}\n", .{@import("builtin").zig_version_string});
    try out.print("  reps      : {d} (+{d} warm-up), interleaved\n", .{ N_REPS, N_WARMUP });
    if (opts.inject_2x) try out.print("  injected  : 2x on the current side\n", .{});
    if (opts.inject_tol) try out.print("  injected  : gap_tol={e} on the current side\n", .{INJECT_GAP_TOL});
    try out.print("\n", .{});

    const cur_tol: f64 = if (opts.inject_tol) INJECT_GAP_TOL else GAP_TOL;
    const cur_extra: u32 = if (opts.inject_2x) 2 else 1;

    // ---- deterministic pass, over every fixture -------------------------
    try out.print("deterministic diff ({d} fixtures: status / iters / ar / gap)\n", .{cases.all.len});
    var n_diff: usize = 0;
    for (cases.all) |entry| {
        const a = solveOnce(cur, gpa, entry.case.points, cur_tol);
        const b = if (opts.aa)
            solveOnce(cur, gpa, entry.case.points, GAP_TOL)
        else
            solveOnce(base, gpa, entry.case.points, GAP_TOL);

        const same_status = std.mem.eql(u8, a.status, b.status);
        const same_iters = a.iters == b.iters;
        const same_ar = a.ar == b.ar; // full precision, deliberately exact
        if (same_status and same_iters and same_ar) continue;

        n_diff += 1;
        try out.print("  {s:24}  cur={s}/{d}/{d:.17}  base={s}/{d}/{d:.17}\n", .{
            entry.name, a.status, a.iters, a.ar, b.status, b.iters, b.ar,
        });
    }
    if (n_diff == 0) {
        try out.print("  none\n", .{});
    } else {
        try out.print("  {d} case(s) differ\n", .{n_diff});
    }
    try out.print("\n", .{});

    // ---- timing, interleaved per rep ------------------------------------
    try out.print("timing (min of {d} reps, µs)\n", .{N_REPS});
    try out.print("  {s:20} {s:>10} {s:>10} {s:>8} {s:>7}\n", .{ "case", "cur", "base", "ratio", "batch" });

    var t_cur: [N_REPS]f64 = undefined;
    var t_base: [N_REPS]f64 = undefined;
    for (TIMING_CASES) |name| {
        const entry = cases.byName(name) orelse {
            try out.print("  {s:20}  (not in manifest)\n", .{name});
            continue;
        };
        const pts = entry.points;

        // A case that errors is reported in the deterministic pass above;
        // timing it would measure an error path.
        const probe_cur = solveOnce(cur, gpa, pts, cur_tol);
        const probe_base = if (opts.aa) solveOnce(cur, gpa, pts, GAP_TOL) else solveOnce(base, gpa, pts, GAP_TOL);
        if (!isOutcome(probe_cur.status) or !isOutcome(probe_base.status)) {
            try out.print("  {s:20}  (error: cur={s} base={s})\n", .{ name, probe_cur.status, probe_base.status });
            continue;
        }

        for (0..N_WARMUP) |_| {
            var o1 = cur.solve(gpa, pts, .{ .gap_tol = cur_tol }) catch continue;
            o1.deinit();
            var o2 = base.solve(gpa, pts, .{ .gap_tol = GAP_TOL }) catch continue;
            o2.deinit();
        }

        // Calibrate the batch from one timed solve on the baseline side, so
        // both sides use the same count and the ratio stays a like-for-like
        // comparison.
        var probe: [1]f64 = undefined;
        timeSide(base, gpa, io, pts, GAP_TOL, 1, 1, &probe, 0);
        const batch = batchFor(probe[0]);

        for (0..N_REPS) |r| {
            // Interleaved: both sides see the same thermal/scheduler state.
            timeSide(cur, gpa, io, pts, cur_tol, batch * cur_extra, batch, &t_cur, r);
            if (opts.aa) {
                timeSide(cur, gpa, io, pts, GAP_TOL, batch, batch, &t_base, r);
            } else {
                timeSide(base, gpa, io, pts, GAP_TOL, batch, batch, &t_base, r);
            }
        }
        std.mem.sort(f64, &t_cur, {}, cmpF64);
        std.mem.sort(f64, &t_base, {}, cmpF64);

        try out.print("  {s:20} {d:10.3} {d:10.3} {d:8.3} {d:>7}\n", .{
            name, t_cur[0], t_base[0], t_cur[0] / t_base[0], batch,
        });
    }
    try out.flush();
}
