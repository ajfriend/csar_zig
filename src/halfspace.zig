//! Geometric preprocessing for the solver:
//!
//! - `halfspaceCheck`: Frank-Wolfe pairwise on the convex hull of the
//!   input points to find a feasible cone axis `b` (or a Farkas
//!   certificate of infeasibility).
//! - `convexHull2d`: Andrew's monotone chain over 2D-projected points,
//!   used to reduce large inputs to their hull boundary.
//! - `shiftPoints` + `projectGnomonic`: shift-then-project
//!   tangent-plane projection at a feasible axis.
//!
//! All of them operate on linear-algebra primitives from `linalg.zig`
//! and read tolerances/constants from `config.zig`. None of them
//! capture solver outer-loop state, so they can live cleanly outside
//! `csar.zig`.

const std = @import("std");
const linalg = @import("linalg.zig");
const config = @import("config.zig");

const Vec3 = linalg.Vec3;
const Mat3x2 = linalg.Mat3x2;
const tol = config.tol;

pub const HalfspaceResult = struct {
    /// If found: unit vector b with x_i · b > 0 for all i.
    b: ?Vec3,
    /// If infeasible: lambda weights on the input points (λ ≥ 0, ∑ λ = 1).
    lam: []f64,
    /// ‖∑ λᵢ xᵢ‖ — small = sharp Farkas certificate; large = FW stalled.
    residual: f64,
};

pub fn halfspaceCheck(allocator: std.mem.Allocator, X: []const Vec3) !HalfspaceResult {
    const n = X.len;
    var z = Vec3.zero;
    for (X) |xi| z = z.add(xi);
    z = z.scale(1.0 / @as(f64, @floatFromInt(n)));

    const lam = try allocator.alloc(f64, n);
    errdefer allocator.free(lam);
    for (lam) |*l| l.* = 1.0 / @as(f64, @floatFromInt(n));

    var b_out: ?Vec3 = null;

    // Iteration cap is a stall backstop only; the intended exits are
    // the all-positive witness (feasible) and the z-exhaustion floor
    // (infeasible or margin below ~1e-8 — see tol.FW_Z_EXHAUSTED).
    // Sized so small-margin feasible inputs (m just above 1e-8, where
    // the witness dots xᵢ·z ~ m² sit barely above noise) have room to
    // converge in direction before the backstop fires.
    var it: u32 = 0;
    while (it < 5000) : (it += 1) {
        var j: usize = 0;
        var k: ?usize = null;
        var g_min: f64 = 1e30;
        var g_max_active: f64 = -1e30;
        var all_positive = true;

        for (X, 0..) |xi, i| {
            const gi = xi.dot(z);
            if (gi <= 0) all_positive = false;
            if (gi < g_min) {
                g_min = gi;
                j = i;
            }
            if (lam[i] > tol.WEIGHT_ACTIVE and gi > g_max_active) {
                g_max_active = gi;
                k = i;
            }
        }

        if (all_positive) {
            const nz = z.norm();
            if (nz > tol.NEAR_SING) {
                b_out = z.scale(1.0 / nz);
            }
            break;
        }
        if (z.dot(z) < tol.FW_Z_EXHAUSTED) break;
        const ki = k orelse break;
        if (ki == j) break;

        const w = X[j].sub(X[ki]);
        const ww = w.dot(w);
        if (ww < tol.TINY) break;

        var gamma = -w.dot(z) / ww;
        if (gamma < 0) gamma = 0;
        if (gamma > lam[ki]) gamma = lam[ki];

        lam[j] += gamma;
        lam[ki] -= gamma;
        z = Vec3.lincomb(1.0, z, gamma, w);
    }

    return .{ .b = b_out, .lam = lam, .residual = z.norm() };
}

// ---- 2D convex hull (Andrew's monotone chain) ----

fn cross2(O: [2]f64, A: [2]f64, B: [2]f64) f64 {
    const ax = A[0] - O[0];
    const ay = A[1] - O[1];
    const bx = B[0] - O[0];
    const by = B[1] - O[1];
    return linalg.diff_of_products(ax, by, ay, bx);
}

const HullCtx = struct {
    P: []const [2]f64,
    pub fn lessThan(ctx: HullCtx, a: u32, b: u32) bool {
        const pa = ctx.P[a];
        const pb = ctx.P[b];
        if (pa[0] != pb[0]) return pa[0] < pb[0];
        return pa[1] < pb[1];
    }
};

/// Andrew's monotone-chain convex hull on `P`. Writes the hull
/// vertices (as indices into `P`) into `hull_idx[0..return_value]`.
///
/// PRECONDITION: `hull_idx.len >= 2 * P.len`. The buffer is used as
/// scratch during construction — lower and upper hull passes can
/// each fill up to `P.len` entries before the trailing dedup. On
/// inputs where most points lie on the hull (e.g. points on a
/// circle), an `hull_idx.len == P.len` buffer overflows.
pub fn convexHull2d(allocator: std.mem.Allocator, P: []const [2]f64, hull_idx: []u32) !u32 {
    const n = @as(u32, @intCast(P.len));
    const idx = try allocator.alloc(u32, n);
    defer allocator.free(idx);
    for (0..n) |i| idx[i] = @intCast(i);

    std.mem.sort(u32, idx, HullCtx{ .P = P }, HullCtx.lessThan);

    var h: u32 = 0;
    for (0..n) |i| {
        while (h >= 2 and cross2(P[hull_idx[h - 2]], P[hull_idx[h - 1]], P[idx[i]]) <= 0) h -= 1;
        hull_idx[h] = idx[i];
        h += 1;
    }
    const lower_size = h + 1;
    var i: isize = @as(isize, @intCast(n)) - 2;
    while (i >= 0) : (i -= 1) {
        while (h >= lower_size and cross2(P[hull_idx[h - 2]], P[hull_idx[h - 1]], P[idx[@intCast(i)]]) <= 0) h -= 1;
        hull_idx[h] = idx[@intCast(i)];
        h += 1;
    }
    h -= 1;
    return h;
}

/// Gnomonic projection over the scalar `T` (qualified inner names, so
/// no split file is needed; if #9 phase 2 genericizes the rest of this
/// file, it splits the way linalg did).
pub fn Gnomonic(comptime T: type) type {
    const la = linalg.Linalg(T);
    return struct {
        const Self = @This();

        /// The reference point `c = X[0]` and the differences
        /// `dᵢ = xᵢ − c` — axis-independent, so `shiftPoints` runs
        /// once per point set and every projection at every trial
        /// axis reuses them (the split's numerics: `projectGnomonic`).
        pub const ShiftedPoints = struct { c: la.Vec3, d: []const la.Vec3 };

        /// Fill `d[0..X.len]` with `xᵢ − X[0]` and return the view.
        /// `X` must be non-empty — a caller with possibly-empty input
        /// owns that case (`cert_primal`'s `empty_support`).
        pub fn shiftPoints(X: []const la.Vec3, d: []la.Vec3) Self.ShiftedPoints {
            const c = X[0];
            for (X, 0..) |xi, i| d[i] = xi.sub(c);
            return .{ .c = c, .d = d[0..X.len] };
        }

        /// Projection is well-defined iff every `b·xᵢ ≥ feas_margin`.
        /// Returns `false` and short-circuits on the first violator;
        /// the trailing `P[i..]` is left unspecified. Callers that
        /// already know feasibility (e.g. post-`halfspaceCheck` initial
        /// projection) can pass −inf to bypass the check.
        ///
        /// Shift-then-project (roadmap item 11): each dot is split
        /// through the reference point — `Qᵀxᵢ = Qᵀc + Qᵀdᵢ`. For a
        /// clustered cell the dᵢ are O(θ) and subtract exactly
        /// (Sterbenz), so `Qᵀdᵢ` carries relative-ε error where the
        /// direct `Qᵀxᵢ` — an O(1) dot cancelling to a θ-sized result —
        /// carries absolute-ε (relative ε/θ, the gapFloor σ_max·ε
        /// term's source). The remaining absolute-ε error in `Qᵀc` is
        /// common to every point: a translation of the chart cloud,
        /// invisible to the MVEE's shape. For non-clustered inputs the
        /// split is mathematically identical and costs one extra
        /// rounding — nothing is lost. The gap evaluation carries its
        /// own copy of this split at the certificate's eigenbasis, with
        /// the reference dots compensated (`gapFromMultipliers`,
        /// gap_generic.zig) — amend both together.
        pub fn projectGnomonic(sp: Self.ShiftedPoints, b: la.Vec3, Q: la.Mat3x2, P: [][2]T, feas_margin: T) bool {
            const qc = Q.applyT(sp.c);
            const bc = b.dot(sp.c);
            for (sp.d, 0..) |di, i| {
                const ci = bc + b.dot(di);
                if (ci < feas_margin) return false;
                const p = la.Vec2.add(qc, Q.applyT(di));
                P[i] = .{ p.m[0] / ci, p.m[1] / ci };
            }
            return true;
        }
    };
}
pub const ShiftedPoints = Gnomonic(f64).ShiftedPoints;
pub const shiftPoints = Gnomonic(f64).shiftPoints;
pub const projectGnomonic = Gnomonic(f64).projectGnomonic;
