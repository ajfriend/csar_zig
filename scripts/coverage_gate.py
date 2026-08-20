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
import tempfile
from pathlib import Path

TEST_BINARY = 'zig-out/bin/csar-test'
LOG = Path('zig-out/test-slow.log')
GATED_DIR = Path('coverage')
SUMMARY = GATED_DIR / 'summary.txt'
SUMMARY_MD = GATED_DIR / 'summary.md'  # fenced form; CI puts it in the step summary + PR comment
INCLUDE_PATTERN = 'src/,tests/'
# Exclusion rules (see dev.md "Coverage exclusions"): `=> unreachable`
# switch arms can never execute in a passing run; `///` doc-comment
# lines are never executable (zig 0.16 DWARF sometimes attributes an
# instruction to one); `kcov-excl` markers carry a per-site reason
# in-source.
EXCLUDE_LINE = '=> unreachable,kcov-excl,///'
GATE_PERCENT = 100.0


def run_kcov(args, out_dir, mode='w'):
    with open(LOG, mode) as log:
        return subprocess.run(
            ['kcov', f'--include-pattern={INCLUDE_PATTERN}', *args, str(out_dir), TEST_BINARY],
            stdout=log,
            stderr=subprocess.STDOUT,
        ).returncode


def data_dir(out_dir):
    dirs = [p for p in out_dir.glob('csar-test.*') if p.is_dir()]
    if len(dirs) != 1:
        sys.exit(f'expected exactly 1 {out_dir}/csar-test.*/ dir, got {len(dirs)}')
    return dirs[0]


def coverage_json(out_dir):
    return json.loads((data_dir(out_dir) / 'coverage.json').read_text())


shutil.rmtree(GATED_DIR, ignore_errors=True)

# Gated pass: runs the suite under kcov with the exclusion rules.
if run_kcov([f'--exclude-line={EXCLUDE_LINE}'], GATED_DIR) != 0:
    print(LOG.read_text(), end='')
    sys.exit(1)
print(LOG.read_text().splitlines()[-1])  # e.g. "All 53 tests passed."

gated = coverage_json(GATED_DIR)

# Raw pass: reclassify the same collected data without the rules, in a
# throwaway copy (only the per-binary data dir; kcov regenerates the
# rest, and the raw hit data is lossy and never consulted anyway).
with tempfile.TemporaryDirectory() as tmp:
    raw_dir = Path(tmp) / 'raw'
    raw_dir.mkdir()
    src = data_dir(GATED_DIR)
    shutil.copytree(src, raw_dir / src.name)
    run_kcov(['--report-only'], raw_dir, mode='a')
    raw = coverage_json(raw_dir)

root = str(Path.cwd()) + '/'
gated_totals = {f['file']: int(f['total_lines']) for f in gated['files']}
excluded = sorted(
    (f['file'].removeprefix(root), int(f['total_lines']) - gated_totals.get(f['file'], 0))
    for f in raw['files']
    if int(f['total_lines']) > gated_totals.get(f['file'], 0)
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
    sys.exit(1)
