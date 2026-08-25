'''Compose the A/B + A/A report comment from ab-report.txt / aa-report.txt
(in CWD), then: in CI (GITHUB_STEP_SUMMARY set), append it to the job summary
and post it to the ref's open PR if there is one — a NEW comment per run:
CI comments are append-only by design (scripts/gate_comment.py likewise), so
nothing is ever edited and each report stays archived. Run locally after
`just ab --aa | tee aa-report.txt` and `just ab | tee ab-report.txt` to print
the same block for pasting into a PR body by hand — one formatter for both
paths (dev.md "The PR procedure, and what gates", step 1).

Run with: uv run scripts/ab_comment.py
'''

import os
import platform
import subprocess
from pathlib import Path

host = os.environ.get('ImageOS') or platform.system()
comment = (
    f'**A/B report** (on-demand, {host}; read ratios against the A/A floor'
    ' below — dev.md "The PR procedure, and what gates"):\n'
    '<details><summary>just ab</summary>\n\n```\n'
    + Path('ab-report.txt').read_text()
    + '```\n</details>\n<details><summary>just ab --aa</summary>\n\n```\n'
    + Path('aa-report.txt').read_text()
    + '```\n</details>\n'
)
Path('ab-comment.md').write_text(comment)

summary = os.environ.get('GITHUB_STEP_SUMMARY')
if not summary:
    print(comment, end='')
    raise SystemExit(0)

with open(summary, 'a') as fh:
    fh.write(comment)
pr = subprocess.run(
    ['gh', 'pr', 'list', '--head', os.environ['GITHUB_REF_NAME'],
     '--state', 'open', '--json', 'number', '--jq', '.[0].number'],
    capture_output=True, text=True,
).stdout.strip()
if pr:
    subprocess.run(['gh', 'pr', 'comment', pr, '--body-file', 'ab-comment.md'], check=True)
