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

# Output is gitignored; the GeoJSON is cached after the first run.
# Fetch + cache the US-states GeoJSON and write scripts/states/data/states.json.
states-gen:
    uv run scripts/states/gen_states.py

# Depends on `just states-gen` having run first.
# Run csar over every US state; writes scripts/states/data/states_aspect.json.
states-aspect:
    zig build states-aspect

# Depends on `just states-aspect` having written states_aspect.json.
# Plot one PNG per state (boundary + enclosing-cone ellipse) into the data dir.
states-plot:
    uv run scripts/states/states_plot.py

# Full states example in one command: fetch -> solve -> plot.
states-all: states-gen states-aspect states-plot

# rank by area; output is gitignored.
# Fetch + cache the Natural Earth countries GeoJSON and write scripts/countries/data/countries.json.
countries-gen:
    uv run scripts/countries/gen_countries.py

# Countries that exceed a hemisphere are reported and skipped (not a
# failure). Depends on `just countries-gen` having run first.
# Run csar over every country; writes scripts/countries/data/countries_aspect.json.
countries-aspect:
    zig build countries-aspect

# Depends on `just countries-aspect` having written countries_aspect.json.
# Plot one PNG per converged country (boundary + enclosing-cone ellipse).
countries-plot:
    uv run scripts/countries/countries_plot.py

# Full countries example in one command: fetch -> solve -> plot.
countries-all: countries-gen countries-aspect countries-plot

# Remove build artifacts, coverage output, and generated example data.
clean:
    rm -rf zig-out .zig-cache coverage coverage_raw scripts/states/data scripts/countries/data
