# Roadmap: remaining algorithmic improvements (speed / convergence / stability)

**Status:** proposal, not started. Written 2026-07-10, from a survey of the
post-0.6.0 state (trust default, drop guard landed, exact envelope Hessian,
eager cert). Supersedes nothing; items here are additive to the record in
docs/trust-solver.md and docs/away-step-fw.md.

## Where the remaining costs actually are

The outer-method problem is essentially solved: the trust path has 0 DNC on
the wide-cap grid, ≤ 5 iterations on geographies, and success-parity with the
alternating path on every DGGS system (probe27 fair metric). What's left
splits into three residuals, and only the first is an MVEE-subproblem
question:

1. **Wall-clock on the mid-size dense band** (np400 ~2.3×, ha_14 ~2.7× vs
   alternating) — pure oracle cost. MVEE work pays here.
2. **The 1e-6 certificate floor on finest-res cells** (~1400–4200 survey DNCs
   at strict tol) — lives in the *certificate arithmetic*, not the MVEE. A
   better inner solver does nothing for it.
3. **The small-cell hot path** — already at parity (0.89–1.02×). Protect
   (CANARY pins, ex-bench per-case), don't optimize.

In the h framing: the outer methods now buy (value, gradient) pairs only when
needed; what's left is making each pair cheaper (items 1–3, 5) and making the
certificate's noise floor lower than the tolerances we certify (item 4).

## Ranked items

### 1. Range-space Newton polish — best single item (speed + latent stability)

**Status: implemented**
(plus a boundary drop rule the investigation surfaced as the real endgame
fix — see the PR for the measurements and the one flagged CANARY shift).

`newtonPolish` (src/newton.zig) solves a dense bordered (k+1)×(k+1) LU per
Newton iteration, O(k³), up to 20 iterations, inside every oracle evaluation.
Its Hessian H_ij = (qᵢᵀW⁻¹qⱼ)² is exactly the C∘C matrix whose rank ≤ 6
structure the exact envelope Hessian already exploits (src/trust.zig, evalH
part 2): Schur square of a rank-3 Gram.

- **Speed:** on dense near-circular supports (ha_*, geographies — exactly the
  residual band, k up to ~60) the same 6-dim range-space substitution turns
  each Newton iteration from O(k³) into O(k·36) + a 7×7 bordered solve. The
  biggest asymptotic win available anywhere in the code.
- **Stability:** for k > 6 the current KKT system is *exactly singular* in
  exact arithmetic — the LU succeeds only because roundoff regularizes it,
  and it can amplify the null-space component of the gradient (active-set
  noise) into the step: the same 1/ε amplification measured and fixed for the
  Hessian correction (~1e5 blowup on a 60-point ring, see
  config.trust.EXACT_HESSIAN). The pseudo-inverse step (flat directions of
  the degenerate optimal face projected out) is the principled direction.
  This is a latent cousin of the drop-step hazard: quiet today, but the shape
  that produces "corrupted state at a converged design."

Touches the shared polish ⇒ full gauntlet (slow suite with CANARY discipline,
ex-bench per-case, a5_res0, geographies, rotations). But it's derived
structure, not a heuristic — the enabling math is written and validated in
trust.zig.

### 2. Harman–Pronzato elimination inside `evalH`

Within one oracle evaluation b is fixed, so the fixed-b MVEE admits the
standard elimination test: points whose gradient gᵢ falls below a bound
derived from the current duality gap provably cannot be in the support and
can be dropped for the rest of the evaluation. Every FW burst currently pays
an O(n) scan over the full working set for 64–320 iterations; on geographies
(hundreds of hull vertices, support ~5–10) and elongated dense inputs,
elimination collapses that scan after the first burst.

- Conservative (provable exclusion, optimum unchanged), literature-standard
  for D-optimal design (Harman & Pronzato 2007).
- Per-evaluation only: the support depends on b, so eliminated points return
  as candidates at the next axis.
- Caveat: helps least exactly where ha_* hurts (near-circular supports where
  most hull points genuinely touch the ellipse). Measure on geographies and
  np400 first; don't judge it on ha_*.

### 3. Harvest the deferred dedup/fusion 20–30%

Already scoped in docs/trust-solver.md ("the dedup half of the fusion work"):
`mveeFw`, `newtonPolish`, and `certifyAt` each rebuild and refactor the design
state S. The eager cert made this irrelevant to the DGGS path, but it applies
verbatim to every full-oracle evaluation — the np400/ha band that is the
remaining loss. Known size, known cost (threading polish internals across the
newton/trust boundary), zero algorithmic risk.

### 4. The certificate floor: extended-precision probe (the convergence lever)

The only convergence lever left is the f64 gap floor, not the solver. The
tell is already in the record (CLAUDE.md, dggs_dnc_test): WHICH finest-res
cells sit above vs below 1e-6 is path-dependent at noise level — so a large
fraction of the floor population sits within a small factor of the tolerance.

`dualityGapConstructed` runs on k ≤ ~10 active points; evaluating its
noise-critical pieces (λᵢ = 3wᵢ/(b·xᵢ), the LᵀZL triple product, `logDet`)
in compensated/double-double arithmetic costs essentially nothing at that k.

The experiment is cheap and cleanly falsifiable: re-certify a batch of
floor-DNC cells with a high-precision gap **at the same iterate**.

- Gaps drop below 1e-6 ⇒ thousands of survey cells convert; the "honest DNC"
  boundary moves; ship the compensated cert.
- Gaps don't drop ⇒ the floor is iterate quantization (w, b themselves at
  f64) and the question closes permanently.

Either outcome is worth having. Note the per-path DNC facts pinned in
tests/dggs_dnc_test.zig will shift if this ships — that's the expected
signature, flag-and-reconcile per CANARY policy.

### 5. SIMD the gradient scan

The `L.solve(qᵢ)` + dot loop in `mveeFw` is the hot kernel of every burst.
Embarrassingly parallel across points; an SoA layout with `@Vector` batching
should give 2–4× on large n. Implementation-level rather than algorithmic,
multiplies with items 2–3, touches no math. Guard: bit-drift on small cells
is acceptable per repo policy (precision drift ≠ regression), but the
small-cell CANARY iteration counts must hold.

## Smaller / conditional

- **Smarter-than-size sparse-seed gate** (the FUTURE note on
  `algo.SEED_SPARSE_MIN_POINTS`): a cheap redundancy proxy (e.g. hull-vertex
  count vs seed-spread ratio) would extend the sparse-seed win to small
  *irregular* polygons the size gate skips. Low risk, modest win.
- **Fully-corrective FW while the support is small** (grow-one-point, exact
  polish over the support each step): attractive on sparse-support inputs,
  but shares away-step FW's measured failure profile — degrades exactly on
  large near-circular supports, where its per-step polish is O(k³) (unless
  item 1 lands first, which changes that math). If tried at all: gate on
  support size, treat as an experiment.

## What not to retry (measured dead ends)

- Away-step FW as the oracle — slower on large near-circular supports
  (ha_05 56 → 261 µs; docs/away-step-fw.md "Stage 1 findings").
- Oracle bursts below 64 — worse robustness AND speed (New York DNC,
  np400 69 → 95 µs).
- Budget/inexact-oracle schemes — three reverts, all oracle-inconsistency
  (ρ → −7.95 on cap82); the (value, gradient) identity needs inner
  optimality.
- BFGS-style model state — deleted for cause (model corruption masquerading
  as convergence).
- Tikhonov on the rank-deficient k×k system — 1/ε null-space amplification.
- Touching `solveAlternating` — it's the bit-stable reference; everything
  above lands in the shared inner machinery or the trust path.

## Suggested order

Start with item 1 (range-space polish): the only item that improves speed on
the residual band *and* removes a latent numerical hazard. Item 4 is the
cheapest experiment with the largest potential convergence payoff and can run
in parallel as a probe. Items 2–3 follow if the np400/ha band still matters
after 1.

## Addendum (2026-07-18): certificate-quality and simplification items

Written during the paper's solution-method section work (skar_paper, branch
`dual-derivation-improvements`), from a duality-side review of the solver.
Items 6–8 attack the same certificate floor as item 4 but from the
construction side rather than the arithmetic side; items 9–10 are pure
simplification. Nothing here touches the inner oracle or the (value,
gradient) consistency contract.

**Reference oracles for this work** (added alongside this addendum;
self-contained, run with `uv run <script>`):

- `scripts/verify_duality.py` — CVXPY checks of every structural identity
  the certificate relies on (strong duality, b-eigenvector at 1/√3,
  Z* = A⁻¹, ‖Xλ‖ = 3, W = A⁻², the recipe, KW conditions, ∇h = −Xλ,
  homogeneity). Any change to the certificate construction must keep
  agreeing with it. The derivations live in skar_paper (branch
  `dual-derivation-improvements`); the identities themselves are restated
  in the script's docstring so this repo is self-sufficient.
- `scripts/gamma_polish_prototype.py` — the item 6 experiment, with
  measured results in its docstring.

**Infrastructure gap (important for anyone implementing 6–8):** the
DGGS-floor measurement harness did NOT migrate from the skar-era repos.
`tests/dggs_dnc_test.zig`, `zig build ex-compare`, the probe programs, and
skar_py's `scripts/dggs/survey.py` (10k-cell h3/s2/a5 sweeps) exist only in
skar_zig / skar_py history. What this repo has: `tests/methods_test.zig`
(wide-cap fixtures + Clarabel references), `tests/cases/`, `just bench`,
and the states/countries pipelines under `scripts/`. Items whose validation
says "floor-marginal S2/A5 populations" need the survey harness ported to
csar_py first (source: skar_py `scripts/dggs/survey.py`; it is a thin loop
over cell boundaries → solve → collect status/gap/AR).

### 6. Certificate polishing — REVISED after prototype measurement

**Original claim (2026-07-18, now largely refuted):** the RECERT phase's
axis micro-motion could be replaced by maximizing the dual over Γ at fixed
λ (a ≤ 18-variable concave problem on the active columns), recovering gap
magnitude lost to certificate-construction noise.

**Measured (scripts/gamma_polish_prototype.py, same day):** under an
inexact-inner-state noise model (Gaussian w-perturbation at
η ∈ {0, 1e-8, 1e-6, 1e-4}, solver-faithful construction: moment → A →
budget rescale → recipe), the recipe γᵢ = λᵢ·A·xᵢ/‖A·xᵢ‖ is already
Γ-optimal within evaluation resolution — the KKT alignment fixed-point
recovers nothing, and CVXPY's own subsolve can't beat the recipe. The
reported gap sits within ~1.2–1.4× of the irreducible p − d* at every η.
Two consequences:

- **No gap-magnitude recovery is available from better Γ.** The floor is
  the iterate (w, b at f64), not the construction. This is evidence for
  the "iterate quantization" branch of item 4's dichotomy — and it
  sharpens item 4's probe with a quantitative prediction: gap ≈ 6×
  (effective w-noise) in this model, so measure the run-to-run /
  path-to-path w variation on floor cells and expect the gap floor at ~6×
  that. If confirmed, item 4's extended-precision arithmetic won't help
  either, and the floor is honest.
- **The surviving scope is PSD-repair, not gap recovery.** The RECERT
  trigger is the M-Cholesky *failure* (Z indefinite at noise amplitude),
  which the prototype's noise model never produced. When Z(recipe) fails
  Cholesky, one μ-shifted alignment step gives a deterministic PSD
  candidate:

      choose μ: smallest power-of-2 multiple of ε·tr(Z) such that
                (Z + μI) admits Cholesky (≤ ~5 attempts)
      D  = (Z + μI)⁻¹ X_active        (Cholesky solves, 3×3)
      γᵢ = λᵢ · Dᵢ / ‖Dᵢ‖            (dual-feasible by construction)
      rebuild Z(Γ), evaluate the gap through the existing M = LᵀZL path

  All primitives exist in src/csar.zig (`Mat3.cholesky`, the M-path in
  `dualityGapConstructed`); ~40 lines behind the existing
  Cholesky-failure branch. **The decisive experiment**: instrument
  `certifyAt` (src/trust.zig) to capture states where the first
  certificate fails M-Cholesky (the A5 res-30 population,
  docs/trust-solver.md "What it took: the re-certification phase"), apply
  the repair step, count how many then certify at `gap_tol`. Succeeds →
  RECERT_MAX, the axis micro-step, and their canary complexity delete
  (item 10 then shrinks to a rename). Fails → keep RECERT, close this
  item, and record the result here.

### 7. Two-component, cancellation-free gap

`dualityGapConstructed` computes the axis term as `w_sum.norm() - 3.0`
(src/csar.zig) — subtracting 3 from a norm that is ≈ 3 near convergence,
discarding the term's value into ~1e-15 cancellation noise. Since
b·Xλ = 3·Σwᵢ structurally, the stable split is

    gap_axis  = 3·(Σ_active wᵢ − 1) + ‖τ‖² / (‖Xλ‖ + b·Xλ)   (τ = tangential part)
    gap_inner = −log det M

Two wins: no cancellation, and the gap decomposes into named components —
"axis off-centering" vs "inner refinement" — so a DNC can report *which*
half stalled. Feeds the certificates-as-provenance direction (paper
Discussion section) and sharpens item 4's probe (only gap_inner moves the
eigenvalues at fixed axis). Afternoon-sized; measure on the floor-marginal
S2/A5 populations (needs the survey harness — see the infrastructure note).

**Implementation notes.** In `dualityGapConstructed` (src/csar.zig, the
`gap = w_sum.norm() - 3.0 - Lm.logDet()` line):

- `s = b·w_sum` — but compute the *deviation* `s − 3` without cancellation:
  since `λᵢ·(b·xᵢ) = 3wᵢ` exactly by construction, `s − 3 = 3·(Σ_active wᵢ
  − 1)`. Two options, measure both: (a) the invariant Σ_workingset w = 1 is
  maintained by FW/polish, so `Σ_active w − 1 = −Σ_dropped w` — sum only
  the (≤ ACTIVE_THRESH) dropped weights, no cancellation at all; (b)
  compensated (Kahan) summation of Σ_active w, then subtract 1. Option (a)
  is exact modulo the fp drift of the simplex invariant; assert the two
  agree to ~1e-14 in a debug check.
- `τ = w_sum − s·b` (tangential part; ‖τ‖² is a sum of squares, no
  cancellation), and
  `gap_axis = (s − 3) + ‖τ‖² / (‖w_sum‖ + s)`,
  `gap_inner = −Lm.logDet()`, `gap = gap_axis + gap_inner`.
  The identity behind the split: ‖w_sum‖² = s² + ‖τ‖², so
  ‖w_sum‖ − s = ‖τ‖²/(‖w_sum‖ + s).
- Surface: add `gap_axis`/`gap_inner` to `GapResult`, thread through
  `buildOutcome` onto `Converged`/`DidNotConverge` (api.zig) next to `gap`.
- Validation: assert `|gap − (gap_axis + gap_inner)| ≤ 1e-12·(1 + |gap|)`
  across the slow suite; all CANARY pins must hold (the split changes
  reported values only at the old formula's ~1e-15 noise scale).

### 8. Gap→AR sensitivity bound → `certified_digits` (spans solver + paper)

Already on the paper's roadmap (Discussion: denominate the tolerance in
answer units); recording here that the algorithmic piece is small. Shipping
`certified_digits` plus a floor-aware adaptive default tolerance dissolves
the "status noisier than the answer" failure mode (h3_gap_floor_report.md in
the predecessor skar_py repo) without moving the floor at all. Highest
user-facing value per line of code on this list. The derivation belongs in
the paper's appendix; the field belongs on every outcome.

**The bound, spelled out** (so implementation is translation, not
derivation). f(A) = −log det A is standard self-concordant. For the optimal
A* and any primal-feasible A with certified gap g = f(A) − d ≥ f(A) − f*:

1. Self-concordance lower bound (Nesterov):
   f(A) ≥ f(A*) + ⟨∇f(A*), Δ⟩ + ω(‖E‖_F), where Δ = A − A*,
   E = A*^{−1/2}·Δ·A*^{−1/2} (the local norm: ‖Δ‖²_{A*} =
   tr(A*⁻¹ΔA*⁻¹Δ) = ‖E‖²_F), and ω(t) = t − ln(1+t).
2. First-order optimality of A* over the (jointly convex) feasible set,
   with f constant in b: ⟨∇f(A*), Δ⟩ ≥ 0. Hence ω(‖E‖_F) ≤ g.
3. Inverting ω with a safe elementary bound (ω(t) ≥ t²/6 on [0, 1]):
   t := ‖E‖_F ≤ √(6g), valid whenever √(6g) ≤ 1.
4. Ostrowski / multiplicative Weyl: A = A*^{1/2}(I + E)A*^{1/2} gives
   σᵢ(A) ∈ σᵢ(A*)·[1 − t, 1 + t], so the aspect ratio satisfies
   |AR(A) − AR(A*)| / AR(A*) ≤ 2t/(1 − t).

So: `rel_ar_err_bound(g) = 2√(6g)/(1 − √(6g))` for g < 1/6, and
`certified_digits = −log10(rel_ar_err_bound(g))`, computed from the
achieved gap on every outcome — no new solver state needed.

**Caveat to state honestly (and measure):** the bound is worst-case over
all feasible A at gap g; empirically cross-method AR agreement is ~4
orders tighter (gap 1e-6 ↔ AR deltas ~1e-7–1e-8; docs/trust-solver.md
DGGS tables) because solver iterates are near-stationary, not adversarial.
Ship the conservative bound as the guarantee; optionally report a
calibrated estimate alongside (constant fit by regressing cross-method AR
deltas against achieved gap on the survey data — needs the harness from
the infrastructure note). The conservative-vs-calibrated decision is the
paper's open question (c); whichever ships, name it accurately in the API
docs.

### 9. Retire the standalone alternating path from the public API

Consistent with (not contradicting) "don't touch `solveAlternating`": the
proposal is to stop *exposing* it, not to edit it. Since the eager phase is
literally the alternating path's opening cadence and trust is at
success-parity or better everywhere measured (probe27), the standalone
method is redundant as a product path: two public methods, two diagnostics
structs, DampState, the quasi-Newton preconditioner and its gates
(PRECOND_COND_MIN, AXIS_WARMUP), and a parallel canary suite. Keep it
compiled as a test-only cross-validation oracle (its bit-stable reference
role) and delete the public surface. Largest pure simplification available;
zero algorithmic risk; the cost is a major-version API change.

**Implementation checklist:**

- api.zig: remove the `.alternating` variant from the public `Method` enum
  (or mark the enum non-exhaustive and stop documenting it); `.auto`
  already resolves to `.trust`.
- Keep `solveAlternating` itself `pub` in the source module so the test
  suite and the CANARY(alternating) pins keep exercising it directly —
  its role becomes cross-validation oracle, stated in its doc comment.
- `Diagnostics` union: the `alternating` variant stays (tests construct
  it); only its reachability from the public entry point changes.
- Check the Python bindings (csar_py) for method exposure before removal —
  if `method=` is surfaced there, the removal lands in both repos in the
  same release.
- Changelog entry + major version bump; note the escape hatch (the test
  oracle) for anyone who was selecting `.alternating` deliberately.
- Follow-up deletions this unlocks (verify unused first): `DampState`,
  `quasiNewtonAxisDirection`, PRECOND_COND_MIN, AXIS_WARMUP — but only if
  the eager/RECERT cadences don't route through them (they use the plain
  damped axis step; check call sites before deleting).

### 10. Unify the eager/OPEN_ROUNDS and RECERT phases

Both are "cheap alternating cadence wrapped around a certification attempt"
— one before TR work, one after. A single shared subroutine removes one of
the two code paths without behavior change. If item 6 lands, the after-side
disappears entirely and this item shrinks to renaming. Do after 6, not
before.

**Implementation notes.** The two cadences are not identical — parameterize
rather than force-merge (all in src/trust.zig):

- eager/opening (before TR): two FW steps + one polish + certify, **no
  axis step before the certificate** (the incoming axis is the one being
  tested), axis step only between rounds.
- RECERT (after TR): FW step + polish + certify, then an **undamped** axis
  micro-step (‖c‖ is at noise scale there; the damped step is the opening
  cadence's).

Shared shape: `cheapRound(state, fw_steps: u32, axis_step: enum {none,
damped, plain}) ?GapResult`. Byte-parity requirement: the refactor must
reproduce the existing iterate sequences exactly — validate with the
CANARY(trust) typed signatures (open/tr/recert counts) and the full slow
suite; any drift is a bug in the unification, not an acceptable
regression.

## Smaller / conditional (addendum)

- **Closed form for triangles**: for n = 3 the inner design is exactly
  w = (⅓, ⅓, ⅓) (with point basis Y, gᵢ = 1/wᵢ), so h and ∇h are explicit
  and the whole solve is 2D Newton on a smooth closed-form function — no FW,
  no polish. Only worth it if triangle inputs matter; DGGS cells are 4–10
  vertices.
- **Batch warm-starts for surveys**: neighboring cells of one resolution
  class are near-congruent; carrying (b, w) across cells could turn most
  solves into eager-cert passes. Bounded win (most cells already converge in
  0–3 iterations); only pursue if survey throughput becomes the metric.
- **Delete `mveeFwAway`**: kept in-tree after the away-step revert; the
  record in docs/away-step-fw.md suffices.
