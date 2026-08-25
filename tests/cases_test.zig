//! Tests driven by the bundled case manifest (`cases/cases.zig`, imported as
//! the `cases` build module). Reached by the test target's root
//! (`test_root.zig` → `tests/all.zig` → here).
//!
//! The data says what a case *is* (tier + claim); this file carries the
//! claimed values — AR pins, tier-2 settings — and the loop that derives
//! each case's obligations from tier x claim. Tier legend: dev.md.

const std = @import("std");
const csar = @import("../src/root.zig");
const cases = @import("cases");
const helpers = @import("helpers.zig");
const Vec3 = csar.Vec3;

const Pin = struct { name: []const u8, ar: f64 };

/// Closed-form pins: the AR is a ground-truth data-fact from the fixture's
/// construction (points on a known gnomonic-plane ellipse), stored test-side
/// only for enforcement uniformity — one loop, one bump-policy site. NEVER
/// bumped: a mismatch here is a solver bug, not drift.
const exact_pins = [_]Pin{
    .{ .name = "exact_min3_ar5", .ar = 5 },
    .{ .name = "exact_tiny_ar3", .ar = 3 },
    .{ .name = "exact_w76_ar20", .ar = 20 },
    .{ .name = "exact_w82_ar1p4", .ar = 1.4230800000000001 },
    .{ .name = "exact_w84_ar1000", .ar = 1000 },
    .{ .name = "exact_w85_ar2", .ar = 2.0154109287112303 },
    .{ .name = "exact_w85_ar2_fill", .ar = 2.0154109287112303 },
    .{ .name = "exact_w88_ar10", .ar = 10 },
    .{ .name = "exact_w88_ar1p5", .ar = 1.5007599182432787 },
    .{ .name = "exact_w89_ar2", .ar = 2.0006285794105323 },
};

/// Measured pins: solver-derived, bumpable — but a bump is a reviewed change
/// whose PR says why (CLAUDE.md "Performance & regression monitoring": a
/// shift is a regression signal first). The grouping is the marking; there
/// is no per-entry flag.
const measured_pins = [_]Pin{
    .{ .name = "dnc_small_wide", .ar = 2.345914858647444 },
    .{ .name = "h3_r12_equator", .ar = 1.1747706650563783 },
    .{ .name = "h3_r12_midLat", .ar = 1.0546757905476078 },
    .{ .name = "h3_r12_pent", .ar = 1.000000000028632 },
    .{ .name = "h3_r12_ring10", .ar = 1.0265391285748902 },
    .{ .name = "h3_r15_equator", .ar = 1.1747700613978662 },
    .{ .name = "h3_r15_midLat", .ar = 1.0546753510934872 },
    .{ .name = "h3_r15_pent", .ar = 1.0000000014804105 },
    .{ .name = "h3_r15_ring10", .ar = 1.2584076676894103 },
    .{ .name = "h3_r5_equator", .ar = 1.1752958153842907 },
    .{ .name = "h3_r5_midLat", .ar = 1.0545590295012641 },
    .{ .name = "h3_r5_pent", .ar = 1.0000000000002196 },
    .{ .name = "h3_r5_ring10", .ar = 1.243366353672534 },
    .{ .name = "h3_r9_equator", .ar = 1.1747851119522874 },
    .{ .name = "h3_r9_midLat", .ar = 1.054683064195106 },
    .{ .name = "h3_r9_pent", .ar = 1.0000000000033948 },
    .{ .name = "h3_r9_ring10", .ar = 1.2580981665189603 },
    .{ .name = "h3_res05", .ar = 1.0666666878954056 },
    .{ .name = "h3_res09", .ar = 1.0666666666762255 },
    .{ .name = "h3_res12", .ar = 1.0666666666666949 },
    .{ .name = "h3_res15", .ar = 1.0666666666666669 },
    .{ .name = "ha_05", .ar = 1.0058545383400732 },
    .{ .name = "ha_08", .ar = 1.0077908248743077 },
    .{ .name = "ha_10", .ar = 1.0105582152823531 },
    .{ .name = "ha_12", .ar = 1.0166530149054471 },
    .{ .name = "ha_14", .ar = 1.0368555055771478 },
    .{ .name = "hex", .ar = 1.0000000000000004 },
    .{ .name = "ico_00", .ar = 1.0000000000000004 },
    .{ .name = "ico_01", .ar = 1.0000000000000013 },
    .{ .name = "ico_02", .ar = 1.0000000000000009 },
    .{ .name = "ico_03", .ar = 1.0000000000000004 },
    .{ .name = "ico_04", .ar = 1.0000000000000004 },
    .{ .name = "ico_05", .ar = 1.0000000000000004 },
    .{ .name = "ico_06", .ar = 1.0000000000000004 },
    .{ .name = "ico_07", .ar = 1.0000000000000009 },
    .{ .name = "ico_08", .ar = 1.0000000000000009 },
    .{ .name = "ico_09", .ar = 1.0000000000000009 },
    .{ .name = "ico_10", .ar = 1.0000000000000013 },
    .{ .name = "ico_11", .ar = 1.0000000000000013 },
    .{ .name = "ico_12", .ar = 1.0000000000000004 },
    .{ .name = "ico_13", .ar = 1.0000000000000004 },
    .{ .name = "ico_14", .ar = 1.0000000000000004 },
    .{ .name = "ico_15", .ar = 1.0000000000000004 },
    .{ .name = "ico_16", .ar = 1.0000000000000004 },
    .{ .name = "ico_17", .ar = 1.0000000000000004 },
    .{ .name = "ico_18", .ar = 1.0000000000000004 },
    .{ .name = "ico_19", .ar = 1.0000000000000009 },
    .{ .name = "np100", .ar = 1.0911969178517065 },
    .{ .name = "np20", .ar = 1.0177775789268264 },
    .{ .name = "np400", .ar = 1.0192804795923 },
    .{ .name = "oct_n0", .ar = 1.0000000000000004 },
    .{ .name = "oct_n1", .ar = 1.0000000000000004 },
    .{ .name = "oct_n2", .ar = 1.0000000000000004 },
    .{ .name = "oct_n3", .ar = 1.0000000000000004 },
    .{ .name = "oct_s0", .ar = 1.0000000000000004 },
    .{ .name = "oct_s1", .ar = 1.0000000000000004 },
    .{ .name = "oct_s2", .ar = 1.0000000000000004 },
    .{ .name = "oct_s3", .ar = 1.0000000000000004 },
    .{ .name = "wide_cap82", .ar = 1.15963441886284510 },
    .{ .name = "wide_cap85", .ar = 1.26918078287291670 },
    .{ .name = "wide_cap89", .ar = 1.54199445138181850 },
};

const pins = exact_pins ++ measured_pins;

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

test "pin and settings tables carry no stale keys" {
    // The other direction — a case missing its entry — fails loudly in the
    // tier x claim loop via requirePin/requireSettings; this catches the
    // orphaned row a rename or deletion leaves behind.
    for (pins) |p| try std.testing.expect(cases.byName(p.name) != null);
    for (settings) |s| try std.testing.expect(cases.byName(s.name) != null);
}

/// The pinned AR for a case, or a labeled hard failure: a tier <= 1
/// `converges` case without a pin is a corpus bug, not a skip.
pub fn requirePin(name: []const u8) !f64 {
    for (pins) |p| if (std.mem.eql(u8, p.name, name)) return p.ar;
    helpers.diagPrint("missing AR pin for case={s} (tests/cases_test.zig)\n", .{name});
    return error.MissingPin;
}

/// The recorded settings for a tier-2 case, or a labeled hard failure.
fn requireSettings(name: []const u8) !Setting {
    for (settings) |s| if (std.mem.eql(u8, s.name, name)) return s;
    helpers.diagPrint("missing tier-2 settings for case={s} (tests/cases_test.zig)\n", .{name});
    return error.MissingSettings;
}

test "requirePin and requireSettings fail loudly on an unlisted case" {
    helpers.quiet_diagnostics = true;
    defer helpers.quiet_diagnostics = false;
    try std.testing.expectError(error.MissingPin, requirePin("not_a_pinned_case"));
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

                // Tiers 0-1 additionally pin the AR. The certified duality
                // gap is the source of truth for correctness; AR agreement
                // is a cross-implementation / cross-version sanity check.
                if (case.tier <= 1) {
                    try checkArEq(entry.name, try requirePin(entry.name), c.aspectRatio(), tol);
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

                var z = Vec3.zero;
                for (inf.cert.indices, inf.cert.lambdas) |idx, l| {
                    z = Vec3.lincomb(1.0, z, l, Vec3{ .m = case.points[idx] });
                }
                try std.testing.expect(z.norm() < 1e-2);
                // residual matches the computed witness magnitude (to a couple of ulp).
                try std.testing.expect(@abs(inf.residual - z.norm()) < 1e-6);
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
