//! The gap oracle (#9 phase 1): re-evaluate a solve outcome's
//! certificate gap at a wider scalar `T`, through the SOLVER'S OWN
//! gap path — `Gap(T).gapFromMultipliers`, the identical arithmetic
//! only wider — separating "the iterate is bad" from "the gap
//! evaluation is noisy". Debug instrument: deliberately not exported
//! from root.zig, zero solve-path contact. NOT `cert_dual`, which is
//! an independent construction (Cholesky of the materialized A)
//! answering a different question.
//!
//! Reconstruction (pinned on #95): everything comes from the returned
//! outcome plus the input points. A is promoted from the outcome's
//! factored (Q, σ) — f64 → T widening is exact, and buildOutcome's
//! handedness flip of v₂ is harmless here since only v·vᵀ enters the
//! gap. Multipliers come from the shipped cert; they are
//! boundary-rescaled (#88), which the λ-scale-invariant gap absorbs
//! mathematically — but the rescale's one rounding per entry moves the
//! recomputed gap by EVALUATION-FLOOR noise (the σ_max·ε cancellation
//! in M = LᵀZL), not ulp noise. The f64 bootstrap therefore reproduces
//! the outcome's gap to floor scale, and that observation is itself
//! the first demonstration of the noise this instrument measures
//! (bound and measurements: tests/oracle_test.zig). A_perp is
//! deliberately NOT rebuilt through chart → recoverAPerp: the
//! ACTIVE_THRESH truncation would perturb M at exactly the resolution
//! #96 measures.
//!
//! Population caveats: sentinel outcomes (empty cert; Q/σ carry no
//! information) and infeasible outcomes return null. An `Uncertified`
//! snapshot is the last CERTIFIED iterate, not the final one — the
//! oracle evaluates what ships.

const std = @import("std");

const linalg = @import("linalg.zig");
const gap_generic = @import("gap_generic.zig");
const api = @import("api.zig");
const config = @import("config.zig");
const tol = config.tol;

/// Re-evaluate a shipped certificate at `T` from its parts: the
/// factored iterate (Q, σ) and the active set in the caller's `X[]`
/// indexing. Returns null when M's Cholesky fails at `T` — the same
/// indefinite-dual guard the solver applies; #96 compares that
/// failure across precisions (branch identity).
pub fn evalCert(
    comptime T: type,
    allocator: std.mem.Allocator,
    X: []const [3]f64,
    Q: linalg.Mat3,
    sigma: [3]f64,
    indices: []const u32,
    lambdas: []const f64,
) !?T {
    const G = gap_generic.Gap(T);
    const la = linalg.Linalg(T);
    const k = indices.len;
    std.debug.assert(k > 0 and lambdas.len == k);

    const b = promote(T, Q.col(0));
    const v1 = promote(T, Q.col(1));
    const v2 = promote(T, Q.col(2));
    const sig: [2]T = .{ sigma[1], sigma[2] };

    const xa = try allocator.alloc(la.Vec3, k);
    defer allocator.free(xa);
    const lam = try allocator.alloc(T, k);
    defer allocator.free(lam);
    const za = try allocator.alloc(la.Vec3, k);
    defer allocator.free(za);
    const lam_out = try allocator.alloc(T, k);
    defer allocator.free(lam_out);
    for (0..k) |i| {
        const p = X[indices[i]];
        xa[i] = .{ .m = .{ p[0], p[1], p[2] } };
        lam[i] = lambdas[i];
    }

    const r = G.gapFromMultipliers(b, v1, v2, sig, xa, lam, za, lam_out);
    if (r.gap == tol.GAP_UNCERTIFIED) return null;
    return r.gap;
}

/// Convenience entry over a solve's returned outcome. Returns null
/// where there is nothing to re-evaluate: `infeasible` (no iterate)
/// and sentinel uncertified outcomes (empty cert).
pub fn evalOutcome(
    comptime T: type,
    allocator: std.mem.Allocator,
    outcome: *const api.Outcome,
    X: []const [3]f64,
) !?T {
    const View = struct { Q: linalg.Mat3, sigma: [3]f64, cert: api.Cert };
    const view: View = switch (outcome.*) {
        .converged => |c| .{ .Q = c.Q, .sigma = c.sigma, .cert = c.cert },
        .did_not_converge, .precision_floor => |u| .{ .Q = u.Q, .sigma = u.sigma, .cert = u.cert },
        .infeasible => return null,
    };
    if (view.cert.indices.len == 0) return null;
    return evalCert(T, allocator, X, view.Q, view.sigma, view.cert.indices, view.cert.lambdas);
}

/// f64 → T widening of a vector: exact for every float `T` ≥ f64, so
/// the `T` evaluation sees exactly the shipped iterate.
fn promote(comptime T: type, v: linalg.Vec3) linalg.Linalg(T).Vec3 {
    return .{ .m = .{ v.m[0], v.m[1], v.m[2] } };
}
