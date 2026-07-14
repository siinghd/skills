---
name: orchestrate
description: Run the current task in orchestrator/worker mode - the session model (Fable 5) plans, delegates execution to Opus-pinned workers (worker/scout/verifier agents), reviews, and integrates, so most tokens bill at Opus rates. Use when the user says "orchestrate", "delegate", "use workers", or when a task involves substantial mechanical execution (multi-file edits, migrations, test writing, broad research) that doesn't need the session model's full context per step.
argument-hint: <task to orchestrate>
---

# Orchestrator mode

You are the orchestrator: an expensive, high-judgment model. Workers are Opus 4.8 agents — strong enough for any packet, at half your rate. Every token you personally spend on mechanical work is billed at the premium rate for no quality gain; every decision you delegate to a worker is a quality risk. The craft is the split.

**Why this pays:** Fable 5 bills $10/$50 per MTok; Opus 4.8 bills $5/$25 — worker tokens cost 50% less. On delegation-heavy tasks the orchestrator typically spends <20% of total tokens. For genuinely easy packets (bulk renames, simple greps), you may pass `model: "sonnet"` on the Agent call to drop that one worker to Sonnet 5 rates ($3/$15; $2/$10 intro through 2026-08-31) — but Opus is the default the user chose.

## The split

**Keep at orchestrator level (you):**
- Understanding the user's intent; anything requiring the conversation's full context
- Architecture and design decisions; choosing the approach
- Writing the work packets (this is where quality is won or lost)
- Reviewing worker output; resolving blockers; final integration and the user-facing summary
- Anything smaller than the overhead of writing a packet for it (a one-file read, a two-line fix)

**Delegate to workers:**
- `worker` — implementation packets: edits, refactors, boilerplate, migrations, tests, docs
- `scout` — read-only research: searches, dependency tracing, "how does X work", parallel exploration fan-outs
- `verifier` — post-implementation checks: run tests/typecheck/build, adversarial diff review vs acceptance criteria

## The loop

1. **Plan.** Restate the goal. Decompose into self-contained packets. Classify each: delegate vs keep. If the codebase is unfamiliar, dispatch scouts FIRST (in parallel) to build the map before you design.

2. **Write packets.** Workers share none of your context — a vague packet produces confident garbage. Each packet must contain:
   - Objective (one sentence) and why (one sentence of intent)
   - Exact files/areas to touch, and explicit non-goals ("do not touch X")
   - Context the worker can't discover cheaply: pasted snippets, conventions, decisions you already made, relevant constraints from the conversation
   - Acceptance criteria + the verification command to run
   - Required report shape (the agents' definitions already specify one)

3. **Dispatch.** Use the Agent tool with `subagent_type: worker | scout | verifier`. Independent packets go in ONE message as parallel Agent calls. For a follow-up to an existing worker (fixing its own output, answering its blocker), use SendMessage to continue it — it keeps its context; do not respawn.

4. **Review.** Read each report. Spot-check the diff where it matters (interfaces, edge cases, anything the worker flagged as a deviation). Send fixes back to the SAME worker with precise feedback; only fix things yourself when the fix is smaller than explaining it.

5. **Verify.** Dispatch `verifier` on the integrated result (or the project's verify skill for user-facing flows). Don't accept a worker's own "tests pass" as final evidence for the whole task.

6. **Report.** Outcome first. Then what changed, verification evidence, and anything the user must decide. Mention the delegation shape in one line (e.g. "3 workers + 1 verifier did the execution").

## Anti-patterns

- Delegating a decision, then rubber-stamping it — workers execute; you decide
- Re-doing a scout's search yourself "to be sure" — review its evidence instead
- One mega-packet ("implement the feature") — that's just paying Sonnet to plan badly
- Spawning a new worker to fix an old worker's diff — SendMessage the original
- Delegating anything that needs the user's conversation history verbatim — summarize the needed context into the packet instead
- Polling or idling while workers run — you're notified on completion; do orchestrator-level work meanwhile

## Escalation: many packets → Workflow

For large fan-outs (~8+ independent packets: migrations across many files, audits, sweeps), use the Workflow tool instead of hand-dispatching — this skill counts as your opt-in. Pin workers to Opus via `opts.model` and xhigh reasoning via `opts.effort` (matching the worker agents' frontmatter):

```javascript
export const meta = {
  name: 'orchestrated-sweep',
  description: 'Fan a work-list out to Opus workers, verify each result',
  phases: [{ title: 'Execute' }, { title: 'Verify' }],
}
const results = await pipeline(
  args.packets,
  p => agent(`WORK PACKET:\n${p.spec}\nReport: files changed as path:line, verification output, deviations, blockers.`,
             {label: `work:${p.id}`, phase: 'Execute', model: 'opus', effort: 'xhigh'}),
  (report, p) => agent(`Adversarially verify this against the acceptance criteria.\nCriteria: ${p.criteria}\nReport: ${report}\nRun the checks yourself; verdict PASS/FAIL first line.`,
             {label: `verify:${p.id}`, phase: 'Verify', model: 'opus', effort: 'xhigh'})
)
return results
```

Discover the work-list yourself (or via scouts) before invoking Workflow; pass it as `args`. Keep judge/synthesis stages at the session model (omit `opts.model`) when correctness of the final merge matters more than its cost.

## Running orchestrated work as a loop

When the task is recurring or has a checkable end state, wrap this pattern in a loop (per Anthropic's "Getting started with loops" guidance):

- **Goal-based (`/goal`):** prefer this when completion is deterministic — tests passing, a count reaching zero, a migration list emptied. State the criteria explicitly so the loop can't stop early or overrun.
- **Time-based (`/loop`, `/schedule`):** for recurring work or watching external systems; match the interval to how fast the underlying state actually changes, not a round number.
- **Proactive/event-driven:** best for well-defined recurring streams — bug reports, issue triage, dependency upgrades — where each item becomes one work packet.
- **Script the deterministic steps.** Anything a script can do (list the work items, run the checks, compute the diff) should be a script, not model reasoning re-derived every iteration. Encode recurring verification as a skill so every iteration runs it identically.
- **Monitor and pilot.** Watch spend and progress with `/usage` and `/workflows`; pilot on a small slice before a large fan-out.
