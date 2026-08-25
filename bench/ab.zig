//! A/B harness: measures the working tree against a pinned baseline, both
//! compiled into THIS binary.
//!
//!   just ab                 # A/B: current vs the pinned baseline
//!   just ab --aa            # calibration: current vs current
//!   just ab --inject-2x     # self-test: the current side solves twice
//!   just ab --inject-tol    # self-test: the current side runs a tight gap_tol
//!   just ab --gap-tol=1e-9  # both sides at 1e-9; deterministic pass only
//!
//! The report is meant to be pasted into a PR. Nothing is written to disk.
//!
//! ## Benchmarking methodology
//!
//! The policy — warm-up, passes per interval, pairing, the statistic — and `Side`, the
//! adapter that reads the clock, live in `core.zig`. What follows are the
//! parts that are properties of *this binary* rather than of `core.zig`.
//!
//! ### No process isolation, deliberately
//!
//! Both versions live in one binary. A freshly built binary's first *launch*
//! runs 2-5x slow, and that penalty survives an in-process warm-up and a
//! min-over-reps, so a two-process A/B can invent a small-cell regression
//! outright. It did, while A/B-ing the 0.16 bump. Sharing one process means
//! both sides pay the launch cost, the allocator and the clock, and all of it
//! divides out.
//!
//! This inverts what JVM harnesses do — they fork per variant because the JIT
//! builds a profile as it runs, so two implementations in one process
//! contaminate each other's compilation. Zig is AOT-compiled: there is no
//! profile to pollute.
//!
//! ### The check
//!
//! `--aa` runs a version against itself. It must yield 1.000; whatever it
//! misses by is that run's noise floor, and no A/B difference smaller than
//! that means anything. It is the only check that catches bias in the harness
//! rather than in the solver, so read it first. Measured on aarch64-macos:
//! ~0.3% on the smallest case, ~0.1% elsewhere, stable across launches; the
//! batch rows ≤0.3% at their 30 reps (1.2% at 10, which is why 30). The
//! floor is per run and per row, not a constant — a single row at 0.995 is
//! inside it; eight batch rows all at 0.97–0.99 are not.
//!
//! ### Known residual bias: code layout
//!
//! The two versions occupy different addresses in one binary, and their
//! relative layout is fixed at link time. Cache-set and alignment luck can
//! therefore favour one side systematically — and unlike everything above,
//! that bias is invisible to more reps, more launches, and even a rebuild,
//! since the build is deterministic. As the Stabilizer paper (ASPLOS'13) puts
//! it, a single binary is one sample from the space of layouts *regardless of
//! the number of runs*, and there layout effects swamped the difference
//! between -O2 and -O3.
//!
//! `--aa` cannot see it either: one module against itself shares layout by
//! construction. The re-pin after each release is the one run with two copies
//! of the same commit in two layouts; the samples are recorded on #22 (so
//! far: inside the A/A floor), which also owns a repeatable measure. Before
//! attributing a small stable shift to layout, diff the disassembly (dev.md
//! "Reading a small stable shift"). Treat an A/B difference near the noise
//! floor as unproven, and prefer a change that shows up across several cases
//! over one that moves a single case slightly.

const std = @import("std");
const bc = @import("core.zig");
const build_options = @import("build_options");
const cur = @import("cur");
const base = @import("base");
const cases = @import("cases");

// Two modules, not one: zig gives this today because a path dependency has
// no hash to dedupe against the tarball's; the assert outlives that
// guarantee. One module would read 1.000 by construction (#22).
comptime {
    std.debug.assert(cur.Outcome != base.Outcome);
}

/// What the report works on: a named list of cells. The deterministic pass
/// diffs a unit as one group (one tally per side, one gap-shift line, the
/// differing rows capped); the timing pass times it as one row. A fixture is a
/// one-cell unit; the whole fixture corpus is one unit with per-row `names`;
/// a batch is ~1000 cells named `name[idx]`.
const Unit = struct {
    name: []const u8,
    cells: []const []const [3]f64,
    /// Per-cell row names; null means `name[idx]`.
    names: ?[]const []const u8 = null,

    fn label(self: Unit, i: usize, buf: []u8) []const u8 {
        if (self.names) |n| return n[i];
        return std.fmt.bufPrint(buf, "{s}[{d}]", .{ self.name, i }) catch unreachable;
    }
};

fn fixture(comptime name: []const u8) Unit {
    return .{ .name = name, .cells = &.{cases.get(name).points} };
}

/// The fixture corpus as one unit, for the deterministic pass. Rows carry
/// their tier as a ` [t1]`/` [t2]`/` [t3]` label (tier 0 unmarked): rows
/// print only when the sides differ, and the label says how to read one —
/// a t2/t3 status flip is a promotion candidate, not a regression
/// (promotion = a reviewed tier edit; the tier legend, dev.md).
const FIXTURES: Unit = blk: {
    var names: [cases.all.len][]const u8 = undefined;
    var cells: [cases.all.len][]const [3]f64 = undefined;
    for (cases.all, 0..) |e, i| {
        names[i] = switch (e.case.tier) {
            0 => e.name,
            1 => e.name ++ " [t1]",
            2 => e.name ++ " [t2]",
            3 => e.name ++ " [t3]",
        };
        cells[i] = e.case.points;
    }
    const n = names;
    const c = cells;
    break :blk .{ .name = "fixtures", .cells = &c, .names = &n };
};

/// The batches the report covers — diffed and timed. Under the coverage build
/// (`-Dcoverage`, the kcov gate's Debug binary) one batch at one rep: a Debug
/// pass over a batch is ~0.4 s, and the gate needs each line to run once, not
/// eight batches × 1000 cells × 2 sides. Outside it, 30 reps rather
/// than `N_REPS`: a batch interval is ~2 ms and already a mean over 1000
/// cells, so the min settles sooner — measured `--aa` floor on batch rows:
/// ≤0.2% at 30 (as the fixture rows), up to 1.2% at 10.
const coverage = build_options.coverage;
const BATCHES: [if (coverage) 1 else cases.batches.all.len]Unit = blk: {
    var units: [if (coverage) 1 else cases.batches.all.len]Unit = undefined;
    for (&units, cases.batches.all[0..units.len]) |*u, e| u.* = .{ .name = e.name, .cells = e.batch.cells };
    break :blk units;
};
const BATCH_REPS = if (coverage) 1 else 30;

/// A timed case row, checked against the timed-set rule (the tier legend,
/// dev.md): timing measures the optimization loop, so a timed row must claim
/// `converges` at tier <= 1 — and must sit in the subsection its tier says.
/// `infeasible` and `rejects` rows ride the deterministic diff only (this is
/// what removed `near_collinear`, formerly the timed set's one
/// infeasible-regime row).
fn timedFixture(comptime name: []const u8, comptime tier: u2) Unit {
    const c = cases.get(name);
    if (c.claim != .converges or c.tier > 1 or c.tier != tier)
        @compileError("not a tier-" ++ .{'0' + tier} ++ " converges case: " ++ name);
    return fixture(name);
}

/// Timed case rows beyond the batches, grouped by tier for the report's two
/// timing subsections. Tier 0: `hex`, the one row whose interval spans many
/// passes — the quantization canary. Tier 1: the regimes the batches lack —
/// `np100` (mid-size), `ha_12` (hard/wide).
const TIMING_T0 = [_]Unit{
    timedFixture("hex", 0),
};
const TIMING_T1 = [_]Unit{
    timedFixture("np100", 1),
    timedFixture("ha_12", 1),
};

/// Differing rows printed per group before "… and k more". Fixtures never
/// reach it; a regressed batch would otherwise print a thousand rows.
const MAX_DIFF_ROWS = 10;

/// Tight enough to push borderline cases off the f64 gap floor, for --inject-tol.
const INJECT_GAP_TOL = 1e-13;

const Opts = struct {
    aa: bool = false,
    inject_2x: bool = false,
    inject_tol: bool = false,
    /// `--gap-tol=X`: both sides solve at X instead of `bc.GAP_TOL`, and the
    /// report is the deterministic pass only. The fixtures' pins hold at the
    /// default, so timing at another tolerance has no baseline to read
    /// against; and a cell that errors there — as the close-pair repro
    /// (tests/neg_gap_test.zig) once did at 1e-9 — would panic `measure`.
    gap_tol: ?f64 = null,
};

const USAGE = "usage: just ab [--aa] [--inject-2x] [--inject-tol] [--gap-tol=X]\n";

pub fn main(init: std.process.Init) !void {
    var opts = Opts{};
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    for (argv[1..]) |a| {
        if (std.mem.eql(u8, a, "--aa")) {
            opts.aa = true;
        } else if (std.mem.eql(u8, a, "--inject-2x")) {
            opts.inject_2x = true;
        } else if (std.mem.eql(u8, a, "--inject-tol")) {
            opts.inject_tol = true;
        } else if (std.mem.startsWith(u8, a, "--gap-tol=")) {
            opts.gap_tol = std.fmt.parseFloat(f64, a["--gap-tol=".len..]) catch {
                std.debug.print("bad --gap-tol: {s}\n" ++ USAGE, .{a});
                return error.UnknownArgument;
            };
        } else {
            // Fail rather than ignore: a misspelt `--inject-2x` would
            // otherwise run a plain A/B and print a report that looks like a
            // passed self-test.
            std.debug.print("unknown argument: {s}\n" ++ USAGE, .{a});
            return error.UnknownArgument;
        }
    }
    // The baseline side is a comptime choice, so it is dispatched here rather
    // than selected inside: in --aa mode it is the current library again.
    if (opts.aa) try report(bc.Side(cur), init, opts) else try report(bc.Side(base), init, opts);
}

/// `Base` is the adapter for what the current tree is measured against: the
/// pinned baseline normally, the current library itself under --aa — or, in a
/// PR whose API change needs one, a shim with `Side`'s two methods.
fn report(comptime Base: type, init: std.process.Init, opts: Opts) !void {
    const gpa = init.gpa;
    const io = init.io;

    var buf: [8192]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    const out = &w.interface;
    // Best-effort on the error path: if the run dies partway, emit the rows
    // that were already formatted rather than nothing. The happy path flushes
    // explicitly at the end, so a real write failure still propagates —
    // "truncated, exit 0" would be worse than the failure this softens.
    defer out.flush() catch {};

    // Both sides solve at `tol`; `--inject-tol` overrides the current side
    // regardless of `--gap-tol`.
    const tol: f64 = opts.gap_tol orelse bc.GAP_TOL;
    const cur_tol: f64 = if (opts.inject_tol) INJECT_GAP_TOL else tol;
    const cur_mult: u32 = if (opts.inject_2x) 2 else 1;

    const Cur = bc.Side(cur);

    var side_cur = Cur{ .gpa = gpa, .io = io, .gap_tol = cur_tol };
    var side_base = Base{ .gpa = gpa, .io = io, .gap_tol = tol };

    // Self-describing: a local report and a CI report must be comparable, and
    // the invariant that travels between machines is the ratio, not the µs.
    const builtin = @import("builtin");
    try out.print("csar A/B report\n", .{});
    try out.print("  mode      : {s}\n", .{if (opts.aa) "A/A (current vs current)" else "A/B (current vs pinned baseline)"});
    try out.print("  host      : {t}-{t}\n", .{ builtin.cpu.arch, builtin.os.tag });
    try out.print("  zig       : {s}\n", .{builtin.zig_version_string});
    try out.print("  baseline  : {s}\n", .{if (opts.aa) "(A/A: the working tree)" else build_options.baseline});
    try out.print("  reps      : {d} (+{d} warm-up), interleaved; batches {d} reps, no warm-up\n", .{ bc.N_REPS, bc.N_WARMUP, BATCH_REPS });
    try out.print("  note      : compare ratios, not µs — absolute times vary 2-5x between\n" ++
        "              launches (see ab.zig, \"No process isolation\"); ratios do not.\n" ++
        "              A small stable shift with an empty diff: dev.md \"Reading a small stable shift\".\n", .{});
    if (opts.inject_2x) try out.print("  injected  : 2x on the current side\n", .{});
    if (opts.inject_tol) try out.print("  injected  : gap_tol={e} on the current side\n", .{INJECT_GAP_TOL});
    if (opts.gap_tol) |t| try out.print("  gap_tol   : {e} on both sides — deterministic pass only\n", .{t});
    try out.print("\n", .{});

    // ---- deterministic pass: the fixtures as one group, each batch as one --
    try out.print("deterministic diff (status / iters / ar; {d} fixtures, {d} batches)\n", .{ cases.all.len, BATCHES.len });
    _ = try diffGroup(out, &side_cur, &side_base, FIXTURES);
    var batch_tallies: [BATCHES.len]Tallies = undefined;
    for (BATCHES, &batch_tallies) |unit, *t| t.* = try diffGroup(out, &side_cur, &side_base, unit);
    if (BATCHES.len < cases.batches.all.len) {
        try out.print("  ({d} of {d} batches: coverage build)\n", .{ BATCHES.len, cases.batches.all.len });
    }
    try out.print("\n", .{});

    if (opts.gap_tol == null) {
        try out.print("timing (min of {d} reps, {d} for a batch; µs per solve — a batch row averages its cells)\n", .{ bc.N_REPS, BATCH_REPS });
        try out.print("tier 0 — the product; above-floor shifts here are the headline (batches are tier 0 by contract)\n", .{});
        try out.print("{s}\n", .{bc.timing_header});
        for (TIMING_T0) |unit| try timeUnit(out, &side_cur, &side_base, cur_mult, unit, null);
        for (BATCHES, batch_tallies) |unit, t| try timeUnit(out, &side_cur, &side_base, cur_mult, unit, t);
        try out.print("tier 1 — correct at defaults; improved gladly, never at tier 0's expense\n", .{});
        try out.print("{s}\n", .{bc.timing_header});
        for (TIMING_T1) |unit| try timeUnit(out, &side_cur, &side_base, cur_mult, unit, null);
    } else {
        try out.print("timing: skipped under --gap-tol (see the header)\n", .{});
    }

    // Not redundant with the `defer` above: this is the one that reports a
    // write failure instead of swallowing it.
    try out.flush();
}

/// Both sides' tallies over one unit, from the deterministic pass.
const Tallies = struct { cur: bc.Tally, base: bc.Tally };

/// One group of the deterministic pass: differing rows (capped), a tally per
/// side, the gap shift.
fn diffGroup(out: *std.Io.Writer, side_cur: anytype, side_base: anytype, unit: Unit) !Tallies {
    var n_diff: usize = 0;
    var t: Tallies = .{ .cur = .{}, .base = .{} };
    var shift: bc.GapShift = .{};
    var buf: [48]u8 = undefined;
    try out.print("  {s} ({d} cells)\n", .{ unit.name, unit.cells.len });
    for (unit.cells, 0..) |pts, i| {
        const a = side_cur.metrics(pts);
        const b = side_base.metrics(pts);
        t.cur.add(a);
        t.base.add(b);
        shift.add(i, a, b);
        if (!bc.differs(a, b)) continue;
        n_diff += 1;
        if (n_diff <= MAX_DIFF_ROWS) try bc.writeDiff(out, unit.label(i, &buf), a, b);
    }
    if (n_diff == 0) {
        try out.print("    none\n", .{});
    } else {
        if (n_diff > MAX_DIFF_ROWS) try out.print("    … and {d} more\n", .{n_diff - MAX_DIFF_ROWS});
        try out.print("    {d} of {d} differ\n", .{ n_diff, unit.cells.len });
    }
    try out.print("    cur : {f}\n", .{t.cur});
    try out.print("    base: {f}\n", .{t.base});
    try out.print("    gap shift : {f}", .{shift});
    if (shift.idx) |i| try out.print(" ({s})", .{unit.label(i, &buf)});
    try out.print("\n", .{});
    return t;
}

/// One timing row, paired and interleaved. A one-cell unit is warmed up and
/// calibrated; a batch is neither — its deterministic pass (`tallies`) already
/// solved every cell, and one pass is far above the interval target, so the
/// answer would be one pass anyway. A batch is timed only if both sides
/// converged every cell: a DNC cell would time `max_outer`, and an errored
/// one (`--inject-tol` errors most) would panic `measure`.
fn timeUnit(out: *std.Io.Writer, side_cur: anytype, side_base: anytype, cur_mult: u32, unit: Unit, tallies: ?Tallies) !void {
    var samples_cur: [bc.N_REPS]f64 = undefined;
    var samples_base: [bc.N_REPS]f64 = undefined;
    side_cur.cells = unit.cells;
    side_base.cells = unit.cells;
    var passes: u32 = 1;
    var reps: usize = BATCH_REPS;
    if (tallies) |t| {
        const n: u32 = @intCast(unit.cells.len);
        const unconverged = n - @min(t.cur.converged, t.base.converged);
        if (unconverged > 0) {
            var buf: [64]u8 = undefined;
            return bc.writeSkipped(out, unit.name, try std.fmt.bufPrint(&buf, "{d} cells did not converge on both sides", .{unconverged}));
        }
    } else {
        bc.warmUp(side_cur);
        bc.warmUp(side_base);
        // Calibrated AFTER warm-up, so the probes measure warm solves, and
        // from the baseline side so both sides use the same passes.
        passes = bc.calibrate(side_base);
        reps = bc.N_REPS;
    }
    const t = bc.pairedRun(side_cur, side_base, passes, @intCast(unit.cells.len), cur_mult, samples_cur[0..reps], samples_base[0..reps]);
    try bc.writeTiming(out, unit.name, t);
}
