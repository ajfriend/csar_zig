//! A/B harness: measures the working tree against a pinned baseline, both
//! compiled into THIS binary. One process, one allocator, one clock, reps
//! interleaved — so the per-process cold-start effect that manufactured a
//! phantom small-cell regression while A/B-ing the 0.16 bump cannot arise.
//!
//!   zig build ab                 # A/B: current vs pinned baseline
//!   zig build ab -- --aa         # calibration: current vs current
//!   zig build ab -- --inject-2x  # self-test: current side solves twice
//!   zig build ab -- --inject-tol # self-test: current side runs a tight gap_tol
//!
//! The report is meant to be pasted into a PR. Nothing is written to disk.

const std = @import("std");
const cur = @import("cur");
const base = @import("base");
const cases = @import("cases");

/// Timing selection: examples spanning the regimes (sub-µs hot path, mid-size,
/// hard/wide, infeasible). Deliberately NOT a curated corpus — #19 decides
/// what a report should highlight. Deterministic metrics run over everything.
const TIMING_CASES = [_][]const u8{ "hex", "np100", "ha_12", "near_collinear" };

const N_WARMUP = 5;
const N_REPS = 100;
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

/// Time one side. `extra` repeats the solve within the measured interval —
/// the 2x injector, which must be deterministic per rep because we report a
/// min: a stochastic injector has no effect on a minimum.
fn timeSide(
    comptime lib: type,
    gpa: std.mem.Allocator,
    io: std.Io,
    pts: []const [3]f64,
    gap_tol: f64,
    extra: u32,
    out: []f64,
    rep: usize,
) void {
    const t0 = std.Io.Timestamp.now(io, .awake);
    for (0..extra) |_| {
        var o = lib.solve(gpa, pts, .{ .gap_tol = gap_tol, .coplanarity_tol = 1e-12 }) catch continue;
        o.deinit();
    }
    const t1 = std.Io.Timestamp.now(io, .awake);
    out[rep] = @as(f64, @floatFromInt(t0.durationTo(t1).nanoseconds)) / 1000.0;
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
    try out.print("  {s:20} {s:>10} {s:>10} {s:>8}\n", .{ "case", "cur", "base", "ratio" });

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
        for (0..N_REPS) |r| {
            // Interleaved: both sides see the same thermal/scheduler state.
            timeSide(cur, gpa, io, pts, cur_tol, cur_extra, &t_cur, r);
            if (opts.aa) {
                timeSide(cur, gpa, io, pts, GAP_TOL, 1, &t_base, r);
            } else {
                timeSide(base, gpa, io, pts, GAP_TOL, 1, &t_base, r);
            }
        }
        std.mem.sort(f64, &t_cur, {}, cmpF64);
        std.mem.sort(f64, &t_base, {}, cmpF64);

        // Below clock resolution a ratio is noise divided by noise; report the
        // times and skip it rather than dividing by ~0. (Carried over from
        // examples/compare.zig.)
        if (t_base[0] < 1.0) {
            try out.print("  {s:20} {d:10.2} {d:10.2} {s:>8}\n", .{ name, t_cur[0], t_base[0], "sub-µs" });
        } else {
            try out.print("  {s:20} {d:10.2} {d:10.2} {d:8.3}\n", .{ name, t_cur[0], t_base[0], t_cur[0] / t_base[0] });
        }
    }
    try out.flush();
}
