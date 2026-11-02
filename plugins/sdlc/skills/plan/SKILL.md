---
name: plan
description: Turn an accepted intent.md into a plan.md, get it approved on Desk, then work through it. Use for the planning and build stages of an SDLC run, when the owner says "/sdlc:plan", or when resuming a run whose plan is approved or waiting. Requires a run started with /sdlc:intent.
argument-hint: "<slug>"
disable-model-invocation: true
---

# Plan, get approval, build

The script is `bash "${CLAUDE_PLUGIN_ROOT}/scripts/sdlc.sh"`, written `sdlc` below. Quote the path. Start with `sdlc status` to see where this run stands, and resume from that point.

Don't use plan mode. The gate does the blocking, and the approval has to survive across sessions and worktrees.

## 1. Write the plan

1. Read `docs/sdlc/<slug>/intent.md`, then the code it touches.
2. Write `docs/sdlc/<slug>/plan.md` from `${CLAUDE_PLUGIN_ROOT}/skills/plan/references/plan-template.md`. Fill every section; an empty one needs a one-line reason.
   - **Decomposition** items name the files that change, in dependency order.
   - **Verification** is the acceptance criteria. It's sealed by the approval, and the verifier judges against it, so write commands and observable results, not intentions.
3. Settle every item under **Open questions**, or mark it deferred with a reason. A plan with unresolved questions isn't ready to approve. Ask the owner rather than inventing answers.

## 2. Get approval

1. Commit it: `git add docs/sdlc/<slug> && git commit -m "plan: <slug>"`.
2. Write a summary of 2–6 lines to a temp file, for someone deciding on a phone: what will change, the riskiest part, and how it'll be verified. The full plan is attached.
3. Post it: `sdlc request <slug> --summary-file <file>`.
4. Tell the owner it's on Desk and give them the link.
5. Wait without spending tokens: run `sdlc wait <slug>` as a **background** Bash command. It stays silent until the owner answers.

When it finishes, act on the first word of its output:

| Output | What to do |
|---|---|
| `approved` | Run `sdlc record <slug>`, commit `gates.json`, and go to step 3 |
| `changes` | Revise the plan as their note asks, then return to step 2 |
| `rejected` | Stop. Report it, and don't rewrite the plan on your own |
| `note` | The owner wrote without tapping Approve. Read it and do what it says. If they meant to approve, ask them to pick Approve on the thread and press Send, then run `sdlc wait` again |
| `mismatch` | The plan changed after posting. Return to step 2 |

An owner's answer only covers what that thread asked. Don't stretch it to anything else.

## 3. Build

1. Re-read the approved plan and work through **Decomposition** in order. Tick each box when its `Verify:` note holds. Ticking boxes and updating the `Status:` line don't void the approval.
2. If you delegate, give each agent a full packet, give parallel workers isolation, and check their work from tree diffs rather than `git status`. Shipping stays in the main session.
3. Commit as you go.
4. **If the plan turns out to be wrong, stop.** Changing its content cancels the approval, and the gate blocks further edits until a new one comes through. That's the point: go back to step 2 and say on Desk what you learned. Don't change the plan and restore it to slip past the gate.
5. Don't route around a block. If the gate blocks something, read why and follow what it says.

When the checklist is done, tell the owner the next step is `/sdlc:ship <slug>`.
