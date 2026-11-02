---
name: intent
description: Start an SDLC run by capturing an idea as a committed intent.md on a feature branch. Use when the owner wants to run a feature through the pipeline, or says "start a run", "new intent" or "/sdlc:intent". Not for quick fixes, which don't need a run.
argument-hint: "<idea in a sentence>"
disable-model-invocation: true
---

# Capture the intent

A run is opt-in per branch. Starting one means code edits on this branch stay blocked until the owner approves a plan on Desk. Branches without a run aren't affected, so quick fixes shouldn't start one.

The script is `bash "${CLAUDE_PLUGIN_ROOT}/scripts/sdlc.sh"`, written `sdlc` below. Quote the path. If this machine may not be set up yet, run `sdlc doctor` first.

## Steps

1. **Pick a slug**: lowercase letters, digits and hyphens, 50 characters at most.
2. **Get onto a feature branch.** If this checkout is on a shared branch or on someone else's work, run `git switch -c feat/<slug>`. If uncommitted changes are in the tree, ask before moving.
3. **Register the run:** `sdlc init <slug>`. It refuses shared branches and a second run on one branch. If it refuses, follow what it says; don't work around it.
4. **Brainstorm with the owner, in the session.** Ask only what you can't work out from the code. One good question beats three vague ones.
5. **Write `docs/sdlc/<slug>/intent.md`** using the template below. Keep it short. It records what and why, in the owner's framing, not how.
6. **Show it to the owner and correct it** until they say it's right. There's no Desk approval at this stage, because they're shaping it with you.
7. **Commit only the run folder:** `git add docs/sdlc/<slug> && git commit -m "intent: <slug>"`.
8. Tell the owner the next step is `/sdlc:plan <slug>`.

## Template

```markdown
# <Title>

Author: <who raised this> • Status: accepted

## Problem
<What's wrong today, and for whom. Concrete, with evidence if you have it.>

## Outcome
<What's true when this is done, stated so someone could check it.>

## Affected users and systems
- <...>

## Constraints
- <Hard limits: compatibility, security, cost, things that must not change.>

## Open questions
- <Anything the plan has to settle. "None" is fine.>
```
