//! Tests driven by the bundled case manifest (`cases/cases.zig`, imported as
//! the `cases` build module). Reached by the test target's root
//! (`test_root.zig` → `tests/all.zig` → here).
//!
//! The data says what a case *is* (tier + claim + its settings-independent
//! AR); this file carries the settings-dependent values — the tier-2
//! settings table — and the loop that derives each case's obligations from
//! tier x claim. Tier legend: dev.md.

const std = @import("std");
const csar = @import("../src/root.zig");
const cases = @import("cases");
const helpers = @import("helpers.zig");

/// Recorded settings for tier-2 cases: the adjustments under which the claim
/// is made (fields not listed keep `cases.pin`'s values). All current entries
/// certify at 1e-4 or tighter (issue #62's sweep), so `gap_tol = 1e-3` — the
/// loosest setting the `gap_tol` docs advise — carries >= 10x headroom each.
/// A case needing a different knob extends this struct.
const Setting = struct { name: []const u8, gap_tol: f64 };
const settings = [_]Setting{
    .{ .name = "band_S150_w1em5", .gap_tol = 1e-3 },
    .{ .name = "sliver_S150_d1em6", .gap_tol = 1e-3 },
    .{ .name = "sliver_S175_d1em4", .gap_tol = 1e-3 },
    .{ .name = "sliver_S90_d1em6", .gap_tol = 1e-3 },
};

/// Gap-reproduction tolerance for the cert.zig obligations: the
/// internal gap route and `cert.verify` factor A differently (internal
/// eigenbasis vs Cholesky of the materialized matrix), so agreement is
/// limited by log-det conditioning on the worst cases. Measured worst
/// 1.7e-9 on tiers 0-1; headroom for the tier-2 slivers and platform
/// variance. Never loosen without a call-out.
const GAP_REPRO_TOL: f64 = 1e-7;

/// Scatter a shipped active-set cert into a full-length λ vector.
fn scatter(lam_full: []f64, c: csar.Cert) void {
    @memset(lam_full, 0);
    for (c.indices, c.lambdas) |idx, l| lam_full[idx] = l;
}

test "settings table carries no stale keys" {
    // The other direction — a tier-2 case missing its entry — fails loudly
    // in the tier x claim loop via requireSettings; this catches the
    // orphaned row a rename or deletion leaves behind.
    for (settings) |s| try std.testing.expect(cases.byName(s.name) != null);
}

/// A case's claimed AR, or a labeled hard failure: a tier <= 1 `converges`
/// case without one is a corpus bug, not a skip.
fn requireAr(name: []const u8, case: cases.Case) !f64 {
    return case.ar orelse {
        helpers.diagPrint("missing .ar for case={s} (converges at tier <= 1 requires one)\n", .{name});
        return error.MissingAr;
    };
}

/// The recorded settings for a tier-2 case, or a labeled hard failure.
fn requireSettings(name: []const u8) !Setting {
    for (settings) |s| if (std.mem.eql(u8, s.name, name)) return s;
    helpers.diagPrint("missing tier-2 settings for case={s} (tests/cases_test.zig)\n", .{name});
    return error.MissingSettings;
}

test "requireAr and requireSettings fail loudly on a case without an entry" {
    helpers.quiet_diagnostics = true;
    defer helpers.quiet_diagnostics = false;
    const bare: cases.Case = .{ .description = "", .points = &.{}, .tier = 1, .claim = .converges };
    try std.testing.expectError(error.MissingAr, requireAr("synthetic", bare));
    try std.testing.expectError(error.MissingSettings, requireSettings("not_a_tier2_case"));
}

/// Labeled approx-equal check on aspect ratios. On failure prints
/// the case label + full-precision expected/actual/delta — useful
/// because the all-cases test loop has dozens of iterations and a
/// plain `expect` failure wouldn't say which case tripped it. The
/// failure branch is exercised by a dedicated negative test below,
/// so kcov covers the print path.
fn checkArEq(label: []const u8, expected: f64, actual: f64, tol: f64) !void {
    if (@abs(expected - actual) > tol) {
        helpers.diagPrint(
            "AR mismatch case={s}: expected={d:.17} actual={d:.17} delta={e:.3}\n",
            .{ label, expected, actual, @abs(expected - actual) },
        );
        return error.AspectRatioMismatch;
    }
}

test "checkArEq prints case label on failure" {
    helpers.quiet_diagnostics = true;
    defer helpers.quiet_diagnostics = false;
    try std.testing.expectError(
        error.AspectRatioMismatch,
        checkArEq("diagnostic-selftest", 1.0, 1.1, 1e-6),
    );
}

test "cases.byName: found and not-found" {
    try std.testing.expect(cases.byName("hex") != null);
    try std.testing.expectEqual(@as(?cases.Case, null), cases.byName("definitely_not_a_case"));
}

test "the tier x claim loop: every case's claim enforced at its tier's settings" {
    const allocator = std.testing.allocator;

    for (cases.all) |entry| {
        const case = entry.case;

        // Schema invariants (dev.md's tier legend).
        try std.testing.expect((case.claim == .none) == (case.tier == 3));
        if (case.claim == .rejects) try std.testing.expect(case.tier <= 1);
        if (case.ar != null) try std.testing.expect(case.claim == .converges and case.tier <= 1);

        // The tier names the settings the claim is made under: defaults for
        // tiers 0-1 and 3, the recorded settings for tier 2.
        var opts = cases.pin(csar.SolveOptions);
        if (case.tier == 2) opts.gap_tol = (try requireSettings(entry.name)).gap_tol;
        const tol = opts.gap_tol;

        // One arm per claim: the arm IS the obligation, solve call included
        // (`rejects` must not solve at all — it asserts the refusal).
        switch (case.claim) {
            .rejects => |reject| {
                const want: csar.InputError = switch (reject) {
                    .insufficient_points => error.InsufficientPoints,
                    .coplanar_input => error.CoplanarInput,
                };
                try std.testing.expectError(want, csar.solve(allocator, case.points, opts));
            },
            .converges => {
                var outcome = try csar.solve(allocator, case.points, opts);
                defer outcome.deinit();
                try std.testing.expect(std.meta.activeTag(outcome) == .converged);
                const c = outcome.converged;
                try std.testing.expect(c.aspectRatio() >= 1.0 - 1e-10);
                // Gap: nonneg by weak duality (solver raises on meaningfully-negative
                // gap; ulp-level negatives can slip through here, hence |gap|).
                try std.testing.expect(@abs(c.gap) < tol);

                // Feasibility: ‖Ax_i‖ ≤ b·x_i for all i (tol includes numerics buffer).
                const viol = csar.checkFeasibility(c, case.points);
                try std.testing.expect(viol <= tol);

                // Primal-cert contract: λ ≥ 0, multipliers exported on the
                // normalized dual's constraint boundary (api.zig `Cert`).
                for (c.cert.lambdas) |l| try std.testing.expect(l >= 0);
                try std.testing.expectApproxEqAbs(3.0, helpers.xlamNorm(case.points, c.cert), 1e-12);

                // cert.zig obligations (module-local tests live in
                // cert_test.zig; the per-case ones belong to this loop
                // so tier-2 settings apply). cert_primal on the shipped
                // (A, b) re-certifies at the case's tolerance, with a
                // near-no-op repair and a boundary-normalized export.
                // Repair tolerance: the shipped A_perp is
                // budget-feasible only to kappa(M)*eps (the #54 class);
                // measured worst |scale - 1| = 2.3e-6 on the tier-2
                // slivers, ~1e-12 on tiers 0-1.
                const co = try csar.cert_primal(allocator, case.points, c.A(), c.b());
                var cd = co.certified;
                defer cd.deinit();
                try std.testing.expect(@abs(cd.gap) < tol);
                try std.testing.expectApproxEqAbs(1.0, cd.scale, 1e-4);
                try std.testing.expectApproxEqAbs(3.0, helpers.xlamNorm(case.points, cd.cert), 1e-12);

                // cert_dual reproduces the certified gap from the shipped
                // parts alone — up to the repair charge 3*log(scale),
                // which cert_dual levies on the shipped iterate's
                // kappa(M)*eps containment slack (the #54 class) and
                // the solver's internal gap does not — and round-trips
                // certify's own export.
                const lam_full = try allocator.alloc(f64, case.points.len);
                defer allocator.free(lam_full);
                scatter(lam_full, c.cert);
                const v = csar.cert_dual(case.points, c.A(), c.b(), lam_full).certified;
                try std.testing.expectApproxEqAbs(c.gap + 3.0 * @log(v.scale), v.gap, GAP_REPRO_TOL);
                try std.testing.expectApproxEqAbs(1.0, v.scale, 1e-4);
                try std.testing.expectApproxEqAbs(1.0, v.dual_scale, 1e-9);
                scatter(lam_full, cd.cert);
                const rv = csar.cert_dual(case.points, c.A(), c.b(), lam_full).certified;
                try std.testing.expectApproxEqAbs(cd.gap, rv.gap, GAP_REPRO_TOL);

                // Tiers 0-1 additionally pin the AR. The certified duality
                // gap is the source of truth for correctness; AR agreement
                // is a cross-implementation / cross-version sanity check.
                if (case.tier <= 1) {
                    try checkArEq(entry.name, try requireAr(entry.name, case), c.aspectRatio(), tol);
                }
            },
            .infeasible => {
                var outcome = try csar.solve(allocator, case.points, opts);
                defer outcome.deinit();
                try std.testing.expect(std.meta.activeTag(outcome) == .infeasible);
                const inf = outcome.infeasible;
                // Verify Farkas certificate: λ ≥ 0, ∑ λ ≈ 1, ‖∑ λᵢ xᵢ‖ small.
                var sum: f64 = 0;
                for (inf.cert.lambdas) |l| {
                    try std.testing.expect(l >= 0);
                    sum += l;
                }
                try std.testing.expect(@abs(sum - 1.0) < 1e-9);

                const wit = helpers.xlamNorm(case.points, inf.cert);
                try std.testing.expect(wit < 1e-2);
                // residual matches the computed witness magnitude (to a couple of ulp).
                try std.testing.expect(@abs(inf.residual - wit) < 1e-6);
            },
            .none => {
                // Tier 3: no claim — the solve returning is the whole check.
                var outcome = try csar.solve(allocator, case.points, opts);
                outcome.deinit();
            },
        }
    }
}

test "the frontier stays populated: some case is not default-correct" {
    // The tier legend's one corpus invariant: tier 3 (or non-default-correct
    // tier 2) stays nonempty — these cases also cover the non-converged
    // reporting paths (examples/cases.zig's DNC print).
    var found = false;
    for (cases.all) |entry| {
        if (entry.case.tier >= 2) found = true;
    }
    try std.testing.expect(found);
}

test "Shape invariants: Q right-handed orthonormal, sigma paired with columns, AR = sigma[2]/sigma[1]" {
    const allocator = std.testing.allocator;
    const case = cases.byName("np100").?;

    var outcome = try csar.solve(allocator, case.points, cases.pin(csar.SolveOptions));
    defer outcome.deinit();

    try std.testing.expect(std.meta.activeTag(outcome) == .converged);
    const c = outcome.converged;

    const c0 = c.Q.col(0);
    const c1 = c.Q.col(1);
    const c2 = c.Q.col(2);

    // Q's three columns are an orthonormal basis.
    try std.testing.expect(@abs(c0.dot(c0) - 1.0) < 1e-14);
    try std.testing.expect(@abs(c1.dot(c1) - 1.0) < 1e-14);
    try std.testing.expect(@abs(c2.dot(c2) - 1.0) < 1e-14);
    try std.testing.expect(@abs(c0.dot(c1)) < 1e-14);
    try std.testing.expect(@abs(c0.dot(c2)) < 1e-14);
    try std.testing.expect(@abs(c1.dot(c2)) < 1e-14);

    // Right-handed: c0 × c1 = c2.
    const cross = c0.cross(c1);
    try std.testing.expect(@abs(cross.m[0] - c2.m[0]) < 1e-14);
    try std.testing.expect(@abs(cross.m[1] - c2.m[1]) < 1e-14);
    try std.testing.expect(@abs(cross.m[2] - c2.m[2]) < 1e-14);

    // b() returns the first column.
    const b = c.b();
    try std.testing.expect(@abs(b.m[0] - c0.m[0]) < 1e-14);
    try std.testing.expect(@abs(b.m[1] - c0.m[1]) < 1e-14);
    try std.testing.expect(@abs(b.m[2] - c0.m[2]) < 1e-14);

    // sigma[0] = 1/√3, tangent eigenvalues ascending, AR = sigma[2]/sigma[1].
    try std.testing.expect(@abs(c.sigma[0] - 1.0 / @sqrt(3.0)) < 1e-14);
    try std.testing.expect(c.sigma[1] <= c.sigma[2]);
    try std.testing.expect(@abs(c.sigma[2] / c.sigma[1] - c.aspectRatio()) < 1e-14);

    // c.A() reconstructs A faithfully: each Q column is an eigenvector of
    // A with the corresponding sigma as eigenvalue.
    const A_mat = c.A();
    const Ac0 = A_mat.apply(c0);
    const Ac1 = A_mat.apply(c1);
    const Ac2 = A_mat.apply(c2);
    try std.testing.expect(@abs(c0.dot(Ac0) - c.sigma[0]) < 1e-12);
    try std.testing.expect(@abs(c1.dot(Ac1) - c.sigma[1]) < 1e-12);
    try std.testing.expect(@abs(c2.dot(Ac2) - c.sigma[2]) < 1e-12);
}
