# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""
The coverage gate + exclusion ledger behind `just test-slow`.

Runs every binary we ship or run — the test binary, each example, and
the A/B harness — under kcov (which must be the process runner — that
is why this can't be `zig build test`), one kcov output dir per run,
merged here from each run's line-level report. The ledger comes from a
second, report-only kcov pass over a copy of each run's collected data:
the lines present raw but absent gated are the lines the exclusion rules
removed. Only the line *classification* of the report-only pass is used;
its hit data is lossy and never consulted. The ledger is then
cross-checked against the source markers, so a rule kcov silently did
not apply — or a stale marker — fails the gate. Policy, the ledger's
meaning, and what the gate does and does not guarantee: dev.md
"Coverage".

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
import re
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
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
LOG = Path('zig-out/test-slow.log')
OUT = Path('coverage')              # one kcov output dir per run, under here
SUMMARY = OUT / 'summary.txt'
SUMMARY_MD = OUT / 'summary.md'     # fenced form; CI puts it in the step summary + PR comment
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
ROOT = str(Path.cwd()) + '/'


def log(text):
    with open(LOG, 'a') as f:
        f.write(text)


def run_logged(argv):
    with open(LOG, 'a') as f:
        f.write(f'\n$ {" ".join(argv)}\n')
        f.flush()
        return subprocess.run(argv, stdout=f, stderr=subprocess.STDOUT).returncode


def kcov(flags, out_dir, binary, bin_args):
    # kcov's own return code is ignored: it does not reliably propagate the
    # child's exit status (it returns 0 on macOS regardless).
    run_logged(['kcov', f'--include-pattern={INCLUDE_PATTERN}', f'--exclude-pattern={EXCLUDE_PATTERN}',
                *flags, str(out_dir), binary, *bin_args])


def lines_by_file(out_dir):
    """{file: {line: hits}} from the single-binary report in `out_dir`.

    Read per run from each run's own cobertura.xml, and merged here, rather
    than from kcov's merge of many runs into one output dir: that merge
    proved non-deterministic on ubuntu's kcov 43+dfsg-2 (binaries and files
    dropping out between identical runs) where one-binary-per-dir has been
    reliable on every platform for years."""
    # `<name>.<hash>/` is the binary's data dir; `<name>/` beside it is kcov's
    # HTML rendering of the same thing.
    xmls = [x for x in out_dir.glob('*/cobertura.xml') if '.' in x.parent.name]
    assert len(xmls) == 1, f'{out_dir}: expected one per-binary report, found {xmls}'
    out = {}
    for cls in ET.parse(xmls[0]).getroot().iter('class'):
        f = out.setdefault(cls.get('filename'), {})
        for l in cls.iter('line'):
            n = int(l.get('number'))
            f[n] = max(f.get(n, 0), int(l.get('hits')))
    return out


def merge(per_run):
    merged = {}
    for lines in per_run:
        for file, fl in lines.items():
            m = merged.setdefault(file, {})
            for n, hits in fl.items():
                m[n] = max(m.get(n, 0), hits)
    return merged


shutil.rmtree(OUT, ignore_errors=True)
LOG.unlink(missing_ok=True)

# Gated pass: each run into its own dir, with the exclusion rules.
run_dirs = []
for i, (binary, bin_args, expect_success) in enumerate(RUNS):
    # The run's outcome, checked directly since kcov will not tell us.
    rc = run_logged([binary, *bin_args])
    if (rc == 0) != expect_success:
        print(LOG.read_text(), end='')
        sys.exit(f'{binary} {" ".join(bin_args)}: exit {rc}, expected {"success" if expect_success else "failure"}')
    d = OUT / f'{i:02d}-{Path(binary).name}{"-" + "-".join(a.strip("-") for a in bin_args) if bin_args else ""}'
    d.mkdir(parents=True)  # kcov creates its output dir, not its parents
    kcov([f'--exclude-line={EXCLUDE_LINE}', f'--exclude-region={EXCLUDE_REGION}'], d, binary, bin_args)
    run_dirs.append((d, binary))
test_summary = next(l for l in reversed(LOG.read_text().splitlines()) if l.startswith('All ') and 'tests passed' in l)
print(test_summary)  # e.g. "All N tests passed."

gated = merge([lines_by_file(d) for d, _ in run_dirs])
for file, fl in sorted(gated.items()):
    log(f'gated {file.removeprefix(ROOT)}: {len(fl)} lines, {sum(1 for h in fl.values() if h == 0)} uncovered\n')

# Raw pass: reclassify each run's collected data without the rules, in a
# throwaway copy (kcov regenerates the report; its hit data in that mode is
# lossy and never consulted — only which lines exist).
with tempfile.TemporaryDirectory() as tmp:
    raws = []
    for d, binary in run_dirs:
        raw_d = Path(tmp) / d.name
        shutil.copytree(d, raw_d)
        kcov(['--report-only'], raw_d, binary, [])
        raws.append(lines_by_file(raw_d))
    raw = merge(raws)

# The ledger: lines present raw but absent gated, per file.
excluded = {file: sorted(set(raw[file]) - set(gated.get(file, {}))) for file in raw}
excluded = {f: ls for f, ls in excluded.items() if ls}

# Cross-check the ledger against the source: every excluded line must be
# explained by a marker (`kcov-excl` on the line, inside a
# kcov-excl-start/end region, or a `=> unreachable` arm), and every marker
# must have excluded something — else kcov did not apply the rule (seen on
# ubuntu's kcov), or the marker no longer sits on an executable line. A
# marker on a line that would have been covered is NOT detectable here:
# kcov excludes it before measuring, and the raw pass's hit data is lossy.
problems = []
marked = {}
for file in sorted(set(raw) | set(gated)):
    src = Path(file).read_text().splitlines()
    explained, in_region = set(), False
    for n, text in enumerate(src, 1):
        if 'kcov-excl-start' in text:
            in_region = True
        if in_region or 'kcov-excl' in text or '=> unreachable' in text:
            explained.add(n)
        if 'kcov-excl-end' in text:
            in_region = False
    marked[file] = explained
    for n in excluded.get(file, []):
        if n not in explained:
            problems.append(f'{file.removeprefix(ROOT)}:{n} excluded by kcov but carries no marker')
    if explained and not excluded.get(file) and any(n in raw.get(file, {}) for n in explained):
        problems.append(f'{file.removeprefix(ROOT)}: has exclusion markers but kcov excluded nothing')

covered = sum(1 for fl in gated.values() for h in fl.values() if h > 0)
total = sum(len(fl) for fl in gated.values())
percent = 100.0 * covered / total if total else 0.0

text = '\n'.join([
    f'csar coverage: {percent:.2f}%',
    f'coverage exclusions: {sum(len(ls) for ls in excluded.values())} lines excluded from the gate',
    *(f'  {f.removeprefix(ROOT)}: {len(ls)}' for f, ls in sorted(excluded.items())),
]) + '\n'
SUMMARY.write_text(text)
SUMMARY_MD.write_text(f'```\n{text}```\n')
print(text, end='')

if problems:
    print('ledger does not match the source markers:')
    for pr in problems:
        print('  ' + pr)
    sys.exit(1)
if percent < GATE_PERCENT:
    for file, fl in sorted(gated.items()):
        missed = [str(n) for n, h in sorted(fl.items()) if h == 0]
        if missed:
            print(f'  uncovered {file.removeprefix(ROOT)}: {",".join(missed)}')
    sys.exit(1)
