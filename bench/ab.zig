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
const bc = @import("benchcore");
const cur = @import("cur");
const base = @import("base");
const cases = @import("cases");

/// Timing selection: examples spanning the regimes (sub-µs hot path, mid-size,
/// hard/wide, infeasible). Deliberately NOT a corpus — #19 decides what a
/// report highlights. Deterministic metrics run over every fixture regardless.
const TIMING_CASES = [_][]const u8{ "hex", "np100", "ha_12", "near_collinear" };

comptime {
    // A misspelt name would otherwise degrade silently to "not in manifest"
    // and quietly measure fewer cases. `just check` catches it instead.
    for (TIMING_CASES) |name| {
        if (cases.byName(name) == null) @compileError("unknown timing case: " ++ name);
    }
}

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

/// One side of the comparison: a library version bound to an allocator, a
/// clock, and the options it solves under. This is the whole "mechanics" half
/// — everything it feeds into lives in `benchcore`.
fn Side(comptime lib: type) type {
    return struct {
        const Self = @This();

        gpa: std.mem.Allocator,
        io: std.Io,
        pts: []const [3]f64 = &.{},
        gap_tol: f64 = GAP_TOL,

        /// Solve once and reduce to comparable metrics. Errors are reported,
        /// not propagated: `solve` can still return one on a valid input
        /// (#1, #2), and a case that errors on one side only is precisely a
        /// difference worth seeing. Dying here would hide it.
        fn metrics(self: Self, pts: []const [3]f64) bc.Metrics {
            var o = lib.solve(self.gpa, pts, .{
                .gap_tol = self.gap_tol,
                .coplanarity_tol = 1e-12,
            }) catch |e| return .{ .status = @errorName(e) };
            defer o.deinit();
            return switch (o) {
                .converged => |c| .{
                    .status = "converged",
                    .iters = c.diag.totalIters(),
                    .ar = c.aspectRatio(),
                    .gap = c.gap,
                },
                .infeasible => .{ .status = "infeasible" },
                .did_not_converge => |p| .{
                    .status = "did_not_converge",
                    .iters = p.diag.totalIters(),
                    .ar = p.sigma[2] / p.sigma[1],
                    .gap = p.gap,
                },
            };
        }

        fn warmUp(self: Self) void {
            for (0..bc.N_WARMUP) |_| {
                var o = lib.solve(self.gpa, self.pts, .{ .gap_tol = self.gap_tol }) catch continue;
                o.deinit();
            }
        }

        /// The `bc.MeasureFn` this side supplies: run `count` solves, return
        /// the elapsed microseconds. The only place a clock is read.
        fn measure(ctx: *anyopaque, count: u32) f64 {
            const self: *Self = @ptrCast(@alignCast(ctx));
            const t0 = std.Io.Timestamp.now(self.io, .awake);
            for (0..count) |_| {
                var o = lib.solve(self.gpa, self.pts, .{
                    .gap_tol = self.gap_tol,
                    .coplanarity_tol = 1e-12,
                }) catch continue;
                o.deinit();
            }
            const t1 = std.Io.Timestamp.now(self.io, .awake);
            return @as(f64, @floatFromInt(t0.durationTo(t1).nanoseconds)) / 1000.0;
        }
    };
}

pub fn main(init: std.process.Init) !void {
    var opts = Opts{};
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    for (argv[1..]) |a| {
        if (std.mem.eql(u8, a, "--aa")) opts.aa = true;
        if (std.mem.eql(u8, a, "--inject-2x")) opts.inject_2x = true;
        if (std.mem.eql(u8, a, "--inject-tol")) opts.inject_tol = true;
    }
    // The baseline side is a comptime choice, so it is dispatched here rather
    // than selected inside: in --aa mode it is the current library again.
    if (opts.aa) try report(cur, init, opts) else try report(base, init, opts);
}

/// `BaseLib` is what the current tree is measured against: the pinned baseline
/// normally, the current library itself under --aa.
fn report(comptime BaseLib: type, init: std.process.Init, opts: Opts) !void {
    const gpa = init.gpa;
    const io = init.io;

    var buf: [8192]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    const out = &w.interface;
    var line: [256]u8 = undefined;

    const cur_tol: f64 = if (opts.inject_tol) INJECT_GAP_TOL else GAP_TOL;
    const cur_mult: u32 = if (opts.inject_2x) 2 else 1;

    const Base = Side(BaseLib);

    var side_cur = Side(cur){ .gpa = gpa, .io = io, .gap_tol = cur_tol };
    var side_base = Base{ .gpa = gpa, .io = io };

    // Self-describing: a local report and a CI report must be comparable, and
    // the invariant that travels between machines is the ratio, not the µs.
    const builtin = @import("builtin");
    try out.print("csar A/B report\n", .{});
    try out.print("  mode      : {s}\n", .{if (opts.aa) "A/A (current vs current)" else "A/B (current vs pinned baseline)"});
    try out.print("  host      : {t}-{t}\n", .{ builtin.cpu.arch, builtin.os.tag });
    try out.print("  zig       : {s}\n", .{builtin.zig_version_string});
    try out.print("  reps      : {d} (+{d} warm-up), interleaved\n", .{ bc.N_REPS, bc.N_WARMUP });
    if (opts.inject_2x) try out.print("  injected  : 2x on the current side\n", .{});
    if (opts.inject_tol) try out.print("  injected  : gap_tol={e} on the current side\n", .{INJECT_GAP_TOL});
    try out.print("\n", .{});

    // ---- deterministic pass, over every fixture -------------------------
    try out.print("deterministic diff ({d} fixtures: status / iters / ar)\n", .{cases.all.len});
    var n_diff: usize = 0;
    for (cases.all) |entry| {
        const a = side_cur.metrics(entry.case.points);
        const b = side_base.metrics(entry.case.points);
        if (!bc.differs(a, b)) continue;
        n_diff += 1;
        try out.print("{s}\n", .{try bc.formatDiff(&line, entry.name, a, b)});
    }
    if (n_diff == 0) {
        try out.print("  none\n", .{});
    } else {
        try out.print("  {d} case(s) differ\n", .{n_diff});
    }
    try out.print("\n", .{});

    // ---- timing, paired and interleaved ---------------------------------
    try out.print("timing (min of {d} reps, µs per solve)\n", .{bc.N_REPS});
    try out.print("{s}\n", .{bc.timing_header});

    var samples_cur: [bc.N_REPS]f64 = undefined;
    var samples_base: [bc.N_REPS]f64 = undefined;
    for (TIMING_CASES) |name| {
        const pts = cases.byName(name).?.points;
        side_cur.pts = pts;
        side_base.pts = pts;

        // A case that errors is already reported above; timing it would
        // measure an error path.
        if (!bc.isOutcome(side_cur.metrics(pts).status) or
            !bc.isOutcome(side_base.metrics(pts).status))
        {
            try out.print("  {s:<20} (error — see the diff above)\n", .{name});
            continue;
        }

        side_cur.warmUp();
        side_base.warmUp();

        // Calibrate the batch from the baseline side, so both sides use the
        // same count and the comparison stays like-for-like.
        const batch = bc.batchFor(Base.measure(&side_base, 1));

        const t = bc.pairedRun(
            Side(cur).measure,
            &side_cur,
            Base.measure,
            &side_base,
            batch,
            cur_mult,
            bc.N_REPS,
            &samples_cur,
            &samples_base,
        );
        try out.print("{s}\n", .{try bc.formatTiming(&line, name, t)});
    }
    try out.flush();
}
