//! The generic linalg namespace. Split from linalg.zig so the f64
//! aliases there (the public spellings) don't shadow the names inside
//! the namespace; see linalg.zig's header for the conventions.

const std = @import("std");
const qmath = @import("qmath");

/// Every float-typed linalg primitive, generic over the scalar `T` —
/// the pattern #9 phase 2 extends to the whole solver. `Linalg(f64)`
/// is re-exported by linalg.zig under the original names, so existing
/// callers compile the identical code through aliases (no wrappers);
/// the f128 instantiation serves the certificate slice's gap oracle.
/// Transcendentals route through qmath (argument-typed, so they
/// follow `T` automatically). `LU` stays f64-only in linalg.zig: it
/// belongs to the Newton polish, outside the slice.
pub fn Linalg(comptime T: type) type {
    return struct {
        /// `a*b − c*d`, computed via Kahan's compensated FMA scheme so the
        /// result is correct to ~2 ulp even when the two products nearly
        /// cancel. Used for 2×2 determinants, cross-product components, and
        /// any other place a difference of products is the canonical form.
        pub inline fn diff_of_products(a: T, b: T, c: T, d: T) T {
            const cd = c * d;
            const err = @mulAdd(T, -c, d, cd);
            const dop = @mulAdd(T, a, b, -cd);
            return dop + err;
        }

        /// Relative threshold for `eig2`'s closed-form vs. axis-aligned
        /// eigenvector fallback. `|b| ≫ sqrt(ulp)·max(|a|,|d|)` ≈ `1.5e-8·scale`
        /// is the regime where `vals[0] − d` retains useful precision.
        ///
        /// The 1e-8 literal — sqrt(eps) for f64 — is deliberately FIXED
        /// across T, per the branch-identity rule (the authoritative
        /// list and rationale: gap_generic.zig's header).
        const EIG2_REL: T = 1e-8;

        // ----------------------------------------------------------------
        // Vec3: 3-vector with method-style operations, backed by [3]T. Matches
        // Mat3's storage convention so vec/mat code reads uniformly.
        // Construct with `Vec3{ .m = arr }`; raw-array access via `v.m`.
        // All methods are static inline — zero runtime cost vs hand-rolled arithmetic.
        // ----------------------------------------------------------------

        pub const Vec3 = extern struct {
            m: [3]T,

            pub const zero: Vec3 = .{ .m = .{ 0, 0, 0 } };

            pub inline fn dot(a: Vec3, b: Vec3) T {
                var t = a.m[0] * b.m[0];
                t = @mulAdd(T, a.m[1], b.m[1], t);
                t = @mulAdd(T, a.m[2], b.m[2], t);
                return t;
            }
            pub inline fn norm(v: Vec3) T {
                return qmath.sqrt(v.dot(v));
            }
            pub inline fn normalize(v: Vec3) Vec3 {
                return v.scale(1.0 / v.norm());
            }
            pub inline fn scale(v: Vec3, s: T) Vec3 {
                return .{ .m = .{ s * v.m[0], s * v.m[1], s * v.m[2] } };
            }
            pub inline fn add(a: Vec3, b: Vec3) Vec3 {
                return .{ .m = .{ a.m[0] + b.m[0], a.m[1] + b.m[1], a.m[2] + b.m[2] } };
            }
            pub inline fn sub(a: Vec3, b: Vec3) Vec3 {
                return .{ .m = .{ a.m[0] - b.m[0], a.m[1] - b.m[1], a.m[2] - b.m[2] } };
            }
            /// Linear combination: s_a·a + s_b·b.
            pub inline fn lincomb(s_a: T, a: Vec3, s_b: T, b: Vec3) Vec3 {
                return .{ .m = .{
                    @mulAdd(T, s_a, a.m[0], s_b * b.m[0]),
                    @mulAdd(T, s_a, a.m[1], s_b * b.m[1]),
                    @mulAdd(T, s_a, a.m[2], s_b * b.m[2]),
                } };
            }
            /// Cross product a × b. Each component is a `diff_of_products`
            /// so near-parallel inputs don't suffer catastrophic cancellation.
            pub inline fn cross(a: Vec3, b: Vec3) Vec3 {
                return .{ .m = .{
                    diff_of_products(a.m[1], b.m[2], a.m[2], b.m[1]),
                    diff_of_products(a.m[2], b.m[0], a.m[0], b.m[2]),
                    diff_of_products(a.m[0], b.m[1], a.m[1], b.m[0]),
                } };
            }

            /// Symmetric vectorization ("svec") of self·selfᵀ: the 6-vector
            /// (x₀², x₁², x₂², √2·x₀x₁, √2·x₀x₂, √2·x₁x₂). The √2 weighting
            /// makes the map an isometry: ⟨svec(x), svec(y)⟩ = (x·y)². Slot
            /// order and weighting are load-bearing — every rank-6 range-space
            /// consumer (the trust path's envelope-Hessian correction, the
            /// Newton polish's KKT solve) must use the SAME convention for its
            /// Gram build and the corresponding Vᵀ apply, so it lives here once.
            pub inline fn svec(self: Vec3) [6]T {
                const x = self.m;
                const SQRT2: T = std.math.sqrt2;
                return .{ x[0] * x[0], x[1] * x[1], x[2] * x[2], SQRT2 * x[0] * x[1], SQRT2 * x[0] * x[2], SQRT2 * x[1] * x[2] };
            }

            /// Pick the standard axis (ex, ey, or ez) least aligned with self.
            /// Used as the seed for `orthoBasis`.
            pub fn pickRefAxis(self: Vec3) Vec3 {
                const b = self;
                const ax = @abs(b.m[0]);
                const ay = @abs(b.m[1]);
                const az = @abs(b.m[2]);
                if (ax <= ay and ax <= az) return .{ .m = .{ 1, 0, 0 } };
                if (ay <= az) return .{ .m = .{ 0, 1, 0 } };
                return .{ .m = .{ 0, 0, 1 } };
            }

            /// Orthonormal tangent basis (e1, e2) at the unit vector self.
            /// e1 = normalize(ax − (ax·b)·b) where ax = pickRefAxis(b) is the
            /// least-aligned standard axis, so |ax·b| ≤ 1/√3 and |e1| ≥ √(2/3)
            /// — catastrophic cancellation is impossible; no fallback needed.
            /// e2 = b × e1 (right-handed, unit).
            pub fn orthoBasis(b: Vec3) Mat3x2 {
                const ax = b.pickRefAxis();
                const e1 = Vec3.lincomb(1.0, ax, -ax.dot(b), b).normalize();
                const e2 = b.cross(e1).normalize();
                return .{ .e1 = e1, .e2 = e2 };
            }

            /// Uniformly random unit vector on the 2-sphere: three iid
            /// standard normals, then normalize. The Gaussian's spherical
            /// symmetry makes the direction uniform with no rejection.
            pub fn randomUnit(rng: std.Random) Vec3 {
                return (Vec3{
                    .m = .{
                        // f64 sampling widens implicitly at wider T; the
                        // precision of a test-helper sampler doesn't matter.
                        rng.floatNorm(f64), rng.floatNorm(f64), rng.floatNorm(f64),
                    },
                }).normalize();
            }
        };

        // ----------------------------------------------------------------
        // Vec2: 2-vector (used for the 2D gnomonic projection plane).
        // ----------------------------------------------------------------

        pub const Vec2 = extern struct {
            m: [2]T,

            pub const zero: Vec2 = .{ .m = .{ 0, 0 } };

            pub inline fn dot(a: Vec2, b: Vec2) T {
                return @mulAdd(T, a.m[1], b.m[1], a.m[0] * b.m[0]);
            }
            pub inline fn norm(v: Vec2) T {
                return qmath.sqrt(v.dot(v));
            }
            pub inline fn scale(v: Vec2, s: T) Vec2 {
                return .{ .m = .{ s * v.m[0], s * v.m[1] } };
            }
            pub inline fn add(a: Vec2, b: Vec2) Vec2 {
                return .{ .m = .{ a.m[0] + b.m[0], a.m[1] + b.m[1] } };
            }
            pub inline fn sub(a: Vec2, b: Vec2) Vec2 {
                return .{ .m = .{ a.m[0] - b.m[0], a.m[1] - b.m[1] } };
            }
            pub inline fn lincomb(s_a: T, a: Vec2, s_b: T, b: Vec2) Vec2 {
                return .{ .m = .{
                    @mulAdd(T, s_a, a.m[0], s_b * b.m[0]),
                    @mulAdd(T, s_a, a.m[1], s_b * b.m[1]),
                } };
            }
        };

        // ----------------------------------------------------------------
        // Mat2: 2x2 matrix (row-major).
        // ----------------------------------------------------------------

        pub const Mat2 = struct {
            m: [4]T,

            pub const zero: Mat2 = .{ .m = .{ 0, 0, 0, 0 } };

            pub inline fn apply(self: Mat2, v: Vec2) Vec2 {
                return .{ .m = .{
                    @mulAdd(T, self.m[1], v.m[1], self.m[0] * v.m[0]),
                    @mulAdd(T, self.m[3], v.m[1], self.m[2] * v.m[0]),
                } };
            }

            pub inline fn det(self: Mat2) T {
                return diff_of_products(self.m[0], self.m[3], self.m[1], self.m[2]);
            }

            pub inline fn scale(self: Mat2, s: T) Mat2 {
                return .{ .m = .{ s * self.m[0], s * self.m[1], s * self.m[2], s * self.m[3] } };
            }

            pub inline fn lincomb(s_a: T, a: Mat2, s_b: T, b: Mat2) Mat2 {
                return .{ .m = .{
                    @mulAdd(T, s_a, a.m[0], s_b * b.m[0]),
                    @mulAdd(T, s_a, a.m[1], s_b * b.m[1]),
                    @mulAdd(T, s_a, a.m[2], s_b * b.m[2]),
                    @mulAdd(T, s_a, a.m[3], s_b * b.m[3]),
                } };
            }

            /// Outer product x yᵀ (2x2).
            pub inline fn outer(x: Vec2, y: Vec2) Mat2 {
                return .{ .m = .{
                    x.m[0] * y.m[0], x.m[0] * y.m[1],
                    x.m[1] * y.m[0], x.m[1] * y.m[1],
                } };
            }

            /// Symmetric rank-1 update: self ← self + w · p · pᵀ. Upper
            /// triangle computed via FMA, mirrored to lower by exact
            /// assignment. Multiplication order `(w·p_r)·p_c` is preserved
            /// by pre-computing `wp_i = w * p.m[i]`. Same rationale as
            /// `Mat3.addSymRank1`: shared `wp_i` precompute amortizes
            /// across both row-0 FMAs (m[0] and m[1]), fewer rounding
            /// steps than any factored alternative. Mirror by exact
            /// assignment (`m[2] = m[1]`) guarantees bit-exact symmetry —
            /// see tests/linalg_test.zig.
            pub inline fn addSymRank1(self: *Mat2, w: T, p: Vec2) void {
                const wp0 = w * p.m[0];
                const wp1 = w * p.m[1];
                self.m[0] = @mulAdd(T, wp0, p.m[0], self.m[0]);
                self.m[3] = @mulAdd(T, wp1, p.m[1], self.m[3]);
                self.m[1] = @mulAdd(T, wp0, p.m[1], self.m[1]);
                self.m[2] = self.m[1];
            }

            /// Inverse of a 2x2 matrix (caller should ensure det ≠ 0).
            pub inline fn inverse(self: Mat2) Mat2 {
                const inv_det = 1.0 / self.det();
                return .{ .m = .{
                    self.m[3] * inv_det,  -self.m[1] * inv_det,
                    -self.m[2] * inv_det, self.m[0] * inv_det,
                } };
            }
        };

        // ----------------------------------------------------------------
        // 3x2 orthonormal basis (two named 3-vectors)
        // ----------------------------------------------------------------

        pub const Mat3x2 = struct {
            e1: Vec3,
            e2: Vec3,

            /// 3×2 · 2-vector = 3-vector: v[0]·e1 + v[1]·e2.
            pub fn apply(self: Mat3x2, v: Vec2) Vec3 {
                return Vec3.lincomb(v.m[0], self.e1, v.m[1], self.e2);
            }

            /// (3×2)ᵀ · 3-vector = 2-vector: (e1·x, e2·x).
            pub fn applyT(self: Mat3x2, x: Vec3) Vec2 {
                return .{ .m = .{ self.e1.dot(x), self.e2.dot(x) } };
            }
        };

        // ----------------------------------------------------------------
        // Mat3: 3x3 matrix (row-major) with methods for the operations we need.
        // Used for both general and symmetric matrices (symmetry is a caller
        // invariant on methods like addSymRank1). The Cholesky factor lives in
        // the separate `Chol3` type, which only exposes forward/back-solve —
        // so the lower-triangular invariant is compile-enforced.
        // ----------------------------------------------------------------

        pub const Mat3 = struct {
            m: [9]T,

            pub const zero: Mat3 = .{ .m = .{0} ** 9 };

            pub inline fn apply(self: Mat3, v: Vec3) Vec3 {
                const a = self.m;
                return .{ .m = .{
                    @mulAdd(T, a[2], v.m[2], @mulAdd(T, a[1], v.m[1], a[0] * v.m[0])),
                    @mulAdd(T, a[5], v.m[2], @mulAdd(T, a[4], v.m[1], a[3] * v.m[0])),
                    @mulAdd(T, a[8], v.m[2], @mulAdd(T, a[7], v.m[1], a[6] * v.m[0])),
                } };
            }

            /// Cofactor expansion along the top row. Each inner 2×2 minor uses
            /// `diff_of_products`; the outer alternating sum chains `@mulAdd`.
            pub inline fn det(self: Mat3) T {
                const a = self.m;
                const m0 = diff_of_products(a[4], a[8], a[5], a[7]);
                const m1 = diff_of_products(a[3], a[8], a[5], a[6]);
                const m2 = diff_of_products(a[3], a[7], a[4], a[6]);
                // a[0]·m0 − a[1]·m1 + a[2]·m2, in two FMA steps.
                return @mulAdd(T, a[2], m2, @mulAdd(T, -a[1], m1, a[0] * m0));
            }

            pub inline fn scale(self: Mat3, s: T) Mat3 {
                var r: Mat3 = undefined;
                for (0..9) |i| r.m[i] = s * self.m[i];
                return r;
            }

            /// Linear combination: s_a·A + s_b·B.
            pub inline fn lincomb(s_a: T, a: Mat3, s_b: T, b: Mat3) Mat3 {
                var r: Mat3 = undefined;
                for (0..9) |i| r.m[i] = @mulAdd(T, s_a, a.m[i], s_b * b.m[i]);
                return r;
            }

            pub inline fn transpose(self: Mat3) Mat3 {
                const a = self.m;
                return .{ .m = .{
                    a[0], a[3], a[6],
                    a[1], a[4], a[7],
                    a[2], a[5], a[8],
                } };
            }

            /// Matrix product self · other.
            pub inline fn mul(self: Mat3, other: Mat3) Mat3 {
                const a = self.m;
                const b = other.m;
                var r: Mat3 = undefined;
                for (0..3) |row| {
                    for (0..3) |c| {
                        var t = a[row * 3 + 0] * b[0 * 3 + c];
                        t = @mulAdd(T, a[row * 3 + 1], b[1 * 3 + c], t);
                        t = @mulAdd(T, a[row * 3 + 2], b[2 * 3 + c], t);
                        r.m[row * 3 + c] = t;
                    }
                }
                return r;
            }

            /// Build a Mat3 from its three columns. Row-major storage; `c0` populates
            /// indices {0,3,6}, `c1` populates {1,4,7}, `c2` populates {2,5,8}.
            pub inline fn fromCols(c0: Vec3, c1: Vec3, c2: Vec3) Mat3 {
                return .{ .m = .{
                    c0.m[0], c1.m[0], c2.m[0],
                    c0.m[1], c1.m[1], c2.m[1],
                    c0.m[2], c1.m[2], c2.m[2],
                } };
            }

            /// Extract column `i` (0..2) as a Vec3.
            pub inline fn col(self: Mat3, i: usize) Vec3 {
                return .{ .m = .{ self.m[i], self.m[3 + i], self.m[6 + i] } };
            }

            /// Outer product x yᵀ.
            pub inline fn outer(x: Vec3, y: Vec3) Mat3 {
                var r: Mat3 = undefined;
                for (0..3) |row| {
                    for (0..3) |c| {
                        r.m[row * 3 + c] = x.m[row] * y.m[c];
                    }
                }
                return r;
            }

            /// Fill the 9 entries with iid samples from the standard normal
            /// distribution (mean 0, stddev 1). Pair with `orthonormalize`
            /// for a Haar-uniform random rotation: Gram-Schmidt of a
            /// Gaussian random matrix is the classical construction.
            pub fn randomNormal(rng: std.Random) Mat3 {
                var r: Mat3 = undefined;
                for (0..9) |i| r.m[i] = rng.floatNorm(f64);
                return r;
            }

            /// In-place modified Gram-Schmidt on the columns, followed by a
            /// determinant-sign correction so the result lives in SO(3)
            /// (det = +1), not O(3). Assumes the columns are linearly
            /// independent; behavior on a singular input is unspecified.
            pub fn orthonormalize(self: *Mat3) void {
                const c0 = self.col(0).normalize();
                const c1_raw = self.col(1);
                const c1 = c1_raw.sub(c0.scale(c0.dot(c1_raw))).normalize();
                const c2_raw = self.col(2);
                const c2_proj = c2_raw.sub(c0.scale(c0.dot(c2_raw))).sub(c1.scale(c1.dot(c2_raw))).normalize();
                // If Gram-Schmidt produced a reflection (det = -1), flip the
                // last column. Half of random orthogonal matrices land in this
                // case; the flip makes the sampler uniform on SO(3).
                const c2 = if (c0.cross(c1).dot(c2_proj) < 0) c2_proj.scale(-1.0) else c2_proj;
                self.* = fromCols(c0, c1, c2);
            }

            /// Symmetric rank-1 update: self ← self + w · q · qᵀ. Updates all 9
            /// entries (upper triangle computed via FMA, mirrored to lower by
            /// exact assignment).
            ///
            /// Multiply order is `(w·q_r)·q_c`. The pre-computed `wq_i = w·q.m[i]`
            /// is shared across all three FMAs in row i — total rounding-step
            /// count for the 6-element upper triangle is 3 muls + 6 FMAs = 9.
            /// A factored form `w·(q_r·q_c)` couldn't share precomputes across
            /// FMAs (each q_i·q_j is used exactly once), needing 6 muls + 6 FMAs
            /// = 12 rounding steps. So the current order isn't just to avoid FP
            /// reassociation drift in degenerate problems — it's also strictly
            /// fewer rounding steps and fewer ops.
            ///
            /// The "compute upper, mirror to lower" pattern guarantees bit-exact
            /// symmetry (m[1] == m[3], m[2] == m[6], m[5] == m[7]) regardless of
            /// FP rounding — see tests/linalg_test.zig.
            pub inline fn addSymRank1(self: *Mat3, w: T, q: Vec3) void {
                const wq0 = w * q.m[0];
                const wq1 = w * q.m[1];
                const wq2 = w * q.m[2];
                self.m[0] = @mulAdd(T, wq0, q.m[0], self.m[0]);
                self.m[4] = @mulAdd(T, wq1, q.m[1], self.m[4]);
                self.m[8] = @mulAdd(T, wq2, q.m[2], self.m[8]);
                self.m[1] = @mulAdd(T, wq0, q.m[1], self.m[1]);
                self.m[3] = self.m[1];
                self.m[2] = @mulAdd(T, wq0, q.m[2], self.m[2]);
                self.m[6] = self.m[2];
                self.m[5] = @mulAdd(T, wq1, q.m[2], self.m[5]);
                self.m[7] = self.m[5];
            }

            /// Symmetric rank-2 update: self ← self + λ · (x zᵀ + z xᵀ) / 2.
            /// Upper triangle computed via FMA, mirrored to lower by exact
            /// assignment.
            ///
            /// Diagonal multiplication order `(lam·x_i)·z_i` is preserved by
            /// pre-computing `lx_i = lam·x.m[i]`. Same rationale as
            /// `addSymRank1`: the shared `lx_i` precompute amortizes across
            /// the three FMAs touching row i (one diagonal + two off-diagonals
            /// after the symmetric average), keeping the total rounding count
            /// lower than any factored alternative.
            ///
            /// Off-diagonal inner sums use `@mulAdd` for the cross term
            /// (addition is commutative, so this is order-equivalent).
            /// Symmetry of the output is bit-exact — see tests/linalg_test.zig.
            pub inline fn addSymRank2(self: *Mat3, lam: T, x: Vec3, z: Vec3) void {
                const lx0 = lam * x.m[0];
                const lx1 = lam * x.m[1];
                const lx2 = lam * x.m[2];
                self.m[0] = @mulAdd(T, lx0, z.m[0], self.m[0]);
                self.m[4] = @mulAdd(T, lx1, z.m[1], self.m[4]);
                self.m[8] = @mulAdd(T, lx2, z.m[2], self.m[8]);
                const half = 0.5 * lam;
                // m[1]: half · (x[0]·z[1] + z[0]·x[1]) added in two FMAs.
                const inner01 = @mulAdd(T, z.m[0], x.m[1], x.m[0] * z.m[1]);
                self.m[1] = @mulAdd(T, half, inner01, self.m[1]);
                self.m[3] = self.m[1];
                const inner02 = @mulAdd(T, z.m[0], x.m[2], x.m[0] * z.m[2]);
                self.m[2] = @mulAdd(T, half, inner02, self.m[2]);
                self.m[6] = self.m[2];
                const inner12 = @mulAdd(T, z.m[1], x.m[2], x.m[1] * z.m[2]);
                self.m[5] = @mulAdd(T, half, inner12, self.m[5]);
                self.m[7] = self.m[5];
            }

            /// Symmetric outer product: (x zᵀ + z xᵀ) / 2.
            pub inline fn symOuter(x: Vec3, z: Vec3) Mat3 {
                var r: Mat3 = undefined;
                for (0..3) |row| {
                    for (0..3) |c| {
                        r.m[row * 3 + c] = (x.m[row] * z.m[c] + z.m[row] * x.m[c]) * 0.5;
                    }
                }
                return r;
            }

            /// Symmetrize: returns (self + selfᵀ) / 2.
            pub inline fn symmetrize(self: Mat3) Mat3 {
                return Mat3.lincomb(0.5, self, 0.5, self.transpose());
            }

            /// Cholesky: returns L (lower-triangular, upper zeroed) such that
            /// self = L · Lᵀ, or null on non-SPD. Inner `a − b*c` subtractions
            /// use `@mulAdd`, matching the pattern in `Chol3.forwardSolve`.
            pub fn cholesky(self: Mat3) ?Chol3 {
                const S = self.m;
                var L: [9]T = .{0} ** 9;
                var s = S[0];
                if (!(s > 0)) return null; // !(s>0), not s<=0: fail CLOSED on NaN
                L[0] = qmath.sqrt(s);
                L[3] = S[1] / L[0];
                L[6] = S[2] / L[0];
                s = @mulAdd(T, -L[3], L[3], S[4]);
                if (!(s > 0)) return null; // !(s>0), not s<=0: fail CLOSED on NaN
                L[4] = qmath.sqrt(s);
                L[7] = @mulAdd(T, -L[6], L[3], S[5]) / L[4];
                s = @mulAdd(T, -L[7], L[7], @mulAdd(T, -L[6], L[6], S[8]));
                if (!(s > 0)) return null; // !(s>0), not s<=0: fail CLOSED on NaN
                L[8] = qmath.sqrt(s);
                return Chol3{ .m = L };
            }
        };

        /// Lower-triangular Cholesky factor of a 3×3 SPD matrix. Produced only
        /// via `Mat3.cholesky`; the restricted API (forward/back/solve only)
        /// prevents accidentally treating the factor as a general 3×3.
        pub const Chol3 = struct {
            m: [9]T,

            /// Forward-solve self·y = b (self is lower-triangular).
            pub inline fn forwardSolve(self: Chol3, b: Vec3) Vec3 {
                const L = self.m;
                const y0 = b.m[0] / L[0];
                const y1 = @mulAdd(T, -L[3], y0, b.m[1]) / L[4];
                const y2 = @mulAdd(T, -L[7], y1, @mulAdd(T, -L[6], y0, b.m[2])) / L[8];
                return .{ .m = .{ y0, y1, y2 } };
            }

            /// Back-solve selfᵀ·x = y.
            pub inline fn backSolve(self: Chol3, y: Vec3) Vec3 {
                const L = self.m;
                const x2 = y.m[2] / L[8];
                const x1 = @mulAdd(T, -L[7], x2, y.m[1]) / L[4];
                const x0 = @mulAdd(T, -L[6], x2, @mulAdd(T, -L[3], x1, y.m[0])) / L[0];
                return .{ .m = .{ x0, x1, x2 } };
            }

            /// Solve (self · selfᵀ) · x = b via forward- then back-substitution.
            pub inline fn solve(self: Chol3, b: Vec3) Vec3 {
                return self.backSolve(self.forwardSolve(b));
            }

            /// log det of the factored matrix: 2·Σ log(diagonal of L).
            pub inline fn logDet(self: Chol3) T {
                return 2.0 * (qmath.log(self.m[0]) + qmath.log(self.m[4]) + qmath.log(self.m[8]));
            }

            /// The factor as a general Mat3 — the sanctioned exit from the
            /// restricted API, for when L is needed as an explicit square root
            /// (e.g. a congruence LᵀZL). Storage is row-major with the upper
            /// triangle guaranteed zero, so this is a reinterpretation, not a
            /// copy-with-fixup.
            pub inline fn asMat3(self: Chol3) Mat3 {
                return .{ .m = self.m };
            }
        };

        /// Eigenvalues (ascending) and eigenvectors (columns) of a 2x2 symmetric M.
        ///
        /// Numerically robust at the near-isotropic boundary: when |b| is small
        /// *relative to the matrix scale* (not just absolutely), the closed-form
        /// eigenvector formula `v = (vals[0] - d, b)` cancels catastrophically
        /// and the resulting direction is dominated by FP noise in `vals[0] - d`.
        /// In that regime we fall back to the standard-axis eigenvectors (sorted
        /// to match vals' ascending order) — for a near-isotropic matrix any
        /// orthonormal basis is a valid eigenbasis, and the standard axes give
        /// a well-defined deterministic choice.
        pub const Eig2 = struct { vals: [2]T, vecs: Mat2 };
        pub fn eig2(M: [4]T) Eig2 {
            const a = M[0];
            const b = M[1];
            const d = M[3];
            const tr = a + d;
            const ad = a - d;
            // (a-d)² + 4·b², via FMA. Sum-of-squares — no cancellation
            // possible, so the win is precision-stylistic consistency, not
            // a robustness fix.
            const disc = qmath.sqrt(@mulAdd(T, 4.0, b * b, ad * ad));
            var result: Eig2 = undefined;
            result.vals[0] = (tr - disc) / 2.0;
            result.vals[1] = (tr + disc) / 2.0;
            // Relative threshold: |b| must be large enough that `vals[0] - d`
            // doesn't lose all its precision in cancellation. The cancellation
            // magnitude is ~|a-d| - disc which is O(b²/(a-d)) for small b. We
            // want b² / max(|a|,|d|) ≫ ulp · max(|a|,|d|), i.e.
            // |b| ≫ sqrt(ulp) · max(|a|,|d|) ≈ 1.5e-8 · scale.
            const scale = @max(@abs(a), @abs(d));
            if (@abs(b) > EIG2_REL * scale) {
                var v0 = result.vals[0] - d;
                var v1 = b;
                const nrm = qmath.sqrt(v0 * v0 + v1 * v1);
                v0 /= nrm;
                v1 /= nrm;
                result.vecs = .{ .m = .{ v0, v1, -v1, v0 } };
            } else if (a <= d) {
                // M nearly diagonal, M[0,0] is the smaller (or equal) eigenvalue.
                // vals[0] = a → eigenvector (1, 0). vals[1] = d → (0, 1).
                result.vecs = .{ .m = .{ 1, 0, 0, 1 } };
            } else {
                // M nearly diagonal, M[1,1] is the smaller eigenvalue.
                // vals[0] = d → eigenvector (0, 1). Right-handed: vals[1] → (-1, 0).
                result.vecs = .{ .m = .{ 0, 1, -1, 0 } };
            }
            return result;
        }
    };
}
