//! Tests for the trust path's step machinery and terminal phases
//! (`src/trust.zig`): the dogleg's three branches unit-tested against
//! their defining equations, trust-region dynamics on inputs hard
//! enough to reject steps, and convergence through the re-certification
//! phase. These pin the paths the cap/manifest suites never leave the
//! happy road to reach.

const std = @import("std");
const csar = @import("../src/root.zig");
const trust = @import("../src/trust.zig");
const linalg = @import("../src/linalg.zig");

const Vec2 = linalg.Vec2;
const Mat2 = linalg.Mat2;
const Vec3 = csar.Vec3;
const tc = @import("../src/config.zig").trust;

fn pred(B: Mat2, g: Vec2, u: Vec2) f64 {
    return -(g.dot(u) + 0.5 * u.dot(B.apply(u)));
}

test "doglegStep: interior Newton point is returned unclipped" {
    const B = Mat2{ .m = .{ 1.0, 0.0, 0.0, 1.0 } };
    const g = Vec2{ .m = .{ 1.0, 0.0 } };
    const step = trust.doglegStep(B, g, 2.0);
    // pn = -B⁻¹g = (-1, 0), inside delta = 2.
    try std.testing.expectApproxEqAbs(@as(f64, -1.0), step.u.m[0], 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), step.u.m[1], 1e-14);
    try std.testing.expectApproxEqAbs(pred(B, g, step.u), step.pred, 1e-14);
    try std.testing.expect(step.pred > 0);
}

test "doglegStep: Cauchy point outside the radius clips to the gradient direction" {
    // B = diag(0.1, 1), g = (1, 1): pu = -g·(g·g)/(gᵀBg) = -(2/1.1)·g,
    // ‖pu‖ ≈ 2.571; pn = -(10, 1), ‖pn‖ ≈ 10.05. delta = 2 < ‖pu‖ →
    // the scaled-gradient branch: u = -delta·g/‖g‖.
    const B = Mat2{ .m = .{ 0.1, 0.0, 0.0, 1.0 } };
    const g = Vec2{ .m = .{ 1.0, 1.0 } };
    const delta = 2.0;
    const step = trust.doglegStep(B, g, delta);
    try std.testing.expectApproxEqAbs(delta, step.u.norm(), 1e-12);
    const expect_c = -delta / g.norm();
    try std.testing.expectApproxEqAbs(expect_c * g.m[0], step.u.m[0], 1e-12);
    try std.testing.expectApproxEqAbs(expect_c * g.m[1], step.u.m[1], 1e-12);
    try std.testing.expectApproxEqAbs(pred(B, g, step.u), step.pred, 1e-12);
    try std.testing.expect(step.pred > 0);
}

test "doglegStep: radius between Cauchy and Newton points interpolates the segment" {
    // Same B, g as above; delta = 5 lies in (‖pu‖, ‖pn‖) → the dogleg
    // segment branch: u = pu + τ·(pn − pu) with ‖u‖ = delta exactly.
    const B = Mat2{ .m = .{ 0.1, 0.0, 0.0, 1.0 } };
    const g = Vec2{ .m = .{ 1.0, 1.0 } };
    const delta = 5.0;
    const step = trust.doglegStep(B, g, delta);
    try std.testing.expectApproxEqAbs(delta, step.u.norm(), 1e-12);
    try std.testing.expectApproxEqAbs(pred(B, g, step.u), step.pred, 1e-12);
    try std.testing.expect(step.pred > 0);
    // The interpolated step must beat the pure-gradient step's model
    // decrease at the same radius (dogleg optimality along the path).
    const u_grad = g.scale(-delta / g.norm());
    try std.testing.expect(step.pred >= pred(B, g, u_grad) - 1e-12);
}

test "doglegStepRobust: degenerate gradient exercises the isotropic retry" {
    // g = 0: the Newton point is 0 with pred exactly 0, so the retry
    // fires; the isotropic Hessian gives the same degenerate answer
    // and the caller's stationary break handles it. This is the only
    // constructible route into the retry — with an SPD-guarded B
    // (Sylvester), a nonpositive pred otherwise needs FP-noise
    // cancellation.
    const B = Mat2{ .m = .{ 1.0, 0.0, 0.0, 1.0 } };
    const g0 = Vec2{ .m = .{ 0.0, 0.0 } };
    const step = trust.doglegStepRobust(B, g0, 1.0);
    try std.testing.expectEqual(@as(f64, 0.0), step.pred);
    try std.testing.expectEqual(@as(f64, 0.0), step.u.norm());
    // Non-degenerate passthrough: identical to doglegStep.
    const g = Vec2{ .m = .{ 1.0, 1.0 } };
    const s2 = trust.doglegStepRobust(B, g, 2.0);
    try std.testing.expectEqual(trust.doglegStep(B, g, 2.0).pred, s2.pred);
}

test "updateRadius: every ρ band of the tuned radius policy" {
    const nan = std.math.nan(f64);

    // Reject band (ρ < ETA), NaN included: shrink relative to the step
    // actually attempted, by SHRINK.
    try std.testing.expect(!trust.accepts(0.0));
    try std.testing.expect(!trust.accepts(nan));
    const rej = trust.updateRadius(1.0, 0.0, 0.5);
    try std.testing.expectEqual(@min(1.0, 0.5) * tc.SHRINK, rej.delta);
    try std.testing.expect(!rej.hit_floor);
    try std.testing.expectEqual(rej.delta, trust.updateRadius(1.0, nan, 0.5).delta);

    // Accepted-but-poor band (ETA ≤ ρ < RHO_POOR): gentle SHRINK_POOR.
    const rho_poor = (tc.ETA + tc.RHO_POOR) / 2.0;
    try std.testing.expect(trust.accepts(rho_poor));
    const poor = trust.updateRadius(1.0, rho_poor, 1.0);
    try std.testing.expectEqual(tc.SHRINK_POOR, poor.delta);
    try std.testing.expect(!poor.hit_floor);

    // Shrink through the DELTA_MIN floor exits the loop (both bands).
    try std.testing.expect(trust.updateRadius(tc.DELTA_MIN, 0.0, tc.DELTA_MIN).hit_floor);
    try std.testing.expect(trust.updateRadius(tc.DELTA_MIN, rho_poor, tc.DELTA_MIN).hit_floor);

    // Middle band (RHO_POOR ≤ ρ < ETA_GOOD): radius held.
    try std.testing.expectEqual(1.0, trust.updateRadius(1.0, (tc.RHO_POOR + tc.ETA_GOOD) / 2.0, 1.0).delta);

    // Very successful (ρ ≥ ETA_GOOD) with a radius-limited step: GROW,
    // capped at DELTA_MAX. A short interior step does not grow.
    try std.testing.expectEqual(1.0 * tc.GROW, trust.updateRadius(1.0, tc.ETA_GOOD, 1.0).delta);
    try std.testing.expectEqual(tc.DELTA_MAX, trust.updateRadius(3.0, 0.99, 3.0).delta);
    try std.testing.expectEqual(1.0, trust.updateRadius(1.0, 0.99, 0.5).delta);
}

/// N points on the boundary of an anisotropic "elliptical cap": tangent
/// ellipse (half-angles `half_a` × `half_b`) at `center`, mapped to the
/// sphere via the exponential map, optionally over a partial arc.
fn ellipseBoundary(center: Vec3, half_a: f64, half_b: f64, phase: f64, arc: f64, out: []Vec3) void {
    const Q = center.orthoBasis();
    const n_f = @as(f64, @floatFromInt(out.len));
    for (out, 0..) |*p, i| {
        const theta = phase + arc * @as(f64, @floatFromInt(i)) / n_f;
        const ta = half_a * @cos(theta);
        const tb = half_b * @sin(theta);
        const r = @sqrt(ta * ta + tb * tb);
        const ca = @cos(r);
        const sa = if (r > 0) @sin(r) / r else 1.0;
        const tan = Vec3.lincomb(sa * ta, Q.e1, sa * tb, Q.e2);
        p.* = Vec3.lincomb(ca, center, 1.0, tan).normalize();
    }
}

test "trust: extreme-anisotropy and arc inputs traverse rejected steps and clipped doglegs" {
    // Wide, strongly anisotropic caps and open arcs start the trust
    // region far from quadratic-model territory: trial steps get
    // rejected (ρ < ETA → weight restore + radius shrink) and doglegs
    // get Cauchy-clipped before the runs finish. Verified via
    // breakpoint counts on darwin-aarch64: 28 rejections across this
    // family. The 50:1 shapes ride the f64 gap floor, and which of
    // them certify below gap_tol is path-dependent at noise level
    // (see CLAUDE.md on finest-resolution cells): a DNC there is
    // honest, so the per-shape assertion is the solver contract, with
    // a converged-count floor across the family (7/7 on zig 0.15.2,
    // 6/7 on 0.16.0, both darwin-aarch64 — headroom to 5).
    const allocator = std.testing.allocator;
    const center = (Vec3{ .m = .{ 0.3, -0.2, 1.0 } }).normalize();
    var buf: [24]Vec3 = undefined;

    const shapes = [_]struct { ha: f64, ratio: f64, arc: f64 }{
        .{ .ha = 0.8, .ratio = 50, .arc = 2.0 * std.math.pi },
        .{ .ha = 1.1, .ratio = 50, .arc = 2.0 * std.math.pi },
        .{ .ha = 1.3, .ratio = 50, .arc = 2.0 * std.math.pi },
        .{ .ha = 1.45, .ratio = 50, .arc = 2.0 * std.math.pi },
        .{ .ha = 0.5, .ratio = 1, .arc = 0.9 * std.math.pi },
        .{ .ha = 1.0, .ratio = 1, .arc = 0.9 * std.math.pi },
        .{ .ha = 1.4, .ratio = 1, .arc = 0.9 * std.math.pi },
    };
    var n_converged: u32 = 0;
    var total_tr_iters: u32 = 0;
    for (shapes) |s| {
        const pts_v = buf[0..24];
        ellipseBoundary(center, s.ha, s.ha / s.ratio, 0.1, s.arc, pts_v);
        const pts: [][3]f64 = @ptrCast(pts_v);
        var o = try csar.solve(allocator, pts, .{});
        defer o.deinit();
        const t = trustTally(&o);
        total_tr_iters += t.tr_iters;
        if (t.converged) {
            n_converged += 1;
            const c = o.converged;
            try std.testing.expect(@abs(c.gap) <= 1e-6);
            try std.testing.expect(csar.checkFeasibility(c, pts) <= 1e-10);
        }
        // Floor-limited DNC misses are tolerated per shape (see above);
        // consistency of DNC snapshots is outcome_consistency_test's job.
    }
    try std.testing.expect(n_converged >= 5);
    try std.testing.expect(total_tr_iters > 0); // TR actually engaged
}

const Tally = struct { converged: bool, tr_iters: u32 };

/// Outcome accounting for the anisotropy family. Both arms are
/// exercised deterministically on every platform: the family's tame
/// shapes converge everywhere, and the budget-clamped test below DNCs
/// everywhere — so the per-shape platform variance above leaves no
/// coverage hole.
fn trustTally(o: *const csar.Outcome) Tally {
    return switch (o.*) {
        .converged => |c| .{ .converged = true, .tr_iters = c.diag.trust.tr_iters },
        .did_not_converge => |d| .{ .converged = false, .tr_iters = d.diag.trust.tr_iters },
        .infeasible => unreachable, // solver bug: every family input is strictly feasible by construction
    };
}

test "trust: budget-clamped wide cap is an honest DNC everywhere" {
    // wide_cap89 with max_outer = 1: the wide-cap eager certificate
    // fails by construction (docs/wide-cap-dnc-report.md), so a single
    // outer iteration cannot certify — deterministic DNC on every
    // platform. A shift here is a regression signal, not a number to
    // bump.
    const allocator = std.testing.allocator;
    const cases = @import("cases");
    const pts = (cases.byName("wide_cap89") orelse unreachable).points;
    var o = try csar.solve(allocator, pts, .{ .method = .trust, .max_outer = 1 });
    defer o.deinit();
    const t = trustTally(&o);
    try std.testing.expect(!t.converged);
}

test "trust: tight gap_tol converges through the re-certification phase" {
    // gap_tol below what the trust loop certifies at its stationary
    // axis, above the f64 floor: the solve must finish in the re-cert
    // phase (fast-cadence FW/polish/certify + axis micro-steps at the
    // TR optimum). Measured on darwin-aarch64: recert_attempts = 8 and
    // the convergence exit fires there; other platforms may certify a
    // step earlier, so only convergence itself is asserted hard.
    const allocator = std.testing.allocator;
    const center = (Vec3{ .m = .{ 0.3, -0.2, 1.0 } }).normalize();
    var buf: [12]Vec3 = undefined;
    ellipseBoundary(center, 0.5, 0.1, 0.3, 2.0 * std.math.pi, buf[0..12]);
    const pts: [][3]f64 = @ptrCast(buf[0..12]);
    var o = try csar.solve(allocator, pts, .{ .gap_tol = 1e-8 });
    defer o.deinit();
    try std.testing.expect(std.meta.activeTag(o) == .converged);
    const c = o.converged;
    try std.testing.expect(@abs(c.gap) <= 1e-8);
    try std.testing.expect(csar.checkFeasibility(c, pts) <= 1e-10);
}
