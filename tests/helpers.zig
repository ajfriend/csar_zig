//! Shared test helpers: sphere-cap geometry and outcome accessors used
//! by multiple test files. Registered in all.zig so the coverage test
//! below (which pins both arms of `resolvedView` on every platform)
//! runs with the suite.

const std = @import("std");
const csar = @import("../src/root.zig");
const cases = @import("cases");

const Vec3 = csar.Vec3;

/// Failure diagnostics print through here so the expectError
/// self-tests — which deliberately drive failure paths during passing
/// runs — can keep stderr silent (set `quiet_diagnostics`, restore
/// via defer). With no stray stderr, `zig build test` is quiet on
/// success and shows the captured diagnostics only on failure — no
/// shell-level log plumbing needed for the fast tier.
pub var quiet_diagnostics = false;

pub fn diagPrint(comptime fmt: []const u8, args: anytype) void {
    if (!quiet_diagnostics) std.debug.print(fmt, args);
}

/// N points on the boundary of an anisotropic "elliptical cap": tangent
/// ellipse (half-angles `half_a` × `half_b`) at `center`, mapped to the
/// sphere via the exponential map, optionally over a partial arc.
/// `half_a == half_b` with a full arc degenerates to a circular cap.
pub fn ellipseBoundary(center: Vec3, half_a: f64, half_b: f64, phase: f64, arc: f64, out: []Vec3) void {
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

/// Points of a bundled manifest case; the fixture must exist or the
/// suite is broken.
pub fn casePoints(name: []const u8) []const [3]f64 {
    return (cases.byName(name) orelse unreachable).points;
}

/// ‖Σ λᵢxᵢ‖ over a certificate, in the caller's indexing.
pub fn xlamNorm(pts: []const [3]f64, cert: csar.Cert) f64 {
    var z = Vec3.zero;
    for (cert.indices, cert.lambdas) |idx, l| {
        z = Vec3.lincomb(1.0, z, l, Vec3{ .m = pts[idx] });
    }
    return z.norm();
}

/// The parts of a resolvable (converged / DNC) outcome that tolerant
/// tests read without caring which way a platform-sensitive solve
/// landed; `null` for an infeasible outcome, which has no iterate. Both
/// resolvable arms are pinned by the coverage test below (see dev.md
/// "Coverage exclusions", the deterministic-sibling technique); callers
/// that know their input is feasible unwrap with `.?`.
pub const ResolvedView = struct { converged: bool, Q: csar.Mat3, diag: csar.Diagnostics };

pub fn resolvedView(o: *const csar.Outcome) ?ResolvedView {
    return switch (o.*) {
        .converged => |c| .{ .converged = true, .Q = c.Q, .diag = c.diag },
        .did_not_converge, .precision_floor => |d| .{ .converged = false, .Q = d.Q, .diag = d.diag },
        .infeasible => null,
    };
}

pub fn expectOrthonormalQ(Qm: csar.Mat3) !void {
    const c0 = Qm.col(0);
    const c1 = Qm.col(1);
    const c2 = Qm.col(2);
    try std.testing.expect(@abs(c0.dot(c1)) < 1e-10);
    try std.testing.expect(@abs(c0.dot(c2)) < 1e-10);
    try std.testing.expect(@abs(c1.dot(c2)) < 1e-10);
    try std.testing.expect(@abs(c0.dot(c0) - 1.0) < 1e-10);
}

/// A solve that DNCs deterministically on every platform (wide_cap89
/// clamped to one outer iteration; its eager certificate fails by
/// construction — docs/wide-cap-dnc-report.md). A shift here is a
/// regression signal, not a number to bump. Caller owns the outcome.
pub fn solveClampedWideCapDnc(allocator: std.mem.Allocator) !csar.Outcome {
    const pts = casePoints("wide_cap89");
    return csar.solve(allocator, pts, .{ .method = .trust, .max_outer = 1 });
}

test "resolvedView: both arms, deterministic on all platforms; snapshot Q orthonormal for both" {
    const allocator = std.testing.allocator;

    // Converged arm: the easy bundled hexagon.
    const hex_pts = casePoints("hex");
    var conv = try csar.solve(allocator, hex_pts, .{ .method = .trust });
    defer conv.deinit();
    const cv = resolvedView(&conv).?;
    try std.testing.expect(cv.converged);
    try expectOrthonormalQ(cv.Q);

    // DNC arm.
    var dnc = try solveClampedWideCapDnc(allocator);
    defer dnc.deinit();
    const dv = resolvedView(&dnc).?;
    try std.testing.expect(!dv.converged);
    try expectOrthonormalQ(dv.Q);

    // And the arm with no view: an infeasible input, by construction.
    var inf = try csar.solve(std.testing.allocator, casePoints("infeas_antipodal"), .{});
    defer inf.deinit();
    try std.testing.expect(resolvedView(&inf) == null);
}
