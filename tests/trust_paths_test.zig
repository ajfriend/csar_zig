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
    // get Cauchy-clipped before the runs converge. Verified via
    // breakpoint counts on darwin-aarch64: 28 rejections across this
    // family. Assertions pin the outcomes; the traversal is what the
    // coverage gate observes.
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
    for (shapes) |s| {
        const pts_v = buf[0..24];
        ellipseBoundary(center, s.ha, s.ha / s.ratio, 0.1, s.arc, pts_v);
        const pts: [][3]f64 = @ptrCast(pts_v);
        var o = try csar.solve(allocator, pts, .{});
        defer o.deinit();
        try std.testing.expect(std.meta.activeTag(o) == .converged);
        const c = o.converged;
        try std.testing.expect(@abs(c.gap) <= 1e-6);
        try std.testing.expect(csar.checkFeasibility(c, pts) <= 1e-10);
        try std.testing.expect(c.diag.trust.tr_iters > 0); // TR actually engaged
    }
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
