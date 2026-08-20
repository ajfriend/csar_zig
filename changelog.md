# Changelog

Notable changes to csar. Terse by design — each entry points to the PR or
commit that carries the full detail.

## [Unreleased]

- The published package now contains only what compiling `csar` needs (13
  files, 208K — was 744K): tests, fixtures and examples no longer ship. The
  fixture corpus moved to `cases/`. Details in
  [#28](https://github.com/ajfriend/csar_zig/pull/28).
- New `just ab`: A/B the working tree against the pinned baseline release in
  one binary — a deterministic diff over every fixture plus interleaved timing.
  The published tarball now also carries `bench/core.zig`, which `tests/`
  imports. Details in [#21](https://github.com/ajfriend/csar_zig/pull/21).

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
