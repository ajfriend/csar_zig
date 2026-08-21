//! Regressions for the consistency of non-converged outcomes
//! (2026-07-08 pre-release review, findings 2 and 3): DNC snapshots
//! must be self-consistent (one iterate's axis + eigenvectors + gap),
//! and the internal "certificate construction failed" sentinel must
//! never certify.

const std = @import("std");
const csar = @import("../src/root.zig");
const helpers = @import("helpers.zig");

test "budget-limited trust DNC returns a self-consistent certified snapshot" {
    // Finding 2: with a small max_outer on a hard input, the trust
    // path used to exhaust its budget on far-field accepted steps
    // (certification is gated on pred), skip RECERT, and pair the
    // FINAL axis with the INITIAL axis's eigenvectors — a
    // non-orthonormal Q (column dots up to 1e-1 measured) and a stale
    // gap. The outcome must now be the last certified iterate:
    // Q orthonormal to roundoff.
    const allocator = std.testing.allocator;
    const pts = helpers.casePoints("wide_cap89");
    var o = try csar.solve(allocator, pts, .{ .method = .trust, .max_outer = 4, .gap_tol = 1e-9 });
    defer o.deinit();
    // Status may be either (converged if the budget suffices on some
    // platform); the invariant under test is snapshot consistency.
    try helpers.expectOrthonormalQ(helpers.resolvedView(&o).?.Q);
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

