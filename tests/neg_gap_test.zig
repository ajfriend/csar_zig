//! The #1 / #2 repros (#6): inputs whose certificate gap goes negative at
//! the certification boundary. `solve` returns an `Outcome` for them —
//! `did_not_converge` with `reason = .precision_floor` when the requested
//! tolerance is below what f64 can certify for that geometry — and the
//! error model behind that verdict (`csar.gapFloor`) is pinned to the
//! inputs that motivated it. The batches at `gap_tol = 1e-9` cover the #2
//! class at scale (`just ab --gap-tol=1e-9`); these are the named originals.

const std = @import("std");
const csar = @import("../src/root.zig");
const core = @import("../src/csar.zig");
const halfspace = @import("../src/halfspace.zig");
const helpers = @import("helpers.zig");
const Vec3 = csar.Vec3;

/// #1: a hex9 r20 cell, ~4e-10 rad across. σ_max ≈ 5e9, so the gap's
/// evaluation noise is ~1e-6 — above the default tolerance.
const HEX1: []const [3]f64 = &.{
    .{ 0.6746833027403286, 0.7369617968776201, -0.04110658032859652 },
    .{ 0.674683302801862, 0.7369617968319514, -0.04110658013740184 },
    .{ 0.6746833029130066, 0.736961796730196, -0.04110658013746045 },
    .{ 0.674683302962618, 0.7369617966741094, -0.04110658032871372 },
    .{ 0.6746833029010845, 0.7369617967197781, -0.041106580519908585 },
    .{ 0.6746833027899399, 0.7369617968215336, -0.04110658051984987 },
};

/// #2: close-pair triples; κ(M) ~ 1e9, where the certificate's A_perp is
/// feasible only to κ(M)·ε and a gap at 1e-9 comes out negative by
/// about that; the floor (`gapFloor`) is ~1.4e-7.
const PAIR: []const [3]f64 = &.{
    .{ 0.4254649902182296, 0.0018345230064538318, 0.9049730253570769 },
    .{ 0.45861147899157634, -0.1500785999019865, 0.8758720940803049 },
    .{ 0.44837395964677834, -0.775982462532212, 0.44363499653782196 },
};

test "#1 hexagon: did_not_converge at the precision floor, gap inside the error model" {
    var o = try csar.solve(std.testing.allocator, HEX1, .{});
    defer o.deinit();
    const d = o.did_not_converge;
    try std.testing.expectEqual(d.reason, .precision_floor);
    try std.testing.expect(d.gap_floor > 1e-6); // the default tolerance is below it
    try std.testing.expect(d.gap > -d.gap_floor);
    try std.testing.expectEqual(@as(u32, 0), d.diag.trust.gaps_below_model);
}

test "#2 close pair: converges at 1e-9 where it used to raise, precision-floored at 1e-10" {
    // The negative gap at 1e-9 was a transient: once it no longer aborts
    // the solve, the next iterate certifies at 9e-10.
    var a = try csar.solve(std.testing.allocator, PAIR, .{ .gap_tol = 1e-9 });
    defer a.deinit();
    try std.testing.expectEqual(std.meta.activeTag(a), .converged);
    var b = try csar.solve(std.testing.allocator, PAIR, .{ .gap_tol = 1e-10 });
    defer b.deinit();
    const d = b.did_not_converge;
    try std.testing.expectEqual(d.reason, .precision_floor);
    try std.testing.expect(d.gap > -d.gap_floor);
    try std.testing.expectEqual(@as(u32, 0), d.diag.trust.gaps_below_model);
}

test "a negative gap is the symptom of an infeasible certificate, and the model flags a real one" {
    // Weak duality holds for a feasible pair, so the only way to a gap
    // below the error model is a primal certificate that violates its
    // budget — what `gaps_below_model` counts and Debug asserts on.
    // Construct one: a regular hexagon, the solver's uniform seed weights
    // (its optimal design by symmetry), a budget-tight A_perp from
    // `recoverAPerp`, then
    // that A_perp inflated by (1 + δ). Inflating A shrinks the cone the
    // certificate claims, so −log det A understates the feasible value by
    // 2·log(1+δ) and the gap drops by that much — ~10⁴× the model at
    // δ = 1e-3.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const pts = helpers.casePoints("hex");
    const X: []const Vec3 = @ptrCast(pts);
    var b = Vec3.zero;
    for (X) |x| b = b.add(x);
    b = b.normalize();
    const Q = b.orthoBasis();
    const P = try a.alloc([2]f64, X.len);
    try std.testing.expect(halfspace.projectGnomonic(X, b, Q, P, 0.0));
    const w = try a.alloc(f64, X.len);
    core.initWeights(P, w); // uniform for ≤ SEED_SPARSE_MIN_POINTS points
    const M = core.computeMoments(P, w, 1.0).M;
    const A_perp = try core.recoverAPerp(P, M);

    var scratch = try core.GapScratch.init(a, X.len);
    const active = try a.alloc(usize, X.len);
    const lam = try a.alloc(f64, X.len);
    const feasible = try core.dualityGapConstructed(w, b, X, A_perp, Q, &scratch, active, lam);
    const delta = 1e-3;
    const inflated = try core.dualityGapConstructed(w, b, X, A_perp.scale(1.0 + delta), Q, &scratch, active, lam);

    const floor = core.gapFloor(feasible.sigma[1], M);
    try std.testing.expect(feasible.gap > -floor);
    try std.testing.expect(inflated.gap < -floor);
    try std.testing.expect(inflated.gap < -1000.0 * floor);
    try std.testing.expect(!core.gapBelowModel(feasible, M, 1e-6));
    try std.testing.expect(core.gapBelowModel(inflated, M, 1e-6));
    // First-order: the dual candidate's zᵢ = A·xᵢ/‖A·xᵢ‖ also move with A,
    // contributing O(δ²) (measured 7e-7 at δ = 1e-3).
    try std.testing.expectApproxEqAbs(feasible.gap - 2.0 * @log(1.0 + delta), inflated.gap, 2.0 * delta * delta);
}
