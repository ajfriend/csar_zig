# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""
The coverage gate + exclusion ledger behind `just test-slow`.

Runs the installed test binary under kcov (which must be the process
runner — that is why this can't be `zig build test`), then derives the
exclusion ledger from a second, report-only kcov pass over a copy of
the same collected data: per file, raw total_lines minus gated
total_lines = the lines the exclusion rules removed. Only the line
*classification* of the report-only pass is used; its hit data is
lossy and never consulted. Policy and the ledger's meaning: dev.md
"Coverage exclusions".

Output contract: quiet on success — the test-run summary line, then
the summary block (also written to coverage/summary.txt, which CI
posts on PRs). Full kcov/runner output lands in zig-out/test-slow.log
and is dumped only when the run fails. Exits nonzero unless coverage
is exactly 100%.

Edit the constants below in place — no CLI args by project convention.
Run with:  uv run scripts/coverage_gate.py   (after `zig build install-test -Dslow=true`)
"""

import json
import shutil
import subprocess
import sys
from pathlib import Path

TEST_BINARY = 'zig-out/bin/csar-test'
LOG = Path('zig-out/test-slow.log')
GATED_DIR = Path('coverage')
RAW_DIR = Path('coverage_raw')
SUMMARY = GATED_DIR / 'summary.txt'
INCLUDE_PATTERN = 'src/,tests/'
# Exclusion rules (see dev.md "Coverage exclusions"): `=> unreachable`
# switch arms can never execute in a passing run; `kcov-excl` markers
# carry a per-site reason in-source.
EXCLUDE_LINE = '=> unreachable,kcov-excl'
GATE_PERCENT = 100.0


def run_kcov(args, out_dir, mode='w'):
    with open(LOG, mode) as log:
        return subprocess.run(
            ['kcov', f'--include-pattern={INCLUDE_PATTERN}', *args, str(out_dir), TEST_BINARY],
            stdout=log,
            stderr=subprocess.STDOUT,
        ).returncode


def coverage_json(out_dir):
    dirs = [p for p in out_dir.glob('csar-test.*') if p.is_dir()]
    if len(dirs) != 1:
        sys.exit(f'expected exactly 1 {out_dir}/csar-test.*/ dir, got {len(dirs)}')
    return json.loads((dirs[0] / 'coverage.json').read_text())


for d in (GATED_DIR, RAW_DIR):
    shutil.rmtree(d, ignore_errors=True)

# Gated pass: runs the suite under kcov with the exclusion rules.
if run_kcov([f'--exclude-line={EXCLUDE_LINE}'], GATED_DIR) != 0:
    print(LOG.read_text(), end='')
    sys.exit(1)
print(LOG.read_text().splitlines()[-1])  # e.g. "All 53 tests passed."

# Raw pass: reclassify the same collected data without the rules.
shutil.copytree(GATED_DIR, RAW_DIR)
run_kcov(['--report-only'], RAW_DIR, mode='a')

gated = coverage_json(GATED_DIR)
raw = coverage_json(RAW_DIR)

root = str(Path.cwd()) + '/'
gated_totals = {f['file']: int(f['total_lines']) for f in gated['files']}
excluded = sorted(
    (f['file'].removeprefix(root), int(f['total_lines']) - gated_totals.get(f['file'], 0))
    for f in raw['files']
    if int(f['total_lines']) > gated_totals.get(f['file'], 0)
)

lines = [f'csar coverage: {gated["percent_covered"]}%']
lines.append(f'coverage exclusions: {sum(d for _, d in excluded)} lines excluded from the gate')
lines.extend(f'  {name}: {d}' for name, d in excluded)
SUMMARY.write_text('\n'.join(lines) + '\n')
print('\n'.join(lines))

if float(gated['percent_covered']) < GATE_PERCENT:
    sys.exit(1)
