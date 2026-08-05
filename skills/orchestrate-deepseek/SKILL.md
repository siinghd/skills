---
name: orchestrate-deepseek
description: Run the current task in orchestrator/worker mode with DeepSeek (or any OpenRouter model) as the execution tier - the session model plans, writes packets, reviews, and integrates; DeepSeek workers execute at ~1/10th of Opus rates via the openrouter skill's plumbing. Use when the user says "orchestrate with deepseek", "deepseek workers", "orchestrate-deepseek", or wants maximum-cheapness delegation for mechanical execution.
argument-hint: <task to orchestrate>
---

# Orchestrator mode — DeepSeek execution tier

Same philosophy as /orchestrate: you are the expensive, high-judgment orchestrator; every mechanical token you spend personally is wasted premium rate; every decision you delegate is a quality risk. The craft is the split. Read this skill together with the `openrouter` skill (invoke it if not already loaded) — it defines the scripts used below (`OR="$HOME/.claude/skills/openrouter/scripts"`).

**Why this pays:** Fable 5 bills $10/$50 per MTok, Opus workers $5/$25; the default execution model `~deepseek/deepseek-v4-flash-latest` (leading `~` is literal — always quote it) bills ~$0.09/$0.18 via OpenRouter (v4-pro, the first escalation tier, ~$0.44/$0.87) — execution at 2–15% of Opus cost. The trade: DeepSeek is weaker at tool-calling through the translation gateway and shares none of your context, so packets must be tighter and verification is non-negotiable.

## Hard rules (learned from a real incident, not theory)

On 2026-08-05 three parallel workers in one checkout ignored explicit NON-GOALS, raced on the same files, and two of them ran `git checkout` on their peers' concurrent edits — reasoning that unexpected changes must be their own overreach. 18 files were destroyed, including completed work from other workers. One worker's report claimed "no other files touched" while `git status` showed three modified.

1. **Parallel workers ALWAYS get `-w` (worktree isolation)** — or don't run them in parallel. NON-GOALS in a packet are not a concurrency mechanism; workers demonstrably ignore them. Note `-w` starts from HEAD: checkpoint-commit or stash anything the worker must build on.
2. **Snapshot before delegating:** `git diff HEAD > /tmp/pre-delegation.patch` (or a checkpoint commit) whenever uncommitted work is in the tree. This is what made the incident recoverable.
3. **Never trust a worker's self-report.** Verify with `git status --porcelain` and read the actual diff. Reports lie — not maliciously, but they do.
4. **Workers cannot read secrets or run DB/cloud CLIs or destructive git** — this is hard-enforced by `worker-settings.json` (see the openrouter skill). If a worker reports it's blocked on a config value, YOU read it and paste a sanitized value into a follow-up packet. Never widen the deny list.
5. **Marker sweep after a fan-out:** confirm the features/files you expected to survive are still present before accepting the batch.

## Preflight (first dispatch only)

1. `$OR/or-chat.sh key-check` — if it fails, give the user the key-setup instructions from the openrouter skill and stop.
2. For agentic packets: `$OR/or-proxy.sh start` (idempotent).

## The split

**Keep at orchestrator level (you):** intent, architecture, approach choices, writing packets, reviewing output, resolving blockers, final integration, the user-facing summary, and anything smaller than the packet describing it.

**Delegate, choosing the dispatch per packet:**

| Packet type | Dispatch | How |
|---|---|---|
| Implementation (edits, refactors, tests, boilerplate) | agentic DeepSeek worker | Agent tool `subagent_type: "deepseek-worker"` (native chaperone — monitorable, SendMessage-continuable); raw `$OR/or-worker.sh -d <repo> packet.md` only for scripted fan-outs |
| Generation/review from context you already hold (draft a module, review a diff, write docs) | DeepSeek oracle | `$OR/or-chat.sh chat -m '~deepseek/deepseek-v4-flash-latest' packet.md` |
| Read-only codebase research | Anthropic `scout` agent (Agent tool) | oracles can't read files; agentic DeepSeek scouting is possible but scouts' value is judgment-dense summarization — keep it on Anthropic |
| Post-implementation verification | Anthropic `verifier` agent (Agent tool) | never verify DeepSeek work with DeepSeek |

Escalation ladder per packet: flash-latest (default) → `-m deepseek/deepseek-v4-pro` if flash fumbles the packet → an Opus `worker` agent (Agent tool) when it needs cross-file judgment, subtle API design, or has failed on both DeepSeek tiers — one clean Opus pass beats three DeepSeek retries.

## The loop

1. **Plan.** Restate the goal, decompose into self-contained packets, classify each per the table. Scouts first (parallel) if the codebase is unfamiliar.
2. **Write packets.** DeepSeek workers get NO conversation context and discover context poorly — packets must be stricter than Opus packets: objective + why, exact file paths, pasted snippets and conventions, explicit non-goals, acceptance criteria, and the report shape (outcome / files changed as path:line / deviations / blockers). For oracles additionally pin the output format (unified diff or full replacement file, nothing else).
3. **Dispatch.** Snapshot the tree first (hard rule 2). Preferred: parallel Agent calls with `subagent_type: "deepseek-worker"`, full packet in the prompt, and the line `ISOLATION: worktree` whenever more than one worker runs at once — runs show up natively and the user can monitor them (`or-monitor.sh watch` tails the live log too). Script path (`or-worker.sh -w`, background Bash) only for scripted fan-outs. Capture from each report: `.result`, `.session_id`, `.total_cost_usd`, and the worktree path if isolated.
4. **Review.** Read the DIFF, not the report (hard rule 3): `git status --porcelain` plus the actual `git diff`, and for isolated runs `git -C <worktree> diff` before merging it into the main tree. Reports have claimed clean when three files were modified. Follow-ups: SendMessage the same chaperone with `RESUME SESSION: <session_id>` (or `or-worker.sh -r <session-id>` directly) — never a fresh spawn.
5. **Verify.** Dispatch an Anthropic `verifier` on the integrated result (workers default to acceptEdits, so they usually haven't run the tests themselves). Never accept a DeepSeek "done" without independent evidence.
6. **Report.** Outcome first; then changes, verification evidence, open decisions, and one line on delegation shape + OpenRouter spend (sum of `.total_cost_usd` — it bills to the user's OpenRouter account, not Claude usage).

## Anti-patterns

- All of /orchestrate's: no rubber-stamping delegated decisions, no re-doing scout work, no mega-packets, no respawning to fix a worker's own diff, no idling while workers run.
- Sending exploration or "figure out how X works" to an oracle — it has no tools; it will hallucinate confidently.
- Trusting a DeepSeek diff without reading it — gateway tool-calling occasionally mangles edits; `git diff` is cheap.
- Running parallel workers in one checkout because "the packets don't overlap" — see hard rule 1; this exact reasoning cost 18 files.
- Sending secrets or private user data in packets — content leaves for a third-party provider. Sanitize values before pasting; prefer describing the shape ("a Postgres URL") over the real string.
- Using DeepSeek to save money on the one packet where a wrong decision is expensive — escalate those to Opus or keep them.

## Scale-out

For ~8+ independent packets, don't hand-dispatch: write packets to files and drive `or-worker.sh` from a loop, or use the Workflow tool with agents whose only job is to run the dispatch script and relay the report. Pilot one packet end-to-end before fanning out, and report aggregate OpenRouter spend at the end.
