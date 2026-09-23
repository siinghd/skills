---
name: startfrom
description: Create a HANDOFF.md document at the end of a long conversation that captures full context (goal, work done, decisions, dead ends, current state, next concrete step) so a fresh Claude session can pick up with zero context loss after /clear.
argument-hint: "[optional: extra notes, focus areas, or a custom file path]"
disable-model-invocation: true
allowed-tools: Write, Read, Bash(git status*), Bash(git branch*), Bash(git log*), Bash(git diff*), Bash(git rev-parse*), Bash(pwd*), Bash(ls*), Bash(test*), Bash(mv*), Bash(date*)
---

<role>
You are writing a session handoff document. Treat the next Claude as a smart colleague who walked into the room with **zero conversation history** — no idea what task is in flight, what's been tried, what decisions were made, or what to do next. Your job is to brief them so they can ACT, not just read.
</role>

<live_state>
Repo root: !`git rev-parse --show-toplevel 2>/dev/null || pwd`
Invoked from: !`pwd`
Current branch: !`git branch --show-current 2>/dev/null || echo "(not a git repo)"`
Working tree status:
!`git status --short 2>/dev/null | head -60 || echo "(not a git repo)"`
Recent commits:
!`git log --oneline -15 2>/dev/null || echo "(not a git repo)"`
Commits on this branch not on origin/main / main / master (whichever exists):
!`git log --oneline -25 HEAD ^origin/main 2>/dev/null || git log --oneline -25 HEAD ^main 2>/dev/null || git log --oneline -25 HEAD ^master 2>/dev/null || echo "(no base branch found)"`
Unstaged diff stat:
!`git diff --stat 2>/dev/null | tail -30 || echo "(none)"`
Staged diff stat:
!`git diff --cached --stat 2>/dev/null | tail -30 || echo "(none)"`
Today: !`date "+%Y-%m-%d %H:%M %Z"`
HANDOFF.md exists at cwd?: !`test -f HANDOFF.md && echo "yes" || echo "no"`
User-supplied notes/focus: $ARGUMENTS
</live_state>

<task>
Write a comprehensive **`HANDOFF.md`** at the project root (current working directory) that bridges this conversation to the next one. The next session will read only this file — they will NOT have access to our chat history. Optimize ruthlessly for cold-read pickup.

If `$ARGUMENTS` looks like a path ending in `.md`, use that as the output file path instead of `HANDOFF.md`. Otherwise treat `$ARGUMENTS` as extra notes/focus the user wants emphasized.
</task>

<procedure>

## Step 1 — Reflect on the conversation

Before writing anything, internally scan the **entire conversation** and answer these questions to yourself:

1. What was the **original goal** the user asked for? (Quote them where possible.)
2. What has been **completed** — concretely, with file paths and line numbers?
3. What is **partially done** or in a known-broken state?
4. What **decisions** were made, especially non-obvious ones, and **why**?
5. What did we **try and reject**? (So next Claude doesn't repeat dead ends.)
6. What is the **single most important next action** the next Claude should take?
7. What **gotchas, surprises, or constraints** did we discover that aren't obvious from reading the code?
8. Are there **open questions** the user still needs to decide?
9. Which files are **most important** for the next Claude to read first?
10. Is there any **environment / setup / credentials / running processes** state that matters?

If the user provided focus notes via `$ARGUMENTS` (and they're not a file path), make sure those are reflected.

## Step 2 — Resolve the output path, then archive any prior handoff

**Resolve the output path** in this order:
1. If `$ARGUMENTS` is a path ending in `.md` → use it verbatim.
2. Else if `Repo root` from `<live_state>` is set and is a real path → write to `<repo_root>/HANDOFF.md`.
3. Else → write to `./HANDOFF.md` (cwd).

**Archive any existing file at that resolved path** before writing the new one. Construct the bash command using the literal resolved path (no placeholders) — for example, if the resolved path is `/repo/HANDOFF.md`:
```
test -f /repo/HANDOFF.md && mv /repo/HANDOFF.md /repo/HANDOFF-archive-$(date +%Y%m%d-%H%M%S).md || true
```
The `$(date ...)` runs inside a real Bash tool call, so substitution works normally. This preserves prior handoffs without forcing the user into git acrobatics.

## Step 3 — Write HANDOFF.md using the template below

Use the **Write** tool. Fill every section. If a section truly has nothing to record, write `_None._` rather than deleting the heading — the next Claude needs to know it was considered and is empty, not skipped by accident.

**Quality bar — every section must pass these tests:**
- **Concrete, not vague.** "Refactored auth" is bad. "Replaced `validateToken()` in `src/auth/jwt.ts:42` with `verifyToken()` from `@/lib/jwt-verify` because the old one didn't check `exp` claims" is good.
- **File paths with line numbers** wherever applicable (`src/foo.ts:123`).
- **Self-contained.** No phrases like "as we discussed", "the issue from earlier", "the bug I mentioned". The next Claude wasn't there.
- **Actionable.** The "Next Step" section must be a thing the next Claude can immediately do, not a goal to plan around.
- **Honest about uncertainty.** If you don't know whether tests pass, say "tests not run this session" — don't guess.

## Step 4 — Verify

After writing, **Read** the file back and self-check:
- Does the TL;DR + Next Step alone (top 30 lines) give enough to act?
- Could a stranger run `git status` + read this file + start working productively in under 2 minutes?
- Are there any "we", "I", "earlier", "the previous attempt" phrases that assume context the next Claude doesn't have? Rewrite them.

Then print a short summary to the user: file path written, archived path (if any), and a one-line reminder of how to bootstrap the next session (see "Bootstrap snippet" at the end of this skill).

</procedure>

<template>

The HANDOFF.md you write must follow this exact section order. Headings are mandatory; bullets are illustrative — replace with real content.

```markdown
# HANDOFF — <one-line topic> — <YYYY-MM-DD HH:MM>

> **Read this entire file before doing anything.** You are picking up a session from a previous Claude conversation. You have no memory of it. This document is your only briefing.

## TL;DR
<2–4 sentences: what is this work, where are we right now, what's the immediate next step.>

## Bootstrap (do this first)
1. Run `git status` and `git log --oneline -10` and confirm they match the "Current state" section below. If they diverge significantly, STOP and tell the user — something changed since handoff.
2. Read `CLAUDE.md` (project instructions) if present.
3. Read `.claude/memory/MEMORY.md` (persistent learnings) if present.
4. Read each file listed in "Key files to read first" below.
5. Then proceed to "Next step".

## Original goal
<What did the user ask for at the start of the session? Quote if possible. Include any constraints they set.>

## What's been done this session
<Concrete, file-level list. Each line: `path:line — what changed and why`. Group by feature/fix if there are many.>
- `src/example.ts:42` — replaced X with Y because Z
- `src/example.test.ts:10-30` — added regression test for the Z case

## Current state
- **Branch:** <name> (<N commits ahead of base / clean / etc.>)
- **Working tree:** <clean / N modified files / list them>
- **Uncommitted changes:** <staged: list / unstaged: list / "none">
- **Last commit:** <hash + subject>
- **Tests:** <passed / failed / not run this session — be honest>
- **Build/typecheck:** <passed / failed / not run this session>
- **Running processes:** <dev server on :3000 / none / etc.>

## Decisions made (and why)
<Non-obvious decisions only. Skip "I named the variable foo." Include things like architecture, library choice, trade-offs.>
- Chose A over B because <reason>. The trade-off is <X>.
- Decided NOT to <do thing> because <reason>.

## What didn't work / dead ends
<Approaches tried and abandoned. Save the next Claude from repeating them.>
- Tried <approach>. Failed because <reason>. Don't retry unless <condition changes>.

## Next step (PRIORITY — start here)
<ONE specific, concrete, immediately-actionable thing. Not "continue refactoring" — but "open `src/foo.ts:88` and replace the inline retry with `withRetry` from `_db/utils.ts`, then run `npm test src/foo.test.ts`".>

## Remaining work (after the next step)
<Ordered TODO list. Be specific. Each item should be small enough to verify done.>
1. <task with concrete acceptance criterion>
2. <task>
3. <task>

## Open questions for the user
<Things the user needs to decide before proceeding. If none, write `_None._`>
- <Question>: <context for why this matters / what the options are>

## Key files to read first
<Top 3–7 files most critical for understanding this work, ranked by importance. Brief justification each.>
- `path/to/file.ts` — <why this matters>
- `path/to/other.ts` — <why this matters>

## Gotchas & non-obvious constraints
<Things that aren't obvious from reading the code. Include anything that bit us this session.>
- <gotcha>
- <constraint discovered>

## Useful commands
<Specific commands the next Claude will likely need.>
- Run tests for this area: `<command>`
- Start dev server: `<command>`
- Reproduce the bug: `<command>`

## External references
<Links, ticket numbers, doc paths, Slack threads — anything the next Claude can't see otherwise.>
- <link or ref>

## User-supplied focus
<If $ARGUMENTS contained extra notes, repeat them here verbatim so they aren't lost. Otherwise `_None._`>
```

</template>

<bootstrap_snippet>
After writing, end your response to the user with a reminder block in this shape (substitute real paths — do not print literal angle-bracket placeholders):

```
Handoff written: <absolute-or-repo-relative path>
(archived previous: <path>)   ← include only if you archived

To resume in a fresh session, /clear and then paste this as your first message:
> Read <handoff-path> and follow the Bootstrap section. Then start the Next step.
```
</bootstrap_snippet>

<rules>
- **Do not summarize the conversation as prose.** The handoff is a structured briefing, not a narrative.
- **Do not invent facts.** If something wasn't established, mark it unknown.
- **Do not commit the file** unless the user explicitly asks. Just write it.
- **Do not modify CLAUDE.md, MEMORY.md, or any other file** — only write the handoff.
- If the working directory is not a git repository, skip git-state lines and note `Not a git repository` in the Current state section.
- If the conversation is short or trivial (no real work was done), tell the user that a handoff isn't necessary rather than writing a thin one.
</rules>
