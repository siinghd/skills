---
name: optimize
description: Context-aware optimization audit for any codebase and language (systems, backend, frontend, libraries, scripts). Finds correctness and security problems, performance hot spots, poor data layout and allocation, scalability limits, memory leaks, dead code, and missing abstractions, then fixes what you approve. Performance advice favors redesign over patching, with every recommendation weighed against the code's actual workload. **By default, scopes to the current working set** (uncommitted changes + files changed on the current branch vs. the base branch). Pass `repo` to scan the full codebase, or a path/glob to scope explicitly (e.g. `/optimize layout src/parser/**`).
argument-hint: "[all | speed | logic | abstractions | security | types | concurrency | observability | tests | layout | performance | rerenders | effects | memory | scalability | deadcode | bundle] [path-or-glob | repo]"
disable-model-invocation: true
---

Run a two-phase optimization audit: find problems read-only, then fix what is approved.

**Argument received:** $ARGUMENTS

A category name narrows both the audit and the fixes to that category. `speed` is shorthand for `layout`, `performance`, `scalability` and `memory`. `all` or no argument audits every applicable category.

**Context decides.** No rule in this skill or its checklists is absolute. A technique that is right for a parser's inner loop can be wrong for a settings page. Recommend a change only when it fits the workload, data, and constraints of the code in front of you, and say which facts made it fit.

## Phase 0 – Detect stack, scope, and context (one short pass)

**Stack.** Read the manifests (`package.json`, `go.mod`, `Cargo.toml`, `pyproject.toml`, `build.zig`, `CMakeLists.txt`, `pom.xml`, etc.). Note the languages, frameworks, bundler, test runner, and available benchmarks or profilers.

**Scope.** Resolve in this order:

1. Path arg is `repo` (or `--all-files`) → the entire repository.
2. A path or glob was given → expand it to a concrete file list.
3. Otherwise → the **current working set**:
   - Uncommitted changes: `git status --porcelain`.
   - Plus branch changes: `git diff --name-only $(git merge-base HEAD origin/main 2>/dev/null || git merge-base HEAD main 2>/dev/null || git merge-base HEAD master 2>/dev/null)...HEAD`.
   - Drop deleted files, binaries, and lock files.
   - If empty, fall back to `git diff --name-only HEAD~1 HEAD`. If still empty, say "no working changes detected — pass `repo` to scan the whole codebase or a path to scope explicitly" and stop.

**Context.** Establish what you can from the code, docs, and benchmarks, and mark the rest `unknown` rather than guessing:

- **Workload:** what runs often, on what data sizes, and which paths are hot or cold.
- **Goal:** latency, throughput, memory, startup, bundle size, or cost, and any stated target.
- **Evidence:** existing profiles, benchmarks, or production metrics.
- **Constraints:** public APIs, memory model and runtime, team conventions, and how long the code is expected to live.

Print these lines before the findings:

```
Stack: <lang(s)> · <frameworks> · <bundler|none> · <test runner|none>
Scope: <working set | repo | glob> (N files)
Context: <workload> · goal:<goal> · evidence:<profile|benchmark|none>
```

On a partial scope, add `cross-file categories may miss findings outside scope.`

## Phase 1 – Audit (read-only, parallel)

Select categories from the table below, skipping any that clearly don't apply. Each subagent reads [reference/audit-protocol.md](reference/audit-protocol.md) and only the checklist files for its categories.

| Categories | Applies to | Checklist |
|---|---|---|
| `logic`, `security`, `types`, `concurrency`, `observability`, `tests` | any code; `types` needs a type system, `observability` needs long-running code, `tests` needs tests | [reference/correctness.md](reference/correctness.md) |
| `layout` | hot paths or large in-memory data, in any language | [reference/layout.md](reference/layout.md) |
| `performance`, `scalability`, `memory` | any code | [reference/performance.md](reference/performance.md) |
| `rerenders`, `effects`, `bundle` | React for the first two; a bundler or browser target for `bundle` | [reference/frontend.md](reference/frontend.md) |
| `deadcode`, `abstractions` | any code | [reference/maintainability.md](reference/maintainability.md) |

**Dispatch by scope size.** Send all subagents in one message so they run concurrently. Use `scout` when available, otherwise a read-only `general-purpose` agent.

| Scope | Fan out by | Why |
|---|---|---|
| 1–3 files | no subagents | Orchestration costs more than it saves |
| ≤ 30 files | ~5 balanced file buckets, each running all applicable categories | Each file is read once, in full context |
| 31–300 files | one agent per applicable category | Trades context for search throughput |
| > 300 files | one agent per top-level module, ranked by hot-path evidence and recent churn; audit the top 5 and list the rest | Keeps cost bounded; report what was not covered |

Give each subagent the resolved file list, the Stack and Context lines, the absolute paths of its reference files (under `${CLAUDE_SKILL_DIR}/reference/`), its categories, and an instruction to return only structured findings. It must not scan outside its list.

**Validate once before printing:**

1. De-dup by `file:line`, keeping the category that owns the issue per the ownership table in the protocol. Break ties on higher confidence.
2. Hide `confidence: low` findings and end with `Suppressed N low-confidence findings.`
3. Drop any finding whose `harm:` is generic or whose `context:` doesn't tie it to this code's workload.
4. Sort each category by impact, then confidence, and keep the top 15.
5. Print the header lines, then categories in this order: logic, abstractions, security, types, concurrency, observability, tests, layout, performance, rerenders, effects, memory, scalability, deadcode, bundle. Skip empty ones.

## Phase 2 – Apply fixes

- `all` → fix everything except `high`-impact items and redesigns. List those in 1–2 lines each and pause once for confirmation.
- A category name or `speed` → fix only that selection, with the same gate.
- No argument → ask: *"Which items should I fix? Reply with 'all', specific numbers, or a category name."*

**Performance claims need numbers.** For `layout`, `performance`, and `memory` fixes that change a data structure or allocation strategy, capture a baseline before the change and rerun the same measurement after it. If no measurement is possible, leave the finding as `flag, don't fix` and say what would need measuring. If the numbers don't improve, revert the change and report that.

**Dispatch.** With 1–2 approved findings, apply them directly. Otherwise group findings by file, so no two agents share a file, and send one agent per bucket in a single message. Use `worker` when available, otherwise `general-purpose`. Each returns one line per fix: `<file>:<line> – <what changed> – <why>`.

**Fix rules:**

- Make one logical fix per edit.
- Don't refactor neighbouring code. Add anything new you find to the audit list.
- Flag architectural changes as notes rather than patching them unsafely, unless the redesign was approved.

**Verify and report.** Run typecheck, lint, and tests once across the whole change set, using `verifier` when available, and report pass or fail. End with:

- Before/after numbers for each measured fix.
- **Code samples:** when more than 3 fixes landed, quote 2–3 short diff hunks, picking the riskiest changes, so the user can spot-check the work without reading the whole diff.
