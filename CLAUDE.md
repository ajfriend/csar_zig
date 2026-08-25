# csar — agent notes

Minimum-volume enclosing ellipsoidal-cone solver (the spherical aspect-ratio
problem). Core: `src/csar.zig` (`solve`, the outer loop, `mveeFw` inner MVEE),
`src/config.zig` (tuning knobs in `algo`/`tol`), `src/api.zig` (public surface).

## Change workflow

- Land changes via **pull requests**: branch off `main`, open a PR whose
  description carries the *details* — what changed and why, measurements /
  benchmarks, validation, and trade-offs. The PR body (plus any linked design
  doc under `docs/`) is the durable record of the change.
- `changelog.md` entries and GitHub **release notes are very short** — one or
  two sentences on the user-visible effect, ending with a link to the **PR**
  (or the commit, if no PR was opened). Detail lives in the PR, not here.
- Release names are just the version (`vX.Y.Z`); detail goes in the release body
  (which itself points to the PR). Procedure: dev.md "Releasing".
- Tree files are self-contained: issue/PR numbers may reference **open**
  work only. When work completes, the ref points at what it became (a
  function, test, doc section) or the prose carries the fact — provenance
  stays in the PR (git blame finds it). The PR that completes a referenced
  issue retires the tree's refs to it.

## Build & test

- **Run `just ci` before pushing a PR** — everything CI checks that can run on
  this machine. `just test` is the fast inner loop; `just test-slow` is the
  gate (enforced 100% line coverage + exclusion ledger) — not bare
  `zig build test`. Per-command detail: dev.md's table.
- The gate covers every binary we ship or run — tests, examples, the A/B
  harness. An uncovered line's first question is whether the code should
  exist; exclusions are governed by dev.md "Coverage exclusions" — read it
  before marking anything excluded; the ledger is posted on every PR.
- `just lint` — every declaration referenced (the dead-code check coverage
  structurally cannot make; dev.md "Coverage").
- The suite must pass under BOTH zig backends (LLVM and self-hosted); CI runs
  both. See dev.md "Two backends".
- `zig build states-aspect` / `countries-aspect` — standalone survey execs over
  `scripts/*/data/*.json` (per-cell aspect ratios + outcome counts).
- Full workflow detail (toolchain setup, commands, coverage machinery): dev.md.

## Performance & regression monitoring (read before "optimizing" the solver)

The hot/common path is **normal-resolution DGGS cells** — 4–10 points, an H3
cell at any resolution the type specimen — which solve in ~1–2 outer
iterations and a few µs. (The *extremely* small, finest-resolution S2/A5
cells are not this tier: they sit near the f64 floor, below, and belong to
tiers 2-3 of dev.md's tier legend.) Protect the hot path:

- The small-cell fixtures in `cases/zon/` (the `h3_*` / `hex` cases,
  driven through `tests/cases_test.zig`) are the deterministic guard —
  a shift in their per-case outcome is a **regression signal**: understand what
  changed and flag it for human confirmation, don't silently bump an expectation.
- Many finest-resolution S2/A5 cells hit an f64 gap floor above the strict 1e-6
  tolerance and honestly DNC there — not a bug. WHICH cells sit above vs below
  the floor is decided at FP-noise level, so it can shift with any change to
  the iteration (it did when the alternating path was retired) — a shift
  there is not by itself a regression.
- **Discard the first launch of a freshly built binary.** It can run several
  times slower than steady state, and `bench/core.zig`'s in-process warm-up does not
  cover it — the penalty survives min-over-reps. Comparing a first launch
  against a warm one invents small-cell regressions that aren't there.
- **A small, stable ratio shift (≈1%, same sign across rows, diff empty) is
  not yet a finding.** Diff the disassembly before reasoning about it —
  dev.md "Reading a small stable shift".
- **Tests assert answers and bounds; exact trajectory stats are the A/B
  harness's job.** Fixture pins carry outcomes and ARs; capability guards
  (e.g. the wide-cap iteration ceilings in `tests/methods_test.zig`) are
  upper bounds that only fire on regression. Never equality-pin an
  iteration count, gap-eval count, or timing in a test — `just ab`
  computes and diffs those against the pinned baseline for review.
  Frontier inputs go into the corpus at tier 2/3 — schema in
  `cases/cases.zig`, tier legend and promotion protocol in dev.md; the
  A/B report is where their shifts surface, as `[t2]`/`[t3]` rows.

When changing the solver, the full check is: `just ci` green (suite + coverage
gate + both backends where supported) + **`just ab`**, which measures the
working tree against the pinned baseline in one binary and reports a
deterministic diff over every fixture and batch cell plus interleaved timing
(the batches — `cases/batches.zig` — are the hot-path rows). CI posts both
the `ab` and `--aa` reports to the PR; a non-empty deterministic diff blocks until
each unexcepted row is explained and accepted in the PR body (exceptions and
procedure: dev.md "The PR procedure, and what gates"). Methodology: `bench/core.zig`
and `bench/ab.zig`.

## Background / history

- `docs/trust-solver.md` — the trust solver (the `SolveOptions.method`
  default since the trust path landed): writeup, measurements, validation ledger.
- `docs/away-step-fw.md` — staged proposal: away-step FW for the inner MVEE
  solver (stage 1: reduced-oracle only; stage 2 is moot since the
  alternating path was removed).
- `docs/algo-roadmap.md` — ranked candidates for future speed/convergence/
  stability work (range-space polish, elimination, cert-floor probe), plus
  the measured dead ends not to retry.
