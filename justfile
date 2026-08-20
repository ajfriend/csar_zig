_:
    just --list

# Fast test loop — skips the -Dslow stress tests and the coverage gate.
test:
    zig build test --summary all

# Full suite + 100% line-coverage gate + exclusion ledger (policy: dev.md "Coverage exclusions").
test-slow:
    zig build install-test -Dslow=true
    uv run scripts/coverage_gate.py

# Full suite under zig's self-hosted backend (see dev.md "Two backends").
test-selfhosted:
    zig build test -Dslow=true -Dllvm=false

# Compile-check the library (CI's Build step).
check:
    zig build

# Everything CI checks that can run on this machine — use before pushing a PR.
ci: check test-slow _ci-selfhosted

[linux]
_ci-selfhosted: test-selfhosted

[macos]
_ci-selfhosted:
    @echo "note: skipping the self-hosted backend suite — unsupported on aarch64-macos; CI covers it (dev.md 'Two backends')"

# Per-case timing (always ReleaseFast, via build.zig).
bench:
    zig build ex-bench

# Remove build artifacts and coverage output (survey data: `just surveys::clean`).
clean:
    rm -rf zig-out .zig-cache coverage

# States/countries survey pipelines: `just --list surveys`.
mod surveys
