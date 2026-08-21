//! Static manifest of solver test cases.
//!
//! Each case lives in its own `cases/*.zon` file with shape:
//!   .{
//!     .description = "...",
//!     .tags = .{ "...", ... },
//!     .points = .{ .{x, y, z}, ... },
//!     .expected = .{ .converged = .{ .ar = 1.234 } }  // or .infeasible
//!   }
//!
//! Everything below is compiled into the binary at build time — no
//! filesystem reads at runtime. Adding a case = drop a `.zon` file, add
//! its `pub const`, and append its line to `all`. The schema enforces
//! shape at compile time; the test loop in `tests/cases_test.zig` runs
//! every entry of `all`, so an unlisted case is the only way to escape
//! coverage.

const std = @import("std");

pub const Expected = union(enum) {
    /// Solver should converge with this aspect ratio (matched within
    /// the integration test's tolerance, currently 1e-6).
    converged: struct { ar: f64 },
    /// Solver should detect infeasibility. Universal sanity checks
    /// (λ ≥ 0, ∑λ ≈ 1, ‖∑ λᵢ xᵢ‖ ≈ residual) live in the test loop;
    /// no per-case residual value is stored.
    infeasible,
};

pub const Case = struct {
    description: []const u8,
    tags: []const []const u8,
    points: []const [3]f64,
    expected: Expected,
};

pub const Entry = struct {
    name: []const u8,
    case: Case,
};

// One declaration per case, so code that names a case at compile time
// names a symbol — `cases.hex.points` — and a misspelling is a compile
// error. `byName` below is for names that arrive at runtime (ex-cases).
pub const dnc_small_wide: Case = @import("zon/dnc_small_wide.zon");
pub const h3_r12_equator: Case = @import("zon/h3_r12_equator.zon");
pub const h3_r12_midLat: Case = @import("zon/h3_r12_midLat.zon");
pub const h3_r12_pent: Case = @import("zon/h3_r12_pent.zon");
pub const h3_r12_ring10: Case = @import("zon/h3_r12_ring10.zon");
pub const h3_r15_equator: Case = @import("zon/h3_r15_equator.zon");
pub const h3_r15_midLat: Case = @import("zon/h3_r15_midLat.zon");
pub const h3_r15_pent: Case = @import("zon/h3_r15_pent.zon");
pub const h3_r15_ring10: Case = @import("zon/h3_r15_ring10.zon");
pub const h3_r5_equator: Case = @import("zon/h3_r5_equator.zon");
pub const h3_r5_midLat: Case = @import("zon/h3_r5_midLat.zon");
pub const h3_r5_pent: Case = @import("zon/h3_r5_pent.zon");
pub const h3_r5_ring10: Case = @import("zon/h3_r5_ring10.zon");
pub const h3_r9_equator: Case = @import("zon/h3_r9_equator.zon");
pub const h3_r9_midLat: Case = @import("zon/h3_r9_midLat.zon");
pub const h3_r9_pent: Case = @import("zon/h3_r9_pent.zon");
pub const h3_r9_ring10: Case = @import("zon/h3_r9_ring10.zon");
pub const h3_res05: Case = @import("zon/h3_res05.zon");
pub const h3_res09: Case = @import("zon/h3_res09.zon");
pub const h3_res12: Case = @import("zon/h3_res12.zon");
pub const h3_res15: Case = @import("zon/h3_res15.zon");
pub const ha_05: Case = @import("zon/ha_05.zon");
pub const ha_08: Case = @import("zon/ha_08.zon");
pub const ha_10: Case = @import("zon/ha_10.zon");
pub const ha_12: Case = @import("zon/ha_12.zon");
pub const ha_14: Case = @import("zon/ha_14.zon");
pub const hex: Case = @import("zon/hex.zon");
pub const ico_00: Case = @import("zon/ico_00.zon");
pub const ico_01: Case = @import("zon/ico_01.zon");
pub const ico_02: Case = @import("zon/ico_02.zon");
pub const ico_03: Case = @import("zon/ico_03.zon");
pub const ico_04: Case = @import("zon/ico_04.zon");
pub const ico_05: Case = @import("zon/ico_05.zon");
pub const ico_06: Case = @import("zon/ico_06.zon");
pub const ico_07: Case = @import("zon/ico_07.zon");
pub const ico_08: Case = @import("zon/ico_08.zon");
pub const ico_09: Case = @import("zon/ico_09.zon");
pub const ico_10: Case = @import("zon/ico_10.zon");
pub const ico_11: Case = @import("zon/ico_11.zon");
pub const ico_12: Case = @import("zon/ico_12.zon");
pub const ico_13: Case = @import("zon/ico_13.zon");
pub const ico_14: Case = @import("zon/ico_14.zon");
pub const ico_15: Case = @import("zon/ico_15.zon");
pub const ico_16: Case = @import("zon/ico_16.zon");
pub const ico_17: Case = @import("zon/ico_17.zon");
pub const ico_18: Case = @import("zon/ico_18.zon");
pub const ico_19: Case = @import("zon/ico_19.zon");
pub const infeas_antipodal: Case = @import("zon/infeas_antipodal.zon");
pub const near_collinear: Case = @import("zon/near_collinear.zon");
pub const np100: Case = @import("zon/np100.zon");
pub const np20: Case = @import("zon/np20.zon");
pub const np400: Case = @import("zon/np400.zon");
pub const oct_n0: Case = @import("zon/oct_n0.zon");
pub const oct_n1: Case = @import("zon/oct_n1.zon");
pub const oct_n2: Case = @import("zon/oct_n2.zon");
pub const oct_n3: Case = @import("zon/oct_n3.zon");
pub const oct_s0: Case = @import("zon/oct_s0.zon");
pub const oct_s1: Case = @import("zon/oct_s1.zon");
pub const oct_s2: Case = @import("zon/oct_s2.zon");
pub const oct_s3: Case = @import("zon/oct_s3.zon");
pub const wide_cap82: Case = @import("zon/wide_cap82.zon");
pub const wide_cap85: Case = @import("zon/wide_cap85.zon");
pub const wide_cap89: Case = @import("zon/wide_cap89.zon");

pub const all: []const Entry = &.{
    .{ .name = "dnc_small_wide", .case = dnc_small_wide },
    .{ .name = "h3_r12_equator", .case = h3_r12_equator },
    .{ .name = "h3_r12_midLat", .case = h3_r12_midLat },
    .{ .name = "h3_r12_pent", .case = h3_r12_pent },
    .{ .name = "h3_r12_ring10", .case = h3_r12_ring10 },
    .{ .name = "h3_r15_equator", .case = h3_r15_equator },
    .{ .name = "h3_r15_midLat", .case = h3_r15_midLat },
    .{ .name = "h3_r15_pent", .case = h3_r15_pent },
    .{ .name = "h3_r15_ring10", .case = h3_r15_ring10 },
    .{ .name = "h3_r5_equator", .case = h3_r5_equator },
    .{ .name = "h3_r5_midLat", .case = h3_r5_midLat },
    .{ .name = "h3_r5_pent", .case = h3_r5_pent },
    .{ .name = "h3_r5_ring10", .case = h3_r5_ring10 },
    .{ .name = "h3_r9_equator", .case = h3_r9_equator },
    .{ .name = "h3_r9_midLat", .case = h3_r9_midLat },
    .{ .name = "h3_r9_pent", .case = h3_r9_pent },
    .{ .name = "h3_r9_ring10", .case = h3_r9_ring10 },
    .{ .name = "h3_res05", .case = h3_res05 },
    .{ .name = "h3_res09", .case = h3_res09 },
    .{ .name = "h3_res12", .case = h3_res12 },
    .{ .name = "h3_res15", .case = h3_res15 },
    .{ .name = "ha_05", .case = ha_05 },
    .{ .name = "ha_08", .case = ha_08 },
    .{ .name = "ha_10", .case = ha_10 },
    .{ .name = "ha_12", .case = ha_12 },
    .{ .name = "ha_14", .case = ha_14 },
    .{ .name = "hex", .case = hex },
    .{ .name = "ico_00", .case = ico_00 },
    .{ .name = "ico_01", .case = ico_01 },
    .{ .name = "ico_02", .case = ico_02 },
    .{ .name = "ico_03", .case = ico_03 },
    .{ .name = "ico_04", .case = ico_04 },
    .{ .name = "ico_05", .case = ico_05 },
    .{ .name = "ico_06", .case = ico_06 },
    .{ .name = "ico_07", .case = ico_07 },
    .{ .name = "ico_08", .case = ico_08 },
    .{ .name = "ico_09", .case = ico_09 },
    .{ .name = "ico_10", .case = ico_10 },
    .{ .name = "ico_11", .case = ico_11 },
    .{ .name = "ico_12", .case = ico_12 },
    .{ .name = "ico_13", .case = ico_13 },
    .{ .name = "ico_14", .case = ico_14 },
    .{ .name = "ico_15", .case = ico_15 },
    .{ .name = "ico_16", .case = ico_16 },
    .{ .name = "ico_17", .case = ico_17 },
    .{ .name = "ico_18", .case = ico_18 },
    .{ .name = "ico_19", .case = ico_19 },
    .{ .name = "infeas_antipodal", .case = infeas_antipodal },
    .{ .name = "near_collinear", .case = near_collinear },
    .{ .name = "np100", .case = np100 },
    .{ .name = "np20", .case = np20 },
    .{ .name = "np400", .case = np400 },
    .{ .name = "oct_n0", .case = oct_n0 },
    .{ .name = "oct_n1", .case = oct_n1 },
    .{ .name = "oct_n2", .case = oct_n2 },
    .{ .name = "oct_n3", .case = oct_n3 },
    .{ .name = "oct_s0", .case = oct_s0 },
    .{ .name = "oct_s1", .case = oct_s1 },
    .{ .name = "oct_s2", .case = oct_s2 },
    .{ .name = "oct_s3", .case = oct_s3 },
    .{ .name = "wide_cap82", .case = wide_cap82 },
    .{ .name = "wide_cap85", .case = wide_cap85 },
    .{ .name = "wide_cap89", .case = wide_cap89 },
};

/// Look up a case by name. Linear scan; the manifest is tiny.
pub fn byName(name: []const u8) ?Case {
    for (all) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.case;
    }
    return null;
}
