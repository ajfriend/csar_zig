# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
'''Compose the A/B + A/A report comment from ab-report.txt / aa-report.txt
(in CWD), then: in CI (GITHUB_STEP_SUMMARY set), append it to the job summary
and post it to the PR — a NEW comment per run — CI comments are append-only
by design (scripts/gate_comment.py likewise), so each report stays archived. Run locally after `just ab --aa | tee
aa-report.txt` and `just ab | tee ab-report.txt` to read the same block CI
posts (dev.md "The PR procedure, and what gates", step 1).

Run with: uv run scripts/ab_comment.py
'''

import os
import platform
import subprocess
from pathlib import Path

host = os.environ.get('ImageOS') or platform.system()
ab_text = Path('ab-report.txt').read_text()
aa_text = Path('aa-report.txt').read_text()
comment = (
    f'**A/B report** ({host}; read ratios against the A/A floor'
    ' below — dev.md "The PR procedure, and what gates"):\n'
    '<details><summary>just ab</summary>\n\n```\n'
    + ab_text
    + '```\n</details>\n<details><summary>just ab --aa</summary>\n\n```\n'
    + aa_text
    + '```\n</details>\n'
)

summary = os.environ.get('GITHUB_STEP_SUMMARY')
if not summary:
    print(comment, end='')
    raise SystemExit(0)

with open(summary, 'a') as fh:
    fh.write(comment)

# Checks-UI annotations, keyed on the verdict phrase of each report's first
# line (bench/ab.zig owns the headline format; matching the phrase alone
# survives title/mode rewording, and drift lands loud — a reworded headline
# warns on every clean run). A non-empty A/B diff warns without turning
# anything red (dev.md: whether CI should enforce the diff is open). A
# non-clean A/A is different: the harness diffed a binary against itself,
# the whole report is invalid evidence, and the job fails — after the
# comment posts, so the evidence of the breakage is on the PR.
ab_headline = ab_text.split('\n', 1)[0]
aa_headline = aa_text.split('\n', 1)[0]
if 'deterministic diff: none' not in ab_headline:
    print(f'::warning title=deterministic diff::{ab_headline}')
aa_broken = 'deterministic diff: none' not in aa_headline
if aa_broken:
    print(f'::error title=A/A invariant violation::{aa_headline}')

# On pull_request events CI passes PR_NUMBER; the ref is N/merge there, so
# a branch lookup cannot work, and falling through to it would end in the
# quiet no-PR skip — an empty PR_NUMBER on such an event fails loudly
# instead. Under workflow_dispatch it is empty and the ref's open PR is
# looked up; check=True separates "no open PR" (exit 0, empty output —
# skip quietly) from "gh broke" (nonzero); stderr flows to the job log.
if os.environ.get('GITHUB_EVENT_NAME') == 'pull_request' and not os.environ.get('PR_NUMBER'):
    raise SystemExit('pull_request event without PR_NUMBER: refusing the silent skip')
pr = os.environ.get('PR_NUMBER') or subprocess.run(
    ['gh', 'pr', 'list', '--head', os.environ['GITHUB_REF_NAME'],
     '--state', 'open', '--json', 'number', '--jq', '.[0].number'],
    stdout=subprocess.PIPE, text=True, check=True,
).stdout.strip()
if pr:
    subprocess.run(
        ['gh', 'pr', 'comment', pr, '--body-file', '-'],
        input=comment, text=True, check=True,
    )
if aa_broken:
    raise SystemExit(1)
