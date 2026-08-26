# csar

Spherical aspect-ratio solver. Given a point set on the unit sphere,
finds the tightest ellipsoidal cone enclosing it (parameterized by a
PSD matrix `A` and unit axis `b`) and returns the cone's axis ratio.

A standalone Zig package with a single first-party dependency,
[qmath](https://github.com/ajfriend/qmath) (transcendental math
routines; details in dev.md "Packaging") — no third-party
dependencies.

## Quick start

```sh
zig build ex-basic     # runs examples/basic.zig — happy-path only
zig build ex-status    # runs examples/status.zig — every Outcome branch
```

[`examples/basic.zig`](examples/basic.zig) is the minimum call:
define points, call `solve`, switch on the outcome, print the aspect
ratio and axis. [`examples/status.zig`](examples/status.zig) shows
the canonical switch over every variant of the `Outcome` union.

In a Zig package, depend on `csar` and call into the public API:

```zig
const csar = @import("csar");

var outcome = try csar.solve(allocator, points, .{});
defer outcome.deinit();

switch (outcome) {
    .converged => |c| {
        const axis = c.b();
        const aspect = c.aspectRatio();
        // ...
    },
    .infeasible => { /* no hemisphere holds the points */ },
    .did_not_converge => { /* budget ran out: raise max_outer */ },
    .precision_floor => { /* gap_tol below the f64 floor: loosen it */ },
}
```

`solve` returns a tagged union, so accessors like `aspectRatio()`,
`b()`, `A()` only exist on the `Converged` variant — there's no
top-level method to accidentally call on a non-converged result.

Solver selection: `SolveOptions.method` defaults to `.auto`, an alias
for the library's recommended method (currently `.trust`, the
trust-region solver). Pin `.trust` if you need version-stable behavior.
The original alternating solver was removed in 0.3.0.

## Layout

- `src/root.zig` — public API re-exports
- `src/api.zig` — public API surface (types + methods + `checkFeasibility`)
- `src/cert.zig` — foreign-candidate certification (`cert_primal` / `cert_dual` / `primal_violation`)
- `src/csar.zig` — solver core: preprocessing, the inner MVEE machinery, dispatch
- `src/trust.zig` — the trust-region solver path (what `.auto` resolves to)
- `src/linalg_generic.zig`, `src/gap_generic.zig` — linalg primitives and the certificate/gap slice, generic over the scalar (f64 aliases re-exported via `src/linalg.zig` / `src/csar.zig`)
- `src/oracle.zig` — debug instrument: re-evaluate a shipped certificate's gap at a wider scalar
- `src/linalg.zig`, `src/halfspace.zig`, `src/newton.zig`, `src/config.zig` — internal modules
- `tests/*_test.zig` — tests (run via `zig build test`); `cases_test.zig` is the one driven by the corpus
- `cases/cases.zig` — comptime manifest over the .zon files; exposed as the `cases` build module
- `cases/zon/*.zon` — fixture point sets + expected outcomes (data only)
- `test_root.zig` — test-target root at repo level
- `floor_survey.zig` — measurement driver at repo level (`zig build floor-survey`; findings: `docs/floor-survey.md`)
- `examples/basic.zig`, `examples/status.zig`, `examples/cases.zig` — end-user usage demos
- `dev.md` — developer-workflow guide (coverage, layout, conventions)

## Build

```sh
zig build              # builds the library
zig build ex-basic     # runs examples/basic.zig
zig build ex-status    # runs examples/status.zig
zig build ex-cases -- hex      # runs one bundled case
zig build ex-cases -- --all    # runs every bundled case
zig build test         # fast unit suite (no coverage)
```

Equivalent `just` targets are in `justfile`. The full suite +
100% line-coverage gate under kcov is `just test-slow` (the
pre-commit / CI check), and `just ci` runs everything CI checks
that can run on your machine — use it before pushing a PR. See
`dev.md` for the full workflow.

## History

`csar` was previously developed as
[`skar_zig`](https://github.com/ajfriend/skar_zig) and forked into this fresh
repository under a new name, alongside its Python bindings
[`csar`](https://github.com/ajfriend/csar_py) (formerly `skar_py`). The
experimental DGGS survey/comparison tooling that once lived here now has its own
repo. The `skar_zig` repository is preserved as-is for its history and provenance.

## License

MIT — see [LICENSE](LICENSE).
