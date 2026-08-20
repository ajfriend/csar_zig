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
| `just ci` | Everything CI checks that can run on this machine, in the order the `ci` recipe lists. Run before pushing a PR. |
| `just test` | Fast test loop — skips long-running randomized stress tests, no coverage gate. Sub-second; the inner-loop iteration command. |
| `just test-slow` | Full suite + the 100% line-coverage gate under `kcov` over every binary (tests, examples, the A/B harness), built Debug with `-Dcoverage=true` and `-Dslow=true`. ~20s; the pre-commit / CI check. |
| `just test-selfhosted` | Full suite under zig's self-hosted backend (`-Dllvm=false`). See "Two backends" below. |
| `just check` | Compile the library and every executable, running nothing (CI's Build step). |
| `just lint` | Every declaration is referenced (zlinter `no_unused`, its own package under `lint/`) — the check coverage cannot make; see "Coverage". ~5s warm, ~30s the first time (it builds the linter). |
| `just consumer-smoke` | Build `scripts/consumer_smoke/` against the tree as a consumer receives it, and print the shipped file list. The only check of the published package rather than the working tree; see "Packaging". |
| `just bench` | Run the benchmark suite (release-built `ex-bench`) — single-version timing. |
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
pass under both backends**; CI runs both on every push. The test
binary defaults to LLVM (`-Dllvm=false` selects self-hosted) because
the kcov gate can only read LLVM-emitted DWARF, so coverage is
measured on the LLVM binary alone. Backend support is per-target:
the self-hosted backend crashes compiling the suite on
aarch64-macos (0.15.2 and 0.16.0), so run `just test-selfhosted` where it is supported
(x86_64-linux; CI covers it).

## Coverage

The gate enforces **100% line coverage over every binary we ship or
run**: the test suite, each example, and the A/B harness. `kcov` runs
a binary as a black box — traps at each source line, recording which
execute — so `scripts/coverage_gate.py` runs it once per binary (and
once per *mode* where one invocation cannot reach a binary's branches:
`ex-cases` four ways, `csar-ab` in each of its modes plus a bad
argument). Each run gets its own output dir, `coverage/NN-<binary>-<args>/`
(browse `<binary>/index.html` inside it), and the script merges the
runs' line-level reports itself. Not kcov's own many-runs-one-dir
merge: on ubuntu's kcov 43+dfsg-2 that proved non-deterministic —
binaries and files dropped out of the merged report between identical
runs — while one binary per dir has been reliable on every platform.

Scope is `INCLUDE_PATTERN` in the script: `src/`, `tests/`, `cases/`,
`examples/`, `bench/`. A file is measured through whichever binary
compiles it — `bench/core.zig` counts via the test binary's copy, not
`csar-ab`'s; they are the same pure functions. `EXCLUDE_PATTERN` keeps
the pinned baseline's sources (unpacked under `bench/zig-pkg/`, compiled
into `csar-ab`) out. Out of scope, and why: `scripts/{states,countries}`
need downloaded survey data; `scripts/consumer_smoke/build.zig` is a
build script, not a runtime binary; the `.zon` fixtures are comptime
data with no line table.

Everything is built Debug for the gate (`-Dcoverage=true`, which
overrides the ReleaseFast forced on `ex-bench` and `csar-ab`): line
coverage of an optimized binary is unreliable. The whole run is ~20s
on aarch64-macos. Test code isn't exempt — dead test helpers are dead
code too. The gate runs under `just test-slow`, not `just test` —
slow-tier tests (currently cap_test) exercise lines the fast tier
doesn't reach. kcov does not reliably propagate a child's exit status,
so the script runs each binary directly first to check it exits as
expected (two runs are *meant* to fail: `ex-cases` with an unknown name
and `csar-ab` with an unknown flag — that is the branch being covered).

What "100% line coverage" buys you:

- Every line in every compiled function is reached by some run — tests,
  and for the examples and the harness, an end-to-end execution on every
  CI run. An example with code that doesn't run isn't a good example;
  this makes the #12 class of rot (examples silently breaking) impossible
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
  `WorkBuffers` outlived its only caller in #30. The gate's guarantee
  is "every compiled line runs"; the complementary question — is every
  *written* declaration referenced — is `just lint` (zlinter's
  `no_unused`, a parse, in `just ci` and CI's Build step). Its
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
  marks a single line; `--exclude-region`'s `// kcov-excl-start:
  <reason>` … `// kcov-excl-end` marks a block. Every marker carries
  its reason in-source — grep `kcov-excl` for the ledger. `src/` and
  `tests/` have none: every previously-marked line was eliminated by
  one of the techniques below. The markers in the tree are in the
  examples and the harness, on arms no bundled input reaches: the DNC
  arm of `ex-cases` and `ex-bench` (no fixture DNCs at the default
  tolerance; `ex-status` shows the variant with a constructed input),
  and `csar-ab`'s "errored on one side" timing row (no timing case
  errors, even under `--inject-tol`).

Before marking a line, exhaust these — each has an in-tree example. The
first is a question, not a technique, and it comes first:

- **Ask whether the code should exist.** An uncovered line is evidence
  that nothing reaches it; before working out how to reach it, check
  whether anything *should*. Removing the alternating path (PR #30) left the
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
  `.auto => unreachable` dispatch arm.
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

What remains excluded in `src/` and `tests/` is exactly the
`=> unreachable` arms (counted in the ledger, never marked). Historical
evidence for the polish-bail
counters staying untriggerable in context: the full fixture library ×
option grids, ~100 synthetic shape families, direct far-field
`solveTrust` seams (lldb breakpoint counts confirming zero hits), and
the real-world states + countries surveys (227 regions, zero polish
failures).

**The ledger is tracked over time, and cross-checked.** `just
test-slow` prints a `coverage exclusions:` summary — the lines the
exclusion rules remove from the gate, per file — and CI posts the same
block as a comment on every PR, so growth is visible in review. The
number is kcov-native: the gate run reports with the exclusion flags, a
second `--report-only` pass on a copy of each run's collected data
reports without them, and the excluded lines are the ones present raw
and absent gated. (Only the line classification of the report-only
pass is trustworthy; its hit data is lossy, so the ledger never uses
it.) The script then checks that ledger against the source: every
excluded line must sit on a `kcov-excl` marker, inside a
`kcov-excl-start/end` region, or on a `=> unreachable` arm, and every
marker must have excluded something. A disagreement fails the gate —
so a kcov build that silently ignores a rule (the Linux failure that
motivated this), or a marker that no longer sits on an executable
line, is caught rather than posted as a smaller number. What it cannot
catch: a marker on a line that *would* have been covered — kcov
excludes it before measuring, and the report-only pass's hit data is
lossy. That one is what the ledger in the PR comment is for.

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
| `src/api.zig` | Public API surface: `Outcome` (`Converged` / `Infeasible` / `DidNotConverge`), `Cert`, `SolveError` / `InputError` / `SolveOptions`, `checkFeasibility`. Read this file end-to-end to learn the API. |
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
| `test_root.zig` | Test-target root at the repo level. One `test {}` block that pulls in `tests/all.zig`. |
| `tests/all.zig` | Aggregator: `comptime { _ = @import(...); }` for each test file. |
| `tests/solver_test.zig` | Synthetic property/contract tests of `solve` (e.g. the `max_outer` DNC contract). No fixture dependency. |
| `tests/extreme_aspect_test.zig` | Rotation-invariance, coplanarity, near-degenerate edge-case tests on synthesized inputs. Also hits internal helpers (`acceptBUpdate`, `convexHull2d`) via filesystem imports for branches not reachable through `solve` for all inputs. |
| `tests/cases_test.zig` | Tests driven by the case manifest: cases.byName lookup, per-case outcome dispatch, Q/sigma shape invariants on np100. |
| `cases/cases.zig` | Comptime manifest over `cases/zon/*.zon` — defines the `Case` schema and the `all` list. Exposed as the `cases` build module; imported by the tests, the examples and `bench/`. Top-level because it is a shared corpus, not test code. |
| `cases/zon/*.zon` | Per-case fixture: description + tags + points + expected outcome. |

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
under `lint/` rather than a step here), and calling `b.lazyDependency`
unconditionally (a lazy dependency the build always asks for is fetched
by every consumer anyway). The `cases` module is exported for path
dependents (`bench/`) and is not available to tarball consumers.

`just consumer-smoke` verifies it on every `just ci` run and in CI: it copies
`scripts/consumer_smoke/` (a package depending on `csar`, with
`examples/basic.zig` as its program) into a temp dir, `zig fetch`es the
working tree into it — a path fetch packs the tree through
`.paths`, exactly as a release tarball is filtered — prints what arrived, and
builds and runs it. A path fetch leaves empty directory skeletons behind, which
is why the listing is of files. #17 covers the tag-time version against the
published tarball.

## Releasing

By hand until #17 automates the tag-time checks. In order; steps 1 and 5
are PRs, the rest are not commits.

1. PR, the last one before the tag: set `build.zig.zon`'s `.version`, rename
   `changelog.md`'s `## [Unreleased]` to `## [X.Y.Z]`, and open a fresh empty
   `## [Unreleased]` above it. The version is not bumped before this PR (#12
   had to revert one that was).
2. Wait for the `ci` run on the merge commit to go green (`gh run watch`); it
   includes `consumer-smoke`, which builds the tree as a consumer receives it
   ("Packaging").
3. On that commit, with `grep version build.zig.zon` agreeing with the tag:
   `git tag vX.Y.Z && git push origin vX.Y.Z`.
4. `gh release create vX.Y.Z --title vX.Y.Z --notes-file <the [X.Y.Z]
   section>` — name and body rules in CLAUDE.md.
5. PR: re-pin the A/B baseline —
   `(cd bench && zig fetch --save=csar_base
   https://github.com/ajfriend/csar_zig/archive/refs/tags/vX.Y.Z.tar.gz)`
   rewrites the URL and hash in place (the comment block survives), then
   `zig build --build-file bench/build.zig check`. The harness always measures
   against the last release (the `csar_base` comment in `bench/build.zig.zon`).
6. ajfriend/csar_py: the same `zig fetch --save=csar <tarball URL>` in its
   `src/zig/`, plus whatever the release changed in the Python surface. Until
   #17, this is also the only build against the *published* tarball.

## A/B benchmarking

`bench/` is a separate zig package that depends on **both** the working tree
(`.path = ".."`) and a hash-pinned release, and compiles them into one
binary. `just ab` measures them side by side: a deterministic diff over every
fixture (status, iterations and aspect ratio; the certified gap is printed but
deliberately not compared — see `differs` in `bench/core.zig`), a per-side
outcome tally, then interleaved timing over a handful of cases.

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
- `just ab --inject-2x` / `--inject-tol` — self-tests. The first must report
  ~2.0, the second must produce deterministic diffs. Without them, a tool that
  always printed "no change" would pass every other check.

The baseline pin lives in `bench/build.zig.zon`; resolving it fetches once per
machine and is then cached (why that's fine, rather than lazy: `bench/build.zig`).
It is a separate package so the library's manifest never carries a benchmark
dependency — consumers can't inherit it, and nothing under `bench/` ships
(see "Packaging"). Reports are for pasting into a PR;
nothing is written to disk.

## Examples

Four single-file programs under `examples/`, each wired into
`build.zig` via `addExample`:

| Step | Source | Role |
| --- | --- | --- |
| `ex-basic` | `examples/basic.zig` | Minimum API call — solve + read AR + axis. |
| `ex-status` | `examples/status.zig` | Full `Outcome` switch with per-variant inspection. |
| `ex-cases` | `examples/cases.zig` | Runs a bundled case by name (`-- hex`) or iterates the whole manifest (`-- --all`). |
| `ex-bench` | `examples/bench.zig` | Per-case timing across a hand-picked subset. Forced to `.ReleaseFast` in `build.zig` regardless of the top-level optimize flag — Debug timings are noise. The `csar`/`cases` modules still inherit the project-wide optimize flag, which looks like it would bench a Debug solver but doesn't: the root module's mode governs codegen for the whole compilation (checked — byte-identical binary either way). |

`addExample` accepts an optional optimize override (`null` inherits
the project-wide flag); only `ex-bench` uses it today. Examples
also receive pass-through args after `--`; only `ex-cases` reads
them today.
