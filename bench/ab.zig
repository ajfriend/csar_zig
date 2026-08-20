//! A/B harness: measures the working tree against a pinned baseline, both
//! compiled into THIS binary.
//!
//!   just ab                 # A/B: current vs the pinned baseline
//!   just ab --aa            # calibration: current vs current
//!   just ab --inject-2x     # self-test: the current side solves twice
//!   just ab --inject-tol    # self-test: the current side runs a tight gap_tol
//!
//! The report is meant to be pasted into a PR. Nothing is written to disk.
//!
//! ## Benchmarking methodology
//!
//! The policy — warm-up, batching, pairing, the statistic — lives in `core.zig`
//! next to the constants that encode it. What follows are the parts that are
//! properties of *this binary* rather than of those constants.
//!
//! ### The instrument
//!
//! A monotonic clock (`Io.Timestamp`, `.awake`), read once on each side of a
//! timed interval. Two properties matter, both per-machine: its resolution
//! (42ns on aarch64-macos, the 24MHz timebase) and the cost of a read (tens of
//! ns). Both reads sit INSIDE the measured interval, so their cost is charged
//! to the solve — but identically on both sides, so it is common-mode and
//! cancels in a ratio. Resolution does not cancel, which is what batching is
//! for.
//!
//! ### No process isolation, deliberately
//!
//! Both versions live in one binary. A freshly built binary's first *launch*
//! runs 2-5x slow, and that penalty survives an in-process warm-up and a
//! min-over-reps, so a two-process A/B can invent a small-cell regression
//! outright. It did, while A/B-ing the 0.16 bump. Sharing one process means
//! both sides pay the launch cost, the allocator and the clock, and all of it
//! divides out.
//!
//! This inverts what JVM harnesses do — they fork per variant because the JIT
//! builds a profile as it runs, so two implementations in one process
//! contaminate each other's compilation. Zig is AOT-compiled: there is no
//! profile to pollute.
//!
//! ### The check
//!
//! `--aa` runs a version against itself. It must yield 1.000; whatever it
//! misses by is that run's noise floor, and no A/B difference smaller than
//! that means anything. It is the only check that catches bias in the harness
//! rather than in the solver, so read it first. Measured on aarch64-macos:
//! ~0.3% on the smallest case, ~0.1% elsewhere, stable across launches.
//!
//! ### Known residual bias: code layout
//!
//! The two versions occupy different addresses in one binary, and their
//! relative layout is fixed at link time. Cache-set and alignment luck can
//! therefore favour one side systematically — and unlike everything above,
//! that bias is invisible to more reps, more launches, and even a rebuild,
//! since the build is deterministic. As the Stabilizer paper (ASPLOS'13) puts
//! it, a single binary is one sample from the space of layouts *regardless of
//! the number of runs*, and there layout effects swamped the difference
//! between -O2 and -O3.
//!
//! `--aa` cannot see it either: identical pins dedupe to one module, so A/A
//! compares one copy against itself and shares layout by construction.
//! Measuring it needs two distinct copies of the *same* commit — two pins that
//! hash differently — tracked in #22. Until then, treat an A/B difference near
//! the noise floor as unproven, and prefer a change that shows up across
//! several cases over one that moves a single case slightly.

const std = @import("std");
const bc = @import("core.zig");
const build_options = @import("build_options");
const cur = @import("cur");
const base = @import("base");
const cases = @import("cases");

/// Timing selection: examples spanning the regimes (sub-µs hot path, mid-size,
/// hard/wide, infeasible). Deliberately NOT a corpus — #19 decides what a
/// report highlights. Deterministic metrics run over every fixture regardless.
const TIMING_CASE_NAMES = [_][]const u8{ "hex", "np100", "ha_12", "near_collinear" };

/// Resolved at comptime rather than looked up at runtime: a misspelt name is a
/// build error here, where `cases.byName` would otherwise return null and the
/// harness would quietly measure fewer cases than intended.
const TIMING_CASES = blk: {
    var out: [TIMING_CASE_NAMES.len]struct { name: []const u8, points: []const [3]f64 } = undefined;
    for (TIMING_CASE_NAMES, 0..) |name, i| {
        const case = cases.byName(name) orelse @compileError("unknown timing case: " ++ name);
        out[i] = .{ .name = name, .points = case.points };
    }
    break :blk out;
};

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
/// — everything it feeds into lives in `core.zig`.
fn Side(comptime lib: type) type {
    return struct {
        const Self = @This();

        gpa: std.mem.Allocator,
        io: std.Io,
        pts: []const [3]f64 = &.{},
        gap_tol: f64 = GAP_TOL,

        /// Returns `lib.SolveOptions`, not `cur.SolveOptions` — the two
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
        fn metrics(self: Self, pts: []const [3]f64) bc.Metrics {
            var o = lib.solve(self.gpa, pts, self.opts()) catch |e| {
                return .{ .status = @errorName(e) };
            };
            defer o.deinit();
            // @tagName, not a literal: this switch is exhaustive over the real
            // union, so a new outcome variant is a compile error HERE, and the
            // status it produces is the library's own spelling — which the
            // suite pins `bc.OutcomeTag` to (tests/bench_core_test.zig).
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

        /// `measure` with the clock ignored.
        fn warmUp(self: *Self) void {
            _ = self.measure(bc.N_WARMUP);
        }

        /// What `bc.pairedRun` calls: run `count` solves, return the elapsed
        /// microseconds. The only place in the harness a clock is read.
        pub fn measure(self: *Self, count: u32) f64 {
            const t0 = std.Io.Timestamp.now(self.io, .awake);
            for (0..count) |_| {
                // Must stay unreachable: firing here would shorten a *timed*
                // interval and report a fast, meaningless µs. The caller only
                // times cases that already solved cleanly.
                var o = lib.solve(self.gpa, self.pts, self.opts()) catch continue;
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
        if (std.mem.eql(u8, a, "--aa")) {
            opts.aa = true;
        } else if (std.mem.eql(u8, a, "--inject-2x")) {
            opts.inject_2x = true;
        } else if (std.mem.eql(u8, a, "--inject-tol")) {
            opts.inject_tol = true;
        } else {
            // Fail rather than ignore: a misspelt `--inject-2x` would
            // otherwise run a plain A/B and print a report that looks like a
            // passed self-test.
            std.debug.print("unknown argument: {s}\nusage: just ab [--aa] [--inject-2x] [--inject-tol]\n", .{a});
            return error.UnknownArgument;
        }
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
    // Best-effort on the error path: if the run dies partway, emit the rows
    // that were already formatted rather than nothing. The happy path flushes
    // explicitly at the end, so a real write failure still propagates —
    // "truncated, exit 0" would be worse than the failure this softens.
    defer out.flush() catch {};

    const cur_tol: f64 = if (opts.inject_tol) INJECT_GAP_TOL else GAP_TOL;
    const cur_mult: u32 = if (opts.inject_2x) 2 else 1;

    const Cur = Side(cur);
    const Base = Side(BaseLib);

    var side_cur = Cur{ .gpa = gpa, .io = io, .gap_tol = cur_tol };
    var side_base = Base{ .gpa = gpa, .io = io };

    // Self-describing: a local report and a CI report must be comparable, and
    // the invariant that travels between machines is the ratio, not the µs.
    const builtin = @import("builtin");
    try out.print("csar A/B report\n", .{});
    try out.print("  mode      : {s}\n", .{if (opts.aa) "A/A (current vs current)" else "A/B (current vs pinned baseline)"});
    try out.print("  host      : {t}-{t}\n", .{ builtin.cpu.arch, builtin.os.tag });
    try out.print("  zig       : {s}\n", .{builtin.zig_version_string});
    try out.print("  baseline  : {s}\n", .{if (opts.aa) "(A/A: the working tree)" else build_options.baseline});
    try out.print("  reps      : {d} (+{d} warm-up), interleaved\n", .{ bc.N_REPS, bc.N_WARMUP });
    try out.print("  note      : compare ratios, not µs — absolute times vary 2-5x between\n" ++
        "              launches (see ab.zig, \"No process isolation\"); ratios do not.\n", .{});
    if (opts.inject_2x) try out.print("  injected  : 2x on the current side\n", .{});
    if (opts.inject_tol) try out.print("  injected  : gap_tol={e} on the current side\n", .{INJECT_GAP_TOL});
    try out.print("\n", .{});

    // ---- deterministic pass, over every fixture -------------------------
    try out.print("deterministic diff ({d} fixtures: status / iters / ar)\n", .{cases.all.len});
    var n_diff: usize = 0;
    var tally_cur: bc.Tally = .{};
    var tally_base: bc.Tally = .{};
    for (cases.all) |entry| {
        const a = side_cur.metrics(entry.case.points);
        const b = side_base.metrics(entry.case.points);
        tally_cur.add(a);
        tally_base.add(b);
        if (!bc.differs(a, b)) continue;
        n_diff += 1;
        try bc.writeDiff(out, entry.name, a, b);
    }
    if (n_diff == 0) {
        try out.print("  none\n", .{});
    } else {
        try out.print("  {d} case(s) differ\n", .{n_diff});
    }
    try out.print("  outcomes  cur : {f}\n", .{tally_cur});
    try out.print("            base: {f}\n", .{tally_base});
    try out.print("\n", .{});

    // ---- timing, paired and interleaved ---------------------------------
    try out.print("timing (min of {d} reps, µs per solve)\n", .{bc.N_REPS});
    try out.print("{s}\n", .{bc.timing_header});

    var samples_cur: [bc.N_REPS]f64 = undefined;
    var samples_base: [bc.N_REPS]f64 = undefined;
    for (TIMING_CASES) |case| {
        side_cur.pts = case.points;
        side_base.pts = case.points;

        // Timing a case that errors would measure an error path. The
        // deterministic pass above already reported it.
        if (!bc.isOutcome(side_cur.metrics(case.points).status) or
            !bc.isOutcome(side_base.metrics(case.points).status))
        {
            try out.print("  {s:<20} (errored on at least one side)\n", .{case.name});
            continue;
        }

        side_cur.warmUp();
        side_base.warmUp();

        // Calibrated AFTER warm-up, so the probe measures a warm solve, and
        // from the baseline side so both sides use the same batch.
        const batch = bc.batchFor(side_base.measure(1));

        const t = bc.pairedRun(&side_cur, &side_base, batch, cur_mult, &samples_cur, &samples_base);
        try bc.writeTiming(out, case.name, t);
    }

    // Not redundant with the `defer` above: this is the one that reports a
    // write failure instead of swallowing it.
    try out.flush();
}
