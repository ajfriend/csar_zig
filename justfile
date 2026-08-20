_:
    just --list

# Skips the long-running randomized stress tests (e.g. cap_test) and
# the coverage gate; use while iterating, and run `just test-slow`
# (or `just ci`) before committing. zig's build runner does the output
# handling natively: pass counts on success, captured output on failure.
# Fast test loop (sub-second inner loop, no coverage gate).
test:
    zig build test --summary all

# The gate logic (kcov invocations, exclusion ledger, threshold) lives
# in scripts/coverage_gate.py; policy: dev.md "Coverage exclusions".
# Full suite + 100% line-coverage gate + exclusion ledger (~10s; the pre-commit / CI check).
test-slow:
    zig build install-test -Dslow=true
    uv run scripts/coverage_gate.py

# Per-target support (it crashes compiling this suite on
# aarch64-macos; CI runs it on x86_64-linux): dev.md "Two backends".
# Full suite under zig's self-hosted backend (-Dllvm=false).
test-selfhosted:
    zig build test -Dslow=true -Dllvm=false

# Compile-check the library (CI's Build step).
check:
    zig build

# The self-hosted backend suite runs where the backend supports the
# target (x86_64-linux); elsewhere it is skipped with a note and CI
# covers it.
# Everything CI checks that can run on this machine — use before pushing a PR.
ci: check test-slow _ci-selfhosted

[linux]
_ci-selfhosted: test-selfhosted

[macos]
_ci-selfhosted:
    @echo "note: skipping the self-hosted backend suite — unsupported on aarch64-macos; CI covers it (dev.md 'Two backends')"

# Build the library (optimized).
build:
    zig build -Doptimize=ReleaseFast

# Run `just test-slow` and print where the HTML coverage report landed.
coverage: test-slow
    @echo "open coverage/csar-test/index.html"

# Run the minimal usage example (examples/basic.zig).
ex-basic:
    zig build ex-basic

# Run the full status-handling example (examples/status.zig).
ex-status:
    zig build ex-status

# Run the per-case timing bench (examples/bench.zig, forced ReleaseFast by build.zig).
bench:
    zig build ex-bench

# Remove build artifacts and coverage output (`just surveys::clean` for survey data).
clean:
    rm -rf zig-out .zig-cache coverage coverage_raw

# Survey pipelines over real-world geometry (states/countries): see `just --list surveys`.
mod surveys
