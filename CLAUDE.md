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
- `zig build ex-bench` — per-case timing (ReleaseFast, 100 reps).
- `zig build states-aspect` / `countries-aspect` — standalone survey execs over
  `scripts/*/data/*.json` (per-cell aspect ratios + outcome counts).
- Full workflow detail (toolchain setup, commands, coverage machinery): dev.md.

## Performance & regression monitoring (read before "optimizing" the solver)

The hot/common path is **small cells** — 4–10 points (H3 hexagons, S2/A5 finest
cells) — which solve in ~1–2 outer iterations and a few µs. Protect them:

- **Do NOT judge a solver change by `ex-bench`'s `TOTAL` line.** It sums
  wall-times and is dominated by the large synthetic cases (np400, ha_*), so a
  real small-cell regression hides in it. µs-scale wall-time on a 6-point cell is
  mostly noise anyway. Read the **per-case rows** (small vs large separately).
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
  times slower than steady state, and `bench.zig`'s in-process warm-up does not
  cover it — the penalty survives min-over-reps. Comparing a first launch
  against a warm one invents small-cell regressions that aren't there.

When changing the solver, the full check is: `just ci` green (suite + coverage
gate + both backends where supported) + **`just ab`**, which measures the
working tree against the pinned baseline in one binary and reports a
deterministic diff over every fixture plus interleaved timing. Attach its
report to the PR; `just ab --aa` gives the noise floor to read it against. Its
methodology is documented in `bench/core.zig` and `bench/ab.zig`.

## Background / history

- `docs/trust-solver.md` — the trust solver (the `SolveOptions.method`
  default since the trust path landed): writeup, measurements, validation ledger.
- `docs/away-step-fw.md` — staged proposal: away-step FW for the inner MVEE
  solver (stage 1: reduced-oracle only; stage 2 is moot since #30).
- `docs/algo-roadmap.md` — ranked candidates for future speed/convergence/
  stability work (range-space polish, elimination, cert-floor probe), plus
  the measured dead ends not to retry.
