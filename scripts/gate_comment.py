# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
'''Compose the coverage-gate report from coverage/summary.txt, append it to
the job summary, and — on a PR — post it as a NEW comment. Append-only on
purpose, like scripts/ab_comment.py: no comment is ever edited, so there is
no marker matching, no upsert, and no ordering to race between the two
workflows; each push leaves its ledger in the record. PR_NUMBER empty (a
push to main) means summary only.

Run with: uv run scripts/gate_comment.py  (CI passes env; see ci.yml)
'''

import os
import subprocess
from pathlib import Path

report = (
    f'**Coverage gate** ({os.environ.get("ImageOS", "ubuntu")}; see dev.md "Coverage"):\n'
    '```\n' + Path('coverage/summary.txt').read_text() + '```\n'
)

with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as fh:
    fh.write(report)

pr = os.environ.get('PR_NUMBER', '')
if pr:
    subprocess.run(
        ['gh', 'pr', 'comment', pr, '--body-file', '-'],
        input=report, text=True, check=True,
    )
