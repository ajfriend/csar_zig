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
const G64 = gap_generic.Gap(f64);

test "Linalg(f128): Cholesky/logDet and eig2 identities hold at f128" {
    // diag(1, 2, 3): log det = log 6, at f128 precision — beyond what
    // any f64 route could produce.
    const d: L128.Mat3 = .{ .m = .{ 1, 0, 0, 0, 2, 0, 0, 0, 3 } };
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
    defer scratch.deinit(allocator);
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
    // value stands as the truth the f64 one approximates). Measured:
    // gap64 = -eps(f64) exactly, gap128 ~ eps(f128) — diff 2.2e-16,
    // 45x under the bound; deterministic cross-platform (qmath
    // transcendentals + guaranteed-fused @mulAdd, no libm variance).
    try std.testing.expect(@abs(@as(f128, r64.gap) - r128.gap) <= 1e-14);
    // Branch identity: same support at both precisions (#94's phase-1
    // rule; protects the oracle's measurement).
    try std.testing.expectEqual(r64.cert_n, r128.cert_n);
    // Sanity tie to the public solve on the same input (identity of
    // the f64 path is proven by the alias/type system, not this bound
    // — the solver's own w need not be the exact uniform w above).
    var outcome = try csar.solve(allocator, &[_][3]f64{ .{ 1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, 0, 1 } }, .{});
    defer outcome.deinit();
    try std.testing.expect(@abs(outcome.converged.gap - r64.gap) <= 1e-12);
    // The alias identity itself, exactly: core's f64 types ARE the
    // Gap(f64) instantiation (memoized), so the comptime sigma0 guard
    // in gap_generic.zig runs on every compile of the solver.
    comptime std.debug.assert(core.GapResult == G64.GapResult);
}

test "Gnomonic(f128): feasibility margin rejects like f64" {
    const la = linalg.Linalg(f128);
    const proj = halfspace.Gnomonic(f128);
    const X = [_]la.Vec3{ .{ .m = .{ 1, 0, 0 } }, .{ .m = .{ 0, 1, 0 } } };
    const b = la.Vec3{ .m = .{ 1, 0, 0 } }; // b·X[1] = 0 < margin
    var P: [2][2]f128 = undefined;
    try std.testing.expect(!proj.projectGnomonic(&X, b, b.orthoBasis(), &P, 1e-30));
}
