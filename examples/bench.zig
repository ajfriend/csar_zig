//! Per-case timing bench. Iterates a hand-picked subset of the
//! comptime case manifest, runs the solver N times per case, prints
//! per-case min/median μs.
//!
//! Uses init.gpa, which resolves to std.heap.smp_allocator (Zig's fast
//! thread-safe production allocator) in this example's forced
//! ReleaseFast build — see the allocator note in csar.zig.

const std = @import("std");
const csar = @import("csar");
const cases = @import("cases");

/// Warms the process, not the binary: a freshly built exe's first *launch*
/// still runs several times slow, and that survives min-over-reps. Discard it
/// — see CLAUDE.md "Performance & regression monitoring".
const N_WARMUP: u32 = 5;
const N_RUNS: u32 = 100;

const Row = struct {
    name: []const u8,
    points: []const [3]f64,
    max_outer: u32,
};

fn row(comptime name: []const u8, max_outer: u32) Row {
    return .{
        .name = name,
        .points = cases.get(name).points,
        .max_outer = max_outer,
    };
}

fn cmpF64(_: void, a: f64, b: f64) bool {
    return a < b;
}

pub fn main(init: std.process.Init) !void {
    // init.gpa resolves to std.heap.smp_allocator in release builds
    // (this example is forced ReleaseFast) — see the allocator note in
    // csar.zig.
    const allocator = init.gpa;

    // Representative subset of the full manifest. Intentionally fewer
    // cases than `cases.all` — bench is for cross-config timing, not
    // completeness; the full case-coverage gate is the test suite.
    // `max_outer` is per case so the table has one row per outcome:
    // wide_cap89 at a budget of 1 cannot converge (its eager certificate
    // fails by construction), so it shows what a DNC row looks like.
    const CASES = [_]Row{
        row("hex", 100),
        row("np20", 100),
        row("np100", 100),
        row("np400", 100),
        row("h3_res05", 100),
        row("h3_res09", 100),
        row("h3_res12", 100),
        row("h3_res15", 100),
        row("ha_05", 100),
        row("ha_08", 100),
        row("ha_10", 100),
        row("ha_12", 100),
        row("ha_14", 100),
        row("infeas_antipodal", 100),
        row("near_collinear", 100),
        row("wide_cap89", 1),
    };

    const io = init.io;
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.print("case                    status    n   iters  time_min_us  time_median_us  aspect_ratio  np_fail\n", .{});
    try stdout.print("----------------------  --------  --  -----  -----------  --------------  ------------  -------\n", .{});

    var total_converged_min: f64 = 0;
    var total_converged_median: f64 = 0;
    var n_converged: u32 = 0;

    for (CASES) |case| {
        const name = case.name;
        const X = case.points;

        var opts = cases.pin(csar.SolveOptions);
        opts.max_outer = case.max_outer;

        // Warm up.
        for (0..N_WARMUP) |_| {
            var outcome = try csar.solve(allocator, X, opts);
            outcome.deinit();
        }

        var times = try allocator.alloc(f64, N_RUNS);
        defer allocator.free(times);

        var last_outcome: ?csar.Outcome = null;
        defer if (last_outcome) |*lo| lo.deinit();
        // The two clock reads sit inside the measured interval, so their cost is
        // charged to the solve: a few percent on the smallest cases, negligible
        // elsewhere. It is common-mode across an A/B pair, so read small-case
        // ratios rather than absolutes.
        for (0..N_RUNS) |r| {
            const t0 = std.Io.Timestamp.now(io, .awake);
            const outcome = try csar.solve(allocator, X, opts);
            const t1 = std.Io.Timestamp.now(io, .awake);
            times[r] = @as(f64, @floatFromInt(t0.durationTo(t1).nanoseconds)) / 1000.0;
            if (last_outcome) |*lo| lo.deinit();
            last_outcome = outcome;
        }

        std.mem.sort(f64, times, {}, cmpF64);
        const t_min = times[0];
        const t_median = times[N_RUNS / 2];

        if (last_outcome) |lo| {
            const status_str = switch (lo) {
                .converged => "ok",
                .infeasible => "infeas",
                .did_not_converge => "DNC",
            };
            // Per-variant: only Converged/DidNotConverge carry iteration
            // counters; Infeasible bails in halfspaceCheck before iterating.
            // Aspect ratio is only meaningful on Converged.
            var outer_iters: u32 = 0;
            var polish_failures: u32 = 0;
            var aspect_ratio: f64 = 0;
            switch (lo) {
                .converged => |c| {
                    outer_iters = c.diag.totalIters();
                    polish_failures = c.diag.trust.polish_failures;
                    aspect_ratio = c.aspectRatio();
                },
                .did_not_converge => |p| {
                    outer_iters = p.diag.totalIters();
                    polish_failures = p.diag.trust.polish_failures;
                    // Uncertified ratio from the last iterate. `DidNotConverge`
                    // intentionally omits an `aspectRatio()` method since the
                    // value isn't certified; compute it inline here.
                    aspect_ratio = p.sigma[2] / p.sigma[1];
                },
                .infeasible => {},
            }
            try stdout.print("{s:22}  {s:8}  {d:2}  {d:5}  {d:11.2}  {d:14.2}  {d:12.6}  {d:7}\n", .{
                name,
                status_str,
                X.len,
                outer_iters,
                t_min,
                t_median,
                aspect_ratio,
                polish_failures,
            });
            if (lo == .converged) {
                total_converged_min += t_min;
                total_converged_median += t_median;
                n_converged += 1;
            }
        }
    }

    // Only converged-case timings are meaningful for cross-config comparison.
    // DNC cases always hit MAX_OUTER and infeasible cases bail in halfspace
    // check — neither reflects solver inner-loop performance.
    //
    // CAUTION when judging a solver change: this TOTAL is a sum of wall-times,
    // so it is dominated by the large synthetic cases (np400, ha_*). It is NOT
    // a guard for the common/hot path — small DGGS cells (hex, h3_res*, 4–10
    // points) that solve in ~1–2 outer iters and µs. A real regression on those
    // hides in TOTAL, and µs-scale wall-time on a 6-point cell is mostly noise.
    // Read the PER-CASE rows above (small vs large separately). See CLAUDE.md
    // "Performance & regression monitoring".
    try stdout.print("----------------------  --------  --  -----  -----------  --------------\n", .{});
    try stdout.print("{s:22}  {s:8}  {d:2}  {s:5}  {d:11.2}  {d:14.2}\n", .{
        "TOTAL (converged only)",
        "ok",
        n_converged,
        "—",
        total_converged_min,
        total_converged_median,
    });
    try stdout.flush();
}
