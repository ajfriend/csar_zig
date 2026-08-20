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

# Compile the library and every executable without running (CI's Build step).
# The bench package builds too — it lives outside this build graph, so nothing
# else would notice it rotting. Resolving its manifest fetches the pinned
# baseline the first time on a machine; see bench/build.zig.
check:
    zig build check
    zig build --build-file bench/build.zig check

# A/B the working tree against the pinned baseline (bench/build.zig.zon).
# `just ab --aa` calibrates; see bench/ab.zig for the injector self-tests.
ab *ARGS:
    zig build --build-file bench/build.zig ab -- {{ARGS}}

# Build a scratch consumer against THIS tree packed through `.paths` — what a
# release tarball would contain — and solve through it (scripts/consumer_smoke).
consumer-smoke:
    #!/usr/bin/env sh
    set -eu
    dir=$(mktemp -d)
    cp scripts/consumer_smoke/* "$dir"
    cd "$dir"
    zig fetch --save=csar "{{justfile_directory()}}"
    # Files, not dirs: a path fetch leaves empty directory skeletons behind.
    echo "shipped:"; (cd zig-pkg/csar-*/ && find . -type f | sort | sed 's|^./|  |')
    zig build run
    rm -rf "$dir"

# Everything CI checks that can run on this machine — use before pushing a PR.
ci: check consumer-smoke test-slow _ci-selfhosted

[linux]
_ci-selfhosted: test-selfhosted

[macos]
_ci-selfhosted:
    @echo "note: skipping the self-hosted backend suite — unsupported on aarch64-macos; CI covers it (dev.md 'Two backends')"

# Per-case timing (always ReleaseFast, via build.zig).
bench:
    zig build ex-bench

# Remove build artifacts and coverage output (survey data: `just surveys::clean`).
# `bench/zig-pkg/` is the baseline unpacked next to the manifest that pins it.
# Removing it costs an unpack, not a fetch — the tarball stays in zig's global
# cache (verified: `just clean && just check` goes nowhere near the network).
clean:
    rm -rf zig-out .zig-cache coverage bench/.zig-cache bench/zig-pkg

# States/countries survey pipelines: `just --list surveys`.
mod surveys
