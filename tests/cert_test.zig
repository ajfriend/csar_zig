//! Tests for `src/cert.zig` — certify/verify of foreign (A, b)
//! candidates.
//!
//! Coverage:
//!  - corpus reproduction: `certify` on every converged corpus solve
//!    re-certifies at the solver's own tolerance, and `verify` on the
//!    shipped certificate reproduces `Converged.gap`;
//!  - round-trip: `verify` on `certify`'s own exported multipliers
//!    reproduces its gap (they ship boundary-normalized);
//!  - repair: the reported gap is invariant under scaling the
//!    candidate's A (the uniform repair absorbs it into `scale`), and
//!    an off-axis candidate still certifies with a valid gap;
//!  - every `no_certificate` reason, from both entry points.

const std = @import("std");
const csar = @import("../src/root.zig");
const cert = csar.cert;
const cases = @import("cases");
const helpers = @import("helpers.zig");

/// Gap-reproduction tolerance, for both `verify`-on-shipped-cert vs
/// `Converged.gap` and the certify→verify round-trip. The routes share
/// the construction but factor A differently (internal eigenbasis vs
/// Cholesky of the materialized A), so agreement is limited by log-det
/// conditioning on the worst corpus cases: measured worst 1.7e-9
/// (extreme-aspect fixtures dominate). 50x headroom for platform
/// variance; never loosen without a call-out.
const GAP_REPRO_TOL: f64 = 1e-7;

/// Scatter a shipped active-set cert into a full-length λ vector.
fn scatter(lam_full: []f64, c: csar.Cert) void {
    @memset(lam_full, 0);
    for (c.indices, c.lambdas) |idx, l| lam_full[idx] = l;
}

test "corpus: certify re-certifies converged solves; verify reproduces shipped gaps" {
    const allocator = std.testing.allocator;
    for (cases.all) |entry| {
        const case = entry.case;
        if (case.claim != .converges) continue;
        var outcome = try csar.solve(allocator, case.points, cases.pin(csar.SolveOptions));
        defer outcome.deinit();
        // Tier-2 cases need non-default settings to converge; whichever
        // way a case lands, only certified cones are in scope here.
        const c = switch (outcome) {
            .converged => |c| c,
            else => continue,
        };

        // certify: the cone re-certifies at the solver's tolerance.
        const co = try cert.certify(allocator, case.points, c.A(), c.b());
        var cd = co.certified;
        defer cd.deinit();
        try std.testing.expect(cd.gap >= -1e-9);
        try std.testing.expect(cd.gap < cases.GAP_TOL);
        // The shipped candidate is containment-tight: repair is a no-op.
        try std.testing.expectApproxEqAbs(1.0, cd.scale, 1e-9);
        // Exported multipliers sit on the boundary.
        try std.testing.expectApproxEqAbs(3.0, helpers.xlamNorm(case.points, cd.cert), 1e-12);

        // verify on the solver's shipped certificate reproduces its gap.
        const lam_full = try allocator.alloc(f64, case.points.len);
        defer allocator.free(lam_full);
        scatter(lam_full, c.cert);
        const v = cert.verify(case.points, c.A(), c.b(), lam_full).verified;
        try std.testing.expectApproxEqAbs(c.gap, v.gap, GAP_REPRO_TOL);
        try std.testing.expectApproxEqAbs(1.0, v.scale, 1e-9);
        try std.testing.expectApproxEqAbs(1.0, v.dual_scale, 1e-9);

        // Round-trip: verify on certify's own export reproduces its gap.
        scatter(lam_full, cd.cert);
        const rv = cert.verify(case.points, c.A(), c.b(), lam_full).verified;
        try std.testing.expectApproxEqAbs(cd.gap, rv.gap, GAP_REPRO_TOL);
        try std.testing.expectApproxEqAbs(1.0, rv.dual_scale, 1e-12);
    }
}

test "repair: gap is invariant under scaling A; off-axis candidates still certify" {
    const allocator = std.testing.allocator;
    const pts = helpers.casePoints("hex");
    var outcome = try csar.solve(allocator, pts, .{});
    defer outcome.deinit();
    const c = outcome.converged;

    const co = try cert.certify(allocator, pts, c.A(), c.b());
    var cd = co.certified;
    defer cd.deinit();

    // Inflate A by 1.3: containment is violated, the repair charges it
    // into `scale`, and the gap — a property of the cone's geometry —
    // is unchanged.
    const co13 = try cert.certify(allocator, pts, c.A().scale(1.3), c.b());
    var cd13 = co13.certified;
    defer cd13.deinit();
    try std.testing.expectApproxEqAbs(cd.gap, cd13.gap, 1e-12);
    try std.testing.expectApproxEqAbs(1.3 * cd.scale, cd13.scale, 1e-12);

    // Tilt the axis: no structural promises hold (b is not an
    // eigenvector of A), yet the candidate certifies — with a gap that
    // is valid (≥ 0) and visibly worse than the optimum's.
    const q1 = c.Q.col(1);
    const b_off = csar.Vec3.lincomb(1.0, c.b(), 0.05, q1).normalize();
    const co_off = try cert.certify(allocator, pts, c.A(), b_off);
    var cd_off = co_off.certified;
    defer cd_off.deinit();
    try std.testing.expect(cd_off.gap >= -1e-12);
    try std.testing.expect(cd_off.gap > 100.0 * cd.gap);
}

test "OOM in certify's last alloc hits the indices errdefer" {
    // Same technique as extreme_aspect_test.zig's cert-builder OOM
    // tests: count parent-allocator calls on a clean run, then fail
    // the last one — `lambdas`, the second of the two back-to-back
    // export allocs — so the `errdefer allocator.free(indices)` runs.
    const pts = helpers.casePoints("hex");
    var outcome = try csar.solve(std.testing.allocator, pts, .{});
    defer outcome.deinit();
    const c = outcome.converged;

    var count_fa = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    {
        const co = try cert.certify(count_fa.allocator(), pts, c.A(), c.b());
        var cd = co.certified;
        cd.deinit();
    }
    var fa = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = count_fa.alloc_index - 1,
    });
    try std.testing.expectError(
        error.OutOfMemory,
        cert.certify(fa.allocator(), pts, c.A(), c.b()),
    );
}

test "no_certificate: every reason, from both entry points" {
    const allocator = std.testing.allocator;
    const octant = [_][3]f64{ .{ 1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, 0, 1 } };
    const lam1 = [_]f64{ 1, 1, 1 };
    const eye = csar.Mat3{ .m = .{ 1, 0, 0, 0, 1, 0, 0, 0, 1 } };
    const b_ok = (csar.Vec3{ .m = .{ 1, 1, 1 } }).normalize();

    // not_psd: a negative pivot fails A's Cholesky.
    const neg = csar.Mat3{ .m = .{ -1, 0, 0, 0, 1, 0, 0, 0, 1 } };
    try std.testing.expect(cert.verify(&octant, neg, b_ok, &lam1).no_certificate == .not_psd);
    const co_psd = try cert.certify(allocator, &octant, neg, b_ok);
    try std.testing.expect(co_psd.no_certificate == .not_psd);

    // axis_not_interior: a zero axis, and an axis with b·xᵢ ≤ 0.
    const b_zero = csar.Vec3.zero;
    try std.testing.expect(cert.verify(&octant, eye, b_zero, &lam1).no_certificate == .axis_not_interior);
    const co_z = try cert.certify(allocator, &octant, eye, b_zero);
    try std.testing.expect(co_z.no_certificate == .axis_not_interior);
    const b_edge = csar.Vec3{ .m = .{ 1, 0, 0 } }; // b·(0,1,0) = 0
    try std.testing.expect(cert.verify(&octant, eye, b_edge, &lam1).no_certificate == .axis_not_interior);
    const co_e = try cert.certify(allocator, &octant, eye, b_edge);
    try std.testing.expect(co_e.no_certificate == .axis_not_interior);

    // empty_support: no strictly positive multiplier.
    const lam0 = [_]f64{ 0, -1, 0 };
    try std.testing.expect(cert.verify(&octant, eye, b_ok, &lam0).no_certificate == .empty_support);

    // dual_indefinite: a single-point λ leaves Z rank-deficient.
    const lam_one = [_]f64{ 1, 0, 0 };
    try std.testing.expect(cert.verify(&octant, eye, b_ok, &lam_one).no_certificate == .dual_indefinite);
    // certify pass-through: two points can never pin a full-rank dual.
    const two = [_][3]f64{ .{ 1, 0, 0 }, .{ 0, 1, 0 } };
    const co_two = try cert.certify(allocator, &two, eye, b_ok);
    try std.testing.expect(co_two.no_certificate == .dual_indefinite);
}
