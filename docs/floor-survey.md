# The floor survey: f64 gap evaluation measured against f128 over the batches

**Status:** measured 2026-08-25; the answer of record for the
iterate-vs-evaluation question (roadmap item 4, now superseded) and
the calibration record for `csar.gapFloor`.
**Instrument:** `floor_survey.zig` (`zig build floor-survey
-Doptimize=ReleaseFast`) over the gap oracle (`src/oracle.zig`) —
the solver's own gap path re-instantiated at `T = f128` on exactly
promoted f64 iterates, so an f64/f128 pair sees bit-identical inputs
and their difference is pure evaluation rounding.
**Data:** every batch cell (`cases/batches.zig`: 8 DGGS families ×
1000 cells, σ_max spanning 2.4e4 – 1.7e7) re-solved at the corpus pin
options with `gap_tol` = 1e-9 and 1e-10 — 16,000 solves, 32,000
oracle evaluations, ~1 s wall ReleaseFast. Per-cell rows: the sweep
is deterministic — regenerate the CSV with
`zig build floor-survey -Doptimize=ReleaseFast -- --csv=<path>`.

**Verdict: the f64 solver is evaluation-limited, not
iterate-limited.** Every tight-tolerance failure in the corpus is a
`precision_floor` classification (zero `did_not_converge`), and at
f128 evaluation the floor-classified population collapses: all 2191
uncertified cells have true gaps below the 1e-6 default tolerance,
stalled at 0.1–3× the *actual* f64 evaluation noise (σ_max·ε scale).
The iteration descends until f64 arithmetic can no longer measure
descent, and stops there — nothing measured suggests the iterates
themselves fall short. Separately, the floor *model* is confirmed in
form (noise ∝ σ_max·ε across three decades of σ_max) and conservative
in coefficient (measured ≤ 1.3 vs the model's `NEG_GAP_SIGMA` = 64).

## The survey table

`zig build floor-survey -Doptimize=ReleaseFast`, this machine
(aarch64-macos), 2026-08-25. `d/f` = |gap_f64 − gap_f128| / floor —
the model-normalized evaluation error; `unc` = uncertified
(floor-classified) cells; the last two columns count uncertified
cells whose f128 gap is below their own `gap_tol`, resp. the 1e-6
pin.

```
  batch    tol |  conv floor  dnc |   d/f p50   d/f p90   d/f max |   unc f128<=tol  <=1e-6
  h3_r9   1e-9 |  1000     0    0 |   2.88e-3   8.18e-3   1.92e-2 |     0         0       0
  h3_r9  1e-10 |  1000     0    0 |   2.88e-3   8.18e-3   1.92e-2 |     0         0       0
 h3_r15   1e-9 |   928    72    0 |   2.75e-3   8.18e-3   1.90e-2 |    72        15      72
 h3_r15  1e-10 |   423   577    0 |   2.82e-3   7.91e-3   1.79e-2 |   577        30     577
 s2_L15   1e-9 |  1000     0    0 |   2.35e-3   6.26e-3   1.59e-2 |     0         0       0
 s2_L15  1e-10 |  1000     0    0 |   2.35e-3   6.26e-3   1.59e-2 |     0         0       0
 s2_L19   1e-9 |  1000     0    0 |   2.10e-3   6.48e-3   1.53e-2 |     0         0       0
 s2_L19  1e-10 |   987    13    0 |   2.15e-3   6.65e-3   1.48e-2 |    13         3      13
 s2_L23   1e-9 |   934    66    0 |   2.25e-3   6.81e-3   2.02e-2 |    66        10      66
 s2_L23  1e-10 |   429   571    0 |   2.18e-3   6.81e-3   1.71e-2 |   571        25     571
 a5_r14   1e-9 |  1000     0    0 |   1.76e-3   5.57e-3   1.68e-2 |     0         0       0
 a5_r14  1e-10 |  1000     0    0 |   1.76e-3   5.57e-3   1.68e-2 |     0         0       0
 a5_r18   1e-9 |  1000     0    0 |   2.01e-3   5.84e-3   1.46e-2 |     0         0       0
 a5_r18  1e-10 |   990    10    0 |   2.03e-3   5.95e-3   1.46e-2 |    10         1      10
 a5_r23   1e-9 |   827   173    0 |   1.79e-3   5.76e-3   1.88e-2 |   173        40     173
 a5_r23  1e-10 |   291   709    0 |   1.79e-3   5.90e-3   1.40e-2 |   709        38     709

uncertified cells 2191: below their gap_tol at f128 162; below the 1e-6 pin at f128 2191; above gap_tol at f128 2029
```

Population notes: no nulls (no sentinel outcomes anywhere — the
survey fails loudly on one), no infeasibles, and f128 evaluation
succeeded on every cell f64 did (branch identity held corpus-wide).
The h3_r9 rows are bit-identical across the two tolerances —
1000/1000 cells ship the same iterate, i.e. a cell that converges at
1e-9 has already passed 1e-10 (the gap falls through that last decade
within one accept; max shipped |gap| over all 6120 converged-at-1e-10
cells is 9.98e-11).

## 1. Iterate-limited or evaluation-limited (the answer of record)

Three measurements, one story:

- **Zero `did_not_converge` cells.** Every tight-tolerance failure is
  floor-classified: the budget never ran out mid-descent; the trust
  loop reached f64 merit stationarity (descent below `PRED_NOISE_REL`
  resolution) and the re-cert phase couldn't certify below tolerance.
- **The stall sits at the actual noise scale.** Over the 2191
  uncertified cells, |gap_f128| / (σ_max·ε) spans p10 0.08 / p50 0.37
  / p90 1.20 / max 3.25. The iterates park exactly where f64
  evaluation noise (measured coefficient ≤ 1.3·σ_max·ε, below) drowns
  the merit signal — not orders of magnitude above it, which is what
  an iterate limitation would look like.
- **The floor-collapse prediction confirmed** (the 2026-08-21 note on
  #9): at f128 evaluation the floor-classified population collapses —
  2191/2191 below the 1e-6 default; 162 are *already* below their
  tight 1e-9/1e-10 tolerance as shipped. There is no genuine-DNC
  residue to stay behind.

The 2029 cells between their tight tolerance and 1e-6 are not
counter-evidence of an iterate limit: their descent stopped because
f64 arithmetic could not resolve further progress, and their true
gaps (p50 ≈ 0.4·σ_max·ε ≈ 1e-9 at σ_max ~ 1e7) sit right at that
resolution. Certifying them at 1e-9/1e-10 needs a wide *evaluation*
in the loop — whether wide iteration is also needed is unmeasured
here and, on this evidence, doubtful.

A curiosity worth recording: 39 uncertified cells evaluate to a
*negative* gap at f128 (most negative −3.9e-10, all within
0.13·σ_max·ε). Not a bug: the constructed certificate's A_perp is
feasible only to κ(M)·ε (the `gapFloor` model's second term), so
exact-arithmetic weak duality does not bind the *constructed* dual —
f128 is simply exact enough to expose the slack. Magnitudes are
noise-scale, consistent with the model.

## 2. `gapFloor` calibration

The model (`csar.gapFloor`): floor = (64·σ_max + κ(M))·ε. Measured,
with c = |gap_f64 − gap_f128| / (σ_max·ε) over all 16,000 evaluations:

| batch | c p50 | c p90 | c p99 | c max |
|---|---|---|---|---|
| h3_r9 | 0.184 | 0.523 | 0.879 | 1.228 |
| h3_r15 | 0.176 | 0.524 | 0.892 | 1.216 |
| s2_L15 | 0.150 | 0.401 | 0.635 | 1.021 |
| s2_L19 | 0.134 | 0.415 | 0.662 | 0.977 |
| s2_L23 | 0.144 | 0.436 | 0.776 | 1.294 |
| a5_r14 | 0.112 | 0.357 | 0.681 | 1.073 |
| a5_r18 | 0.128 | 0.374 | 0.686 | 0.931 |
| a5_r23 | 0.114 | 0.369 | 0.718 | 1.201 |
| **all** | **0.142** | **0.430** | **0.755** | **1.294** |

- **Form confirmed:** the coefficient distribution is flat across
  eight families and three decades of σ_max — the noise really scales
  as σ_max·ε, which is what lets one constant serve the whole corpus.
- **Coefficient ~50× conservative:** worst measured c = 1.29 vs the
  model's 64. On these geometries the model never under-predicts
  (d/f max 2e-2 corpus-wide) and the κ term never matters
  (floor/(σ_max·ε) = 64.0 to three digits on every cell).
- **Scope (the #62 caveat):** the batches are benign DGGS families.
  #62 measured the same model off by up to ~7400× on thin slivers, in
  both directions; this calibration says nothing about them, and any
  retune of `NEG_GAP_SIGMA` must weigh that population separately —
  and would be its own PR with its own A/B report, per the
  measurement-only scope here.

## 3. What this feeds (recorded on #9)

Phase 1's question — is the full `Solver(f128)` the *next* step? —
gets a *not yet* on the iterate-error branch of the gate: on this
corpus the f64 iteration reaches its own evaluation floor, so the
binding constraint is the certificate's arithmetic, not the
iteration's. The near-term lever is the narrow one: a **wide gap
evaluation on the floor path** — on this corpus it would certify
100% of floor-classified cells at the 1e-6 default outright, and
gives the loop a merit signal down to ~σ_max·ε²-scale for the
tight-tolerance residue. The full sweep's cost hint: 32,000 oracle
evaluations inside a ~1 s run — wide evaluation is
microseconds-scale per cell even at soft-float f128. Whether it
ships as f128 (this slice), compensated f64 (#55), or is removed
algebraically (#58) is that pair's bake-off — refereed against this
survey's per-cell record once #58 lands, per the roadmap's addendum.

Sequencing, not a verdict on f128 (#9's standing direction): the
program is two compounding tracks. First, squeeze the f64 numerics —
solver and certificate — as far as they go; through the generic
slice those improvements carry to every instantiation, and the f128
oracle is the debugging instrument that makes that work measurable
at any precision. Then the full `Solver(T)` extends whatever the
hardened numerics achieve when inputs push past what f64 can reach —
this corpus doesn't produce such inputs, but it was chosen before we
could look past the old floor, and the solvability horizon is meant
to keep moving. Neither track substitutes for the other; the survey
only says which one the *current* corpus is waiting on.

## Reproducing

- `zig build floor-survey -Doptimize=ReleaseFast` — the full sweep
  (summary table above on stderr).
- `-- --csv=<path>` — the per-cell rows (the PR artifact);
  `--batch=<name>` / `--limit=<n>` restrict.
- Coverage slices run in `just test-slow` (registered in
  `scripts/coverage_gate.py` RUNS).
- The analysis cuts here (coefficient distributions, stall scale) are
  plain column arithmetic over the CSV; percentiles are nearest-rank.
