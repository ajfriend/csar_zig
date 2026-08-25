//! Certify and verify (A, b) cone candidates from any source.
//!
//! The solver certifies its own iterates inside the solve loop
//! (`dualityGapConstructed`, csar.zig); this module makes the same
//! certificate math reachable for a candidate produced elsewhere — a
//! generic conic solver, a shipped certificate being re-checked, a
//! hand-constructed cone. Two entry points, one core: `certify`
//! manufactures a certificate for a cone ("how good is this cone?"),
//! `verify` checks a supplied one ("does this certificate check
//! out?") — and `certify` funnels through `verify`, so its output is
//! checked by the identical path a third party would run.
//!
//! Both are total: every input yields a payload or an enumerated
//! `no_certificate` reason — never an error (`certify` can also fail
//! on allocation). Both repair rather than reject, by one mechanism
//! per side, applied unconditionally: a uniform primal rescale onto
//! containment-tightness (`Verified.scale`) and a dual rescale onto
//! the normalized dual's constraint boundary (`Verified.dual_scale`).
//! The reported gap is the solver's own closed form against the
//! normalized dual (the gap comment in `dualityGapConstructed`), plus
//! the primal repair's 3·log s charge.

const std = @import("std");

const linalg = @import("linalg.zig");
const Vec3 = linalg.Vec3;
const Mat3 = linalg.Mat3;

const config = @import("config.zig");
const algo = config.algo;
const tol = config.tol;

const core = @import("csar.zig");
const halfspace = @import("halfspace.zig");
const api = @import("api.zig");
const Cert = api.Cert;

/// Why no certificate could be produced. Every reason is a statement
/// about the input, not a solver failure: the candidate (or its
/// multipliers) sits outside the domain where the bound is defined.
pub const Reason = enum {
    /// A failed Cholesky: not (numerically) positive definite. The
    /// primal objective −log det A needs A ≻ 0.
    not_psd,
    /// b is (numerically) zero, or some b·xᵢ ≤ 0: no open hemisphere
    /// around the axis contains the points, so containment
    /// ‖Axᵢ‖ ≤ b·xᵢ cannot hold for any scaling.
    axis_not_interior,
    /// No strictly positive multiplier: the zero dual point proves
    /// nothing (log det 0 = −∞).
    empty_support,
    /// Z = ½(XΓᵀ + ΓXᵀ) is not (numerically) positive definite, so
    /// log det Z is undefined. For constructed multipliers this means
    /// the support is too thin to pin a full-rank dual (fewer than
    /// three effective points); a foreign λ can land here for any
    /// reason. Skipping such points is the same guard the solver
    /// applies to its own iterates.
    dual_indefinite,
};

/// A checked certificate: the bound `lambda` proves for the repaired
/// candidate. All values refer to the repaired pair — A/`scale` on the
/// primal side, `dual_scale`·λ on the dual side — and
/// `gap = primal − dual` by construction.
pub const Verified = struct {
    /// Certified duality gap of the repaired pair: primal − dual ≥ 0
    /// up to f64 roundoff (weak duality).
    gap: f64,
    /// Primal objective of the repaired candidate:
    /// −log det(A/scale) = −log det A + 3·log scale.
    primal: f64,
    /// Dual objective of the boundary-rescaled multipliers — a valid
    /// lower bound on the problem's optimal value p*.
    dual: f64,
    /// Primal repair factor s = max_i ‖A xᵢ‖ / (b·xᵢ): the certified
    /// cone is (A/s, b). s > 1 means the candidate violated
    /// containment (charged 3·log s); s < 1 means it was strictly
    /// interior (tightened for free).
    scale: f64,
    /// Dual repair factor 3/‖Xλ‖: `dual_scale`·λ is the
    /// boundary-normalized multiplier vector the bound is stated for.
    dual_scale: f64,
};

pub const VerifyOutcome = union(enum) {
    verified: Verified,
    no_certificate: Reason,
};

/// A manufactured certificate: `verify`'s payload plus the multipliers
/// `certify` derived, exported boundary-normalized (‖Σᵢ λᵢxᵢ‖₂ = 3, the
/// same invariant as a solver-shipped `Cert` — see api.zig) so `verify`
/// accepts them without repair.
pub const Certified = struct {
    // Scalars as in `Verified`; `dual_scale` is absent because the
    // exported multipliers are already boundary-normalized.
    gap: f64,
    primal: f64,
    dual: f64,
    scale: f64,
    /// Active-set certificate in the caller's `X[]` indexing;
    /// multipliers on the normalized dual's constraint boundary.
    cert: Cert,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Certified) void {
        self.allocator.free(self.cert.indices);
        self.allocator.free(self.cert.lambdas);
    }
};

pub const CertifyOutcome = union(enum) {
    certified: Certified,
    no_certificate: Reason,
};

/// Worst containment violation of (A, b) over X: max_i ‖A xᵢ‖ − b·xᵢ.
/// ≤ 0 means every point is inside the cone; positive means at least
/// one point is not covered. `api.checkFeasibility` delegates here.
pub fn primalViolation(X: []const [3]f64, A: Mat3, b: Vec3) f64 {
    var max_viol: f64 = -1e30;
    const Xv: []const Vec3 = @ptrCast(X);
    for (Xv) |xi| {
        const viol = A.apply(xi).norm() - b.dot(xi);
        if (viol > max_viol) max_viol = viol;
    }
    return max_viol;
}

/// Check the certificate (A, b, λ): pure arithmetic, no solve. Repairs
/// both sides unconditionally (module doc), assembles the aligned dual
/// point γᵢ = λᵢ·Axᵢ/‖Axᵢ‖ (SOC-tight by construction; alignment is
/// invariant under the primal repair), and returns the gap the pair
/// proves. `lambda` pairs with `X` (`lambda.len == X.len`); entries
/// ≤ 0 are treated as inactive. A slack λ inflates the gap honestly:
/// it bounds the *pair's* suboptimality — a large gap says "this
/// certificate proves little", not "this cone is bad"; `certify`
/// answers the latter.
pub fn verify(X: []const [3]f64, A: Mat3, b_raw: Vec3, lambda: []const f64) VerifyOutcome {
    std.debug.assert(lambda.len == X.len);
    const b_norm = b_raw.norm();
    if (!(b_norm > tol.TINY)) return .{ .no_certificate = .axis_not_interior };
    const b = b_raw.scale(1.0 / b_norm);

    const La = A.cholesky() orelse return .{ .no_certificate = .not_psd };

    // One pass: the primal repair factor over all points, and the
    // aligned dual point Z = Σᵢ λᵢ·(xᵢzᵢᵀ + zᵢxᵢᵀ)/2 over the active
    // ones. zᵢ = Axᵢ/‖Axᵢ‖ is unchanged by scaling A, so Z needs no
    // re-assembly after the repair.
    const Xv: []const Vec3 = @ptrCast(X);
    var s: f64 = 0;
    var Z = Mat3.zero;
    var xlam = Vec3.zero;
    var k: usize = 0;
    for (Xv, lambda) |xi, li| {
        const bx = b.dot(xi);
        if (!(bx > 0)) return .{ .no_certificate = .axis_not_interior };
        const ax = A.apply(xi);
        const na = ax.norm();
        s = @max(s, na / bx);
        if (li > 0) {
            Z.addSymRank2(li, xi, ax.scale(1.0 / na));
            xlam = Vec3.lincomb(1.0, xlam, li, xi);
            k += 1;
        }
    }
    if (k == 0) return .{ .no_certificate = .empty_support };
    // t > 0 structurally: b·Xλ = Σ λᵢ(b·xᵢ) with every term positive.
    const t = xlam.norm();

    // M = Lᵀ·Z·L with L·Lᵀ = A.
    const Lmat = La.asMat3();
    const M = Lmat.transpose().mul(Z).mul(Lmat).symmetrize();
    const Lm = M.cholesky() orelse return .{ .no_certificate = .dual_indefinite };

    // Gap of the repaired pair (A/s, 3λ/t): the primal repair scales M
    // by 1/s (charge 3·log s) and the dual rescale contributes the
    // solver's closed-form boundary term.
    const gap = 3.0 * std.math.log1p((t - 3.0) / 3.0) + 3.0 * @log(s) - Lm.logDet();
    const primal = -La.logDet() + 3.0 * @log(s);
    return .{ .verified = .{
        .gap = gap,
        .primal = primal,
        .dual = primal - gap,
        .scale = s,
        .dual_scale = 3.0 / t,
    } };
}

/// Certify the cone (A, b): repair, run the inner-MVEE machinery at
/// the candidate's axis to manufacture multipliers
/// (λᵢ = 3wᵢ/(b·xᵢ), then boundary-normalized), and `verify`. The
/// candidate carries no structural promises — its b need not be an
/// eigenvector of its A — so only A ≻ 0 and b·xᵢ > 0 are assumed, and
/// both are checked, not trusted. The only error is allocation
/// failure; every numerical outcome is a `CertifyOutcome`.
pub fn certify(
    allocator: std.mem.Allocator,
    X: []const [3]f64,
    A: Mat3,
    b_raw: Vec3,
) error{OutOfMemory}!CertifyOutcome {
    const n = X.len;
    const b_norm = b_raw.norm();
    if (!(b_norm > tol.TINY)) return .{ .no_certificate = .axis_not_interior };
    const b = b_raw.scale(1.0 / b_norm);
    const Xv: []const Vec3 = @ptrCast(X);

    // All transient scratch on one arena (the `solve` idiom); only the
    // exported cert arrays land on the parent allocator.
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Gnomonic chart at the candidate's axis; rejects any b·xᵢ at or
    // below zero (the projection divides by it).
    const P_buf = try arena.alloc([2]f64, n);
    if (!halfspace.projectGnomonic(Xv, b, b.orthoBasis(), P_buf, tol.TINY)) {
        return .{ .no_certificate = .axis_not_interior };
    }
    const Ps = try arena.alloc([2]f64, n);
    _ = core.rescaleP(P_buf, Ps);

    // Inner MVEE at fixed axis: the D-optimal weights are invariant
    // under the chart rescale, so w reads off the scaled chart
    // directly. A degenerate design (collinear chart points) makes FW
    // stop on its Cholesky guard; the thin multipliers then surface as
    // `dual_indefinite` from `verify` — total either way.
    const w = try arena.alloc(f64, n);
    const Ql = try arena.alloc(Vec3, n);
    core.initWeights(Ps, w);
    core.mveeFw(Ps, config.cert.FW_MAX_ITER, config.cert.FW_INNER_TOL, Ql, w);

    // Conic multipliers from the design weights, on the solver's
    // active-set cutoff.
    const lam_full = try arena.alloc(f64, n);
    @memset(lam_full, 0);
    var k: usize = 0;
    for (w, 0..) |wi, i| {
        if (wi > algo.ACTIVE_THRESH) {
            lam_full[i] = 3.0 * wi / b.dot(Xv[i]);
            k += 1;
        }
    }

    const v = switch (verify(X, A, b, lam_full)) {
        .verified => |v| v,
        .no_certificate => |r| return .{ .no_certificate = r },
    };

    // Export the active pairs boundary-normalized, matching the
    // shipped-`Cert` invariant. A second pass over lam_full is forced:
    // the normalization factor `v.dual_scale` exists only after
    // `verify` has seen the full vector.
    const indices = try allocator.alloc(u32, k);
    errdefer allocator.free(indices);
    const lambdas = try allocator.alloc(f64, k);
    var j: usize = 0;
    for (lam_full, 0..) |li, i| {
        if (li > 0) {
            indices[j] = @intCast(i);
            lambdas[j] = v.dual_scale * li;
            j += 1;
        }
    }
    return .{ .certified = .{
        .gap = v.gap,
        .primal = v.primal,
        .dual = v.dual,
        .scale = v.scale,
        .cert = .{ .indices = indices, .lambdas = lambdas },
        .allocator = allocator,
    } };
}
