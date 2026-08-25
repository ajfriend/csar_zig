# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
'''Compose the A/B + A/A report comment from ab-report.txt / aa-report.txt
(in CWD), then: in CI (GITHUB_STEP_SUMMARY set), append it to the job summary
and post it to the PR — a NEW comment per run: CI comments are append-only
by design (scripts/gate_comment.py likewise), so nothing is ever edited and
each report stays archived. Run locally after `just ab --aa | tee
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

# A non-empty deterministic diff raises a checks-UI warning — visible from
# the merge button without turning anything red (dev.md: nothing mechanical
# acts on the diff; full gating stays an open question). An A/A headline
# that is not 'none' is a harness invariant violation and warns doubly.
for headline in (ab_text.splitlines()[0], aa_text.splitlines()[0]):
    if 'deterministic diff: none' not in headline:
        print(f'::warning title=deterministic diff::{headline}')

# On pull_request events CI passes PR_NUMBER (the ref is N/merge there, so
# a branch lookup cannot work — and falling through to it would end in the
# quiet no-PR skip, so an empty PR_NUMBER on such an event fails loudly
# instead); under workflow_dispatch it is empty and the ref's open PR is
# looked up. check=True separates "no open PR" (exit 0,
# empty output — skip quietly) from "gh broke" (nonzero — fail the job);
# stderr flows to the job log.
if os.environ.get('GITHUB_EVENT_NAME') == 'pull_request' and not os.environ.get('PR_NUMBER'):
    raise SystemExit('pull_request event without PR_NUMBER: refusing the silent skip')
pr = os.environ.get('PR_NUMBER', '') or subprocess.run(
    ['gh', 'pr', 'list', '--head', os.environ['GITHUB_REF_NAME'],
     '--state', 'open', '--json', 'number', '--jq', '.[0].number'],
    stdout=subprocess.PIPE, text=True, check=True,
).stdout.strip()
if pr:
    subprocess.run(
        ['gh', 'pr', 'comment', pr, '--body-file', '-'],
        input=comment, text=True, check=True,
    )
