//! Tests for the certificate slice's `T = f128` instantiation
//! (src/linalg_generic.zig, src/gap_generic.zig, halfspace's
//! `Gnomonic`). Per #94's acceptance this proves the instantiation
//! exists and behaves — the f128 *values* become authoritative with
//! the oracle work; here we pin instantiation, basic identities, the
//! f64/f128 gap agreement at f64-noise scale on a promoted case, and
//! branch identity (same active set at both precisions).

const std = @import("std");
const csar = @import("../src/root.zig");
const core = @import("../src/csar.zig");
const linalg = @import("../src/linalg.zig");
const halfspace = @import("../src/halfspace.zig");
const gap_generic = @import("../src/gap_generic.zig");
const qmath = @import("qmath");

const L128 = linalg.Linalg(f128);
const G128 = gap_generic.Gap(f128);
const G64 = gap_generic.Gap(f64);

test "Linalg(f128): Cholesky/logDet and eig2 identities hold at f128" {
    // diag(1, 2, 3): log det = log 6, at f128 precision — beyond what
    // any f64 route could produce.
    var d: L128.Mat3 = .{ .m = .{ 1, 0, 0, 0, 2, 0, 0, 0, 3 } };
    _ = &d;
    const chol = d.cholesky().?;
    const want = qmath.log(@as(f128, 6.0));
    try std.testing.expect(@abs(chol.logDet() - want) <= 4 * std.math.floatEps(f128) * want);

    // [[2,1],[1,2]]: eigenvalues exactly {1, 3}.
    const e = L128.eig2(.{ 2, 1, 1, 2 });
    try std.testing.expect(@abs(e.vals[0] - 1.0) <= 8 * std.math.floatEps(f128));
    try std.testing.expect(@abs(e.vals[1] - 3.0) <= 8 * std.math.floatEps(f128));
}

/// The octant case promoted to T: chart, moments, recovered A_perp,
/// and the constructed dual gap, all at T. Mirrors the f64 pipeline
/// the solver runs, over the same (exactly promotable) inputs.
fn octantGap(comptime T: type, allocator: std.mem.Allocator) !struct { gap: T, cert_n: usize } {
    const G = gap_generic.Gap(T);
    const la = linalg.Linalg(T);
    const proj = halfspace.Gnomonic(T);

    const X = [_]la.Vec3{
        .{ .m = .{ 1, 0, 0 } },
        .{ .m = .{ 0, 1, 0 } },
        .{ .m = .{ 0, 0, 1 } },
    };
    const b = (la.Vec3{ .m = .{ 1, 1, 1 } }).normalize();
    const Q = b.orthoBasis();

    var P_buf: [3][2]T = undefined;
    try std.testing.expect(proj.projectGnomonic(&X, b, Q, &P_buf, 0));
    var Ps: [3][2]T = undefined;
    const s_scale = G.rescaleP(&P_buf, &Ps);
    const w = [_]T{ 1.0 / 3.0, 1.0 / 3.0, 1.0 / 3.0 };
    const moments = G.computeMoments(&Ps, &w, s_scale);
    const A_perp = try G.recoverAPerp(&P_buf, moments.M);

    var scratch = try G.GapScratch.init(allocator, 3);
    defer {
        allocator.free(scratch.active_idx);
        allocator.free(scratch.lam);
        allocator.free(scratch.xa);
        allocator.free(scratch.za);
    }
    var cert_active: [3]usize = undefined;
    var cert_lambdas: [3]T = undefined;
    const r = try G.dualityGapConstructed(&w, b, &X, A_perp, Q, &scratch, &cert_active, &cert_lambdas);
    return .{ .gap = r.gap, .cert_n = r.cert_n };
}

test "Gap(f128) vs Gap(f64): agreement at f64-noise scale, branch identity" {
    const allocator = std.testing.allocator;
    const r64 = try octantGap(f64, allocator);
    const r128 = try octantGap(f128, allocator);

    // The octant's uniform weights are the exact optimum: both gaps are
    // ~eps-level, and they must agree to f64 evaluation noise (the f128
    // value stands as the truth the f64 one approximates).
    try std.testing.expect(@abs(@as(f128, r64.gap) - r128.gap) <= 1e-14);
    // Branch identity: same support at both precisions (#94's phase-1
    // rule; protects the oracle's measurement).
    try std.testing.expectEqual(r64.cert_n, r128.cert_n);
    // And the f64 instantiation through the generic path IS the
    // solver's own: same alias, spot-checked against the public solve.
    var outcome = try csar.solve(allocator, &[_][3]f64{ .{ 1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, 0, 1 } }, .{});
    defer outcome.deinit();
    try std.testing.expect(@abs(outcome.converged.gap - r64.gap) <= 1e-12);
}

test "Gnomonic(f128): feasibility margin rejects like f64" {
    const la = linalg.Linalg(f128);
    const proj = halfspace.Gnomonic(f128);
    const X = [_]la.Vec3{ .{ .m = .{ 1, 0, 0 } }, .{ .m = .{ 0, 1, 0 } } };
    const b = la.Vec3{ .m = .{ 1, 0, 0 } }; // b·X[1] = 0 < margin
    var P: [2][2]f128 = undefined;
    try std.testing.expect(!proj.projectGnomonic(&X, b, b.orthoBasis(), &P, 1e-30));
}

test "sigma0 comptime guard: the f64 instantiation reproduces the literal" {
    // The guard lives in gap_generic.zig as a comptime assert; this
    // test just forces both instantiations' analysis so the guard runs
    // even if the suite otherwise skipped one.
    comptime {
        _ = G64;
        _ = G128;
    }
    // core's f64 aliases are the same instantiation.
    try std.testing.expectEqual(@as(usize, @sizeOf(core.GapResult)), @sizeOf(G64.GapResult));
}
