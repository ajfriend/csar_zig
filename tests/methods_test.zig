//! Tests for `SolveOptions.method` and the trust solver's wide-cap
//! canaries (`src/trust.zig`), incl. the away-step FW solver kept for
//! the record.
//!
//! Coverage:
//!  - the wide-cap manifest cases (cases/zon/wide_cap*.zon) that the
//!    removed alternating path limit-cycled on: `.trust` must converge
//!    within iteration ceilings, matching the Clarabel SDP cross-check;
//!  - `.auto` is a pure alias for `Method.recommended` (currently
//!    `.trust`) — identical outcomes, and the resolution pinned;
//!  - certificate sanity on a trust solve (λ ≥ 0, certified gap in
//!    [−gap_tol, gap_tol], primal feasibility ≤ roundoff).

const std = @import("std");
const csar = @import("../src/root.zig");
const cases = @import("cases");
const helpers = @import("helpers.zig");
const csar_core = @import("../src/csar.zig");

const GAP_TOL: f64 = 1e-6;
/// The certified gap bounds primal suboptimality, but AR is a ratio of
/// eigenvalues of a near-optimal iterate — allow a few × 1e-4 relative
/// against the Clarabel reference (which has its own ~1e-8 tolerance).
const AR_REF_REL_TOL: f64 = 1e-3;

test "trust: wide-cap iteration ceilings (CANARY-style) + Clarabel cross-check" {
    // Trust-region iteration guard on the wide-angle frontier
    // (flag-don't-bump policy: a shift is a regression signal, not a
    // number to update). Observed: 20 / 34 /
    // 14; ceilings leave headroom for FP drift across platforms while
    // catching a trust-region or oracle regression that turns the
    // frontier slow again.
    //
    // The AR is cross-checked against the CLARABEL reference from the
    // wide-cap investigation's SDP probe — independent provenance from
    // the solver-derived `.ar` pins the manifest loop
    // (tests/cases_test.zig) checks on the same cases. Explicit
    // `.method = .trust` (not the default), so this keeps guarding the
    // trust path even if `.auto` is ever re-pointed.
    const allocator = std.testing.allocator;
    const fixtures = [_]struct { name: []const u8, ceiling: u32, clarabel_ar: f64 }{
        .{ .name = "wide_cap82", .ceiling = 30, .clarabel_ar = 1.159634 },
        .{ .name = "wide_cap85", .ceiling = 50, .clarabel_ar = 1.269181 },
        .{ .name = "wide_cap89", .ceiling = 25, .clarabel_ar = 1.542028 },
    };
    for (fixtures) |f| {
        const pts = helpers.casePoints(f.name);
        var o = try csar.solve(allocator, pts, .{ .method = .trust });
        defer o.deinit();
        try std.testing.expect(std.meta.activeTag(o) == .converged);
        const c = o.converged;
        try std.testing.expect(@abs(c.gap) <= GAP_TOL);
        // Structured-cone primal feasibility: within roundoff of 0.
        try std.testing.expect(csar.checkFeasibility(c, pts) <= 1e-12);
        try std.testing.expect(@abs(c.aspectRatio() - f.clarabel_ar) <= AR_REF_REL_TOL * f.clarabel_ar);
        try std.testing.expect(c.diag.totalIters() <= f.ceiling);
    }
}

test "auto: resolves to Method.recommended (pure alias, identical outcomes)" {
    // .auto is the "library's current recommendation" placeholder;
    // `Method.recommended` is the single source of truth for the
    // resolution, and this test is where a re-point gets recorded.
    try std.testing.expectEqual(csar.Method.trust, csar.Method.recommended);
    try std.testing.expectEqual(csar.Method.Resolved.trust, csar.Method.auto.resolved());

    // Behavioral half: same dispatch target ⇒ identical outcomes,
    // including the diag tag (the expectEqual on `.diag.trust` panics
    // on a wrong active tag, so a silent re-point trips loudly).
    const allocator = std.testing.allocator;
    for ([_][]const u8{ "hex", "h3_res09" }) |name| {
        const case = cases.byName(name) orelse unreachable;
        var trust_out = try csar.solve(allocator, case.points, .{ .method = .trust });
        defer trust_out.deinit();
        var auto_out = try csar.solve(allocator, case.points, .{ .method = .auto });
        defer auto_out.deinit();
        try std.testing.expectEqual(
            trust_out.converged.diag.trust,
            auto_out.converged.diag.trust,
        );
        try std.testing.expectEqual(trust_out.converged.gap, auto_out.converged.gap);
        try std.testing.expectEqual(trust_out.converged.sigma, auto_out.converged.sigma);
    }
}

test "mveeFwAway: converges the design and keeps weights in the simplex" {
    // Bit-rot guard for the away-step FW solver, kept in-tree for the
    // record after the stage-1 experiment (docs/away-step-fw.md
    // "Stage 1 findings"): hazard-free by construction but slower than
    // pairwise as the trust oracle. This pins its correctness so the
    // recorded findings stay reproducible.
    // Slightly irregular quad in the chart: optimal design weights are
    // non-uniform, support is all 4 points.
    const P = [_][2]f64{ .{ 1.0, 0.1 }, .{ -0.9, 0.2 }, .{ 0.15, 1.1 }, .{ -0.1, -1.0 } };
    var Ql: [4]csar.Vec3 = undefined;
    var w = [_]f64{ 0.25, 0.25, 0.25, 0.25 };
    csar_core.mveeFwAway(&P, 200, 1e-10, &Ql, &w);

    var sum: f64 = 0;
    for (w) |wi| {
        try std.testing.expect(wi >= 0);
        sum += wi;
    }
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), sum, 1e-12);

    // Design optimality: g_i = q_i' S^-1 q_i within tol of 3 on the
    // support (Kiefer-Wolfowitz).
    var S = csar.Mat3.zero;
    for (Ql, 0..) |q, i| S.addSymRank1(w[i], q);
    const L = S.cholesky().?;
    for (Ql, 0..) |q, i| {
        if (w[i] > 1e-9) {
            const gi = q.dot(L.solve(q));
            try std.testing.expect(@abs(gi - 3.0) < 1e-6);
        }
    }
}

test "mveeFwAway: kappa-limited input exits via the stall guard, invariants intact" {
    // Near-collinear chart points: the lifted design is ill-conditioned,
    // so the away-step gap hits an f64 floor well above zero and stops
    // improving geometrically — the noise-floor stall exit must fire
    // (inner_tol = 0 makes the convergence break unreachable) and the
    // weights must still be a valid design. Guards the stall exit the
    // convergent-input test never reaches.
    var P: [8][2]f64 = undefined;
    var Ql: [8]csar.Vec3 = undefined;
    var w: [8]f64 = undefined;
    for (&P, 0..) |*p, i| {
        const x = -1.0 + 2.0 * @as(f64, @floatFromInt(i)) / 7.0;
        // ~1e-9 transverse spread: comfortably above degeneracy, far
        // below conditioning that would let the gap reach the tol.
        p.* = .{ x, 1e-9 * (1.0 + 0.3 * x + x * x) };
        w[i] = 1.0 / 8.0;
    }
    csar_core.mveeFwAway(&P, 100_000, 0.0, &Ql, &w);

    var sum: f64 = 0;
    for (w) |wi| {
        try std.testing.expect(wi >= 0);
        sum += wi;
    }
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), sum, 1e-12);
}

test "initWeights: fully degenerate input falls back to uniform weights" {
    // All points coincident: the farthest-point seed's d0 scan finds
    // nothing above tol.TINY and must fall back to uniform weights
    // (n > SEED_SPARSE_MIN_POINTS so the sparse-seed path is taken;
    // n and the coordinates are powers of two so the centroid sum and
    // scale are binary-exact and the point-to-centroid distances are
    // exactly zero).
    const n = 32;
    var P: [n][2]f64 = undefined;
    var w: [n]f64 = undefined;
    for (&P) |*p| p.* = .{ 0.5, -0.25 };
    csar_core.initWeights(&P, &w);
    for (w) |wi| try std.testing.expectApproxEqAbs(1.0 / @as(f64, n), wi, 1e-15);
}

test "trust: certificate sanity on a wide-cap solve" {
    const allocator = std.testing.allocator;
    const pts = helpers.casePoints("wide_cap85");
    var outcome = try csar.solve(allocator, pts, .{ .method = .trust });
    defer outcome.deinit();
    const c = outcome.converged;
    // Weak duality: certified gap is non-negative up to FP noise.
    try std.testing.expect(c.gap >= -1e-10);
    // Dual multipliers are non-negative and the cert carries at least
    // the >= 3 points any non-degenerate cone needs.
    try std.testing.expect(c.cert.indices.len >= 3);
    for (c.cert.lambdas) |lam| try std.testing.expect(lam >= 0);
    // Indices point into the caller's array.
    for (c.cert.indices) |idx| try std.testing.expect(idx < pts.len);
}
