//! Tests for the gap oracle (src/oracle.zig) — #95's acceptance.
//!
//! Coverage:
//!  - f64 bootstrap: the oracle's f64 re-evaluation reproduces every
//!    converged corpus outcome's gap to evaluation-floor noise (see
//!    BOOTSTRAP_TOL — the bound is measured, and its scale is itself
//!    a finding);
//!  - branch identity across the corpus: the f128 evaluation succeeds
//!    exactly where the f64 one does (same Cholesky verdict), on the
//!    same given active set;
//!  - the Uncertified path evaluates the last-certified snapshot;
//!  - null returns: infeasible outcomes and empty-cert sentinels.
//!
//! The numeric verdicts — what gap_f128 says about the f64 floor —
//! belong to #96, not here.

const std = @import("std");
const csar = @import("../src/root.zig");
const oracle = @import("../src/oracle.zig");
const cases = @import("cases");
const helpers = @import("helpers.zig");

/// |oracle_f64 − outcome.gap|: same arithmetic, same factored A; the
/// only input difference is the shipped λ's boundary rescale (one
/// rounding per entry). That ulp-level perturbation moves the gap by
/// EVALUATION-FLOOR noise, not ulp noise: M = LᵀZL sums σ_max-sized
/// products that cancel to O(1), so the diff scales with the
/// σ_max·ε floor (measured: ~1e-12 on h3_r9, ~3e-11 on r12, worst
/// 9.1e-10 on h3_r15_ring10) — a bootstrap-sized demonstration of
/// exactly the phenomenon the oracle program measures. Bit-for-bit
/// was never on the table; per-cell floor-normalized verdicts are
/// #96's. Never loosen without a call-out.
const BOOTSTRAP_TOL: f64 = 1e-8;

test "corpus: f64 bootstrap reproduces shipped gaps; f128 branch identity" {
    const allocator = std.testing.allocator;
    var worst: f64 = 0;
    for (cases.all) |entry| {
        const case = entry.case;
        if (case.claim != .converges) continue;
        var outcome = try csar.solve(allocator, case.points, cases.pin(csar.SolveOptions));
        defer outcome.deinit();
        const c = switch (outcome) {
            .converged => |c| c,
            else => continue,
        };

        const o64 = (try oracle.evalOutcome(f64, allocator, &outcome, case.points)).?;
        const o128 = (try oracle.evalOutcome(f128, allocator, &outcome, case.points)).?;

        // Bootstrap: the f64 oracle is the solver's own evaluation on
        // the shipped parts.
        const diff = @abs(o64 - c.gap);
        if (diff > worst) worst = diff;
        try std.testing.expect(diff <= BOOTSTRAP_TOL);

        // Branch identity: both precisions succeeded (non-null above),
        // and the wider evaluation is sane — the value verdict is #96's.
        try std.testing.expect(std.math.isFinite(o128));
        try std.testing.expect(@abs(@as(f128, o64) - o128) < 1e-3);
    }
    // Uncomment to re-measure: std.debug.print("bootstrap worst = {e}\n", .{worst});
}

test "the Uncertified path evaluates the last-certified snapshot" {
    const allocator = std.testing.allocator;
    var outcome = try helpers.solveClampedWideCapDnc(allocator);
    defer outcome.deinit();
    const u = outcome.did_not_converge;
    const o64 = (try oracle.evalOutcome(f64, allocator, &outcome, helpers.casePoints("wide_cap89"))).?;
    const o128 = (try oracle.evalOutcome(f128, allocator, &outcome, helpers.casePoints("wide_cap89"))).?;
    try std.testing.expect(@abs(o64 - u.gap) <= BOOTSTRAP_TOL);
    try std.testing.expect(std.math.isFinite(o128));
}

test "null: infeasible outcomes and empty-cert sentinels" {
    const allocator = std.testing.allocator;
    var inf = try csar.solve(allocator, helpers.casePoints("infeas_antipodal"), .{});
    defer inf.deinit();
    try std.testing.expectEqual(@as(?f64, null), try oracle.evalOutcome(f64, allocator, &inf, helpers.casePoints("infeas_antipodal")));

    // A sentinel-shaped Uncertified (empty cert), constructed by hand —
    // the same technique extreme_aspect_test uses for payloads.
    var sentinel: csar.Outcome = .{ .did_not_converge = .{
        .Q = .{ .m = .{ 1, 0, 0, 0, 1, 0, 0, 0, 1 } },
        .sigma = .{ 1, 1, 1 },
        .gap = 1e30,
        .gap_floor = 0,
        .diag = .{ .trust = .{ .eager_certified = false, .open_iters = 0, .tr_iters = 0, .recert_attempts = 0, .polish_failures = 0, .gaps_below_model = 0 } },
        .cert = .{ .indices = &[_]u32{}, .lambdas = &[_]f64{} },
        .allocator = allocator,
    } };
    const pts = [_][3]f64{ .{ 1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, 0, 1 } };
    try std.testing.expectEqual(@as(?f64, null), try oracle.evalOutcome(f64, allocator, &sentinel, &pts));
}
