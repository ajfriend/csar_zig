//! Module-local tests for `src/cert.zig` — `cert_primal` /
//! `cert_dual` for foreign (A, b) candidates. The per-case corpus obligations (re-certify,
//! shipped-gap reproduction, round-trip) live in cases_test.zig's
//! tier x claim loop, where tier-2 settings apply.
//!
//! Coverage:
//!  - repair: the reported gap is invariant under scaling the
//!    candidate's A (the uniform repair absorbs it into `scale`), and
//!    an off-axis candidate still certifies with a valid gap;
//!  - every `no_certificate` reason, from both entry points;
//!  - OOM on the last export alloc hits the `errdefer`.

const std = @import("std");
const csar = @import("../src/root.zig");
const helpers = @import("helpers.zig");

test "repair: gap is invariant under scaling A; off-axis candidates still certify" {
    const allocator = std.testing.allocator;
    const pts = helpers.casePoints("hex");
    var outcome = try csar.solve(allocator, pts, .{});
    defer outcome.deinit();
    const c = outcome.converged;

    const co = try csar.cert_primal(allocator, pts, c.A(), c.b());
    var cd = co.certified;
    defer cd.deinit();

    // Inflate A by 1.3: containment is violated, the repair charges it
    // into `scale`, and the gap — a property of the cone's geometry —
    // is unchanged.
    const co13 = try csar.cert_primal(allocator, pts, c.A().scale(1.3), c.b());
    var cd13 = co13.certified;
    defer cd13.deinit();
    try std.testing.expectApproxEqAbs(cd.gap, cd13.gap, 1e-12);
    try std.testing.expectApproxEqAbs(1.3 * cd.scale, cd13.scale, 1e-12);

    // Tilt the axis: no structural promises hold (b is not an
    // eigenvector of A), yet the candidate certifies — with a gap that
    // is valid (≥ 0) and visibly worse than the optimum's.
    const q1 = c.Q.col(1);
    const b_off = csar.Vec3.lincomb(1.0, c.b(), 0.05, q1).normalize();
    const co_off = try csar.cert_primal(allocator, pts, c.A(), b_off);
    var cd_off = co_off.certified;
    defer cd_off.deinit();
    try std.testing.expect(cd_off.gap >= -1e-12);
    try std.testing.expect(cd_off.gap > 100.0 * cd.gap);
}

test "OOM in cert_primal's last alloc hits the indices errdefer" {
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
        const co = try csar.cert_primal(count_fa.allocator(), pts, c.A(), c.b());
        var cd = co.certified;
        cd.deinit();
    }
    var fa = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = count_fa.alloc_index - 1,
    });
    try std.testing.expectError(
        error.OutOfMemory,
        csar.cert_primal(fa.allocator(), pts, c.A(), c.b()),
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
    try std.testing.expect(csar.cert_dual(&octant, neg, b_ok, &lam1).no_certificate == .not_psd);
    const co_psd = try csar.cert_primal(allocator, &octant, neg, b_ok);
    try std.testing.expect(co_psd.no_certificate == .not_psd);

    // axis_not_interior: a zero axis, and an axis with b·xᵢ ≤ 0.
    const b_zero = csar.Vec3.zero;
    try std.testing.expect(csar.cert_dual(&octant, eye, b_zero, &lam1).no_certificate == .axis_not_interior);
    const co_z = try csar.cert_primal(allocator, &octant, eye, b_zero);
    try std.testing.expect(co_z.no_certificate == .axis_not_interior);
    const b_edge = csar.Vec3{ .m = .{ 1, 0, 0 } }; // b·(0,1,0) = 0
    try std.testing.expect(csar.cert_dual(&octant, eye, b_edge, &lam1).no_certificate == .axis_not_interior);
    const co_e = try csar.cert_primal(allocator, &octant, eye, b_edge);
    try std.testing.expect(co_e.no_certificate == .axis_not_interior);

    // empty_support: no strictly positive multiplier.
    const lam0 = [_]f64{ 0, -1, 0 };
    try std.testing.expect(csar.cert_dual(&octant, eye, b_ok, &lam0).no_certificate == .empty_support);

    // dual_indefinite: a single-point λ leaves Z rank-deficient.
    const lam_one = [_]f64{ 1, 0, 0 };
    try std.testing.expect(csar.cert_dual(&octant, eye, b_ok, &lam_one).no_certificate == .dual_indefinite);
    // cert_primal pass-through: two points can never pin a full-rank dual.
    const two = [_][3]f64{ .{ 1, 0, 0 }, .{ 0, 1, 0 } };
    const co_two = try csar.cert_primal(allocator, &two, eye, b_ok);
    try std.testing.expect(co_two.no_certificate == .dual_indefinite);
}

test "cert_primal: empty input yields empty_support" {
    // The one public entry that can see zero points; it guards before
    // `shiftPoints` (which requires a reference point). Solver paths
    // always pass a non-empty work set.
    const A: csar.Mat3 = .{ .m = .{ 1, 0, 0, 0, 1, 0, 0, 0, 1 } };
    const b: csar.Vec3 = .{ .m = .{ 0, 0, 1 } };
    const co = try csar.cert_primal(std.testing.allocator, &.{}, A, b);
    try std.testing.expectEqual(csar.NoCertReason.empty_support, co.no_certificate);
}
