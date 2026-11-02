---
name: ship
description: Verify a finished SDLC run against its sealed criteria, push it and open a PR that links the artifacts. Use when the owner says "/sdlc:ship" or a run's approved plan is fully built. Must run in the main session, since subagents can't use gh. Never merges.
argument-hint: "<slug>"
disable-model-invocation: true
---

# Verify and open the PR

The script is `bash "${CLAUDE_PLUGIN_ROOT}/scripts/sdlc.sh"`, written `sdlc` below. Quote the path. Merging is the owner's call: never attempt it, and hand them the PR link.

## 1. Verify

1. Commit all the code. A verdict has to refer to committed code.
2. Dispatch one `sdlc:verifier` agent. Give it the plan's **Verification** section as the acceptance criteria, first and unmodified, and name the range to diff: `git merge-base <base> HEAD`..`HEAD`. Don't give it your account of the work or your opinion of it. Don't convene a panel: one verifier owns the verdict.
3. Save its report to a temp file and record it, setting provenance from the report's decisive finding (`execution`, `deterministic` or `model`):

   ```bash
   sdlc record-verify <slug> --verdict <PASS|PASS-WITH-NOTES|FAIL> --provenance <kind> --report <file>
   ```

4. Do what its `NEXT:` line says:

| Result | What to do |
|---|---|
| PASS or PASS-WITH-NOTES | Commit the run folder and continue. Include any notes in the PR |
| FAIL, execution or deterministic | Fix it, commit, and verify again. Up to 3 rounds |
| FAIL, model | Ask the owner on Desk with the finding and your view. A verdict from reading the code never triggers a rewrite on its own |
| Round cap reached | Stop and report on Desk. Report this as the cap being hit, never as success |

If a fix means changing the plan, go back to `/sdlc:plan`, since that cancels the approval.

## 2. Open the PR

1. Push the branch. The gate checks Desk live; if it blocks you, read why and follow what it says.
2. Create it with `gh pr create`, based on the branch the work started from. The body covers:
   - What changed and why, in a few lines
   - Links to `docs/sdlc/<slug>/intent.md`, `plan.md` and `verify.md`
   - The Desk thread that approved the plan, from `sdlc thread <slug>`. Required: reviewers need it to see who approved what
   - The verification evidence, plus anything marked **Not checked**
3. Tell the owner on Desk: `sdlc report <slug> --pr <url>`. It posts the link on the approval thread and resolves it.
4. Stop. The run is finished once the owner merges.
