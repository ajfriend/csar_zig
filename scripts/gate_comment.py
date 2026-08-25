'''Compose the coverage-gate report from coverage/summary.txt, append it to
the job summary, and upsert it as the PR's ledger comment. Upsert, not
`gh pr comment --edit-last`: that flag edits the bot's most recent comment
regardless of content, so after an on-demand A/B run posts its report
(scripts/ab_comment.py), --edit-last would overwrite the A/B comment with
the ledger and strand the old ledger stale. Instead: find the bot comment
whose body starts with the ledger's marker line and PATCH it; create one
only if none exists. PR_NUMBER empty (a push to main) means summary only.

Run with: uv run scripts/gate_comment.py  (CI passes env; see ci.yml)
'''

import json
import os
import subprocess
from pathlib import Path

MARKER = '**Coverage gate**'

report = (
    f'{MARKER} ({os.environ.get("ImageOS", "ubuntu")}; see dev.md "Coverage"):\n'
    '```\n' + Path('coverage/summary.txt').read_text() + '```\n'
)
Path('gate-report.md').write_text(report)

with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as fh:
    fh.write(report)

pr = os.environ.get('PR_NUMBER', '')
if not pr:
    raise SystemExit(0)

repo = os.environ['GITHUB_REPOSITORY']
comments = json.loads(subprocess.run(
    ['gh', 'api', f'repos/{repo}/issues/{pr}/comments', '--paginate'],
    capture_output=True, text=True, check=True,
).stdout)
ledger = [c['id'] for c in comments if c['body'].startswith(MARKER)]
if ledger:
    subprocess.run(
        ['gh', 'api', '-X', 'PATCH', f'repos/{repo}/issues/comments/{ledger[-1]}',
         '-F', 'body=@gate-report.md'],
        check=True, capture_output=True,
    )
else:
    subprocess.run(['gh', 'pr', 'comment', pr, '--body-file', 'gate-report.md'], check=True)
