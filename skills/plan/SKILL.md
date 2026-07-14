---
name: plan
description: Creates a durable, file-based implementation plan with up-to-date dependency research. Use when the user types `/plan <task>` to scope a non-trivial change, design an approach, or break multi-step work into a tracked checklist. Saves each plan to `.claude/plans/YYYY-MM-DD-<slug>.md`, supports resume across sessions, and verifies external libraries/APIs are current before drafting.
argument-hint: "[task] | resume <slug> | list | show <slug>"
disable-model-invocation: true
---

# Plan

Produce a maintained `.md` plan that survives the session, captures up-to-date research on any external dependencies the work touches, and decomposes the task into a verifiable checklist.

Each plan lives at `.claude/plans/YYYY-MM-DD-<slug>.md` (relative to the git root, or current directory if not in a repo). Plans are durable artifacts — they're meant to be re-read, resumed, and reviewed after the session ends.

## Inputs

`$ARGUMENTS` is one of:

| Form | Meaning |
|---|---|
| `<task description>` | Create or resume a plan for this task. Default mode. |
| `resume <slug>` | Resume the named plan without prompting. |
| `list` | List all plans in `.claude/plans/` with their status, sorted newest first. Stop after listing. |
| `show <slug>` | Print the named plan's status header + checklist progress. Stop after printing. |
| *(empty)* | Ask the user what to plan, then proceed with whatever they reply. Do not invent a task. |

Compute the slug from the task description: lowercase, alphanumerics and hyphens only, max 50 chars, no leading/trailing hyphens. Example: `"Add user auth with JWT"` → `add-user-auth-with-jwt`.

## Workflow

Copy this checklist into your response and check items off as you complete them:

```
Plan progress:
- [ ] 1. Resolve mode and locate plan file
- [ ] 2. Investigate current state (parallel)
- [ ] 3. Research external dependencies (parallel)
- [ ] 4. Surface ambiguities and clarify
- [ ] 5. Draft plan from template
- [ ] 6. Write the plan file
- [ ] 7. Summarize and request approval
```

Do not proceed past Step 7 to execution unless the user approves.

### Step 1 — Resolve mode and locate plan file

1. Determine the plan directory: `git rev-parse --show-toplevel` if inside a repo, else current working directory. Append `/.claude/plans`. Create it with `mkdir -p` if missing.
2. Apply the slug rule above to `$ARGUMENTS`.
3. Glob the plan directory for `*-<slug>.md` (any date prefix, exact slug suffix).

| Glob result | Action |
|---|---|
| 0 matches | New plan. Filename: `YYYY-MM-DD-<slug>.md` using today's date. |
| 1 match | Read it. Print its status-header line and the **Decomposition** section (preserve `[x]` / `[ ]`). Ask: *resume* (continue editing), *revise* (new file with `-v2`, `-v3`, … suffix; copy unchecked items forward), or *new* (force a fresh plan with `-HHMM` time suffix). |
| 2+ matches | Same as one match, but pick the most recently modified file. List the others by name so the user can switch with `resume <slug>`. |

If `$ARGUMENTS` starts with `resume <slug>`, skip the prompt and go straight to resume mode.

### Step 2 — Investigate current state (parallel sub-agents)

Fan out investigation. Issue a single message with multiple `Agent` tool calls so they run concurrently. Use `subagent_type: "Explore"` for read-only lookups.

Required sweeps (skip any whose target doesn't exist):

- **Repo state**: `git status --short`, current branch, last 10 commits on this branch, `git diff --stat` against the merge-base with `main`/`master`. Note uncommitted work that the plan will collide with.
- **Code touchpoints**: search the codebase for terms from `$ARGUMENTS` using `rg`. For each hit, capture file path, line number, and one line of context. Cap at 30 hits to keep context bounded.
- **Dependency manifests**: read `package.json`, `pyproject.toml`, `Cargo.toml`, `go.mod`, `Gemfile`, etc. — whichever exist. Record currently-installed versions of any libraries the task is likely to involve.
- **Existing plans**: `ls .claude/plans/` if any plans exist — note related ones so the new plan can cross-link.

Each sub-agent returns a compact bulleted summary. Aggregate into a single **Context & current state** section in the plan.

### Step 3 — Research external dependencies (parallel)

This step is required when the plan touches any external library, framework, API, SDK, CLI, or service. Skip only when the work is purely internal refactor / docs / no external surface — and explicitly note the skip in the plan's Research findings section ("No external dependencies — research skipped").

For each external dependency named in the task or surfaced in Step 2:

1. Read the currently-installed version from the manifest/lockfile.
2. `WebSearch` for `"<lib> latest stable <current-year>"` (use the current year from system context). Capture the latest version, release date, and any breaking-change notes.
3. If the work uses a specific API or method, `WebFetch` the official docs page for that method. Capture the URL.
4. Note any deprecations, security advisories, or migration paths between installed and latest.

Output format (one line per dependency, in the **Research findings** section of the plan):

```
- <name>: installed <version> → latest <version> (released <YYYY-MM-DD>) — <one-line note>. Docs: <url> (checked YYYY-MM-DD).
```

Run these lookups in parallel. Cap searches at 8 dependencies per pass; if more, group by criticality and search the top 8.

### Step 4 — Surface ambiguities and clarify

Before drafting, list the open questions:
- Scope boundaries that aren't obvious from the task description.
- Choices between viable approaches (frame as a real trade-off, not a fake binary).
- Constraints the user has but the plan can't infer (timeline, performance budget, compat targets).

If there are 1–4 substantive questions, use `AskUserQuestion` to ask them before drafting. If the questions are minor, list them in the plan's **Open questions** section and proceed.

Do not invent answers. A plan written on assumptions is worse than a plan with explicit gaps.

### Step 5 — Draft plan from template

Read `references/plan-template.md` and fill every section. Section guidance:

- **Status header**: one line — `Status: draft • Created: YYYY-MM-DD • Updated: YYYY-MM-DD • Branch: <git-branch>`. Update `Updated` and `Status` on every revision.
- **Goal**: one paragraph. What "done" looks like, in the user's own framing.
- **Non-goals**: bullets. Things explicitly out of scope so future-you doesn't drift.
- **Context & current state**: distilled from Step 2.
- **Research findings**: from Step 3, in the format above. If skipped, note why.
- **Approach**: the chosen design. Diagrams in mermaid only if they earn their tokens.
- **Alternatives considered**: at least one alternative with a one-line rationale for rejection. If there genuinely is only one approach, write `Only viable approach — <why>`.
- **Decomposition**: the checklist. Each item is one atomic action — small enough to verify, large enough to matter. Use `- [ ]` markdown checkboxes. Order by dependency, not by file. Aim for 5–15 items; more means the work should be split into multiple plans.
- **Verification**: how to know each step worked. Tests to run, manual checks, expected output. This is what makes the plan executable rather than aspirational.
- **Risks & mitigations**: concrete failure modes, not "could fail". Each risk gets a mitigation or an explicit "accepted".
- **Rollback plan**: how to undo. For migrations, schema changes, deploys — required. For pure code changes — `git revert <commit-range>` is fine if true.
- **Open questions**: from Step 4. Empty is allowed.

Decomposition rules:
- Each item is verifiable on its own. "Refactor auth" is not an item; "Extract `verifyJWT()` from `routes/login.ts` into `auth/jwt.ts` and update the one call site" is.
- No item depends on a not-yet-listed item.
- Items reference exact files/symbols where possible.
- Reuse existing utilities — search before adding new ones (e.g., `withRetry` in `_db/utils.ts` style helpers).

### Step 6 — Write the plan file

Use the `Write` tool to create the file at the resolved path. Do not use `cat <<EOF` via Bash — `Write` is the correct tool.

If resuming an existing plan: use `Edit` to update sections in place. Update the `Updated:` date in the status header. Preserve checked items (`[x]`) and any notes the user added between the bullets.

If revising (new `-v2` file): copy unchecked items forward; checked items go into a single `## Carried over from <previous-filename>` section noting they're already done.

### Step 7 — Summarize and request approval

Reply with:
1. The plan file path (so the user can open it).
2. The status header line.
3. The decomposition list (checked + unchecked).
4. Open questions, if any.
5. The line: *"Approve to proceed, or tell me what to change."*

Do not start executing the plan. Wait for explicit approval.

## Resume mode

When resuming an existing plan:

1. Read the file in full.
2. Re-run Step 2 (investigate current state) — repo state has changed since last time, and the plan needs to reflect what's now true.
3. Re-run Step 3 only for dependencies whose `checked` date is older than 14 days, or if the user asks for a refresh. Update lines in place.
4. Edit the status header: bump `Updated:` to today, change `Status:` if appropriate (`draft` → `in-progress` after first checked item, → `done` when all checked, → `blocked` if user says so).
5. Show the user what changed since last time:
   - Items completed since the previous `Updated:` date (look at git log for the affected files).
   - Items that are now stale because the surrounding code changed.
   - Dependencies whose latest version moved.
6. Ask what to do next — pick up the next unchecked item, or revisit the plan structure.

## List mode

When `$ARGUMENTS` is `list`:

1. Read every `.md` in `.claude/plans/`.
2. Extract the status-header line from each.
3. Print a table sorted by `Updated:` desc:

```
slug                          status        created      updated      branch
add-user-auth-with-jwt        in-progress   2026-05-01   2026-05-07   feature/auth
migrate-pdfjs                 done          2026-04-15   2026-04-22   main
investigate-rate-limiter      blocked       2026-05-03   2026-05-04   spike/rl
```

Stop. Do not draft or modify anything.

## Show mode

When `$ARGUMENTS` is `show <slug>`:

1. Resolve the slug to a file (most recent if multiple).
2. Print the status header + the **Decomposition** section + any **Open questions**.
3. Stop.

## Notes for the planner

- **Use `rg` not `grep`**, **`bat` not `cat`** when displaying code to the user — these are the user's universal preferences.
- **Run investigation tools in parallel.** Step 2 and Step 3 are the slow steps; if you serialize them, the skill feels sluggish. One message, multiple `Agent` calls.
- **Don't pad.** Empty sections are better than fluffy ones. If there are no risks worth listing, write `- None identified at planning time; flag during execution if any emerge.`
- **Don't refactor neighbouring concerns.** A plan to add JWT auth doesn't include "while we're there, also fix logging." Surface adjacent issues in **Open questions** and let the user decide whether to expand scope.
- **Treat the plan as the source of truth during execution.** When the user comes back and says "continue the auth plan," `resume` is the right move — re-read the file before doing anything.

## Reference

Plan section template and field-by-field guidance: see `references/plan-template.md`.
