//! Linear algebra primitives used by the solver: 2D/3D vectors, 2×2 and
//! 3×3 matrices, a 3×2 orthonormal basis, the lower-triangular Cholesky
//! factor of a 3×3 SPD matrix, and a closed-form 2×2 symmetric
//! eigendecomposition. Defined generically over the scalar in
//! linalg_generic.zig (`Linalg(T)`); the f64 instantiation is
//! re-exported here under the original names. The one exception is
//! `LU` below — f64-only (the bordered-KKT path), defined in place
//! rather than in the generic slice. No algorithm-specific
//! knowledge — generic enough for a standalone numerical library.
//!
//! Cancellation hygiene: dot products and their variants chain
//! `@mulAdd` to save 1 rounding per term. Cross products and 2×2
//! determinants use `diff_of_products`, Kahan's compensated FMA scheme
//! for `a*b − c*d`, accurate to ~2 ulp even at near-cancellation.
//! Pattern mirrored from sibling project sparea_zig.

pub const Linalg = @import("linalg_generic.zig").Linalg;

const l64 = Linalg(f64);
pub const diff_of_products = l64.diff_of_products;
pub const Vec3 = l64.Vec3;
pub const Vec2 = l64.Vec2;
pub const Mat2 = l64.Mat2;
pub const Mat3x2 = l64.Mat3x2;
pub const Mat3 = l64.Mat3;
pub const Chol3 = l64.Chol3;
pub const Eig2 = l64.Eig2;
pub const eig2 = l64.eig2;

/// LU factorization with partial pivoting, dimension-generic. Storage
/// (`data`, `piv`) is borrowed from the caller — `factorize` mutates
/// `data` in place to hold the packed L\U factors. The returned handle
/// just binds the dimension to those slices so `solve` can't mismatch
/// them. Used for the bordered KKT system in `newton.zig`.
pub const LU = struct {
    data: []f64, // n·n, row-major; L (strict lower, unit diag) + U (upper)
    piv: []usize, // n
    n: usize,

    /// In-place factorization. Returns null when a pivot's magnitude
    /// falls below `pivot_min` (singular for the caller's purposes).
    pub fn factorize(data: []f64, n: usize, piv: []usize, pivot_min: f64) ?LU {
        for (0..n) |kk| {
            var pmax = kk;
            var vmax = @abs(data[kk * n + kk]);
            for (kk + 1..n) |i| {
                const v = @abs(data[i * n + kk]);
                if (v > vmax) {
                    vmax = v;
                    pmax = i;
                }
            }
            if (vmax < pivot_min) return null;
            piv[kk] = pmax;
            if (pmax != kk) {
                for (0..n) |j| {
                    const t = data[kk * n + j];
                    data[kk * n + j] = data[pmax * n + j];
                    data[pmax * n + j] = t;
                }
            }
            const inv = 1.0 / data[kk * n + kk];
            for (kk + 1..n) |i| {
                data[i * n + kk] *= inv;
                for (kk + 1..n) |j| {
                    data[i * n + j] = @mulAdd(f64, -data[i * n + kk], data[kk * n + j], data[i * n + j]);
                }
            }
        }
        return .{ .data = data, .piv = piv, .n = n };
    }

    /// In-place solve: overwrites b with the solution of (P·L·U)·x = b.
    pub fn solve(self: LU, b: []f64) void {
        const n = self.n;
        const data = self.data;
        const piv = self.piv;
        for (0..n) |kk| {
            const p = piv[kk];
            if (p != kk) {
                const t = b[kk];
                b[kk] = b[p];
                b[p] = t;
            }
        }
        for (1..n) |i| {
            for (0..i) |j| b[i] = @mulAdd(f64, -data[i * n + j], b[j], b[i]);
        }
        var i: usize = n;
        while (i > 0) {
            i -= 1;
            var j = i + 1;
            while (j < n) : (j += 1) b[i] = @mulAdd(f64, -data[i * n + j], b[j], b[i]);
            b[i] /= data[i * n + i];
        }
    }
};
