//! The certificate slice, generic over the scalar `T` — the gap
//! evaluation a promoted-iterate oracle re-runs at f128 (#9 phase 1).
//! `Gap(f64)` is re-exported by csar.zig under the original names, so
//! the solver compiles the identical code through aliases; only the
//! slice lives here — the solver loop, FW, and Newton polish stay
//! f64 in csar.zig.
//!
//! T-typed constants (`sigma0`, the KW `budget`) are derived at `T` —
//! see `sigma0`'s doc and comptime guard for the whole story.
//!
//! Guards (branch identity, #9 phase 1): every threshold used here —
//! `tol.PSD_NEG_REL`, `algo.ACTIVE_THRESH`, `tol.UNDERFLOW`,
//! `tol.GAP_UNCERTIFIED`, Cholesky's `!(s > 0)`, and `eig2`'s
//! `EIG2_REL` (linalg_generic.zig) — keeps its f64 literal value at
//! every `T` (comparisons widen exactly), so the f128 evaluation
//! takes the same branches as f64 on promoted iterates. Per-T
//! scaling laws are phase 2's triage. This header is the one
//! authoritative list; the per-site notes point here.

const std = @import("std");
const qmath = @import("qmath");

const config = @import("config.zig");
const algo = config.algo;
const tol = config.tol;

const linalg = @import("linalg.zig");
const api = @import("api.zig");
const SolveError = api.SolveError;

pub fn Gap(comptime T: type) type {
    return struct {
        const la = linalg.Linalg(T);
        const Vec2 = la.Vec2;
        const Vec3 = la.Vec3;
        const Mat2 = la.Mat2;
        const Mat3 = la.Mat3;
        const Mat3x2 = la.Mat3x2;
        const eig2 = la.eig2;

        /// The structural axial eigenvalue, evaluated in comptime_float
        /// (f128-precision) and coerced to `T` — full precision at
        /// f128, and at f64 bit-identical to `config.SIGMA_0`, which is
        /// the SAME comptime expression. The identity is carried by the
        /// guard below, not by any "rounds once" story: an
        /// `@as(T, 3.0)` spelling computes sqrt and divide at T and
        /// lands one ulp off the config literal at f64 — the guard
        /// caught exactly that in this PR's first build.
        const sigma0: T = 1.0 / @sqrt(3.0);
        comptime {
            if (T == f64) std.debug.assert(sigma0 == config.SIGMA_0);
        }

        /// Rescale P_buf into Ps so max ‖Ps‖ = 1 (numerical hygiene for FW).
        /// Returns the scale factor so callers can lift moments back to
        /// unscaled coordinates.
        pub inline fn rescaleP(P_buf: []const [2]T, Ps: [][2]T) T {
            var s2_max: T = 0;
            for (P_buf) |p| {
                const sq = @mulAdd(T, p[1], p[1], p[0] * p[0]);
                if (sq > s2_max) s2_max = sq;
            }
            var s_scale = qmath.sqrt(s2_max);
            if (s_scale < tol.UNDERFLOW) s_scale = 1.0;
            const inv_s = 1.0 / s_scale;
            for (P_buf, 0..) |p, i| Ps[i] = .{ p[0] * inv_s, p[1] * inv_s };
            return s_scale;
        }

        /// Weighted 2D moments of the scaled projected points, lifted back to
        /// original (unscaled) coordinates: center = Σ w·P, M = Σ w·P·Pᵀ.
        pub const Moments = struct { center: Vec2, M: Mat2 };

        pub inline fn computeMoments(Ps: []const [2]T, w: []const T, s_scale: T) Moments {
            var center_s = Vec2.zero;
            var M_s = Mat2.zero;
            for (Ps, 0..) |p_arr, i| {
                const p = Vec2{ .m = p_arr };
                center_s = Vec2.lincomb(1.0, center_s, w[i], p);
                M_s.addSymRank1(w[i], p);
            }
            return .{ .center = center_s.scale(s_scale), .M = M_s.scale(s_scale * s_scale) };
        }

        /// Recovers the 2×2 tangent-plane shape A_perp from the weights' moment matrix M.
        /// A_perp is Minv_half scaled by √(2/(3·g_max)), where g_max = max_i pᵢᵀ·M⁻¹·pᵢ
        /// enforces the budget max_i ‖A_perp·pᵢ‖² = 2/3 that pins the axial eigenvalue
        /// of A to sigma0.
        pub fn recoverAPerp(P: []const [2]T, M: Mat2) SolveError!Mat2 {
            const Minv = M.inverse();

            // Max of pᵀ M⁻¹ p over points (used for scaling).
            var g_max: T = 0;
            for (P) |p_arr| {
                const p = Vec2{ .m = p_arr };
                const g = p.dot(Minv.apply(p));
                if (g > g_max) g_max = g;
            }

            // Closed-form sqrt of symmetric SPD 2×2 Minv:
            //   sqrt(S) = (S + √det(S)·I) / √(tr(S) + 2√det(S))
            // avoids eigendecomposition when eigenvalues are nearly equal.
            // Minv is PSD by construction (M is PD ⇒ Minv is PD), so det(Minv)
            // and tr(Minv) are both ≥ 0 in exact arithmetic. Roundoff can push
            // det negative when M is near-singular; clip ulp-scale noise and
            // raise SingularMoment beyond that. tr is a sum of squared FMAs,
            // bounded below by 0 structurally, but we guard it the same way
            // for completeness.
            const tr = Minv.m[0] + Minv.m[3];
            const det = Minv.det();
            if (det < -tol.PSD_NEG_REL * tr * tr) return SolveError.SingularMoment;
            const s_det = qmath.sqrt(@max(det, 0));
            const denom = qmath.sqrt(@mulAdd(T, 2.0, s_det, tr));
            const eye2: Mat2 = .{ .m = .{ 1, 0, 0, 1 } };
            const Minv_half = Mat2.lincomb(1.0 / denom, Minv, s_det / denom, eye2);

            const budget: T = 2.0 / 3.0;
            return Minv_half.scale(qmath.sqrt(budget / g_max));
        }

        /// Scratch for `dualityGapConstructed` (constructed dual certificate + gap).
        pub const GapScratch = struct {
            active_idx: []usize, // [nmax]  points with w > thresh
            lam: []T, // [nmax]  dual lambdas: 3 w_i / (b·x_i)
            xa: []Vec3, // [nmax]  active x_i (from X_work)
            p: [][2]T, // [nmax]  chart coords of the active z_i (gap scratch)

            pub fn deinit(self: *GapScratch, allocator: std.mem.Allocator) void {
                allocator.free(self.active_idx);
                allocator.free(self.lam);
                allocator.free(self.xa);
                allocator.free(self.p);
            }

            pub fn init(allocator: std.mem.Allocator, nmax: usize) !GapScratch {
                const active_idx = try allocator.alloc(usize, nmax);
                errdefer allocator.free(active_idx);
                const lam = try allocator.alloc(T, nmax);
                errdefer allocator.free(lam);
                const xa = try allocator.alloc(Vec3, nmax);
                errdefer allocator.free(xa);
                return .{
                    .active_idx = active_idx,
                    .lam = lam,
                    .xa = xa,
                    .p = try allocator.alloc([2]T, nmax),
                };
            }
        };

        // ----------------------------------------------------------------
        // Dual-certificate gap
        // ----------------------------------------------------------------

        pub const GapResult = struct {
            gap: T,
            cert_n: usize,
            /// A's tangent-plane eigenvectors (lifted to 3D) and eigenvalues. Valid
            /// only when gap < tol.GAP_UNCERTIFIED; `solve` reuses these to fill `info.Q`/`info.sigma`,
            /// skipping a redundant eig2 + lift at the end of the outer loop.
            v1: Vec3,
            v2: Vec3,
            sigma: [2]T,
        };

        /// Structural dual gap on (b, A_perp, Q_ortho). A's eigendecomposition falls out
        /// of eig(A_perp) + lifting through Q_ortho, so we build L = V·√Λ directly — no
        /// Cholesky with fallback.
        pub fn dualityGapConstructed(
            w: []const T,
            b: Vec3,
            X_work: []const Vec3,
            A_perp: Mat2,
            Q_ortho: Mat3x2,
            s: *GapScratch,
            cert_active_out: []usize,
            cert_lambdas_out: []T,
        ) SolveError!GapResult {
            // A's eigendecomposition: V = [b | v₁ | v₂], Λ = diag(sigma0, σ₁, σ₂).
            // Always valid (depends only on A_perp and Q_ortho); returned in GapResult
            // so `solve`'s finalization reuses it without re-decomposing.
            const eAPerp = eig2(A_perp.m);
            // A_perp is PSD by construction; eig2 can produce ulp-scale negative
            // eigenvalues from FP noise. Clip noise to 0 (so the sqrt below is
            // well-defined and downstream M = LᵀZL routes through the Cholesky
            // null guard as "no progress"), but raise NegativeEigenvalue when
            // the negative value is meaningful — that signals Newton polish
            // landed on a non-PSD iterate or eig2 has a bug.
            const sigma_raw: [2]T = eAPerp.vals;
            const sigma_neg_thr = tol.PSD_NEG_REL * @max(sigma_raw[1], 1.0);
            if (sigma_raw[0] < -sigma_neg_thr) return SolveError.NegativeEigenvalue;
            const sigma: [2]T = .{ @max(sigma_raw[0], 0), @max(sigma_raw[1], 0) };
            const v1 = Vec3.lincomb(eAPerp.vecs.m[0], Q_ortho.e1, eAPerp.vecs.m[1], Q_ortho.e2);
            const v2 = Vec3.lincomb(eAPerp.vecs.m[2], Q_ortho.e1, eAPerp.vecs.m[3], Q_ortho.e2);

            const active_idx = s.active_idx;
            const lam = s.lam;
            const xa = s.xa;
            var k: usize = 0;
            for (w, 0..) |wi, i| {
                if (wi > algo.ACTIVE_THRESH) {
                    active_idx[k] = i;
                    k += 1;
                }
            }
            if (k == 0) return .{ .gap = tol.GAP_UNCERTIFIED, .cert_n = 0, .v1 = v1, .v2 = v2, .sigma = sigma };

            for (0..k) |i| {
                const idx = active_idx[i];
                xa[i] = X_work[idx];
                lam[i] = 3.0 * w[idx] / b.dot(xa[i]);
                cert_active_out[i] = idx;
            }
            return gapFromMultipliers(b, v1, v2, sigma, xa[0..k], lam[0..k], s.p, cert_lambdas_out);
        }

        /// The post-active-set core of `dualityGapConstructed`: the gap
        /// of an EXPLICIT multiplier set. Its own entry point so a
        /// caller holding (λ, active xᵢ) — the f128 oracle
        /// re-evaluating a shipped certificate — reaches the identical
        /// arithmetic. `p_buf` is scratch (≥ xa.len entries); the
        /// boundary-normalized multipliers land in
        /// `cert_lambdas_out[0..lam.len]`.
        ///
        /// CHART FORM (roadmap item 11). The dual it constructs is unchanged —
        /// γᵢ = λᵢ·A·xᵢ/‖A·xᵢ‖, gap = 3·log1p((‖Xλ‖−3)/3) − log det M
        /// with M = Lᵀ·Z·L — but every quantity is evaluated in the
        /// tangent chart at `b` spanned by (v₁, v₂), A's own eigenbasis,
        /// reached through the shifted projection. The algebra: with
        /// zᵢ = xᵢ/(b·xᵢ) = b + p₁ᵢv₁ + p₂ᵢv₂ exactly, λᵢxᵢ = 3wᵢzᵢ
        /// (wᵢ = λᵢ(b·xᵢ)/3), and ẑᵢ = A·zᵢ/‖A·zᵢ‖, the similarity
        /// collapses to
        ///   M_jk = E_jk · (σⱼ+σₖ)/(2√(σⱼσₖ)),
        ///   E    = 3·Σᵢ (wᵢ/nᵢ)·tᵢtᵢᵀ,
        ///   tᵢ   = Λ·[1; pᵢ] = [σ₀; σ₁p₁ᵢ; σ₂p₂ᵢ],  nᵢ = ‖A·zᵢ‖ = ‖tᵢ‖,
        /// and Xλ = 3·(S_w·b + m₁v₁ + m₂v₂) with S_w = Σwᵢ, m = Σwᵢpᵢ.
        /// Every accumulated term is O(1): σⱼ ~ 1/θ meets pᵢ ~ θ inside
        /// tᵢ before any sum, so no O(1) dot cancels to a θ-sized
        /// result and the σ_max·ε evaluation floor (docs/floor-survey.md)
        /// is gone; the remaining amplification is the √κ(A)-scale
        /// mixing factor on E's near-cancelling off-diagonal moments.
        /// ‖Xλ‖−3 uses the cancellation-free form (algo-roadmap item
        /// 7): (S_w²−1) exact-to-one-rounding via a fused S_w·S_w − 1,
        /// plus ‖m‖², over √(·)+1.
        ///
        /// Guards, branch-identical across T (header rules): the
        /// M-Cholesky failure is the same indefinite-dual sentinel as
        /// ever; a zero tangential eigenvalue (sigma[0] clipped to 0)
        /// made the 3D form's M singular — same Cholesky-null sentinel,
        /// tested before the division that would now produce NaN.
        pub inline fn gapFromMultipliers(
            b: Vec3,
            v1: Vec3,
            v2: Vec3,
            sigma: [2]T,
            xa: []const Vec3,
            lam: []const T,
            p_buf: [][2]T,
            cert_lambdas_out: []T,
        ) GapResult {
            const k = xa.len;
            std.debug.assert(k > 0 and lam.len == k);
            if (!(sigma[0] > 0))
                return .{ .gap = tol.GAP_UNCERTIFIED, .cert_n = 0, .v1 = v1, .v2 = v2, .sigma = sigma };

            // Shifted projection of the active set onto (v₁, v₂) at b —
            // the same split halfspace.projectGnomonic documents, at the
            // certificate's own basis. Also recovers wᵢ = λᵢ(b·xᵢ)/3.
            // The reference point's own chart coordinates are the one
            // remaining cancelling dot (O(1) components, θ-sized
            // result); their absolute-ε error is common to every point,
            // and away from exact optimality the gap is first-order
            // sensitive to that common offset with a σ-amplified
            // coefficient (E's first-moment rows × the √κ mixing
            // factors) — so these two dots, and only these, are
            // compensated. b·c cancels nothing (≈ 1); plain.
            const c = xa[0];
            const qc1 = la.Vec3.dotCompensated(v1, c);
            const qc2 = la.Vec3.dotCompensated(v2, c);
            const bc = b.dot(c);
            var S_w: T = 0;
            var m1: T = 0;
            var m2: T = 0;
            var E = Mat3.zero;
            for (0..k) |i| {
                const d = xa[i].sub(c);
                const ci = bc + b.dot(d);
                const p1 = (qc1 + v1.dot(d)) / ci;
                const p2 = (qc2 + v2.dot(d)) / ci;
                p_buf[i] = .{ p1, p2 };
                const wi = lam[i] * ci / 3.0;
                S_w += wi;
                m1 = @mulAdd(T, wi, p1, m1);
                m2 = @mulAdd(T, wi, p2, m2);
                const t = Vec3{ .m = .{ sigma0, sigma[0] * p1, sigma[1] * p2 } };
                E.addSymRank1(3.0 * wi / t.norm(), t);
            }

            // M from E via the eigenvalue mixing factors. σ₀ is fixed;
            // f_jk = (σⱼ+σₖ)/(2√(σⱼσₖ)) ≥ 1, equal to 1 on the diagonal.
            const s0: T = sigma0;
            const f01 = (s0 + sigma[0]) / (2.0 * qmath.sqrt(s0 * sigma[0]));
            const f02 = (s0 + sigma[1]) / (2.0 * qmath.sqrt(s0 * sigma[1]));
            const f12 = (sigma[0] + sigma[1]) / (2.0 * qmath.sqrt(sigma[0] * sigma[1]));
            const M = Mat3{ .m = .{
                E.m[0],       f01 * E.m[1], f02 * E.m[2],
                f01 * E.m[3], E.m[4],       f12 * E.m[5],
                f02 * E.m[6], f12 * E.m[7], E.m[8],
            } };
            const Lm = M.cholesky() orelse
                return .{ .gap = tol.GAP_UNCERTIFIED, .cert_n = 0, .v1 = v1, .v2 = v2, .sigma = sigma };

            // ‖Xλ‖ in chart form; the boundary rescale and the gap read
            // off it. Export the multipliers rescaled onto the normalized
            // dual's constraint boundary (‖Xλ‖ = 3), so a shipped
            // certificate satisfies the stated feasible set literally.
            // Only the exported copy is scaled: the gap below already
            // prices in the rescale, and the raw `lam` keeps the exact
            // identity λᵢ·(b·xᵢ) = 3wᵢ. No zero guard: ‖Xλ‖ ≥ b·Xλ =
            // 3·S_w ≈ 3 whenever k > 0.
            const m_sq = @mulAdd(T, m1, m1, m2 * m2);
            const root = qmath.sqrt(@mulAdd(T, S_w, S_w, m_sq));
            const cert_scale = 1.0 / root;
            for (0..k) |i| {
                cert_lambdas_out[i] = cert_scale * lam[i];
            }

            // Gap against the normalized dual (max log det Z s.t.
            // ‖Xλ‖ ≤ 3): the boundary rescale contributes
            // 3·log(‖Xλ‖/3), and via the similarity the two log det A
            // terms cancel: gap = 3·log(‖Xλ‖/3) − log det M. ‖Xλ‖ is
            // used directly rather than assuming b·Xλ = 3: active-set
            // truncation breaks that identity, and the ‖Xλ‖ form is a
            // valid dual value regardless — do not "simplify" the
            // assumption in. The log1p argument is the cancellation-free
            // split of ‖Xλ‖/3 − 1 (header note).
            const dev = (@mulAdd(T, S_w, S_w, -1.0) + m_sq) / (root + 1.0);
            const gap = 3.0 * qmath.log1p(dev) - Lm.logDet();
            return .{
                .gap = gap,
                .cert_n = k,
                .v1 = v1,
                .v2 = v2,
                .sigma = sigma,
            };
        }
    };
}
