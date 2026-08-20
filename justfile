_:
    just --list

kcov_include := "src/,tests/"
kcov_exclude := "=> unreachable,kcov-excl"

# Skips the long-running randomized stress tests (e.g. cap_test) and
# the coverage gate; use while iterating, and run `just test-slow`
# (or `just ci`) before committing. zig's build runner does the output
# handling natively: pass counts on success, captured output on failure.
# Fast test loop (sub-second inner loop, no coverage gate).
test:
    zig build test --summary all

# Exclusion policy and the ledger's meaning: dev.md "Coverage
# exclusions". The report-only second pass derives the exclusion
# ledger from the same collected data (its line classification only;
# report-only hit data is lossy and never consulted). The summary
# block lands in coverage/summary.txt for CI to post on PRs; full
# runner output lands in zig-out/test-slow.log, shown on failure.
# Full suite + 100% line-coverage gate + exclusion ledger (~10s; the pre-commit / CI check).
test-slow:
    @zig build install-test -Dslow=true
    @rm -rf coverage coverage_raw
    @kcov --include-pattern={{kcov_include}} --exclude-line='{{kcov_exclude}}' coverage zig-out/bin/csar-test > zig-out/test-slow.log 2>&1 || { cat zig-out/test-slow.log; exit 1; }
    @tail -1 zig-out/test-slow.log
    @cp -r coverage coverage_raw
    @kcov --report-only --include-pattern={{kcov_include}} coverage_raw zig-out/bin/csar-test >> zig-out/test-slow.log 2>&1
    @n=$(ls -1d coverage/csar-test.*/ 2>/dev/null | wc -l | tr -d ' '); \
        if [ "$n" != "1" ]; then echo "expected exactly 1 coverage/csar-test.*/ dir, got $n"; exit 1; fi
    @{ jq -r '"csar coverage: \(.percent_covered)%"' coverage/csar-test.*/coverage.json; \
        jq -rn --arg root "$(pwd)/" --slurpfile g coverage/csar-test.*/coverage.json --slurpfile r coverage_raw/csar-test.*/coverage.json \
        '($g[0].files | INDEX(.file)) as $gt | [$r[0].files[] | {f: (.file|ltrimstr($root)), d: ((.total_lines|tonumber) - (($gt[.file].total_lines // 0) | tonumber))} | select(.d > 0)] | sort_by(.f) as $per | "coverage exclusions: \($per | map(.d) | add // 0) lines excluded from the gate", ($per[] | "  \(.f): \(.d)")'; } > coverage/summary.txt
    @cat coverage/summary.txt
    @jq -e '(.percent_covered | tonumber) >= 100' coverage/csar-test.*/coverage.json > /dev/null

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
