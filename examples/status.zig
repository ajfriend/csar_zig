//! Full outcome-handling example: shows the canonical switch on the
//! `Outcome` tagged union and per-variant inspection.
//!
//! Run with:
//!   zig build ex-status
//!
//! `solve` returns four distinct outcomes; only `.converged` produces
//! a certified cone. `.infeasible`, `.did_not_converge` and
//! `.precision_floor` are still valid library responses — the caller
//! dispatches on the union tag to decide what to do. Structural input problems (too few points,
//! rank-deficient X) propagate as `InputError` via `try`.

const std = @import("std");
const csar = @import("csar");

pub fn main(init: std.process.Init) !void {
    // init.gpa: leak-checked DebugAllocator in Debug, smp_allocator in
    // release builds.
    const allocator = init.gpa;

    // One input per outcome, so the switch below is exercised end to end.
    //
    // 1. The basis vectors: one octant, converges to a circular cone.
    // 2. Two antipodal points plus one more: no hemisphere contains them
    //    all, so the Farkas check reports infeasibility before iterating.
    // 3. An irregular triple with an iteration budget of one and a
    //    tolerance below the f64 floor: the budget runs out first.
    // 4. A hexagon ~4e-10 rad across (an H3 r15-scale cell far from the
    //    origin): its certificate's f64 floor is ~1e-6, above the default
    //    tolerance, so the cone is found but cannot be certified.
    const octant = [_][3]f64{ .{ 1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, 0, 1 } };
    const antipodal = [_][3]f64{ .{ 1, 0, 0 }, .{ -1, 0, 0 }, .{ 0, 1, 0 } };
    const irregular = [_][3]f64{ .{ 1, 0, 0 }, .{ 0.1, 0.97, 0.2 }, .{ -0.2, 0.3, 0.93 } };
    const tiny_hex = [_][3]f64{
        .{ 0.6746833027403286, 0.7369617968776201, -0.04110658032859652 },
        .{ 0.674683302801862, 0.7369617968319514, -0.04110658013740184 },
        .{ 0.6746833029130066, 0.736961796730196, -0.04110658013746045 },
        .{ 0.674683302962618, 0.7369617966741094, -0.04110658032871372 },
        .{ 0.6746833029010845, 0.7369617967197781, -0.041106580519908585 },
        .{ 0.6746833027899399, 0.7369617968215336, -0.04110658051984987 },
    };

    // Solve with default options. Pass `.{}` for sensible defaults;
    // override individual fields with named-field syntax:
    //   .{ .gap_tol = 1e-9 }
    //   .{ .coplanarity_tol = -1 }   // disable the coplanarity check
    //   .{ .max_outer = 500 }
    //
    // `solve` can also return `InputError` (caller passed bad
    // arguments — too few points, bad tolerance), `SolveError`
    // (library internal-correctness violation), or `OutOfMemory`.
    // All three propagate via `try`.
    try report(allocator, &octant, .{});
    try report(allocator, &antipodal, .{});
    try report(allocator, &irregular, .{ .max_outer = 1, .gap_tol = 1e-20 });
    try report(allocator, &tiny_hex, .{});
}

fn report(allocator: std.mem.Allocator, points: []const [3]f64, opts: csar.SolveOptions) !void {
    var outcome = try csar.solve(allocator, points, opts);
    defer outcome.deinit();

    switch (outcome) {
        .converged => |c| {
            // `c` is a `Converged` — accessors like `aspectRatio()`,
            // `b()`, `A()` live here, not on `Outcome` directly. The
            // type system prevents calling them without first switching.
            const b = c.b(); // Vec3 — cone axis
            const aspect = c.aspectRatio();
            std.debug.print("converged: aspect ratio = {d:.6}\n", .{aspect});
            std.debug.print("  cone axis     b = ({d:.4}, {d:.4}, {d:.4})\n", .{ b.m[0], b.m[1], b.m[2] });
            std.debug.print("  duality gap     = {e:.3}\n", .{c.gap});
            std.debug.print("  iters           = {d}\n", .{c.diag.totalIters()});
            std.debug.print("  active in cert  = {d} of {d} input points\n", .{ c.cert.indices.len, points.len });
        },
        .infeasible => |i| {
            // No hemisphere contains all input points. `i.cert` is a
            // Farkas certificate (λ ≥ 0, Σλ = 1, with ‖Σ λᵢ xᵢ‖ near
            // zero); the witness magnitude lives on `i.residual`.
            std.debug.print("infeasible: no hemisphere fits all points\n", .{});
            std.debug.print("  Farkas residual = {e:.3}\n", .{i.residual});
        },
        .did_not_converge => |p| {
            // Solver hit `max_outer` without closing the gap. The
            // last iterate is in p.Q / p.sigma but isn't a verified
            // certificate; p.gap holds the last computed gap (not
            // certified to be ≤ `gap_tol`, unlike `Converged.gap`).
            // Remedy: raise `max_outer`.
            std.debug.print("did_not_converge: hit max iterations ({d})\n", .{p.diag.totalIters()});
            std.debug.print("  last gap = {e:.3}\n", .{p.gap});
        },
        .precision_floor => |p| {
            // The iterate is at the f64 floor for this input: the gap
            // cannot be certified below p.gap_floor, and `gap_tol` asked
            // for less. Same payload as `.did_not_converge`; the aspect
            // ratio from p.sigma is as accurate as the input allows.
            // Remedy: loosen `gap_tol` (raising `max_outer` does nothing).
            std.debug.print("precision_floor: gap_tol {e:.0} is below this input's floor {e:.1}\n", .{ opts.gap_tol, p.gap_floor });
            std.debug.print("  last gap = {e:.3}, uncertified aspect ratio = {d:.6}\n", .{ p.gap, p.sigma[2] / p.sigma[1] });
        },
    }
}
