//! Minimum-volume ellipsoidal cone (spherical aspect ratio) solver.
//!
//! Shared solver core: preprocessing (Farkas halfspace check, optional
//! convex-hull reduction, coplanarity rejection), the gnomonic-chart MVEE
//! primitives (FW steps, damped axis step, Newton polish), and `solve`,
//! which dispatches to `trust.zig`. The moments / constructed-dual-
//! certificate slice is generic over T in gap_generic.zig and
//! re-exported here at f64 under the original names.
//!
//! Allocator convention:
//!   - solve() takes any std.mem.Allocator. The returned Info.cert lives on
//!     that allocator (caller frees via Info.deinit).
//!   - Internally, solve() wraps an ArenaAllocator over the caller's
//!     allocator for transient scratch (O(10) small+medium buffers per call);
//!     the arena's single deinit at function exit replaces per-buffer frees.
//!   - Recommended parent allocators:
//!       * Tests:      std.testing.allocator (leak detection on teardown)
//!       * Production: std.heap.smp_allocator (fast, thread-safe; beats
//!                     std.heap.c_allocator on this workload by ~1.5-3×
//!                     on mid-size cases due to arena-friendly growth)

const std = @import("std");

// ----------------------------------------------------------------
// Configuration
// ----------------------------------------------------------------

const config = @import("config.zig");
const algo = config.algo;
const tol = config.tol;
const SIGMA_0 = config.SIGMA_0;

const linalg = @import("linalg.zig");
const Vec2 = linalg.Vec2;
const Vec3 = linalg.Vec3;
const Mat2 = linalg.Mat2;
const Mat3 = linalg.Mat3;
const Mat3x2 = linalg.Mat3x2;
const eig2 = linalg.eig2;

// ----------------------------------------------------------------
// Geometric preprocessing (halfspaceCheck, convex hull, projection)
// ----------------------------------------------------------------

const halfspace = @import("halfspace.zig");
const HalfspaceResult = halfspace.HalfspaceResult;
const halfspaceCheck = halfspace.halfspaceCheck;
const convexHull2d = halfspace.convexHull2d;
const projectGnomonic = halfspace.projectGnomonic;

// Public API surface (types, methods, `checkFeasibility`) lives in
// `api.zig`. `solve` is defined below and constructs `api.Outcome`
// variants directly.
const api = @import("api.zig");
const Cert = api.Cert;
const Outcome = api.Outcome;
const SolveError = api.SolveError;
const InputError = api.InputError;
const SolveOptions = api.SolveOptions;

// ----------------------------------------------------------------
// The certificate slice — generic over T in gap_generic.zig; the f64
// instantiation re-exported here under the original names (aliases,
// not wrappers: identical code). See that file's header for the
// T-typed constants and branch-identity rules.
// ----------------------------------------------------------------

const gap64 = @import("gap_generic.zig").Gap(f64);
pub const rescaleP = gap64.rescaleP;
pub const Moments = gap64.Moments;
pub const computeMoments = gap64.computeMoments;
pub const recoverAPerp = gap64.recoverAPerp;
pub const GapScratch = gap64.GapScratch;
pub const GapResult = gap64.GapResult;
pub const dualityGapConstructed = gap64.dualityGapConstructed;

/// Feasibility-safeguarded b update, fused with the projection that the
/// next cycle will consume. The raw step b + α·Q·u can walk b out of the
/// cone {v : v·xᵢ > 0 ∀i}; once outside, projectGnomonic divides by a
/// negative b·xᵢ and the iteration locks onto a spurious cm=0 fixed
/// point (observed on ha_12 rotations). `projectGnomonic` short-circuits
/// on any violator, so each backtrack is one trial projection — on
/// acceptance the next cycle's P_buf/Ps/s_scale are already in place.
///
/// On full rejection, the last rejected trial partially overwrote
/// P_buf; restore it (and Ps/s_scale) against the input (b, Q) so the
/// caller's loop invariant still holds.
pub const BStep = struct { b: Vec3, Q: Mat3x2, s_scale: f64 };

pub fn acceptBUpdate(
    sp: halfspace.ShiftedPoints,
    b: Vec3,
    Q: Mat3x2,
    u: Vec2,
    alpha0: f64,
    P_buf: [][2]f64,
    Ps: [][2]f64,
) BStep {
    const dQc = Q.apply(u);
    var alpha_try: f64 = alpha0;
    var bt: u32 = 0;
    while (bt < algo.MAX_BACKTRACKS) : (bt += 1) {
        const b_trial = Vec3.lincomb(1.0, b, alpha_try, dQc).normalize();
        const Q_trial = b_trial.orthoBasis();
        if (projectGnomonic(sp, b_trial, Q_trial, P_buf, algo.FEAS_MARGIN)) {
            const s_scale = rescaleP(P_buf, Ps);
            return .{ .b = b_trial, .Q = Q_trial, .s_scale = s_scale };
        }
        alpha_try *= 0.5;
    }
    _ = projectGnomonic(sp, b, Q, P_buf, -std.math.inf(f64));
    const s_scale = rescaleP(P_buf, Ps);
    return .{ .b = b, .Q = Q, .s_scale = s_scale };
}

// ----------------------------------------------------------------
// MVEE inner: pairwise FW on lifted points [P; 1]
// ----------------------------------------------------------------

pub fn mveeFw(
    P: []const [2]f64,
    max_iter: u32,
    inner_tol: f64,
    Ql: []Vec3,
    w: []f64,
) void {
    for (P, 0..) |p, i| Ql[i] = .{ .m = .{ p[0], p[1], 1.0 } };

    var it: u32 = 0;
    while (it < max_iter) : (it += 1) {
        var S = Mat3.zero;
        // Inlined `addSymRank1` minus the mirror writes — we mirror
        // once after the loop instead of per-iteration. Shared
        // `wq_i = wi · qi.m[i]` precompute + chained @mulAdd: 3 muls
        // + 6 FMAs = 9 rounds per iter, vs the prior 12 muls + 6 adds
        // = 18 ops / 12 rounds. Multiplication order `(wi·qi_r)·qi_c`
        // preserved.
        for (Ql, 0..) |qi, i| {
            const wi = w[i];
            const wq0 = wi * qi.m[0];
            const wq1 = wi * qi.m[1];
            const wq2 = wi * qi.m[2];
            S.m[0] = @mulAdd(f64, wq0, qi.m[0], S.m[0]);
            S.m[1] = @mulAdd(f64, wq0, qi.m[1], S.m[1]);
            S.m[2] = @mulAdd(f64, wq0, qi.m[2], S.m[2]);
            S.m[4] = @mulAdd(f64, wq1, qi.m[1], S.m[4]);
            S.m[5] = @mulAdd(f64, wq1, qi.m[2], S.m[5]);
            S.m[8] = @mulAdd(f64, wq2, qi.m[2], S.m[8]);
        }
        S.m[3] = S.m[1];
        S.m[6] = S.m[2];
        S.m[7] = S.m[5];

        const L = S.cholesky() orelse break;

        var j_max: usize = 0;
        var j_min: ?usize = null;
        var g_max: f64 = -1e30;
        var g_min: f64 = 1e30;
        var x_min: Vec3 = undefined;
        for (Ql, 0..) |qi, i| {
            const x = L.solve(qi);
            const gi = qi.dot(x);
            if (gi > g_max) {
                g_max = gi;
                j_max = i;
            }
            if (w[i] > tol.WEIGHT_ACTIVE and gi < g_min) {
                g_min = gi;
                j_min = i;
                x_min = x;
            }
        }

        if (g_max - 3.0 < inner_tol) break;

        if (j_min) |jm| {
            if (jm != j_max) {
                const g_cross = Ql[j_max].dot(x_min);
                const a = g_max - g_min;
                const det_G = linalg.diff_of_products(g_max, g_min, g_cross, g_cross);
                var step: f64 = if (det_G > tol.NEAR_SING) a / (2.0 * det_G) else w[jm];
                if (step > w[jm]) step = w[jm];
                // Drop guard. A full-mass step (step = w[jm], zeroing the
                // donor) is only justified when it genuinely improves the
                // design. The exact log-det change of the rank-2 update
                // S' = S + γ(q_a·q_aᵀ − q_b·q_bᵀ) is available in closed
                // form from quantities already in hand:
                //   det S'/det S = (1 + γ·g_max)(1 − γ·g_min) + γ²·g_cross²
                // Take the drop only if that ratio exceeds 1 — a
                // threshold-free real-improvement test. Without it, the
                // near-singular fallback (and the cap when det_G is
                // small-but-positive under an anisotropic inner metric)
                // fires full drops on noise-level descent signals at
                // converged designs, zeroing support points that
                // newtonPolish cannot resurrect (its active set is
                // w-thresholded) — the hazard that bit the trust path's
                // oracle four times (docs/trust-solver.md). Interior
                // steps (step < w[jm]) are exact 1-D line-search optima
                // and need no guard. On a blocked drop, fall through to
                // the vanilla FW step below.
                var take = true;
                if (step == w[jm]) {
                    const ratio = (1.0 + step * g_max) * (1.0 - step * g_min) + step * step * g_cross * g_cross;
                    take = ratio > 1.0;
                }
                if (take) {
                    w[j_max] += step;
                    w[jm] -= step;
                    continue;
                }
            }
        }
        // Vanilla FW fallback.
        const step = (g_max - 3.0) / (3.0 * (g_max - 1.0));
        for (w) |*wi| wi.* *= (1.0 - step);
        w[j_max] += step;
    }
}

/// Noise-floor exit for `mveeFwAway`: stop when its optimality gap has
/// not improved by AWAY_GAP_IMPR within AWAY_STALL_ITERS iterations.
/// Local to the (unwired) experimental solver — deliberately NOT in
/// `config.algo`, which is the audited tuning surface for shipping
/// paths.
const AWAY_GAP_IMPR: f64 = 0.9;
const AWAY_STALL_ITERS: u32 = 24;

/// Away-step Frank–Wolfe for the lifted D-optimal design. NOT wired
/// into any solver path: it was stage 1 of docs/away-step-fw.md, tried
/// as the trust path's oracle and reverted (measurably slower than
/// pairwise on large near-circular supports — see the "Stage 1
/// findings" there). Kept in-tree for the record with a bit-rot guard
/// test in tests/methods_test.zig.
///
/// Same per-iteration quantities as `mveeFw` (gradients gᵢ = qᵢᵀS⁻¹qᵢ,
/// toward-vertex j_max, away-vertex j_min), different decision: pick
/// the direction with more first-order progress (toward: g_max − 3;
/// away: 3 − g_min) and take the EXACT 1-D line-search step of the
/// log-det objective along it:
///
///   toward  w ← (1−γ)w + γ·e_j,  γ* = (g−3)/(3(g−1)), capped at 1
///   away    w ← (1+γ)w − γ·e_j,  γ* = (3−g)/(3(g−1)), capped at
///           γmax = w[j]/(1−w[j]) — the drop boundary, where w[j]
///           hits exactly 0. For g ≤ 1 (deep interior point) the
///           objective is monotone along the away ray, so the full
///           drop is optimal.
///
/// Because the step length is proportional to the gap it closes, a
/// noise-level away gap produces a noise-level step — this solver
/// cannot fire the full-mass drop `mveeFw`'s near-singular pairwise
/// fallback takes on noise at converged designs (the hazard that bit
/// the trust path four times; see docs/trust-solver.md).
pub fn mveeFwAway(
    P: []const [2]f64,
    max_iter: u32,
    inner_tol: f64,
    Ql: []Vec3,
    w: []f64,
) void {
    for (P, 0..) |p, i| Ql[i] = .{ .m = .{ p[0], p[1], 1.0 } };

    var gap_best: f64 = std.math.inf(f64);
    var since_best: u32 = 0;
    var it: u32 = 0;
    while (it < max_iter) : (it += 1) {
        var S = Mat3.zero;
        for (Ql, 0..) |qi, i| {
            const wi = w[i];
            const wq0 = wi * qi.m[0];
            const wq1 = wi * qi.m[1];
            const wq2 = wi * qi.m[2];
            S.m[0] = @mulAdd(f64, wq0, qi.m[0], S.m[0]);
            S.m[1] = @mulAdd(f64, wq0, qi.m[1], S.m[1]);
            S.m[2] = @mulAdd(f64, wq0, qi.m[2], S.m[2]);
            S.m[4] = @mulAdd(f64, wq1, qi.m[1], S.m[4]);
            S.m[5] = @mulAdd(f64, wq1, qi.m[2], S.m[5]);
            S.m[8] = @mulAdd(f64, wq2, qi.m[2], S.m[8]);
        }
        S.m[3] = S.m[1];
        S.m[6] = S.m[2];
        S.m[7] = S.m[5];

        const L = S.cholesky() orelse break;

        var j_max: usize = 0;
        var j_min: ?usize = null;
        var g_max: f64 = -1e30;
        var g_min: f64 = 1e30;
        for (Ql, 0..) |qi, i| {
            const x = L.solve(qi);
            const gi = qi.dot(x);
            if (gi > g_max) {
                g_max = gi;
                j_max = i;
            }
            if (w[i] > tol.WEIGHT_ACTIVE and gi < g_min) {
                g_min = gi;
                j_min = i;
            }
        }

        const toward_gap = g_max - 3.0;
        const away_gap = if (j_min != null) 3.0 - g_min else -1e30;
        const gap = @max(toward_gap, away_gap);
        if (gap < inner_tol) break;
        // Noise-floor exit on the solver's OWN optimality measure: when
        // the gap stops improving geometrically it has hit the f64
        // floor for this input (κ-limited cells never reach any fixed
        // inner_tol) — stop instead of random-walking the budget away.
        // This replaces the caller-side burst/stall machinery: the gap
        // is a sound convergence signal; an h-sample window was a proxy
        // that misread slow-but-genuine descent phases as stalls.
        if (gap < AWAY_GAP_IMPR * gap_best) {
            gap_best = gap;
            since_best = 0;
        } else {
            since_best += 1;
            if (since_best >= AWAY_STALL_ITERS) break;
        }

        if (toward_gap >= away_gap) {
            const denom = 3.0 * (g_max - 1.0);
            if (denom < tol.NEAR_SING) break;
            var gamma = toward_gap / denom;
            if (gamma > 1.0) gamma = 1.0;
            for (w) |*wi| wi.* *= (1.0 - gamma);
            w[j_max] += gamma;
        } else {
            const jm = j_min.?;
            const one_minus = 1.0 - w[jm];
            if (one_minus < tol.NEAR_SING) break; // sole support point
            const gamma_max = w[jm] / one_minus;
            var gamma: f64 = gamma_max;
            if (g_min > 1.0 + tol.NEAR_SING) {
                const g_star = away_gap / (3.0 * (g_min - 1.0));
                if (g_star < gamma_max) gamma = g_star;
            }
            for (w) |*wi| wi.* *= (1.0 + gamma);
            w[jm] -= gamma;
            if (w[jm] < 0 or gamma == gamma_max) w[jm] = 0;
        }
    }
}

/// Uniform FW weights `w_i = 1/len`. The maximum-entropy start, optimal for
/// near-circular inputs whose enclosing ellipse touches every point.
fn uniformWeights(w: []f64) void {
    const inv = 1.0 / @as(f64, @floatFromInt(w.len));
    for (w) |*wi| wi.* = inv;
}

/// Sparse farthest-point seed of the FW weights: pick up to `k_req` well-spread
/// points and put weight 1/m on them (m = #picks), 0 elsewhere, so the inner FW
/// *grows* the support instead of *draining* a full active set. The first three
/// picks (farthest-from-centroid, farthest-from-that, farthest-from-their-line)
/// are non-collinear given a 2D-spanning scatter — guaranteed upstream by
/// `isCoplanarInput` — so the lifted [P;1] simplex is full rank and `mveeFw`'s
/// first Cholesky won't break. Falls back to uniform if the scatter is
/// degenerate. O(k·n), once. Gated on input size — see
/// `algo.SEED_SPARSE_MIN_POINTS` for the rationale and the a5_res0 story.
fn farthestPointSeed(P: []const [2]f64, w: []f64, k_req: usize) void {
    const max_seeds = 16; // buffer bound; k_req is small (algo.SEED_SPARSE_K = 5)
    const n = P.len;
    const k = @min(@min(k_req, n), max_seeds);
    var picks: [max_seeds]usize = undefined;

    // Centroid of P.
    var c = Vec2.zero;
    for (P) |p| c = c.add(.{ .m = p });
    c = c.scale(1.0 / @as(f64, @floatFromInt(n)));

    // pick0: farthest from centroid.
    var p0: usize = 0;
    var d0_max: f64 = -1;
    for (P, 0..) |p, i| {
        const d = (Vec2{ .m = p }).sub(c).norm();
        if (d > d0_max) {
            d0_max = d;
            p0 = i;
        }
    }
    if (d0_max < tol.TINY or k < 3) {
        uniformWeights(w); // degenerate (or tiny): nothing to seed
        return;
    }
    picks[0] = p0;

    // pick1: farthest from pick0.
    const a = Vec2{ .m = P[p0] };
    var p1: usize = p0;
    var d1_max: f64 = -1;
    for (P, 0..) |p, i| {
        const d = (Vec2{ .m = p }).sub(a).norm();
        if (d > d1_max) {
            d1_max = d;
            p1 = i;
        }
    }
    picks[1] = p1;

    // pick2: farthest (perpendicular) from the line pick0–pick1. The divisor
    // ‖b−a‖ is constant over i, so maximizing |cross| suffices.
    const bma = (Vec2{ .m = P[p1] }).sub(a);
    var p2: usize = p0;
    var cr_max: f64 = -1;
    for (P, 0..) |p, i| {
        const pma = (Vec2{ .m = p }).sub(a);
        const cr = @abs(linalg.diff_of_products(bma.m[0], pma.m[1], bma.m[1], pma.m[0]));
        if (cr > cr_max) {
            cr_max = cr;
            p2 = i;
        }
    }
    picks[2] = p2;

    // Remaining picks: farthest-from-the-chosen-set (max-min distance).
    // When every remaining point coincides with a pick (fewer distinct
    // positions than k — possible with hull preprocessing disabled),
    // best_mindist stays 0 and the argmax would re-pick an already
    // chosen index; stop with the m distinct picks found instead
    // (a duplicated index would silently collapse two weight shares
    // and seed Σw < 1, which FW's pairwise steps and Newton's KKT
    // both conserve — measured as a hard DNC on a trivial input).
    var m: usize = 3;
    while (m < k) : (m += 1) {
        var best: usize = 0;
        var best_mindist: f64 = -1;
        for (P, 0..) |p, i| {
            const pv = Vec2{ .m = p };
            var mindist: f64 = std.math.inf(f64);
            for (0..m) |j| {
                const d = pv.sub(.{ .m = P[picks[j]] }).norm();
                if (d < mindist) mindist = d;
            }
            if (mindist > best_mindist) {
                best_mindist = mindist;
                best = i;
            }
        }
        if (!(best_mindist > 0)) break;
        picks[m] = best;
    }

    // Weights: 1/m on the picks, 0 elsewhere. `+=` (not `=`) so the
    // invariant Σw = 1 survives even if a duplicate pick ever slips
    // through — two shares then land on one point instead of one
    // share evaporating.
    for (w) |*wi| wi.* = 0;
    const wval = 1.0 / @as(f64, @floatFromInt(m));
    for (0..m) |j| w[picks[j]] += wval;
}

/// Initialize the inner-FW weight vector, choosing the regime by working-set
/// size: large/dense inputs get a sparse farthest-point seed (so FW grows the
/// support instead of draining it — the a5_res0 DNC fix, also faster on genuine
/// medium/large inputs); small inputs get the uniform start (already optimal for
/// near-circular cells, where a sparse seed would break symmetry and slow them).
/// `P` and `w` index the same working set. See `algo.SEED_SPARSE_MIN_POINTS`.
pub fn initWeights(P: []const [2]f64, w: []f64) void {
    if (P.len > algo.SEED_SPARSE_MIN_POINTS) {
        farthestPointSeed(P, w, algo.SEED_SPARSE_K);
    } else {
        uniformWeights(w);
    }
}

// ----------------------------------------------------------------
// Newton polish (extracted to newton.zig)
// ----------------------------------------------------------------

const newton = @import("newton.zig");
const NewtonScratch = newton.NewtonScratch;
const newtonPolish = newton.newtonPolish;

// The solver (`trust.solveTrust`).
const trust = @import("trust.zig");

// ----------------------------------------------------------------
// Preprocessing helpers used by `solve`
// ----------------------------------------------------------------

/// Build the infeasibility certificate from the halfspace result.
/// Keeps only the nonzero (above-threshold) λ entries with their
/// original indices. The witness magnitude ‖Σ λᵢ xᵢ‖ lives on the
/// enclosing `Infeasible` variant as `residual`, not on the cert.
fn buildFarkasCert(allocator: std.mem.Allocator, hs: HalfspaceResult) !Cert {
    var k: u32 = 0;
    for (hs.lam) |l| if (l > algo.ACTIVE_THRESH) {
        k += 1;
    };
    const indices = try allocator.alloc(u32, k);
    errdefer allocator.free(indices);
    const lambdas = try allocator.alloc(f64, k);
    var j: u32 = 0;
    for (hs.lam, 0..) |l, i| {
        if (l > algo.ACTIVE_THRESH) {
            indices[j] = @intCast(i);
            lambdas[j] = l;
            j += 1;
        }
    }
    return .{ .indices = indices, .lambdas = lambdas };
}

/// Build the active-set certificate for a converged (or DNC-best-effort)
/// solve. Translates work-set indices back to the caller's original
/// `X[]` indexing via `work_to_orig` (`null` when no hull reduction
/// happened). The scalar quality measurement (the `gap` field) lives
/// on the enclosing variant.
fn buildPrimalCert(
    allocator: std.mem.Allocator,
    cert_active: []const usize,
    cert_lambdas: []const f64,
    cert_n: usize,
    work_to_orig: ?[]const u32,
) !Cert {
    const indices = try allocator.alloc(u32, cert_n);
    errdefer allocator.free(indices);
    const lambdas = try allocator.alloc(f64, cert_n);
    for (0..cert_n) |i| {
        const idx_in_work = cert_active[i];
        indices[i] = if (work_to_orig) |wto| wto[idx_in_work] else @intCast(idx_in_work);
        lambdas[i] = cert_lambdas[i];
    }
    return .{ .indices = indices, .lambdas = lambdas };
}

const HullResult = struct {
    /// The working point set the solver should iterate on. Either the hull
    /// subset (when reduction fired) or the original input (when disabled,
    /// skipped, or the hull collapsed to < 3 vertices).
    Xw: []const Vec3,
    /// Indices into the original X[] for each point in Xw. `null` when no
    /// reduction was performed (Xw == Xv); the solver uses the identity
    /// mapping in that case.
    work_to_orig: ?[]const u32,
};

/// Optional convex-hull preprocessing. If `n_hull >= 0` and there are more
/// than `n_hull` points, project to the tangent plane at b, run Andrew's
/// monotone chain, and keep only the hull vertices. Falls back to the
/// original input on disable, small n, or hull-collapse (< 3 vertices).
fn hullPreprocess(
    scratch: std.mem.Allocator,
    Xv: []const Vec3,
    b: Vec3,
    n_hull: i32,
) !HullResult {
    var result = HullResult{ .Xw = Xv, .work_to_orig = null };
    if (n_hull < 0 or Xv.len <= @as(usize, @intCast(n_hull))) return result;

    const Qh = b.orthoBasis();
    const P2 = try scratch.alloc([2]f64, Xv.len);
    for (Xv, 0..) |xi, i| {
        P2[i] = Qh.applyT(xi).m;
    }
    // 2·n: Andrew's monotone chain uses `hull_idx` as scratch for the
    // lower and upper passes; on inputs where most points are on the
    // hull (e.g. equispaced on a circle), both passes can write up to
    // n entries before the final dedup. Allocating only n overflows.
    const hull_idx = try scratch.alloc(u32, 2 * Xv.len);
    const nh = try convexHull2d(scratch, P2, hull_idx);
    if (nh >= 3) {
        const Xhull = try scratch.alloc(Vec3, nh);
        for (0..nh) |i| Xhull[i] = Xv[hull_idx[i]];
        result.Xw = Xhull;
        result.work_to_orig = hull_idx[0..nh];
    }
    return result;
}

/// True iff the points lie (approximately) in a 2D subspace through the
/// origin — i.e., on a single great circle. Projects to the tangent plane
/// at b and tests the 2×2 centered scatter via `4·det(C) < tol · trace(C)²`.
/// That's the cancellation-safe form of `λ_min/λ_max` for ill-conditioned C
/// (the literal `(T − √(T² − 4D))/2` form loses precision exactly where the
/// check needs to fire). Scale-invariant "fraction of isotropic" ∈ [0, 1]:
/// 1 for a circular scatter, → 0 for a perfect line. Tight clusters on the
/// sphere (e.g. H3 res-15) have full-rank 2D scatter regardless of absolute
/// scale, so this correctly distinguishes them from genuinely rank-deficient
/// input.
///
/// Implementation: two-pass accumulator. Pass 1 computes the mean; pass 2
/// accumulates squared deviations from the mean. The textbook one-pass form
/// (`Σx² − (Σx)²/n`) is cancellation-prone when the projection cluster sits
/// far from the tangent-plane origin (mean comparable in magnitude to spread).
/// Two-pass avoids the subtraction entirely — each deviation term is small
/// and non-negative, so `tr ≥ 0` is structural rather than a roundoff
/// coincidence.
fn isCoplanarInput(points: []const Vec3, b: Vec3, threshold: f64) bool {
    const Qh = b.orthoBasis();

    // Pass 1: mean of the 2D projections.
    var ps0: f64 = 0;
    var ps1: f64 = 0;
    for (points) |xi| {
        const p = Qh.applyT(xi);
        ps0 += p.m[0];
        ps1 += p.m[1];
    }
    const inv_n = 1.0 / @as(f64, @floatFromInt(points.len));
    const m0 = ps0 * inv_n;
    const m1 = ps1 * inv_n;

    // Pass 2: squared deviations from mean — no cancellation.
    var c00: f64 = 0;
    var c01: f64 = 0;
    var c11: f64 = 0;
    for (points) |xi| {
        const p = Qh.applyT(xi);
        const d0 = p.m[0] - m0;
        const d1 = p.m[1] - m1;
        c00 += d0 * d0;
        c01 += d0 * d1;
        c11 += d1 * d1;
    }

    const tr = c00 + c11;
    const det = linalg.diff_of_products(c00, c11, c01, c01);
    return tr <= 0 or 4.0 * det < threshold * tr * tr;
}

/// Preprocessed problem handed to the solver: a strictly feasible
/// axis, the (possibly hull-reduced) working point set, and the map
/// back to the caller's original indices (`null` = identity).
pub const Prep = struct {
    b0: Vec3,
    Xw: []const Vec3,
    work_to_orig: ?[]const u32,
};

const PrepResult = union(enum) {
    /// Input is infeasible; carries the ready-to-return outcome
    /// (Farkas certificate already on the parent allocator).
    infeasible: Outcome,
    ready: Prep,
};

/// Everything before the solver: input validation, Farkas
/// feasibility check, optional hull reduction, coplanarity rejection.
/// `scratch_alloc` backs `Xw`/`work_to_orig` (arena, freed by `solve`);
/// `allocator` backs the Farkas cert on the infeasible branch.
fn preprocess(
    scratch_alloc: std.mem.Allocator,
    allocator: std.mem.Allocator,
    Xv: []const Vec3,
    opts: SolveOptions,
) !PrepResult {
    // 0) Input validation. Catch malformed caller inputs at the boundary
    //    so they propagate as typed errors instead of slipping into the
    //    algorithm where they manifest as NaN-tainted statuses or silent
    //    perf cliffs. See the InputError doc-comments in api.zig for the
    //    contract on each tolerance.
    if (Xv.len < 3) return InputError.InsufficientPoints;
    if (!std.math.isFinite(opts.gap_tol) or opts.gap_tol <= 0 or opts.gap_tol >= tol.GAP_UNCERTIFIED) return InputError.InvalidTolerance;
    // Non-finite coplanarity_tol violates the InvalidTolerance
    // contract ("not finite, or invalid sign"): +inf would reject
    // every input as CoplanarInput (the check's RHS becomes inf).
    // Negative-finite stays legal — it opts out of the near-coplanar
    // rejection.
    if (!std.math.isFinite(opts.coplanarity_tol)) return InputError.InvalidTolerance;

    // 1) Feasibility via Farkas FW.
    const hs = try halfspaceCheck(scratch_alloc, Xv);
    var b: Vec3 = undefined;
    if (hs.b) |bb| {
        b = bb;
    } else {
        // Infeasible: Farkas cert lives on the parent allocator since it's
        // returned to the caller.
        const farkas = try buildFarkasCert(allocator, hs);
        return .{ .infeasible = .{ .infeasible = .{
            .cert = farkas,
            .residual = hs.residual,
            .allocator = allocator,
        } } };
    }

    // 2) Optional hull preprocessing.
    const hp = try hullPreprocess(scratch_alloc, Xv, b, opts.n_hull);

    // 2.5) Coplanarity check on the hulled subset — an input whose hull is
    //      collinear in the tangent plane drives the SDP to a degenerate
    //      cone (one tangent eigenvalue → 0) and produces NaN downstream.
    //      Signaled as `InputError.CoplanarInput`, symmetric with
    //      `InsufficientPoints` — both are "X is structurally bad."
    //      `coplanarity_tol <= 0` opts out of the NEAR-coplanar
    //      rejection only: exactly rank-deficient input is always
    //      rejected (tol.COPLANAR_FLOOR) — there is no meaningful
    //      answer for it, and letting it through surfaced an internal
    //      error mislabeled as a library bug.
    const cop_tol = if (opts.coplanarity_tol > 0) opts.coplanarity_tol else tol.COPLANAR_FLOOR;
    if (isCoplanarInput(hp.Xw, b, cop_tol)) {
        return InputError.CoplanarInput;
    }

    return .{ .ready = .{ .b0 = b, .Xw = hp.Xw, .work_to_orig = hp.work_to_orig } };
}

/// Classify a freshly computed certificate gap: true when the solve is
/// converged at `gap_tol`, false for "no certificate this time" — the
/// caller iterates on or reports an uncertified outcome. A negative gap is
/// never an error here: weak duality holds in exact arithmetic, so a
/// negative value is floating-point error (`gapFloor`), and the accept
/// test runs first so a converged-at-noise gap (−5e-9 on H3 r15 cells)
/// certifies.
pub fn gapConverged(gap: f64, gap_tol: f64) bool {
    // The no-certificate sentinel is not a measured gap and must never
    // certify, no matter how loose gap_tol is (validation additionally
    // caps gap_tol below it, so this guard is belt-and-braces).
    if (gap >= tol.GAP_UNCERTIFIED) return false;
    return @abs(gap) <= gap_tol;
}

/// The error model: how far below zero a valid certificate's computed
/// gap can fall at this precision, for this geometry. Two measured
/// sources, with coefficients in units of ε so a higher-precision
/// instantiation need only supply its own `floatEps` and κ:
///   - evaluating the gap costs ≈ σ_max·ε (4–7× measured; the factor
///     `tol.NEG_GAP_SIGMA` = 64 gives headroom);
///   - the certificate's A_perp is feasible only to κ(M)·ε, the error
///     in forming M^{-1/2} (0.03× measured; coefficient 1).
/// A logic error in the duality code violates this by orders of
/// magnitude (inflating A by 0.1% moves the gap ~10⁴× the bound:
/// `tests/neg_gap_test.zig`). A gap inside the bound is reported as
/// `.precision_floor`; one beyond it trips the Debug assert in
/// `trust.certify` and counts in `TrustDiagnostics.gaps_below_model`.
pub fn gapFloor(sigma_max: f64, M: Mat2) f64 {
    const e = eig2(M.m).vals;
    const kappa = e[1] / e[0];
    return (tol.NEG_GAP_SIGMA * sigma_max + kappa) * std.math.floatEps(f64);
}

/// The bug detector: true when a certificate's gap is negative beyond
/// both the tolerance and the error model — impossible for a valid
/// certificate.
pub fn gapBelowModel(r: GapResult, M: Mat2, gap_tol: f64) bool {
    // The common path ends here; the model's eig2 runs only on the rare
    // negative-beyond-tolerance branch.
    if (r.gap >= -gap_tol) return false;
    return r.gap < -gapFloor(r.sigma[1], M);
}

/// The last certificate, as one consistent snapshot: the gap, the chart
/// moment matrix it was built from (the error model's κ input), and the
/// axis. A solver's certification sites write it whole — TR-loop
/// certification is gated on pred and the RECERT loop can be
/// budget-skipped, so on an uncertified outcome the final axis may be
/// several accepted steps past this one.
pub const LastCert = struct { gap: GapResult, M: Mat2, b: Vec3 };

/// Bundle the final outcome: translate the work-set certificate back to
/// caller indices, bundle the full
/// eigendecomposition (Q's columns are (b, v1, v2) with eigenvalues
/// (SIGMA_0, sigma[0], sigma[1]); v2 flipped if needed so det Q = +1),
/// and wrap as `converged`, or `did_not_converge` / `precision_floor`.
/// `last` is one snapshot by construction (see `LastCert`): Q's
/// orthonormality (and the meaning of gap/sigma) depends on v1/v2
/// being tangent to the exact axis the gap was computed at.
pub fn buildOutcome(
    allocator: std.mem.Allocator,
    converged: bool,
    last: LastCert,
    diag: api.Diagnostics,
    cert_active: []const usize,
    cert_lambdas: []const f64,
    work_to_orig: ?[]const u32,
    gap_tol: f64,
) !Outcome {
    const last_gap = last.gap;
    const b = last.b;
    const cert = try buildPrimalCert(allocator, cert_active, cert_lambdas, last_gap.cert_n, work_to_orig);

    var v1 = last_gap.v1;
    var v2 = last_gap.v2;
    if (v1.cross(v2).dot(b) < 0) v2 = v2.scale(-1.0);
    const Qmat = Mat3.fromCols(b, v1, v2);
    const sigma: [3]f64 = .{ SIGMA_0, last_gap.sigma[0], last_gap.sigma[1] };

    if (converged) {
        return .{ .converged = .{
            .Q = Qmat,
            .sigma = sigma,
            .gap = last_gap.gap,
            .diag = diag,
            .cert = cert,
            .allocator = allocator,
        } };
    } else {
        // Evaluated here, off the converged path. `.precision_floor`
        // needs both halves: the tolerance is below the floor AND the
        // iterate actually reached the floor — a solve that ran out of
        // budget far from optimum (or never built a certificate: the
        // sentinel) is `.did_not_converge` whatever the tolerance.
        const gap_floor = gapFloor(last_gap.sigma[1], last.M);
        const at_floor = gap_tol < gap_floor and @abs(last_gap.gap) <= gap_floor;
        const payload: api.Uncertified = .{
            .Q = Qmat,
            .sigma = sigma,
            .gap = last_gap.gap,
            .gap_floor = gap_floor,
            .diag = diag,
            .cert = cert,
            .allocator = allocator,
        };
        return if (at_floor) .{ .precision_floor = payload } else .{ .did_not_converge = payload };
    }
}

/// Main solver. Returns an `Outcome` tagged union — switch on the tag
/// to dispatch (`converged` carries the cone's eigendecomposition +
/// primal certificate; `infeasible` carries the Farkas certificate;
/// `did_not_converge` / `precision_floor` carry the last iterate for
/// diagnostics).
/// Structural input problems (too few points, bad tolerance,
/// rank-deficient X) propagate as `InputError` via `try`. `opts`
/// controls convergence, preprocessing, validation, and solver-path
/// knobs — see `SolveOptions` for per-field docs and defaults.
///
/// Preprocessing (validation, Farkas feasibility, hull reduction,
/// coplanarity rejection) is shared; `opts.method` selects the solver
/// that runs on the preprocessed working set (see `api.Method`; today
/// only `.trust`).
pub fn solve(
    allocator: std.mem.Allocator,
    X: []const [3]f64,
    opts: SolveOptions,
) !Outcome {
    // Arena for all transient scratch allocations in this solve call.
    // Single backing alloc (bumped) + single free-all on deinit — vastly
    // cheaper than per-buffer alloc/free. The returned cert (for the
    // Converged / Infeasible / Uncertified variants) lives on the
    // parent `allocator` so it outlives the arena.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch_alloc = arena.allocator();

    // Cast once: Vec3 is an extern struct over [3]f64, so layout is shared.
    // All internal routines work in []const Vec3.
    const Xv: []const Vec3 = @ptrCast(X);

    const prep = switch (try preprocess(scratch_alloc, allocator, Xv, opts)) {
        .infeasible => |outcome| return outcome,
        .ready => |p| p,
    };

    switch (opts.method.resolved()) {
        .trust => return trust.solveTrust(allocator, scratch_alloc, prep, opts),
    }
}
