_:
    just --list

kcov_include := "src/,tests/"
kcov_exclude := "=> unreachable,kcov-excl"

# Fast test loop. Skips long-running randomized stress tests
# (e.g. cap_test). No coverage gate. Sub-second; use this while
# iterating. Run `just test-slow` before committing.
test:
    zig build install-test
    ./zig-out/bin/csar-test

# Full test suite + 100% line coverage gate under kcov. -Dslow=true
# runs the randomized stress tests too; ~10s — the pre-commit / CI
# check. Exclusion policy and the ledger's meaning: dev.md "Coverage
# exclusions". The report-only second pass derives the exclusion
# ledger from the same collected data (its line classification only;
# report-only hit data is lossy and never consulted). The summary
# block lands in coverage/summary.txt for CI to post on PRs.
test-slow:
    zig build install-test -Dslow=true
    rm -rf coverage coverage_raw
    kcov --include-pattern={{kcov_include}} --exclude-line='{{kcov_exclude}}' --exclude-region=kcov-excl-start:kcov-excl-stop coverage zig-out/bin/csar-test
    cp -r coverage coverage_raw
    kcov --report-only --include-pattern={{kcov_include}} coverage_raw zig-out/bin/csar-test
    @n=$(ls -1d coverage/csar-test.*/ 2>/dev/null | wc -l | tr -d ' '); \
        if [ "$n" != "1" ]; then echo "expected exactly 1 coverage/csar-test.*/ dir, got $n"; exit 1; fi
    @{ jq -r '"csar coverage: \(.percent_covered)%"' coverage/csar-test.*/coverage.json; \
        jq -rn --arg root "$(pwd)/" --slurpfile g coverage/csar-test.*/coverage.json --slurpfile r coverage_raw/csar-test.*/coverage.json \
        '($g[0].files | INDEX(.file)) as $gt | [$r[0].files[] | {f: (.file|ltrimstr($root)), d: ((.total_lines|tonumber) - (($gt[.file].total_lines // 0) | tonumber))} | select(.d > 0)] | sort_by(.f) as $per | "coverage exclusions: \($per | map(.d) | add // 0) lines excluded from the gate", ($per[] | "  \(.f): \(.d)")'; } > coverage/summary.txt
    @cat coverage/summary.txt
    @jq -e '(.percent_covered | tonumber) >= 100' coverage/csar-test.*/coverage.json > /dev/null

# Full suite under zig's self-hosted backend. Policy and per-target
# support (it crashes compiling this suite on aarch64-macos; CI runs
# it on x86_64-linux): dev.md "Two backends".
test-selfhosted:
    zig build test -Dslow=true -Dllvm=false

# Compile-check the library (CI's Build step).
check:
    zig build

# Everything CI checks that can run on this machine — use before
# pushing a PR. The self-hosted backend suite runs where the backend
# supports the target (x86_64-linux); elsewhere it is skipped with a
# note and CI covers it.
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

# Fetch + cache the US-states GeoJSON and write scripts/states/data/states.json.
# Output is gitignored; the GeoJSON is cached after the first run.
states-gen:
    uv run scripts/states/gen_states.py

# Run csar over every US state; writes scripts/states/data/states_aspect.json.
# Depends on `just states-gen` having run first.
states-aspect:
    zig build states-aspect

# Plot one PNG per state (boundary + enclosing-cone ellipse) into the data dir.
# Depends on `just states-aspect` having written states_aspect.json.
states-plot:
    uv run scripts/states/states_plot.py

# Full states example in one command: fetch -> solve -> plot.
states-all: states-gen states-aspect states-plot

# Fetch + cache the Natural Earth countries GeoJSON, rank by area, and write
# scripts/countries/data/countries.json (all countries). Output is gitignored.
countries-gen:
    uv run scripts/countries/gen_countries.py

# Run csar over every country; writes scripts/countries/data/countries_aspect.json.
# Countries that exceed a hemisphere are reported and skipped (not a failure).
# Depends on `just countries-gen` having run first.
countries-aspect:
    zig build countries-aspect

# Plot one PNG per converged country (boundary + enclosing-cone ellipse).
# Depends on `just countries-aspect` having written countries_aspect.json.
countries-plot:
    uv run scripts/countries/countries_plot.py

# Full countries example in one command: fetch -> solve -> plot.
countries-all: countries-gen countries-aspect countries-plot

# Remove build artifacts, coverage output, and generated example data.
clean:
    rm -rf zig-out .zig-cache coverage coverage_raw scripts/states/data scripts/countries/data
