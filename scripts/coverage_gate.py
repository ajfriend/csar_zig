# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""
The coverage gate + exclusion ledger behind `just test-slow`.

Runs every binary we ship or run under kcov — one kcov output dir per
run, merged here — then derives the exclusion ledger from a report-only
pass and cross-checks it against the source markers. Policy, what the
gate guarantees, and the ledger's meaning: dev.md "Coverage".

Output: the test-run summary line, then one report — the coverage
line, the exclusion ledger, and on failure the sections that say why
(failed runs, ledger mismatches, uncovered lines). The report is also
written to coverage/summary.txt, which CI posts on the PR green or red.
Every kcov invocation's output lands in zig-out/test-slow.log, in RUNS
order, dumped only when a run fails.

The runs are independent (one output dir each) and dominate the wall
time, so they go through a thread pool; each captures its own output
and the log is assembled afterwards, so all runs finish before any
failure is reported. Coverage reads which lines ran, never how long, so
concurrency cannot change the result — only the timing tables csar-ab's
self-test modes print into the log get noisy.

Exits nonzero unless coverage is exactly 100% and the ledger matches
the markers.

Edit the constants below in place — no CLI args by project convention.
Run with:  uv run scripts/coverage_gate.py   (after `just test-slow`'s
two install builds, which use `-Dcoverage=true`).
"""

import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

# (binary, args, expect_success). Several runs per binary reach the
# branches one invocation cannot; the two `False` runs are expected to
# exit nonzero — that IS the branch being covered.
RUNS = [
    ('zig-out/bin/csar-test', [], True),
    ('zig-out/bin/csar-ex-basic', [], True),
    ('zig-out/bin/csar-ex-status', [], True),
    ('zig-out/bin/csar-ex-cases', [], True),
    ('zig-out/bin/csar-ex-cases', ['hex'], True),
    ('zig-out/bin/csar-ex-cases', ['--all'], True),
    ('zig-out/bin/csar-ex-cases', ['no-such-case'], False),
    ('bench/zig-out/bin/csar-ab', [], True),
    ('bench/zig-out/bin/csar-ab', ['--aa'], True),
    ('bench/zig-out/bin/csar-ab', ['--inject-2x'], True),
    ('bench/zig-out/bin/csar-ab', ['--inject-tol'], True),
    ('bench/zig-out/bin/csar-ab', ['--gap-tol=1e-9'], True),
    ('bench/zig-out/bin/csar-ab', ['--gap-tol=abc'], False),
    ('bench/zig-out/bin/csar-ab', ['--no-such-flag'], False),
    # Reduced floor-survey slice (full sweep: floor_survey.zig header).
    # s2_L23's first 30 cells cover both outcome arms — converged (with
    # certFloor) at 1e-9 and precision_floor (with the stall/negative
    # aggregates) at 1e-10; an unfiltered small-limit run adds no lines.
    ('zig-out/bin/csar-floor-survey', ['--batch=s2_L23', '--limit=30'], True),
    ('zig-out/bin/csar-floor-survey', ['--batch=no-such-batch'], False),
    ('zig-out/bin/csar-floor-survey', ['--limit=abc'], False),
    ('zig-out/bin/csar-floor-survey', ['--no-such-flag'], False),
]
INSTALL_DIRS = ['zig-out/bin', 'bench/zig-out/bin']  # every binary here must be in RUNS
LOG = Path('zig-out/test-slow.log')
OUT = Path('coverage')              # one kcov output dir per run, under here
SUMMARY = OUT / 'summary.txt'       # the report; CI posts it on the PR
INCLUDE_PATTERN = 'src/,tests/,cases/,examples/,bench/,floor_survey.zig'
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
# The gate is exactly 100%: any uncovered line fails it (dev.md "Coverage exclusions").
ROOT = str(Path.cwd()) + '/'


def rel(file):
    return file.removeprefix(ROOT)


def run(argv):
    """(exit code, log text) — the command line, then its combined output."""
    p = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors='replace')
    return p.returncode, f'\n$ {" ".join(argv)}\n{p.stdout}'


def kcov(flags, out_dir, binary, bin_args):
    # kcov's own return code is ignored: it does not reliably propagate the
    # child's exit status (it returns 0 on macOS regardless), so each run's
    # outcome is checked by a direct run instead.
    return run(['kcov', f'--include-pattern={INCLUDE_PATTERN}', f'--exclude-pattern={EXCLUDE_PATTERN}',
                *flags, str(out_dir), str(binary), *bin_args])[1]


def lines_by_file(out_dir):
    """{file: {line: hits}} from the single-binary report in `out_dir`.

    Read per run and merged here rather than via kcov's own many-runs-one-dir
    merge, which dropped binaries and files between identical runs on
    ubuntu's kcov 43+dfsg-2; one binary per dir has been reliable everywhere."""
    # `<name>.<hash>/` is the binary's data dir; `<name>/` beside it is HTML.
    xmls = [x for x in out_dir.glob('*/cobertura.xml') if '.' in x.parent.name]
    assert len(xmls) == 1, f'{out_dir}: expected one per-binary report, found {xmls}'
    root = ET.parse(xmls[0]).getroot()
    # `filename` is relative to the report's <source>, the common prefix of
    # the files in THAT report — so it varies per run; rejoin it.
    base = Path(root.find('sources/source').text)
    out = {}
    for cls in root.iter('class'):
        f = out.setdefault(str(base / cls.get('filename')), {})
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


# A binary that is installed but never run is exactly the silence this
# gate exists to end.
installed = {str(p) for d in INSTALL_DIRS for p in Path(d).iterdir() if p.is_file() and p.suffix == ''}
if missing := installed - {b for b, _, _ in RUNS}:
    sys.exit(f'installed but not in RUNS: {sorted(missing)}')

shutil.rmtree(OUT, ignore_errors=True)
LOG.unlink(missing_ok=True)

# Per run: the direct run (for the exit code), then kcov into the run's
# own dir with the exclusion rules. The first run of each binary also does
# the raw pass: reclassify the collected data WITHOUT the rules, in a
# throwaway copy — which lines exist is a property of the binary, not the
# args. kcov's hit data in that mode is lossy; only the classification is
# used. Returns (log, exit code, gated lines, raw lines or None).
def measure(i, spec, tmp):
    binary, bin_args, _ = spec
    rc, log = run([binary, *bin_args])  # the outcome, since kcov won't say
    d = OUT / f'{i:02d}-{Path(binary).name}{"-" + "-".join(a.strip("-") for a in bin_args) if bin_args else ""}'
    # kcov gets its own copy of the binary: on macOS it runs `dsymutil` beside
    # the binary on EVERY invocation (a fresh .dSYM does not stop it), so
    # concurrent runs of one binary would race on the .dSYM ("kcov: error:
    # Not a debug file", lines silently dropped from the report).
    (d / 'bin').mkdir(parents=True)
    copy = shutil.copy2(binary, d / 'bin')
    log += kcov([f'--exclude-line={EXCLUDE_LINE}'], d, copy, bin_args)
    raw = None
    if i == next(j for j, (b, _, _) in enumerate(RUNS) if b == binary):
        raw_d = Path(tmp) / d.name
        shutil.copytree(d, raw_d)
        log += kcov(['--report-only'], raw_d, raw_d / 'bin' / Path(binary).name, [])
        raw = lines_by_file(raw_d)
    return log, rc, lines_by_file(d), raw


with tempfile.TemporaryDirectory() as tmp, ThreadPoolExecutor() as pool:
    results = list(pool.map(lambda ir: measure(*ir, tmp), enumerate(RUNS)))
log = ''.join(r[0] for r in results)
LOG.write_text(log)
failed = [f'{" ".join([b, *a])}: exit {rc}, expected {"success" if ok else "failure"}'
          for (b, a, ok), (_, rc, _, _) in zip(RUNS, results) if (rc == 0) != ok]
if failed:
    print(log, end='')
else:
    print(next(l for l in reversed(log.splitlines()) if l.startswith('All ') and 'tests passed' in l))

gated = merge([g for _, _, g, _ in results])
raw = merge([r for _, _, _, r in results if r])

# The ledger: lines present raw but absent gated, per file.
excluded = {f: sorted(raw[f].keys() - gated.get(f, {}).keys()) for f in raw if raw[f].keys() - gated.get(f, {}).keys()}

# Cross-check the ledger against the source, both ways: every excluded
# line must carry a marker (`kcov-excl` on the line, or a `=> unreachable`
# arm), and every marker must have excluded something — else kcov did not
# apply the rule, or the marker no longer sits on an executable line. A
# marked file no run measured is an error too. Not detectable: a marker on
# a line that would have been covered (kcov excludes before measuring).
sources = {str(p.resolve()): p.read_text() for pat in INCLUDE_PATTERN.split(',')
           for p in ([Path(pat)] if Path(pat).is_file() else Path(pat).rglob('*.zig'))
           if EXCLUDE_PATTERN not in str(p)}
marked = {f for f, t in sources.items() if 'kcov-excl' in t or '=> unreachable' in t}
problems = []
for file in sorted(set(raw) | set(gated) | marked):
    if file not in gated and file not in raw:
        problems.append(f'{rel(file)}: carries exclusion markers but was not measured by any run')
        continue
    exc, in_gate, explained = set(excluded.get(file, [])), gated.get(file, {}).keys(), set()
    for n, text in enumerate(sources.get(file, Path(file).read_text()).splitlines(), 1):
        if 'kcov-excl' in text:
            explained.add(n)
            if n not in exc:
                problems.append(f'{rel(file)}:{n}: kcov-excl marker excluded nothing' + (' (the line is still in the gate)' if n in in_gate else ''))
        elif '=> unreachable' in text:
            explained.add(n)
            if n in in_gate:
                problems.append(f'{rel(file)}:{n}: `=> unreachable` arm is still in the gate')
    for n in sorted(exc - explained):
        problems.append(f'{rel(file)}:{n}: excluded by kcov but carries no marker')

covered = sum(1 for fl in gated.values() for h in fl.values() if h > 0)
total = sum(len(fl) for fl in gated.values())
percent = 100.0 * covered / total if total else 0.0

uncovered = {f: ns for f, fl in gated.items() if (ns := [n for n, h in sorted(fl.items()) if h == 0])}


def section(title, rows, count=None):
    """`title: count`, then the indented rows; nothing when there are none."""
    return [f'{title}: {len(rows) if count is None else count}', *(f'  {r}' for r in rows)] if rows else []


def per_file(lines):
    return [f'{rel(f)}: {",".join(map(str, ns))}' for f, ns in sorted(lines.items())]


kcov_version = run(['kcov', '--version'])[1].splitlines()[-1]
report = [
    f'csar coverage: {percent:.2f}%  ({kcov_version})',
    *section('excluded lines', per_file(excluded), sum(map(len, excluded.values()))),
    *section('failed runs', failed),
    *section('ledger mismatches', problems),
    *section('uncovered lines', per_file(uncovered), sum(map(len, uncovered.values()))),
]
text = '\n'.join(report) + '\n'
SUMMARY.write_text(text)
print(text, end='')
sys.exit(1 if failed or problems or uncovered else 0)
