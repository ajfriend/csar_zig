# Development notes

## Dependencies

- **[zig](https://ziglang.org/)** 0.16.0+ — the language. Managed via
  [mise](https://mise.jdx.dev/), pinned by the committed `mise.toml`:
  `brew install mise` on macOS, then `mise install` in the repo root.
  On macOS 0.16.0 is a hard floor, not a preference: 0.15.x fails to link
  against macOS 26.x SDKs — the build runner itself dies with
  `undefined symbol: _free` and a dozen similar — so `zig build` cannot
  run at all there, and `--sysroot` doesn't help (the runner is compiled
  before the flag applies).
- **[just](https://github.com/casey/just)** — task runner.
  `brew install just`.
- **[kcov](https://github.com/SimonKagstrom/kcov)** — line-coverage tool
  used by `just test-slow`. `brew install kcov` works on macOS and
  Linux alike; on Ubuntu, `apt install kcov` also works on 22.04 and on
  25.10+, but *not* on 24.04 — the archive skips noble. The exclusion
  ledger is derived from kcov's own line classification, so if a local
  kcov and CI's disagree about it, CI is authoritative.
- **[uv](https://docs.astral.sh/uv/)** — runs the Python scripts
  (`scripts/coverage_gate.py` behind `just test-slow`, and the
  states/countries examples). `brew install uv`.

## Common commands

| Command | What it does |
| --- | --- |
| `just ci` | Everything CI checks that can run on this machine, in the order the `ci` recipe lists (CI runs each recipe as its own job, in parallel). Run before pushing a PR. |
| `just test` | Fast test loop — skips long-running randomized stress tests, no coverage gate. Sub-second; the inner-loop iteration command. |
| `just test-slow` | Full suite + the 100% line-coverage gate under `kcov` over every binary (tests, examples, the A/B harness), built with `-Dcoverage=true` and `-Dslow=true`. ~20s; the pre-commit / CI check. |
| `just test-selfhosted` | Full suite under zig's self-hosted backend (`-Dllvm=false`). See "Two backends" below. |
| `just check` | Compile the library and every executable, running nothing (CI's `check` job). |
| `just lint` | Every declaration is referenced (zlinter `no_unused`, its own package under `lint/`) — the check coverage cannot make; see "Coverage". The first run builds the linter. |
| `just consumer-smoke` | Build `scripts/consumer_smoke/` against the tree as a consumer receives it, and print the shipped file list. The only check of the published package rather than the working tree; see "Packaging". |
| `just ab` | A/B the working tree against the pinned baseline, both in one binary. `just ab --aa` calibrates. See "A/B benchmarking" below. |
| `just clean` | Remove `zig-out/`, `.zig-cache/`, `coverage/`, and the bench package's caches and unpacked baseline. |
| `just surveys::…` | The states/countries survey pipelines (research/example tooling), grouped in the `surveys` module (`surveys.just`) — `just --list surveys`. |

### Two test tiers

`just test` is the dev fast loop — runs every test except those gated
on `-Dslow`. `just test-slow` adds the slow ones and enforces the
coverage gate. The slow flag is plumbed via `build.zig`'s
`b.addOptions("test_options", ...)` into a `test_options` module
that gated tests import:

```zig
const test_options = @import("test_options");

test "my slow test" {
    if (!test_options.slow) return error.SkipZigTest;
    // ...
}
```

Slow tests show up as `SKIP` in the fast tier and `OK` in the slow
tier. Coverage only makes sense on the slow tier — fast-tier
coverage would be incomplete by design.

Both tiers are quiet on success and show full output on failure. The
fast tier gets this natively from zig's build runner (which is why
failure-diagnostic self-tests set `helpers.quiet_diagnostics` — stray
stderr from a passing run would otherwise be forwarded). The slow
tier must run the installed binary under kcov, which streams
everything, so the recipe captures it to `zig-out/test-slow.log` and
dumps that only when the run fails.

### Two backends

Zig has two code generators (LLVM, and its own self-hosted backend —
the Debug default on x86_64-linux), and their FP code paths can
differ, which matters for this solver's κ-limited cells. Policy: the
**suite — including the deterministic iteration-ceiling bounds — must
pass under both backends**; CI runs both on every push. kcov reads
only LLVM-emitted DWARF, so every binary the coverage gate runs is
built with LLVM (`-Dcoverage=true` forces it; the test binary's
`-Dllvm=false` selects self-hosted for the other suite run) and
coverage is measured on LLVM binaries alone. Backend support is per-target:
the self-hosted backend crashes compiling the suite on
aarch64-macos (0.15.2 and 0.16.0), so run `just test-selfhosted` where it is supported
(x86_64-linux; CI covers it).

## Coverage

The gate enforces **100% line coverage over every binary we ship or
run**: the test suite, each example, and the A/B harness. `kcov` runs
a binary as a black box — traps at each source line, recording which
execute — so `scripts/coverage_gate.py` runs it once per binary and per
mode (`RUNS` in the script), each run into its own
`coverage/NN-<binary>-<args>/` (browse `<binary>/index.html` inside it),
and merges the runs' line-level reports itself (why not kcov's merge:
`lines_by_file` in the script). Every installed binary must appear in
`RUNS`; the script refuses to run otherwise. The A/B harness knows it is
the gate's binary (`-Dcoverage` reaches it as a `build_options` flag) and
covers one batch at one rep instead of all of them (`BATCHES` in
`bench/ab.zig` says why).

Scope is `INCLUDE_PATTERN` in the script: `src/`, `tests/`, `cases/`,
`examples/`, `bench/`. A file is measured through whichever binary
compiles it — `bench/core.zig` counts via the test binary's copy, not
`csar-ab`'s; they are the same pure functions. `EXCLUDE_PATTERN` keeps
the pinned baseline's sources (unpacked under `bench/zig-pkg/`, compiled
into `csar-ab`) out. Out of scope, and why: `scripts/{states,countries}`
need downloaded survey data; `scripts/consumer_smoke/build.zig` is a
build script, not a runtime binary; the `.zon` fixtures are comptime
data with no line table.

The gate's binaries are built with `-Dcoverage=true`: Debug (line
coverage of an optimized binary is unreliable — it overrides the
ReleaseFast forced on `csar-ab`) and LLVM (see "Two
backends"). Test code isn't exempt — dead test helpers are dead code
too. The gate runs under `just test-slow`, not `just test` — slow-tier
tests (currently cap_test) exercise lines the fast tier doesn't reach.

What "100% line coverage" buys you:

- Every line in every compiled function is reached by some run — tests,
  and for the examples and the harness, an end-to-end execution on every
  CI run. An example with code that doesn't run isn't a good example;
  this makes that old class of rot — examples silently breaking — impossible
  rather than merely caught by `just check`.
- `comptime` branches that aren't realized at runtime don't appear in
  the binary, so they don't show as uncovered — Zig's comptime is
  naturally well-suited to line coverage.

What it **doesn't** buy you:

- **Branch coverage.** A one-line `if (a) x() else y()` counts as one
  line. Both sides being executed isn't measured. Discipline plus code
  review fill the gap; explicit tests for both branches are the norm.
- **"Nothing is dead."** Zig's analysis is lazy: a declaration nothing
  references is never compiled, has no line entries, and is invisible
  to the gate — it does not even enter the denominator. That is how
  `WorkBuffers` outlived its only caller when the
  alternating path was removed. The gate's guarantee is "every
  compiled line runs"; the complementary question — is every
  *written* declaration referenced — is `just lint` (zlinter's
  `no_unused`, a parse, in `just ci` and CI). Its
  known blind spot is #32: a declaration referenced only from inside
  its own body. For the library's *pub* surface, `test_root.zig` also
  forces every declaration through analysis (`refAllDeclsRecursive`),
  so a dead pub decl lands in the line table and fails the gate.

### Coverage exclusions

The gate stays at exactly 100% — a newly uncovered line always fails
it. Lines that *cannot* execute in a passing run are excluded
explicitly rather than absorbed into a percentage allowance (which
would let real regressions slip through silently). Two generic rules
plus a per-site marker, all wired in `scripts/coverage_gate.py`'s
kcov invocation:

- `--exclude-line='=> unreachable'`: a switch arm ending in
  `unreachable` that executes is a panic, so no passing run ever
  covers one. The pattern is deliberately this narrow: `orelse
  unreachable` lines DO execute normally and stay counted (and
  covered). Before adding such an arm, consider whether a narrower
  type removes it instead — `Method.resolved()` returning
  `Method.Resolved` is the in-tree example.
- `--exclude-line=kcov-excl`: a trailing `// kcov-excl: <reason>`
  marks a single line. Every marker carries its reason in-source —
  grep `kcov-excl` for the ledger. (kcov also supports
  `--exclude-region` start/stop markers for blocks; add that flag with
  its first user if one ever appears.)

Before marking a line, exhaust these — each has an in-tree example. The
first is a question, not a technique, and it comes first:

- **Ask whether the code should exist.** An uncovered line is evidence
  that nothing reaches it; before working out how to reach it, check
  whether anything *should*. Removing the alternating path left the
  quasi-Newton preconditioner in `quasiNewtonAxisDirection` uncovered:
  the trust path's opening rounds never iterate far enough to engage it,
  so it was dead with the shipped constants. It was deleted, along with
  its two gating constants — not tested, not excluded.
- **Construct an input.** The dogleg branches, re-cert convergence,
  TR step rejection, away-step stall, and degenerate-seed fallback
  all looked "unhittable" until tests constructed inputs.
- **Extract a pure function and test it directly.** The TR radius
  policy (`updateRadius`), the KKT H-build (`buildKktH`), and the
  pred ≤ 0 isotropic retry (`doglegStepRobust`) were inline excluded
  branches until extracted; the last is reachable only via a
  degenerate g or FP-noise cancellation, and its direct test feeds
  the degenerate g.
- **Narrow a type so the dead line disappears.**
  `Method.resolved()` returning `Method.Resolved` deleted the
  `.auto => unreachable` dispatch arm; `helpers.resolvedView` returning
  `?ResolvedView` moved "infeasible has no view" to the callers' `.?`,
  which executes and is covered, and deleted the last `=> unreachable`
  arm in `tests/`.
- **Collapse a trivial branch body onto its condition's line.** The
  polish-bail counters are `if (...) polish_failures += 1;`
  one-liners: the line executes (and is covered) every pass. This
  leans on the documented branch-coverage caveat above — reserve it
  for bodies trivially correct by inspection.
- **Cover a failure path with an expectError self-test.** A failure
  diagnostic lives in a helper, and a self-test drives it with fake
  inputs, asserting the expected error (`checkRotationInvariance`'s
  three self-tests in extreme_aspect_test). Such self-tests set
  `helpers.quiet_diagnostics` (with a `defer` restore) so the
  deliberately-driven diagnostic stays out of passing-run output; the
  fake inputs are labeled `case=diagnostic-selftest` so the line is
  self-identifying if it ever does surface.
- **Cover platform-dependent arms with a deterministic sibling.**
  The tolerant switch over converged/DNC lives once, in
  `tests/helpers.zig` (`resolvedView`), and its own test feeds it
  both a guaranteed-converged solve (hex) and a guaranteed-DNC solve
  (`solveClampedWideCapDnc`: wide_cap89 at max_outer = 1 — the
  wide-cap eager certificate fails by construction) so both arms
  execute on every platform.

Nothing anywhere is currently excluded — the ledger is empty (the
last marker, on `examples/cases.zig`'s DNC print, was retired when
the tier-2/3 frontier fixtures made that line genuinely covered).
Historical
evidence for the polish-bail
counters staying untriggerable in context: the full fixture library ×
option grids, ~100 synthetic shape families, direct far-field
`solveTrust` seams (lldb breakpoint counts confirming zero hits), and
the real-world states + countries surveys (227 regions, zero polish
failures).

**The ledger is tracked over time, and cross-checked.** When any
exclusions exist, `just test-slow` prints an `excluded lines:`
section — the count in the header, and per file the line numbers the
exclusion rules removed (no section means an empty ledger) — and
CI posts the gate's whole report as a comment on every PR, green or
red, so growth is visible in review and a reviewer can go look at each
marker. On a red run the report also says why: `failed runs`, `ledger
mismatches`, or `uncovered lines` (same shape). The number is
kcov-native: a second, report-only kcov pass reports without the rules,
and the excluded lines are the ones present raw and absent gated (only
that pass's line classification is trustworthy; its hit data is lossy).
The script then checks the ledger against the source both ways — every
excluded line must sit on a marker or a `=> unreachable` arm, and every
marker must have excluded something — and a disagreement fails the
gate, so a rule kcov silently ignored, or a marker that no longer sits
on an executable line, cannot pass as a smaller number. What it cannot
catch: a marker on a line that *would* have been covered — kcov
excludes before measuring. That one is what the PR comment is for.

### Why kcov and not LLVM source-based coverage?

Zig 0.15.x / 0.16.x doesn't expose the LLVM coverage flags
(`-fprofile-instr-generate`, `-fcoverage-mapping`) that would feed
`llvm-cov` and unlock branch coverage. The CLI only has `-ffuzz` for
instrumentation. Track
[ziglang/zig#352](https://github.com/ziglang/zig/issues/352) — when
LLVM-style coverage lands upstream, swap the kcov pipeline in
`justfile` for an `llvm-profdata merge` + `llvm-cov show` flow and
pick up branch coverage automatically.

## Source layout

The `src/` directory contains library code only — nothing in there
should be test- or diagnostic-specific.

| File | Role |
| --- | --- |
| `src/root.zig` | Module entry point — thin re-export shim over `api.zig` + `solve` from `csar.zig`. |
| `src/api.zig` | Public API surface: `Outcome` (`Converged` / `Infeasible` / `Uncertified` ×2), `Cert`, `SolveError` / `InputError` / `SolveOptions`, `checkFeasibility`. Read this file end-to-end to learn the API. |
| `src/csar.zig` | Algorithm orchestration: mvee/gap inner code, outer-loop driver, `solve`. |
| `src/linalg.zig` | Linear algebra primitives: Vec2/3, Mat2/3/3x2, Chol3, `eig2`. |
| `src/config.zig` | Internal tuning: `SIGMA_0`, `algo` (algorithm tuning), `tol` (numerical tolerances). |
| `src/halfspace.zig` | Geometric preprocessing: `halfspaceCheck`, `convexHull2d`, `projectGnomonic`. |
| `src/newton.zig` | Newton polish on the D-optimal dual + bordered KKT/LU. |

## Test layout

Tests live at top-level `tests/`, not inside `src/`. The test target
roots at `test_root.zig` at the repo root; its module's
filesystem-import scope therefore covers both `src/` (the library
under test, reached via `@import("../src/foo.zig")` from test files)
and `tests/` (the test files themselves). This lets tests reach
internals like `acceptBUpdate` or `convexHull2d` directly, without
re-exporting them through the public API.

| File | Role |
| --- | --- |
| `test_root.zig` | Test-target root at the repo level: pulls in `tests/all.zig` and forces the library's pub declarations through analysis so the gate sees them. |
| `tests/all.zig` | Aggregator: `comptime { _ = @import(...); }` for each test file. |
| `tests/solver_test.zig` | Synthetic property/contract tests of `solve` (e.g. the `max_outer` DNC contract). No fixture dependency. |
| `tests/extreme_aspect_test.zig` | Rotation-invariance, coplanarity, near-degenerate edge-case tests on synthesized inputs. Also hits internal helpers (`acceptBUpdate`, `convexHull2d`) via filesystem imports for branches not reachable through `solve` for all inputs. |
| `tests/cases_test.zig` | Tests driven by the case manifest: cases.byName lookup, per-case outcome dispatch, Q/sigma shape invariants on np100. |
| `tests/batches_test.zig` | The batch contract: per batch, tally every cell (`bench/core.zig`'s `Side`/`Tally`) and require all of them converged. A failure prints the tally and names the batch. Slow tier (`-Dslow`): 8000 Debug solves guarding a gate property. |
| `cases/cases.zig` | Comptime manifest over `cases/zon/*.zon` — defines the `Case` schema and the `all` list — plus `GAP_TOL` and `pin(Options)`, the solver options every pin in the corpus is taken under (the tests and `bench/core.zig` take them from here rather than carrying copies). Exposed as the `cases` build module; imported by the tests, the examples and `bench/`. Top-level because it is a shared corpus, not test code. |
| `cases/zon/*.zon` | Per-case fixture: description + points + tier + claim (+ `ar` for tier <= 1 `converges`). |
| `cases/batches.zig`, `cases/batches/*.{zon,ids}` | Batch fixtures: ~1000 distinct cells of one DGGS family at one resolution (H3 r9/r15; S2 and A5 count-matched to H3 r9/r12/r15) — the timing workload for `csar-ab`; the contract (every cell converges) and its rationale are in `batches.zig`'s header. The `.ids` is the portable artifact; `just surveys::batches-gen` regenerates both from `scripts/batches/gen_batches.py` (dggs_compare's sampler and bindings), `just surveys::batches-verify` checks the committed `.zon` against the `.ids` by vertex chord distance — on demand, not in `just ci`, so the family wheels stay out of CI. The batches are plain comptime `@import`s like the cases, measured at +0.25 s cold `zig build test`, +130 MB compiler peak RSS, +2 MB in the two binaries that reference them (test, `csar-ab`), examples unchanged. That scales with the data: at ~10× more cells compiler memory reaches several GB and a runtime loader (`load(allocator)`, callers own the memory) becomes the right shape. |

To add a new test file: create `tests/<name>_test.zig`, then add
`_ = @import("<name>_test.zig");` to `tests/all.zig`. The test
binary picks it up automatically.

## Packaging

`build.zig.zon`'s `.paths` is the allowlist for what a consumer receives, and
it lists only what compiling the `csar` module needs — `src/` plus the build
and doc files. `tests/`, `cases/`, `examples/` and `bench/` stay out.

`build.zig` still references those paths. That is safe by construction, not by
luck: a dependency's `build()` constructs its step graph, but `b.path(...)` is
a `LazyPath` resolved only when a step that uses it is *made*, and a consumer
asking for `csar.module("csar")` never makes the test, example or survey
steps. Two things break it, and `just consumer-smoke` is how both were
found: configure-time filesystem access in `build.zig` (`std.fs`,
`@embedFile` of a fixture, or a dependency's builder that walks
directories — zlinter's does, which is why the linter is its own package
under `lint/`), and a dependency the build always asks for, lazy or not
(every consumer fetches it). The `cases` module is exported for path
dependents (`bench/`) and is not available to tarball consumers.

`just consumer-smoke` verifies it on every `just ci` run and in CI: it copies
`scripts/consumer_smoke/` (a package depending on `csar`, with
`examples/basic.zig` as its program) into a temp dir, `zig fetch`es the
working tree into it — a path fetch packs the tree through
`.paths`, exactly as a release tarball is filtered — prints what arrived, and
builds and runs it. A path fetch leaves empty directory skeletons behind, which
is why the listing is of files. The tag-time build against the *published*
tarball is "Releasing" step 6.

## Releasing

By hand, with one alarm: `release-check.yml` fails a `v*` tag push that
disagrees with `build.zig.zon`'s `.version` (#17). In order; steps 1 and 5
are PRs, the rest are not commits.

1. PR, the last one before the tag: set `build.zig.zon`'s `.version`, rename
   `changelog.md`'s `## [Unreleased]` to `## [X.Y.Z]`, and open a fresh empty
   `## [Unreleased]` above it. The version is not bumped before this PR
   (one bumped early had to be reverted).
2. Wait for the `ci` run on the merge commit to go green (`gh run watch`); it
   includes `consumer-smoke`, which builds the tree as a consumer receives it
   ("Packaging").
3. On that commit, with `grep version build.zig.zon` agreeing with the tag:
   `git tag vX.Y.Z && git push origin vX.Y.Z`, then wait for the
   `release-check` run on the tag to go green (`gh run watch`).
4. `gh release create vX.Y.Z --title vX.Y.Z --notes-file <the [X.Y.Z]
   section>` — name and body rules in CLAUDE.md.
5. PR: re-pin the A/B baseline —
   `(cd bench && zig fetch --save=csar_base
   https://github.com/ajfriend/csar_zig/archive/refs/tags/vX.Y.Z.tar.gz)`
   rewrites the URL and hash in place (the comment block survives), then
   `zig build --build-file bench/build.zig check`. The harness always measures
   against the last release (the `csar_base` comment in `bench/build.zig.zon`).
   Before anything touching `src/` merges after the tag: run `just ab --aa`,
   then `just ab`, attach both to the PR, and record the ratios on #22 — the
   A/B is then a layout-bias sample (`bench/ab.zig` "Known residual bias").
6. ajfriend/csar_py: the same `zig fetch --save=csar <tarball URL>` in its
   `src/zig/`, plus whatever the release changed in the Python surface. This
   is also the only build against the *published* tarball (#17's check 2 is
   left to it).

## A/B benchmarking

`bench/` is a separate zig package that depends on **both** the working tree
(`.path = ".."`) and a hash-pinned release, and compiles them into one
binary. `just ab` measures them side by side and reports in four parts:
a **headline** carrying the gate's verdict (a deterministic diff over
every fixture and every batch cell — status, iterations and aspect ratio;
the certified gap is deliberately not compared, see `differs` in
`bench/core.zig`), followed immediately by the differing rows (capped per
unit) when there are any; then interleaved **timing**, µs per solve,
in two tier subsections (the timed-set rule and roles: the tier legend
below): tier 0 — `hex` (the many-passes quantization canary) and the eight
batches (the hot path — `cases/batches.zig`) — then tier 1, the regimes
batches lack (`np100`, `ha_12`). A batch row is a mean over its ~1000
cells where a fixture row is one cell: less row noise, the same layout bias
(below); the `solves` column is how many solves each timed interval spanned
— the calibrated passes for a fixture, the cell count for a batch — and a
batch is timed only if both sides converged every cell (a DNC cell would
time `max_outer`; otherwise its row says `skipped`). Then a **corpus**
table, one outcome-tally row per unit with its gap-shift figure (a unit
expands to per-side detail only when it differs, or when `below_model`
fires — that counter is not diff-compared, so it is never assumed
side-symmetric); then **meta** (mode, host, baseline, reps), trailing
because it is context for numbers already read.

One binary rather than two processes is the point: a freshly built binary's
first launch runs 2–5× slow and that survives warm-up and min-over-reps, so a
two-process A/B can invent a small-cell regression. Fast cases are batched
rather than special-cased, so clock granularity stops mattering. **Both are
explained, with everything else, in `bench/core.zig` and `bench/ab.zig`'s
headers** — the policy next to the constants that encode it, the rest next to
the binary. Read those before changing any of it.

One limitation to know before reading any ratio: both versions live in one
binary at a layout fixed at link time, so cache-set and alignment luck can
favour one side systematically — and unlike everything else, that bias survives
more reps, more launches, and a rebuild. `--aa` cannot detect it either. The
argument, the citation and the measured noise floor are in `bench/ab.zig`,
"Known residual bias: code layout"; the practical rule is to treat a difference
near the noise floor as unproven.

- `just ab` — current vs the pinned baseline.
- `just ab --aa` — current vs current. The ratio should read 1.000; whatever it
  isn't by is that run's noise floor. Nothing is stored — re-measure instead.
- `just ab --gap-tol=1e-9` — both sides at that tolerance, deterministic
  pass only (why: `Opts.gap_tol` in `bench/ab.zig`). For a change whose
  effect lives below the suite's tolerance — the negative-gap class
  (tests/neg_gap_test.zig).
- The corpus table's `gap shift` figure is the largest move of the
  certified gap among rows the diff does *not* flag — a number for a PR
  body, not a gate (see "The PR procedure, and what
  gates" below).
- `just ab --inject-2x` / `--inject-tol` — self-tests. The first must report
  ~2.0, the second must produce deterministic diffs (and `skipped` batch rows,
  since the current side then fails to converge most cells). Without them, a
  tool that always printed "no change" would pass every other check.

Every loop has one lever, each a constant edited in place — no flags:

| loop | cost | lever |
| --- | --- | --- |
| `just test` | ~2.5 s | the batch contract test is slow-tier (`-Dslow`), like the stress tests: a gate property, not an inner-loop one |
| `just test-slow` | the coverage build's `csar-ab` runs | `BATCHES` / `BATCH_REPS` in `bench/ab.zig` (why: their doc comment) |
| `just ab` | ~1 s | `N_REPS`, `INTERVAL_TARGET_US` in `bench/core.zig`; `BATCH_REPS` and the unit lists in `bench/ab.zig` |

A quick local `just ab`, if ever wanted, is the same `build_options`
mechanism the coverage build uses.

The baseline pin lives in `bench/build.zig.zon`; resolving it fetches once per
machine and is then cached (why that's fine, rather than lazy: `bench/build.zig`).
The pin advances in its own PR after each tag ("Releasing"); a
mid-cycle re-pin records its reason in the PR that moves it.
It is a separate package so the library's manifest never carries a benchmark
dependency — consumers can't inherit it, and nothing under `bench/` ships
(see "Packaging"). Reports go to stdout — CI posts them to the PR
(step 1 below); nothing is written to disk.

### The PR procedure, and what gates

The aim is legible joint review — human and agent reading the same
report in the same PR. The report showing a change is produced and
posted mechanically; nothing mechanical *acts* on it — a non-empty
diff fails no check — and whether it should is open. The procedure
applies to any PR that touches the report's inputs — the solve path
(`src/`), the harness and baseline pin (`bench/`), the corpus
(`cases/`), the build files — or its delivery mechanism; only
docs-class PRs skip:

1. **CI posts both reports as a PR comment** on any PR touching the
   in-scope paths (`.github/workflows/ab.yml` — its filter is the
   executable form of the scope above). Run `just ab --aa` +
   `just ab` locally when iterating, or dispatch a re-run:
   `gh workflow run ab --ref <branch>`. CI *timing* is coarse —
   between-session runner variance is ~10x the within-run A/A floor
   (#22) — so a CI-only ratio shift needs a second dispatch or a
   local run before it is named in the PR body.
2. **The deterministic diff is the gate.** A non-empty diff blocks
   the PR until every differing row is explained and accepted in the
   PR body. Exceptions — named in the PR body, no justification
   needed: `[t2]`/`[t3]` rows (a status flip is a promotion candidate;
   promotion = a reviewed tier edit in the data — tier legend below)
   and floor-marginal status flips (the FP-noise class of CLAUDE.md's
   monitoring notes — including when two machines disagree on such a
   row). `[t1]` rows are hard claims: they get no exception.
3. **Wall time never gates, but above-floor shifts get named in the
   PR body.** Read ratios against the same session's `--aa` floor —
   that is also how local and CI reports compare, never by µs — and a
   small stable shift with an empty diff is not yet a finding
   ("Reading a small stable shift" below).

### The tier legend

Every fixture carries `tier: 0-3` and a `claim` (schema:
`cases/cases.zig`; enforcement: `tests/cases_test.zig`'s tier x claim
loop). The tier names the settings the claim is made under and how
much the row's speed matters — this legend is the single home for
what each tier means:

| tier | commitment | benchmark role |
|---|---|---|
| 0 | correct at default settings; **the product and optimization target** (normal-resolution DGGS cells — an H3 cell at any resolution is the type specimen; the batches are tier 0 by their every-cell-converges contract) | timed; above-floor shifts are the headline |
| 1 | correct at default settings; improved gladly, never at tier 0's expense or much code complexity | timed (`converges` claims only) |
| 2 | correct only at adjusted settings, recorded per case with headroom (`settings`, `tests/cases_test.zig`) | deterministic diff only, `[t2]` label |
| 3 | no *reasonable* settings known; `claim = none` | deterministic diff only, `[t3]` label |

The claim says what "correct" is — a certified cone (`converges`), a
certified rejection (`infeasible`), a named `InputError` refusal
(`rejects`). Two lines are deliberate prose judgments: 0 vs 1
(priority — tier 0 membership needs no argument; a case that needs a
case made for it is tier 1) and 1 vs 2 (robustness margin — a case
that clears `GAP_TOL` only by a whisker parks at 2/3; a misjudgment
announces itself as a flaking assertion). The 2 vs 3 line is
anchored, not judged: *reasonable* means settings the `gap_tol` docs
themselves advise (today `gap_tol <= 1e-3`); the line moves if the
documented advice does.

**The timed set is `claim: converges` at tier <= 1** — timing
measures the optimization loop; `infeasible` and `rejects` rows ride
the deterministic diff, where error names and status flips already
surface. **Promotion** is a reviewed tier edit in the data: an
improvement that flips a frontier case shows up as a `[t2]`/`[t3]`
diff row in that PR's report, and the tier moves in review — no
mechanism guarantees noticing (a stale-low tier is safe-direction
drift). **One corpus invariant**, test-checked: tier >= 2 stays
nonempty — those cases also cover the non-converged reporting paths
(`examples/cases.zig`'s DNC print); if the frontier ever fully
converges, replenish it (e.g. thinner slivers), don't delete the
branch. A change that trades tier-0 speed for edge-case robustness
is backwards by default — accepting one needs the case made in the
PR body.

For scale, a clean report reads: a `deterministic diff: none` headline,
gap shift ≤ 1.5e-24, timing ratios 0.987–1.012 against a roughly-1% per-row
`--aa` floor — from the gap-formula change this procedure was
calibrated on (that report, a corpus-growth report, and a CI-timing
investigation are in their PRs). The gate is row-agnostic: report
curation, tracked in the issues, does not change what blocks.

### Reading a small stable shift

A stable ≈1% ratio shift with an empty deterministic diff is a change in
machine code, and the machine code can be read. Before blaming layout
(`bench/ab.zig` "Known residual bias", #22):

1. Several commits in the PR: bisect — check out each commit's `src/`,
   re-run `just ab`; expect the shift to belong to one.
2. Get both versions of `csar.solve` as ReleaseFast machine code. The
   bench binary already holds both sides, so when `main` is the pinned
   release one `zig build --build-file bench/build.zig install` and one
   `objdump -d bench/zig-out/bin/csar-ab` has `cur` and `base` side by
   side. Otherwise `git worktree add` at each commit and `zig build
   --build-file bench/build.zig install` there — `csar-ab` is forced
   ReleaseFast and keeps that commit's `csar.solve` as the `cur` side's
   symbol. Builds are
   deterministic, so this is the code the report measured.
3. Find what moved. On Linux `nm --size-sort`; Mach-O has no symbol
   sizes, so on macOS take address deltas from `nm -n` (symbols carry a
   leading `_`) or diff `objdump -d` per function. What is inlined into
   `csar.solve` is the compiler's call — `nm` tells you, each time.
4. `objdump -d` the mover and read the changed loop. A new store/load to
   the stack inside it (aarch64 `str`/`ldr` to `[sp, …]`; x86-64 `mov` to
   `[rsp+…]`) is a spilled loop-carried value — a few cycles per
   iteration, which on a 6–10 point cell is the ~20 ns a 1% batch row is.

First use, `trust.zig`'s DampState collapse: the collapsed struct kept
`1.0` and a norm live
across the solver calls, which spilled the inlined `computeMoments`
accumulator. Forcing that call out of line recovered about half and was
not kept.

## Examples

Three single-file programs under `examples/`, each wired into
`build.zig` via `addExample`:

| Step | Source | Role |
| --- | --- | --- |
| `ex-basic` | `examples/basic.zig` | Minimum API call — solve + read AR + axis. |
| `ex-status` | `examples/status.zig` | Full `Outcome` switch with per-variant inspection. |
| `ex-cases` | `examples/cases.zig` | Runs a bundled case by name (`-- hex`) or iterates the whole manifest (`-- --all`). |

Examples receive pass-through args after `--`; only `ex-cases`
reads them today.
