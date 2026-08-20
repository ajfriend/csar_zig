//! Regressions for the consistency of non-converged outcomes
//! (2026-07-08 pre-release review, findings 2 and 3): DNC snapshots
//! must be self-consistent (one iterate's axis + eigenvectors + gap),
//! and the internal "certificate construction failed" sentinel must
//! never certify.

const std = @import("std");
const csar = @import("../src/root.zig");
const cases = @import("cases");

/// The certified snapshot's eigenbasis, for either resolvable outcome.
/// Both arms are exercised deterministically on every platform by the
/// "both outcome kinds" test below, so platform-dependent solves (like
/// the budget-limited one) can use this without tolerant-arm coverage
/// holes.
fn snapshotQ(o: *const csar.Outcome) csar.Mat3 {
    return switch (o.*) {
        .converged => |c| c.Q,
        .did_not_converge => |p| p.Q,
        .infeasible => unreachable,
    };
}

fn expectOrthonormalQ(Qm: csar.Mat3) !void {
    const c0 = Qm.col(0);
    const c1 = Qm.col(1);
    const c2 = Qm.col(2);
    try std.testing.expect(@abs(c0.dot(c1)) < 1e-10);
    try std.testing.expect(@abs(c0.dot(c2)) < 1e-10);
    try std.testing.expect(@abs(c1.dot(c2)) < 1e-10);
    try std.testing.expect(@abs(c0.dot(c0) - 1.0) < 1e-10);
}

test "snapshot Q is orthonormal for both outcome kinds (deterministic on all platforms)" {
    const allocator = std.testing.allocator;

    // Converged arm: the easy bundled hexagon.
    const hex_pts = (cases.byName("hex") orelse unreachable).points;
    var conv = try csar.solve(allocator, hex_pts, .{ .method = .trust });
    defer conv.deinit();
    try std.testing.expect(std.meta.activeTag(conv) == .converged);
    try expectOrthonormalQ(snapshotQ(&conv));

    // DNC arm: wide_cap89 clamped to a single outer iteration. The
    // wide-cap eager certificate fails by construction (see
    // docs/wide-cap-dnc-report.md), so this DNCs on every platform —
    // a shift here is a regression signal, not a number to bump.
    const cap_pts = (cases.byName("wide_cap89") orelse unreachable).points;
    var dnc = try csar.solve(allocator, cap_pts, .{ .method = .trust, .max_outer = 1 });
    defer dnc.deinit();
    try std.testing.expect(std.meta.activeTag(dnc) == .did_not_converge);
    try expectOrthonormalQ(snapshotQ(&dnc));
}

test "budget-limited trust DNC returns a self-consistent certified snapshot" {
    // Finding 2: with a small max_outer on a hard input, the trust
    // path used to exhaust its budget on far-field accepted steps
    // (certification is gated on pred), skip RECERT, and pair the
    // FINAL axis with the INITIAL axis's eigenvectors — a
    // non-orthonormal Q (column dots up to 1e-1 measured) and a stale
    // gap. The outcome must now be the last certified iterate:
    // Q orthonormal to roundoff.
    const allocator = std.testing.allocator;
    const pts = (cases.byName("wide_cap89") orelse unreachable).points;
    var o = try csar.solve(allocator, pts, .{ .method = .trust, .max_outer = 4, .gap_tol = 1e-9 });
    defer o.deinit();
    // Status may be either (converged if the budget suffices on some
    // platform); the invariant under test is snapshot consistency.
    try expectOrthonormalQ(snapshotQ(&o));
}

test "the no-certificate sentinel never certifies, and absurd gap_tol is rejected" {
    // Finding 3: dualityGapConstructed signals "certificate
    // construction failed" with gap = tol.GAP_UNCERTIFIED (1e30); that
    // sentinel used to satisfy gapConverged for a legal-but-absurd
    // gap_tol (1e300), manufacturing Outcome.converged with an EMPTY
    // cert. Now: gap_tol >= the sentinel is InvalidTolerance, and
    // gapConverged refuses the sentinel regardless of gap_tol.
    const core = @import("../src/csar.zig");
    const config = @import("../src/config.zig");

    // The pure convergence predicate: the sentinel never certifies,
    // even at the loosest legal tolerance.
    try std.testing.expect(!try core.gapConverged(config.tol.GAP_UNCERTIFIED, 1e29));
    // A real gap at the same tolerance does certify (the guard is
    // specific to the sentinel, not a blanket ceiling).
    try std.testing.expect(try core.gapConverged(1e-7, 1e-6));

    // Validation cap on the option itself.
    const allocator = std.testing.allocator;
    const pts = [_][3]f64{ .{ 1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, 0, 1 } };
    try std.testing.expectError(
        csar.InputError.InvalidTolerance,
        csar.solve(allocator, &pts, .{ .gap_tol = 1e30 }),
    );
}

test "alternating DNC snapshot is also self-consistent" {
    // Same invariant on the alternating path (whose staleness was one
    // damped axis step rather than several TR steps — smaller, but the
    // same class). Wide caps DNC structurally under .alternating.
    const allocator = std.testing.allocator;
    const pts = (cases.byName("wide_cap82") orelse unreachable).points;
    var o = try csar.solve(allocator, pts, .{ .method = .alternating });
    defer o.deinit();
    try std.testing.expect(std.meta.activeTag(o) == .did_not_converge);
    const Qm = o.did_not_converge.Q;
    try std.testing.expect(@abs(Qm.col(0).dot(Qm.col(1))) < 1e-10);
    try std.testing.expect(@abs(Qm.col(0).dot(Qm.col(2))) < 1e-10);
}
