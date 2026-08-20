# Development notes

## Dependencies

- **[zig](https://ziglang.org/)** 0.15.2+ — the language. `brew install zig`
  on macOS; see ziglang.org for other platforms.
- **[just](https://github.com/casey/just)** — task runner.
  `brew install just`.
- **[kcov](https://github.com/SimonKagstrom/kcov)** — line-coverage tool
  used by `just test-slow`. `brew install kcov` on macOS and Linux
  alike (the formula ships a linux bottle; it's not in the Ubuntu apt
  repos). CI installs it the same way.
- **[jq](https://stedolan.github.io/jq/)** — used by `just test-slow` to
  check the coverage threshold. `brew install jq` / `apt-get install jq`.

## Common commands

| Command | What it does |
| --- | --- |
| `just ci` | Everything CI checks that can run on this machine: `check` + `test-slow` (+ `test-selfhosted` where supported). Run before pushing a PR. |
| `just test` | Fast test loop — skips long-running randomized stress tests, no coverage gate. Sub-second; the inner-loop iteration command. |
| `just test-slow` | Full suite + 100% line coverage gate under `kcov`. Builds with `-Dslow=true` so randomized stress tests run. ~10s; the pre-commit / CI check. |
| `just test-selfhosted` | Full suite under zig's self-hosted backend (`-Dllvm=false`). See "Two backends" below. |
| `just check` | Compile-check the library (CI's Build step). |
| `just build` | Build the library (release-optimized). |
| `just coverage` | Same as `just test-slow`, then prints the path to the HTML report. |
| `just bench` | Run the benchmark suite (release-built `ex-bench`). |
| `just clean` | Remove `zig-out/`, `.zig-cache/`, `coverage/`. |

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
the 0.15.2 self-hosted backend crashes compiling the suite on
aarch64-macos, so run `just test-selfhosted` where it's supported
(x86_64-linux; CI covers it).

## Coverage

`kcov` runs the test binary as a black box: it instruments the binary
with traps at each source line and records which lines execute. It
writes two directories under `coverage/`:

- `coverage/csar-test/` — the **merged** HTML report; open
  `coverage/csar-test/index.html` to browse covered lines.
- `coverage/csar-test.<hash>/` — the **per-binary** report containing
  the `coverage.json` summary that `just test` parses with `jq` to
  enforce the threshold.

Both contain the same aggregate percentages today (one binary, one
run). If you're debugging a gate failure, the JSON is in the
hash-suffixed sibling, not the merged dir.

The gate enforces **100% line coverage** across both production code
(`src/*.zig`, `tests/*.zig`) and the case manifest (`tests/cases/cases.zig`).
Test code isn't exempt — dead test helpers are dead code too. The
gate runs under `just test-slow`, not `just test` — slow-tier tests
(currently cap_test) exercise lines that the fast tier doesn't reach.

What "100% line coverage" buys you:

- Every line in every shipped function is reached by some test.
- `comptime` branches that aren't realized at runtime don't appear in
  the binary, so they don't show as uncovered — Zig's comptime is
  naturally well-suited to line coverage.

What 100% line coverage **doesn't** buy you:

- **Branch coverage.** A one-line `if (a) x() else y()` counts as one
  line. Both sides being executed isn't measured. Discipline plus code
  review fill the gap; explicit tests for both branches are the norm.

### Coverage exclusions

The gate stays at exactly 100% — a newly uncovered line always fails
it. Lines that *cannot* execute in a passing run are excluded
explicitly rather than absorbed into a percentage allowance (which
would let real regressions slip through silently). Two generic rules
plus a per-site marker, all wired in the `justfile` kcov invocation:

- `--exclude-line='=> unreachable'`: a switch arm ending in
  `unreachable` that executes is a panic, so no passing run ever
  covers one. The pattern is deliberately this narrow: `orelse
  unreachable` lines DO execute normally and stay counted (and
  covered). Before adding such an arm, consider whether a narrower
  type removes it instead — `Method.resolved()` returning
  `Method.Resolved` is the in-tree example.
- `--exclude-line=kcov-excl`: a trailing `// kcov-excl: <reason>`
  marks a single line; `--exclude-region=kcov-excl-start:kcov-excl-stop`
  marks a block. Every marker must carry its reason in-source — grep
  `kcov-excl` for the ledger. **There are currently zero markers in
  the tree**: every previously-marked line was eliminated by one of
  the techniques below. The mechanism stays wired for the case that
  genuinely survives all of them.

Before marking a line, exhaust these — each has an in-tree example:

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
  inputs, asserting the expected error (`expectArAgreement` in
  methods_test; `checkRotationInvariance`'s three self-tests in
  extreme_aspect_test). Such self-tests set
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

What remains excluded is exactly the `=> unreachable` arms (counted
in the ledger, never marked). Historical evidence for the polish-bail
counters staying untriggerable in context: the full fixture library ×
option grids, ~100 synthetic shape families, direct far-field
`solveTrust` seams (lldb breakpoint counts confirming zero hits), and
the real-world states + countries surveys (227 regions, zero polish
failures).

**The ledger is tracked over time.** `just test-slow` prints a
`coverage exclusions:` summary — the total number of lines the
exclusion rules remove from the gate, with a per-file breakdown — and
CI posts the same block as a comment on every PR, so growth is visible
in review. The number is kcov-native, not a source grep: the gate run
reports with the exclusion flags, a second `--report-only` pass on a
copy of the same collected data reports without them, and the ledger
is the per-file difference in `total_lines`. (Only the line
classification of the report-only pass is trustworthy; its hit data is
lossy — kcov's stored database does not faithfully round-trip covered
lines — so the ledger never uses it.)

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
| `tests/cases/cases.zig` | Comptime manifest over `tests/cases/zon/*.zon` — defines the `Case` schema and the `all` list. Exposed as the `cases` build module; imported by tests / bench / the `ex-cases` example. |
| `tests/cases/cases_test.zig` | Tests driven by the case manifest: cases.byName lookup, per-case outcome dispatch, Q/sigma shape invariants on np100. Lives next to `cases.zig` but is not part of the cases module compilation. |
| `tests/cases/zon/*.zon` | Per-case fixture: description + tags + points + expected outcome. |

To add a new test file: create `tests/<name>_test.zig`, then add
`_ = @import("<name>_test.zig");` to `tests/all.zig`. The test
binary picks it up automatically.

## Examples

Four single-file programs under `examples/`, each wired into
`build.zig` via `addExample`:

| Step | Source | Role |
| --- | --- | --- |
| `ex-basic` | `examples/basic.zig` | Minimum API call — solve + read AR + axis. |
| `ex-status` | `examples/status.zig` | Full `Outcome` switch with per-variant inspection. |
| `ex-cases` | `examples/cases.zig` | Runs a bundled case by name (`-- hex`) or iterates the whole manifest (`-- --all`). |
| `ex-bench` | `examples/bench.zig` | Per-case timing across a hand-picked subset. Forced to `.ReleaseFast` in `build.zig` regardless of the top-level optimize flag — Debug timings are noise. |

`addExample` accepts an optional optimize override (`null` inherits
the project-wide flag); only `ex-bench` uses it today. Examples
also receive pass-through args after `--`; only `ex-cases` reads
them today.
