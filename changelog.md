# Changelog

Notable changes to csar. Terse by design — each entry points to the PR or
commit that carries the full detail.

## [Unreleased]

## [0.6.0]

- Normalize dual variables so `‖Xλ‖₂ = 3` (#88)
- Refresh the `verify_duality.py` oracle to the normalized dual (#89)
- Add `cert_primal` / `cert_dual` for foreign `(A, b)` candidates (#90)

## [0.5.0]

- The A/B report leads with the gate's verdict and the timing tables;
  per-unit detail collapses to a corpus table when clean (`min gap` is
  gone — `below_model` remains the anomaly flag). Details in [#81](https://github.com/ajfriend/csar_zig/pull/81).

- `ex-bench` is retired — `just ab` is the timing tool — and fixtures no
  longer carry a `tags` field (tier + claim + description say everything
  it did). Details in [#75](https://github.com/ajfriend/csar_zig/pull/75).

- Corpus fixtures now carry a commitment tier (0-3) and a claim
  (converges / infeasible / rejects / none) instead of `Expected`; tests
  derive their obligations from the pair, and the A/B report groups
  timing by tier and labels diff rows `[t1]`/`[t2]`/`[t3]`. Details in
  [#74](https://github.com/ajfriend/csar_zig/pull/74).

- The certified gap is now measured against the normalized dual — a
  never-looser bound; behavior otherwise unchanged (deterministic diff
  empty, timing within noise). Details in
  [#65](https://github.com/ajfriend/csar_zig/pull/65).

## [0.4.0]

- **Breaking:** `Outcome` gains `.precision_floor` (the tolerance is below
  the input's f64 floor — loosen `gap_tol`), `.did_not_converge` now means
  the budget ran out, both carry `Uncertified` (was `DidNotConverge`), and
  `SolveError.NegativeDualityGap` is removed. Details in
  [#53](https://github.com/ajfriend/csar_zig/pull/53).

## [0.3.0]

- **Breaking:** the original alternating solver is removed — `Method.alternating`,
  `AlternatingDiagnostics`, and `examples/compare.zig` are gone; `.auto` and
  `.trust` are unchanged. Details in [#30](https://github.com/ajfriend/csar_zig/pull/30).
- The published package now contains only what compiling `csar` needs; tests,
  fixtures and examples no longer ship. The fixture corpus moved to `cases/`.
  Details in [#28](https://github.com/ajfriend/csar_zig/pull/28).
- New `just ab`: A/B the working tree against the pinned baseline release in
  one binary — a deterministic diff over every fixture plus interleaved timing.
  Details in [#21](https://github.com/ajfriend/csar_zig/pull/21).

## [0.2.0]

- Minimum zig raised to **0.16.0** (breaking for source builders); toolchain
  now pinned via a committed `mise.toml`. No algorithmic changes — this tag is
  the first A/B-harness baseline. Details in
  [#12](https://github.com/ajfriend/csar_zig/pull/12).

## [0.1.0]

- Initial release of `csar`: a standalone, std-only Zig package that solves the
  spherical aspect-ratio problem — given a point set on the unit sphere, it
  finds the tightest ellipsoidal cone enclosing it (a PSD matrix `A` + unit axis
  `b`) and returns the cone's axis ratio. `solve` returns a tagged `Outcome`
  union (`Converged` / `Infeasible` / `DidNotConverge`); `SolveOptions.method`
  selects the path (`.auto` default, resolving to the trust-region solver).
  Continues the solver previously developed as
  [`skar_zig`](https://github.com/ajfriend/skar_zig) (preserved as-is for its
  history and provenance); the experimental DGGS survey/comparison tooling now
  lives in a separate repo.
