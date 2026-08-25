#!/bin/sh
# Compose the A/B + A/A report comment from ab-report.txt / aa-report.txt
# (in CWD), then: in CI (GITHUB_STEP_SUMMARY set), append it to the job
# summary and post it to the ref's open PR if there is one — a NEW comment
# per run, deliberately not `gh pr comment --edit-last`, which edits the
# bot's most recent comment and would clobber the coverage ledger. Run
# locally after `just ab --aa | tee aa-report.txt` and `just ab | tee
# ab-report.txt` to print the same block for pasting into a PR body by
# hand — one formatter for both paths (dev.md "The PR procedure, and what
# gates", step 1).
set -eu

out=ab-comment.md
{ printf '**A/B report** (on-demand, %s; read ratios against the A/A floor below — dev.md "The PR procedure, and what gates"):\n' "${ImageOS:-$(uname -s)}"
  printf '<details><summary>just ab</summary>\n\n```\n'
  cat ab-report.txt
  printf '```\n</details>\n<details><summary>just ab --aa</summary>\n\n```\n'
  cat aa-report.txt
  printf '```\n</details>\n'
} > "$out"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  cat "$out" >> "$GITHUB_STEP_SUMMARY"
  pr=$(gh pr list --head "${GITHUB_REF_NAME}" --state open --json number --jq '.[0].number' || true)
  if [ -n "$pr" ]; then
    gh pr comment "$pr" --body-file "$out"
  fi
else
  cat "$out"
fi
