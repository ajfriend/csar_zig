# Changelog

Notable changes to csar. Terse by design — each entry points to the PR or
commit that carries the full detail.

## [Unreleased]

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
