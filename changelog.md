# Changelog

Notable changes to csar. Terse by design — each entry points to the PR or
commit that carries the full detail.

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
