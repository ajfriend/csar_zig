# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""
The coverage gate + exclusion ledger behind `just test-slow`.

Runs every binary we ship or run — the test binary, each example, and
the A/B harness — under kcov (which must be the process runner — that
is why this can't be `zig build test`), one kcov invocation per run,
all into one output dir: kcov merges them (per-binary data dirs plus
`kcov-merged/`). The ledger comes from a second, report-only kcov pass
over a copy of the same collected data: per file, raw total_lines minus
gated total_lines = the lines the exclusion rules removed. Only the
line *classification* of the report-only pass is used; its hit data is
lossy and never consulted. Policy, the ledger's meaning, and what the
gate does and does not guarantee: dev.md "Coverage".

Output contract: quiet on success — the test-run summary line, then
the summary block (also written to coverage/summary.txt, which CI
posts on PRs). Full kcov/runner output lands in zig-out/test-slow.log
and is dumped only when a run fails. Exits nonzero unless coverage is
exactly 100%.

Edit the constants below in place — no CLI args by project convention.
Run with:  uv run scripts/coverage_gate.py   (after the two install
builds in the justfile's `test-slow` recipe, which build with
`-Dcoverage=true` so every binary is Debug).
"""

import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

# (binary, args, expect_success). Several runs per binary reach the
# branches a single invocation cannot: ex-cases' usage / one case / all /
# unknown-name paths, and the A/B harness's modes plus its bad-argument
# path. The two `False` runs are expected to exit nonzero — that IS the
# branch being covered.
RUNS = [
    ('zig-out/bin/csar-test', [], True),
    ('zig-out/bin/csar-ex-basic', [], True),
    ('zig-out/bin/csar-ex-status', [], True),
    ('zig-out/bin/csar-ex-cases', [], True),
    ('zig-out/bin/csar-ex-cases', ['hex'], True),
    ('zig-out/bin/csar-ex-cases', ['--all'], True),
    ('zig-out/bin/csar-ex-cases', ['no-such-case'], False),
    ('zig-out/bin/csar-ex-bench', [], True),
    ('bench/zig-out/bin/csar-ab', [], True),
    ('bench/zig-out/bin/csar-ab', ['--aa'], True),
    ('bench/zig-out/bin/csar-ab', ['--inject-2x'], True),
    ('bench/zig-out/bin/csar-ab', ['--inject-tol'], True),
    ('bench/zig-out/bin/csar-ab', ['--no-such-flag'], False),
]
BINARIES = list(dict.fromkeys(b for b, _, _ in RUNS))
LOG = Path('zig-out/test-slow.log')
GATED_DIR = Path('coverage')
SUMMARY = GATED_DIR / 'summary.txt'
SUMMARY_MD = GATED_DIR / 'summary.md'  # fenced form; CI puts it in the step summary + PR comment
INCLUDE_PATTERN = 'src/,tests/,cases/,examples/,bench/'
# The A/B harness compiles the pinned baseline's sources too (unpacked under
# bench/zig-pkg/); those match `src/` and must not be measured.
EXCLUDE_PATTERN = 'zig-pkg/'
# Exclusion rules (see dev.md "Coverage exclusions"): `=> unreachable`
# switch arms can never execute in a passing run; `kcov-excl` markers
# carry a per-site reason in-source. (zig 0.16 DWARF attributes some
# instructions to `///` doc-comment lines, but under the forced LLVM
# backend those instructions execute, so no exclusion is needed; if a
# future toolchain flags an uncovered doc-comment line, add `///`
# here with that justification.)
EXCLUDE_LINE = '=> unreachable,kcov-excl'
# Block form, for a multi-line arm: `// kcov-excl-start: <reason>` … `// kcov-excl-end`.
EXCLUDE_REGION = 'kcov-excl-start:kcov-excl-end'
GATE_PERCENT = 100.0


def kcov(args, out_dir, binary, bin_args, mode):
    with open(LOG, mode) as log:
        log.write(f'\n$ kcov {" ".join(args)} {out_dir} {binary} {" ".join(bin_args)}\n')
        log.flush()
        return subprocess.run(
            ['kcov', f'--include-pattern={INCLUDE_PATTERN}', f'--exclude-pattern={EXCLUDE_PATTERN}', *args, str(out_dir), binary, *bin_args],
            stdout=log,
            stderr=subprocess.STDOUT,
        ).returncode


def merged_json(out_dir):
    return json.loads((out_dir / 'kcov-merged' / 'coverage.json').read_text())


def per_binary_totals(out_dir):
    """{file: total_lines}, unioned over every per-binary report (max per
    file). Read from each binary's own `<name>.<hash>/coverage.json`, not
    from `kcov-merged/`: how a report-only pass regenerates the merged
    report differs between kcov builds (reading it, CI's ubuntu kcov
    43+dfsg-2 produced a 1-line ledger where macOS's kcov 43 produced the
    same 7 lines this derivation gives), and the ledger must not depend
    on it. Also logs the per-binary totals of every file with an exclusion
    rule, for the next time the ledger disagrees between machines."""
    totals = {}
    with open(LOG, 'a') as log:
        log.write(f'\n{out_dir.name}/ contains: {", ".join(sorted(p.name for p in out_dir.iterdir()))}\n')
        for d in sorted(out_dir.iterdir()):
            if not d.is_dir() or d.name == 'kcov-merged' or '.' not in d.name:
                continue
            for f in json.loads((d / 'coverage.json').read_text())['files']:
                n = int(f['total_lines'])
                if n > totals.get(f['file'], 0):
                    totals[f['file']] = n
                log.write(f'{out_dir.name}/{d.name}: {f["file"]} total_lines={n}\n')
    return totals


shutil.rmtree(GATED_DIR, ignore_errors=True)
LOG.unlink(missing_ok=True)

# Gated pass: every run under kcov with the exclusion rules, merged.
# kcov does not reliably propagate the child's exit status (it returns 0
# on macOS regardless), so each run's outcome is checked by running the
# binary directly first; kcov's own return code is ignored.
for binary, bin_args, expect_success in RUNS:
    with open(LOG, 'a') as log:
        log.write(f'\n$ {binary} {" ".join(bin_args)}\n')
        log.flush()
        rc = subprocess.run([binary, *bin_args], stdout=log, stderr=subprocess.STDOUT).returncode
    if (rc == 0) != expect_success:
        print(LOG.read_text(), end='')
        sys.exit(f'{binary} {" ".join(bin_args)}: exit {rc}, expected {"success" if expect_success else "failure"}')
    kcov([f'--exclude-line={EXCLUDE_LINE}', f'--exclude-region={EXCLUDE_REGION}'], GATED_DIR, binary, bin_args, 'a')
test_summary = next(l for l in reversed(LOG.read_text().splitlines()) if l.startswith('All ') and 'tests passed' in l)
print(test_summary)  # e.g. "All N tests passed."

gated = merged_json(GATED_DIR)

# Raw pass: reclassify the same collected data without the rules, in a
# throwaway copy (only the per-binary data dirs; kcov regenerates the
# rest, and the raw hit data is lossy and never consulted anyway).
with tempfile.TemporaryDirectory() as tmp:
    raw_dir = Path(tmp) / 'raw'
    raw_dir.mkdir()
    for d in GATED_DIR.iterdir():
        if d.is_dir() and d.name != 'kcov-merged':
            shutil.copytree(d, raw_dir / d.name)
    for binary in BINARIES:
        kcov(['--report-only'], raw_dir, binary, [], 'a')
    raw_totals = per_binary_totals(raw_dir)

root = str(Path.cwd()) + '/'
gated_totals = per_binary_totals(GATED_DIR)
excluded = sorted(
    (file.removeprefix(root), n - gated_totals.get(file, 0))
    for file, n in raw_totals.items()
    if n > gated_totals.get(file, 0)
)

text = '\n'.join([
    f'csar coverage: {gated["percent_covered"]}%',
    f'coverage exclusions: {sum(d for _, d in excluded)} lines excluded from the gate',
    *(f'  {name}: {d}' for name, d in excluded),
]) + '\n'
SUMMARY.write_text(text)
SUMMARY_MD.write_text(f'```\n{text}```\n')
print(text, end='')

if float(gated['percent_covered']) < GATE_PERCENT:
    # Name the lines, so a failure on another machine is diagnosable from
    # the log alone.
    import xml.etree.ElementTree as ET
    tree = ET.parse(GATED_DIR / 'kcov-merged' / 'cobertura.xml').getroot()
    with open(LOG, 'a') as log:
        for cls in tree.iter('class'):
            missed = [l.get('number') for l in cls.iter('line') if l.get('hits') == '0']
            if missed:
                log.write(f'uncovered {cls.get("filename")}: {",".join(missed)}\n')
    print(f'uncovered lines are listed in {LOG}')
    sys.exit(1)
