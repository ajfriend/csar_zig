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
//! The policy — warm-up, batching, pairing, the statistic — and `Side`, the
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
//! ~0.3% on the smallest case, ~0.1% elsewhere, stable across launches.
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
//! `--aa` cannot see it either: identical pins dedupe to one module, so A/A
//! compares one copy against itself and shares layout by construction.
//! Measuring it needs two distinct copies of the *same* commit — two pins that
//! hash differently — tracked in #22. Until then, treat an A/B difference near
//! the noise floor as unproven, and prefer a change that shows up across
//! several cases over one that moves a single case slightly.

const std = @import("std");
const bc = @import("core.zig");
const build_options = @import("build_options");
const cur = @import("cur");
const base = @import("base");
const cases = @import("cases");

/// Timing selection: examples spanning the regimes (sub-µs hot path, mid-size,
/// hard/wide, infeasible). Deliberately NOT a corpus — #19 decides what a
/// report highlights. Deterministic metrics run over every fixture regardless.
const TIMING_CASES = [_]TimingCase{
    timing("hex"),
    timing("np100"),
    timing("ha_12"),
    timing("near_collinear"),
};

const TimingCase = struct {
    name: []const u8,
    points: []const [3]f64,
};

fn timing(comptime name: []const u8) TimingCase {
    return .{
        .name = name,
        .points = cases.get(name).points,
    };
}

/// Tight enough to push borderline cases off the f64 gap floor, for --inject-tol.
const INJECT_GAP_TOL = 1e-13;

const Opts = struct {
    aa: bool = false,
    inject_2x: bool = false,
    inject_tol: bool = false,
    /// `--gap-tol=X`: both sides solve at X instead of `bc.GAP_TOL`, and the
    /// report is the deterministic pass only. The fixtures' pins hold at the
    /// default, so timing at another tolerance has no baseline to read
    /// against; and a cell that errors there — the #2 class at 1e-9, once
    /// #6 adds those repros as fixtures — would panic `measure`.
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
    try out.print("  reps      : {d} (+{d} warm-up), interleaved\n", .{ bc.N_REPS, bc.N_WARMUP });
    try out.print("  note      : compare ratios, not µs — absolute times vary 2-5x between\n" ++
        "              launches (see ab.zig, \"No process isolation\"); ratios do not.\n", .{});
    if (opts.inject_2x) try out.print("  injected  : 2x on the current side\n", .{});
    if (opts.inject_tol) try out.print("  injected  : gap_tol={e} on the current side\n", .{INJECT_GAP_TOL});
    if (opts.gap_tol) |t| try out.print("  gap_tol   : {e} on both sides — deterministic pass only\n", .{t});
    try out.print("\n", .{});

    // ---- deterministic pass, over every fixture -------------------------
    try out.print("deterministic diff ({d} fixtures: status / iters / ar)\n", .{cases.all.len});
    var n_diff: usize = 0;
    var tally_cur: bc.Tally = .{};
    var tally_base: bc.Tally = .{};
    var shift: bc.GapShift = .{};
    for (cases.all) |entry| {
        const a = side_cur.metrics(entry.case.points);
        const b = side_base.metrics(entry.case.points);
        tally_cur.add(a);
        tally_base.add(b);
        shift.add(entry.name, a, b);
        if (!bc.differs(a, b)) continue;
        n_diff += 1;
        try bc.writeDiff(out, entry.name, a, b);
    }
    if (n_diff == 0) {
        try out.print("  none\n", .{});
    } else {
        try out.print("  {d} case(s) differ\n", .{n_diff});
    }
    try out.print("  outcomes  cur : {f}\n", .{tally_cur});
    try out.print("            base: {f}\n", .{tally_base});
    try out.print("  gap shift : {f}\n", .{shift});
    try out.print("\n", .{});

    if (opts.gap_tol == null) {
        try timingSection(out, &side_cur, &side_base, cur_mult);
    } else {
        try out.print("timing: skipped under --gap-tol (see the header)\n", .{});
    }

    // Not redundant with the `defer` above: this is the one that reports a
    // write failure instead of swallowing it.
    try out.flush();
}

/// The timing section: paired and interleaved, over `TIMING_CASES`.
fn timingSection(out: *std.Io.Writer, side_cur: anytype, side_base: anytype, cur_mult: u32) !void {
    try out.print("timing (min of {d} reps, µs per solve)\n", .{bc.N_REPS});
    try out.print("{s}\n", .{bc.timing_header});

    var samples_cur: [bc.N_REPS]f64 = undefined;
    var samples_base: [bc.N_REPS]f64 = undefined;
    for (TIMING_CASES) |case| {
        side_cur.pts = case.points;
        side_base.pts = case.points;

        bc.warmUp(side_cur);
        bc.warmUp(side_base);

        // Calibrated AFTER warm-up, so the probes measure warm solves, and
        // from the baseline side so both sides use the same batch.
        const batch = bc.calibrate(side_base);

        const t = bc.pairedRun(side_cur, side_base, batch, cur_mult, &samples_cur, &samples_base);
        try bc.writeTiming(out, case.name, t);
    }
}
