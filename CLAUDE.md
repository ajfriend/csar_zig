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
  (which itself points to the PR).

## Build & test

- `zig build test` — fast unit suite (sub-second).
- `zig build test -Dslow=true` — full suite incl. randomized stress tests; this
  is the CI gate (`.github/workflows/ci.yml`). Run it before committing.
- `zig build ex-bench` — per-case timing (ReleaseFast, 100 reps).
- `zig build states-aspect` / `countries-aspect` — standalone survey execs over
  `scripts/*/data/*.json` (per-cell aspect ratios + outcome counts).

## Performance & regression monitoring (read before "optimizing" the solver)

The hot/common path is **small cells** — 4–10 points (H3 hexagons, S2/A5 finest
cells) — which solve in ~1–2 outer iterations and a few µs. Protect them:

- **Do NOT judge a solver change by `ex-bench`'s `TOTAL` line.** It sums
  wall-times and is dominated by the large synthetic cases (np400, ha_*), so a
  real small-cell regression hides in it. µs-scale wall-time on a 6-point cell is
  mostly noise anyway. Read the **per-case rows** (small vs large separately).
- The small-cell fixtures in `tests/cases/zon/` (the `h3_*` / `hex` cases,
  driven through `tests/cases/cases_test.zig`) are the deterministic guard —
  a shift in their per-case outcome is a **regression signal**: understand what
  changed and flag it for human confirmation, don't silently bump an expectation.
- Many finest-resolution S2/A5 cells hit an f64 gap floor above the strict 1e-6
  tolerance and honestly DNC there — not a bug. WHICH cells sit above vs below
  the floor is path-dependent at noise level (`.trust` vs `.alternating`).

When changing the solver, the full check is: `zig build test -Dslow=true` green
+ `ex-bench` per-case (small cells not slower).

## Background / history

- `docs/trust-solver.md` — the trust solver (the `SolveOptions.method`
  default since the trust path landed): writeup, measurements, validation ledger.
- `docs/away-step-fw.md` — staged proposal: away-step FW for the inner MVEE
  solver (stage 1: reduced-oracle only; stage 2: alternating-path adoption).
- `docs/algo-roadmap.md` — ranked candidates for future speed/convergence/
  stability work (range-space polish, elimination, cert-floor probe), plus
  the measured dead ends not to retry.
