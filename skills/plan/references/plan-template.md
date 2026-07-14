# Plan template

This is the canonical structure for a plan file. Copy this skeleton and fill every section. Empty sections are allowed when explicitly noted with a one-line reason (e.g. "No external deps — research skipped").

```markdown
# <Task title — one short sentence>

Status: draft • Created: YYYY-MM-DD • Updated: YYYY-MM-DD • Branch: <git-branch>

## Goal

<One paragraph. What "done" looks like, in the user's own framing. No implementation details — those go under Approach.>

## Non-goals

- <Things explicitly out of scope. Each one prevents future drift.>
- <Be specific: "not migrating the legacy `oldAuth` callers" beats "not touching legacy code".>

## Context & current state

<Distilled from investigation. What exists today that the plan will touch:>
- Files / modules involved: `path/to/file.ts:42`, `path/to/other.ts`
- Current branch state: clean / N uncommitted files / behind main by N commits
- Related work: links to other plans in `.claude/plans/`, recent commits, open PRs

## Research findings

<For each external dependency the plan touches:>
- <name>: installed <version> → latest <version> (released YYYY-MM-DD) — <one-line note on breaking changes or relevance>. Docs: <url> (checked YYYY-MM-DD).

<Or, if the work is purely internal:>
No external dependencies — research skipped.

## Approach

<The chosen design. 1–3 paragraphs. Cover:>
- The shape of the change (which files/modules, in what order)
- Any new abstractions and where they live
- Data/state flow if non-obvious
- Mermaid diagram only if it earns its tokens

## Alternatives considered

- **<Alternative name>**: <one-line summary>. Rejected because <one-line reason>.
- **<Another alternative>**: <one-line summary>. Rejected because <one-line reason>.

<Or, if there genuinely is only one viable approach:>
Only viable approach — <one-line why>.

## Decomposition

<5–15 atomic, verifiable steps. Each is one logical change. Order by dependency.>

- [ ] 1. <Concrete action with file path>. Verify: <how>.
- [ ] 2. <Next step>. Verify: <how>.
- [ ] 3. <…>
- [ ] 4. <…>

<Item rules:>
- Each item is small enough to verify on its own.
- Each item names exact files / symbols where possible.
- Each item carries an inline `Verify:` note (or links to the Verification section).
- No item depends on a not-yet-listed item.

## Verification

<How to know the whole thing works after every item is checked.>
- Tests: <which suites to run, expected pass/fail before vs after>
- Manual checks: <click-throughs, curl commands, log assertions>
- Performance budgets, if relevant: <p50/p95 numbers, bundle size deltas>

## Risks & mitigations

- **<Risk, stated as a concrete failure mode>**: <mitigation, or "accepted — <reason>">.
- **<Another risk>**: <mitigation>.

<Or:>
- None identified at planning time; flag during execution if any emerge.

## Rollback plan

<How to undo if this lands and breaks something.>
- Pure code change: `git revert <expected-commit-range>` is sufficient.
- Migration / schema change / deploy: <step-by-step rollback, including data recovery if relevant>.

## Open questions

- [ ] <Question for the user, or for future investigation. Each is blocking until resolved or explicitly deferred.>
- [ ] <…>

<Or:>
- None.
```

## Field rationale

A few sections deserve explicit reasoning, since their value isn't obvious from the heading alone.

### Status header

One line, four fields. Why one line: it's grep-able. `rg "Status: " .claude/plans/` returns one row per plan.

- `Status` is one of: `draft`, `in-progress`, `blocked`, `done`, `abandoned`. Update on every meaningful state change.
- `Created` never changes. `Updated` changes on every edit.
- `Branch` records where the work lives. If the plan jumps branches mid-execution, append: `Branch: feature/auth (was: spike/auth)`.

### Decomposition checklist

This is the single source of truth for progress. Avoid duplicating it in a "Progress log" or "Status" section — three places to update means two of them go stale.

The checklist evolves during execution: if a step turns out to need sub-steps, replace it with the sub-steps inline; don't keep a phantom parent step that never gets checked. If a step turns out to be unnecessary, strike through (`- [ ] ~~item~~ — not needed because <reason>`) rather than delete, so the plan retains its history.

### Verification

This is what makes a plan executable rather than wishful. A step without verification is a step without a definition of done. Inline `Verify:` notes per item are usually enough; the dedicated **Verification** section is for end-to-end checks that don't belong with any single item.

### Research findings

Stale plans are worse than no plan. The `(checked YYYY-MM-DD via <url>)` suffix on every research line lets a future read of the plan immediately judge whether the dependency information is still load-bearing or needs a refresh.

When resuming a plan, re-check any line whose date is more than 14 days old.

### Open questions

Treat as blocking until resolved or explicitly deferred. A plan with three open questions and no answers is not approved — it's a draft. The act of crossing them off (or marking them deferred with a reason) is part of approval.
