//! The floor survey: re-solve every batch cell at tolerances tighter
//! than the corpus pin (1e-9, 1e-10) and re-evaluate each shipped
//! certificate through the gap oracle (src/oracle.zig) at f64 and
//! f128 — the measurement that separates "the iterate falls short"
//! from "the f64 gap evaluation can't see below its noise floor",
//! per cell, normalized by the floor model. Findings and methodology:
//! docs/floor-survey.md.
//!
//! Lives at the repo root for the same reason as test_root.zig: the
//! driver needs both the public API and the oracle (deliberately not
//! exported from root.zig), so its module must span `src/`.
//!
//! Run: `zig build floor-survey -Doptimize=ReleaseFast` for the full
//! measurement; `-- --batch=<name> --limit=<n> --csv=<path>` restrict
//! the sweep and dump per-cell rows. Registered in the coverage
//! gate's RUNS on reduced slices.
//!
//! Per cell: solve at the pinned options with the tight `gap_tol`,
//! then `oracle.evalOutcome` at f64 and f128 on the returned outcome.
//! The f64/f128 pair sees bit-identical inputs (promotion is exact),
//! so their difference is pure evaluation noise — the quantity the
//! floor model (`csar.gapFloor`) predicts. The floor: shipped
//! `gap_floor` for uncertified outcomes; for converged ones the model
//! is re-run on chart moments rebuilt from the certificate (below).

const std = @import("std");
const csar = @import("src/root.zig");
const core = @import("src/csar.zig");
const linalg = @import("src/linalg.zig");
const halfspace = @import("src/halfspace.zig");
const oracle = @import("src/oracle.zig");
const cases = @import("cases");

/// The two tolerances the measurement runs at — one decade below the
/// corpus pin's 1e-6 floor-free regime starts mattering (1e-9), and
/// one more to push every fine-resolution family into its floor.
const TOLS = [_]f64{ 1e-9, 1e-10 };

const usage_text =
    \\usage: csar-floor-survey [--batch=<name>] [--limit=<n>] [--csv=<path>]
    \\  --batch=<name>  run one batch (default: all of cases/batches.zig)
    \\  --limit=<n>     first n cells per batch (default: all)
    \\  --csv=<path>    write per-cell rows to <path>
    \\
;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());

    var filter: ?[]const u8 = null;
    var limit: usize = std.math.maxInt(usize);
    var csv_path: ?[]const u8 = null;
    for (argv[1..]) |arg| {
        if (std.mem.startsWith(u8, arg, "--batch=")) {
            filter = arg["--batch=".len..];
        } else if (std.mem.startsWith(u8, arg, "--limit=")) {
            limit = std.fmt.parseInt(usize, arg["--limit=".len..], 10) catch return badArg(arg);
        } else if (std.mem.startsWith(u8, arg, "--csv=")) {
            csv_path = arg["--csv=".len..];
        } else return badArg(arg);
    }

    if (csv_path) |path| {
        var file = try std.Io.Dir.cwd().createFile(init.io, path, .{ .truncate = true });
        defer file.close(init.io);
        var buf: [4096]u8 = undefined;
        var writer = file.writer(init.io, &buf);
        try run(allocator, filter, limit, &writer.interface);
        try writer.interface.flush();
    } else {
        try run(allocator, filter, limit, null);
    }
}

fn badArg(arg: []const u8) error{BadArgument} {
    std.debug.print("bad argument: {s}\n{s}", .{ arg, usage_text });
    return error.BadArgument;
}

/// Aggregate over every uncertified cell in the sweep — the numbers
/// the phase-2 decision reads directly. Counts only; docs/floor-survey.md
/// interprets.
const Verdict = struct {
    uncertified: u32 = 0,
    /// |gap_f128| <= the cell's gap_tol: the shipped iterate was
    /// already converged, invisible to the f64 evaluation.
    collapse_tol: u32 = 0,
    /// |gap_f128| <= the corpus pin (1e-6): would certify at the
    /// default tolerance under an f128 evaluation.
    collapse_pin: u32 = 0,
};

fn run(allocator: std.mem.Allocator, filter: ?[]const u8, limit: usize, csv: ?*std.Io.Writer) !void {
    if (csv) |w| try w.print("batch,gap_tol,cell,status,gap_shipped,gap_f64,gap_f128,diff,sigma_max,floor,diff_over_floor\n", .{});
    std.debug.print("floor survey: options = corpus pin except gap_tol; oracle f64/f128 per cell; d/f = |gap_f64 - gap_f128| / floor\n\n", .{});
    std.debug.print("{s:>7} {s:>6} | {s:>5} {s:>5} {s:>4} | {s:>9} {s:>9} {s:>9} | {s:>5} {s:>9} {s:>7}\n", .{
        "batch", "tol", "conv", "floor", "dnc", "d/f p50", "d/f p90", "d/f max", "unc", "f128<=tol", "<=1e-6",
    });

    var total: Verdict = .{};
    var matched = false;
    for (cases.batches.all) |entry| {
        if (filter) |f| if (!std.mem.eql(u8, entry.name, f)) continue;
        matched = true;
        for (TOLS) |gap_tol| try runBatch(allocator, entry, gap_tol, limit, csv, &total);
    }
    if (!matched) return badArg(filter.?);

    std.debug.print("\nuncertified cells {d}: below their gap_tol at f128 {d}; below the 1e-6 pin at f128 {d}; above gap_tol at f128 {d}\n", .{
        total.uncertified, total.collapse_tol, total.collapse_pin, total.uncertified - total.collapse_tol,
    });
}

const Status = enum { converged, precision_floor, did_not_converge };

/// One evaluated cell: the shipped gap, the outcome's sigma_max, and
/// the floor the diff is normalized by.
const Row = struct { status: Status, gap: f64, sigma_max: f64, floor: f64 };

fn runBatch(
    allocator: std.mem.Allocator,
    entry: cases.batches.Entry,
    gap_tol: f64,
    limit: usize,
    csv: ?*std.Io.Writer,
    total: *Verdict,
) !void {
    const cells = entry.batch.cells[0..@min(limit, entry.batch.cells.len)];
    var opts = cases.pin(csar.SolveOptions);
    opts.gap_tol = gap_tol;

    const ratios = try allocator.alloc(f64, cells.len);
    defer allocator.free(ratios);
    var n_ratio: usize = 0;
    var counts = std.enums.EnumArray(Status, u32).initFill(0);
    var v: Verdict = .{};

    for (cells, 0..) |cell, idx| {
        var outcome = try csar.solve(allocator, cell, opts);
        defer outcome.deinit();

        // A null means an empty-cert sentinel — nothing in the batch
        // corpus produces one (the survey measured zero, and every cell
        // converges at the corpus pin). Silently skipping would corrupt
        // the population, so a null is a loud failure of the run.
        const g64 = (try oracle.evalOutcome(f64, allocator, &outcome, cell)) orelse return error.SentinelOutcome;
        const g128 = (try oracle.evalOutcome(f128, allocator, &outcome, cell)) orelse return error.SentinelOutcome;

        const row: Row = switch (outcome) {
            .converged => |c| .{
                .status = .converged,
                .gap = c.gap,
                .sigma_max = c.sigma[2],
                .floor = try certFloor(allocator, cell, c.Q, c.sigma, c.cert),
            },
            // One arm: the survey measured zero did_not_converge cells
            // corpus-wide (the trust path's floor classifier catches every
            // tight-tolerance stall), so a dedicated arm would sit
            // permanently uncovered.
            .did_not_converge, .precision_floor => |u| .{
                .status = if (outcome == .precision_floor) .precision_floor else .did_not_converge,
                .gap = u.gap,
                .sigma_max = u.sigma[2],
                .floor = u.gap_floor,
            },
            // Feasibility is a property of the point set alone, and every
            // batch cell is a valid DGGS cell (batches.zig's contract).
            .infeasible => unreachable,
        };
        counts.getPtr(row.status).* += 1;

        const diff: f64 = @floatCast(@abs(@as(f128, g64) - g128));
        const ratio = diff / row.floor;
        ratios[n_ratio] = ratio;
        n_ratio += 1;

        if (row.status != .converged) {
            v.uncertified += 1;
            const a128: f64 = @floatCast(@abs(g128));
            if (a128 <= gap_tol) v.collapse_tol += 1;
            if (a128 <= cases.GAP_TOL) v.collapse_pin += 1;
        }

        if (csv) |w| try w.print("{s},{e},{d},{s},{e},{e},{e},{e},{e},{e},{e}\n", .{
            entry.name,                 gap_tol, idx,           @tagName(row.status), row.gap, g64,
            @as(f64, @floatCast(g128)), diff,    row.sigma_max, row.floor,            ratio,
        });
    }

    std.mem.sort(f64, ratios[0..n_ratio], {}, std.sort.asc(f64));
    const r = ratios[0..n_ratio];
    std.debug.print("{s:>7} {e:>6.0} | {d:>5} {d:>5} {d:>4} | {e:>9.2} {e:>9.2} {e:>9.2} | {d:>5} {d:>9} {d:>7}\n", .{
        entry.name,     gap_tol,      counts.get(.converged), counts.get(.precision_floor), counts.get(.did_not_converge),
        pct(r, 0.50),   pct(r, 0.90), pct(r, 1.0),            v.uncertified,                v.collapse_tol,
        v.collapse_pin,
    });

    total.uncertified += v.uncertified;
    total.collapse_tol += v.collapse_tol;
    total.collapse_pin += v.collapse_pin;
}

/// The floor model input for a converged outcome, rebuilt from what
/// ships: project the certificate's active points into the gnomonic
/// chart at the shipped axis, weight by normalized λ, and hand the
/// chart moments to `csar.gapFloor`. The inactive points' near-zero
/// weights perturb κ(M) negligibly, and gapFloor's κ term is
/// scale-invariant in λ — the boundary rescale washes out.
/// A chart-infeasible axis is impossible for a converged outcome
/// (every active point is strictly inside the shipped cone), so it
/// fails the run rather than skewing the population.
fn certFloor(allocator: std.mem.Allocator, X: []const [3]f64, Q: linalg.Mat3, sigma: [3]f64, cert: csar.Cert) !f64 {
    const k = cert.indices.len;
    const xa = try allocator.alloc(linalg.Vec3, k);
    defer allocator.free(xa);
    const w = try allocator.alloc(f64, k);
    defer allocator.free(w);
    var lam_sum: f64 = 0;
    for (cert.lambdas) |l| lam_sum += l;
    for (0..k) |i| {
        xa[i] = .{ .m = X[cert.indices[i]] };
        w[i] = cert.lambdas[i] / lam_sum;
    }

    const P_buf = try allocator.alloc([2]f64, k);
    defer allocator.free(P_buf);
    const Ps = try allocator.alloc([2]f64, k);
    defer allocator.free(Ps);
    const Q_tan: linalg.Mat3x2 = .{ .e1 = Q.col(1), .e2 = Q.col(2) };
    if (!halfspace.projectGnomonic(xa, Q.col(0), Q_tan, P_buf, 0)) return error.InfeasibleChart;
    const s_scale = core.rescaleP(P_buf, Ps);
    const moments = core.computeMoments(Ps, w, s_scale);
    return core.gapFloor(sigma[2], moments.M);
}

/// Nearest-rank percentile of an ascending-sorted, non-empty slice.
fn pct(sorted: []const f64, p: f64) f64 {
    std.debug.assert(sorted.len > 0);
    const last = sorted.len - 1;
    const i: usize = @intFromFloat(p * @as(f64, @floatFromInt(last)) + 0.5);
    return sorted[@min(i, last)];
}
