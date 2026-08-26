//! The solvable frontier as pinned numbers: synthetic triangle cells
//! at descending scale θ (σ_max ~ 1/θ), solved at the corpus pin.
//! Per rung, two pinned counts:
//!  - `raw`     cells returning `.converged`;
//!  - `genuine` of those, cells whose oracle-f128 gap is within
//!    GAP_TOL — the certification is real, not evaluation noise.
//! raw > genuine means certifications were granted on evaluation
//! noise. The stack is deterministic cross-platform (qmath
//! transcendentals, fused ops), so the counts are exact pinnable
//! facts: a solver change that moves one fails this test until the
//! pin is re-pinned in the same PR — the frontier shift becomes a
//! reviewable data diff, flag-and-reconcile like any fixture pin.
//!
//! Untimed by design (timing is the batches' job), and deliberately
//! outside the batches' every-cell-converges contract: the bottom
//! rungs converge for nobody today — headroom future work can
//! visibly claim.

const std = @import("std");
const csar = @import("../src/root.zig");
const oracle = @import("../src/oracle.zig");
const cases = @import("cases");
const helpers = @import("helpers.zig");
const test_options = @import("test_options");

const SEEDS = 32;

const Rung = struct { theta: f64, raw: u32, genuine: u32 };

/// Pinned on main. Re-pin protocol: on mismatch the test prints every
/// rung's measured counts (run `just test-slow`); copy them in and
/// explain the shift in the PR body.
const LADDER = [_]Rung{
    .{ .theta = 3e-9, .raw = 32, .genuine = 32 },
    .{ .theta = 1e-9, .raw = 10, .genuine = 5 },
    .{ .theta = 4e-10, .raw = 1, .genuine = 0 },
    .{ .theta = 2.5e-10, .raw = 0, .genuine = 0 },
    .{ .theta = 1.5e-10, .raw = 0, .genuine = 0 },
    .{ .theta = 8e-11, .raw = 0, .genuine = 0 },
};

/// One frontier cell: a fixed isoceles triangle in the tangent chart
/// at a fixed axis — vertices (1,0), (−1/2, ±1/√3), centroid at the
/// origin, second-moment axis ratio 1.5 (clear of the AR≈1
/// eigenvector-degeneracy region) — rotated by seed·golden-angle
/// (rotation re-rolls every floating-point alignment while leaving
/// the problem identical), scaled by θ, and normalized onto the
/// sphere. Three points ⇒ the chart MVEE touches all of them with
/// weights exactly ⅓: total support, no active-set flicker, so count
/// changes measure the precision mechanism and nothing else.
fn cell(theta: f64, seed: u32) [3][3]f64 {
    const b = (csar.Vec3{ .m = .{ 0.6746833, 0.7369618, -0.0411066 } }).normalize();
    // Tangent frame: Gram-Schmidt of e_z against b, then the cross.
    var u = csar.Vec3{ .m = .{ -b.m[2] * b.m[0], -b.m[2] * b.m[1], 1.0 - b.m[2] * b.m[2] } };
    u = u.normalize();
    const v = b.cross(u);

    const phi = @as(f64, @floatFromInt(seed)) * 2.399963229728653; // golden angle
    const c = std.math.cos(phi);
    const s = std.math.sin(phi);
    const q = [3][2]f64{ .{ 1.0, 0.0 }, .{ -0.5, 1.0 / @sqrt(3.0) }, .{ -0.5, -1.0 / @sqrt(3.0) } };

    var pts: [3][3]f64 = undefined;
    for (q, 0..) |qk, k| {
        const qx = theta * (c * qk[0] - s * qk[1]);
        const qy = theta * (s * qk[0] + c * qk[1]);
        var p = csar.Vec3.lincomb(1.0, b, qx, u);
        p = csar.Vec3.lincomb(1.0, p, qy, v);
        pts[k] = p.normalize().m;
    }
    return pts;
}

test "frontier ladder: pinned convergence counts + genuine-certification audit" {
    if (!test_options.slow) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var failed = false;
    for (LADDER) |rung| {
        var raw: u32 = 0;
        var genuine: u32 = 0;
        for (0..SEEDS) |seed| {
            const pts = cell(rung.theta, @intCast(seed));
            var o = try csar.solve(allocator, &pts, cases.pin(csar.SolveOptions));
            defer o.deinit();
            if (o != .converged) continue;
            raw += 1;
            const g128 = (try oracle.evalOutcome(f128, allocator, &o, &pts)).?;
            genuine += @intFromBool(@abs(g128) <= cases.GAP_TOL);
        }
        if (!checkRung(rung, raw, genuine)) failed = true; // report every rung before failing
    }
    try std.testing.expect(!failed);
}

/// Compare measured counts against a rung's pin; print the re-pin
/// line on mismatch. The failure-print branch is exercised by the
/// negative self-test below (the coverage discipline dev.md
/// describes for failure diagnostics).
fn checkRung(rung: Rung, raw: u32, genuine: u32) bool {
    if (raw == rung.raw and genuine == rung.genuine) return true;
    helpers.diagPrint("frontier re-pin needed: theta={e:.1}: raw {d} (pinned {d}), genuine {d} (pinned {d})\n", .{ rung.theta, raw, rung.raw, genuine, rung.genuine });
    return false;
}

test "checkRung: mismatch prints the re-pin line and returns false" {
    helpers.quiet_diagnostics = true;
    defer helpers.quiet_diagnostics = false;
    const rung: Rung = .{ .theta = 1e-9, .raw = 1, .genuine = 1 };
    try std.testing.expect(!checkRung(rung, 0, 0));
    try std.testing.expect(checkRung(rung, 1, 1));
}
