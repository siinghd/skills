---
name: research
description: Autonomous ML research loop for a "research lab" repo — survey, hypothesize, pre-register, run matched-compute experiments with seeds and a negative control, hostile review, log, decide, repeat. Use for any request to run an experiment, test a hypothesis, try a variant or ablation, reproduce a paper or a number, build a scaling ladder, profile and optimize a training/inference bottleneck, explain why a model behaves some way, or continue research from STATE.md. Also use when the user says "research", "experiment", "ablate", "reproduce", "baseline", "sweep", or drops a note in INBOX.md. Invoke as /research <topic> or bare /research to continue.
argument-hint: <topic, or empty to continue>
---

# /research — one full iteration, then go again

Topic: $ARGUMENTS

## Find or create the lab — no setup step for the human
1. `lab.json` in cwd or an ancestor → that is the lab. Work there.
2. Otherwise, if `~/research/` contains a lab whose lab.json `name` or STATE.md matches the
   topic → use it. If the topic is empty and exactly one lab exists → use it.
3. Otherwise create one: `${CLAUDE_SKILL_DIR}/scripts/init_lab.sh ~/research/<topic-slug>`.
   Never scaffold into a directory that already has code in it. If cwd is empty or a fresh
   repo, scaffold in place instead.
Run every `bin/` command from the lab root (`cd <lab> && bin/...`). When the lab is not the
session's cwd, run `bin/session_start.sh` yourself — the hook only fires inside the lab —
and tell the human the lab path once.

Topic empty and the lab has state → continue from STATE.md. No state at all → write 3
candidate directions with rationale to QUESTIONS.md and start on the strongest.

You are the researcher. The human is an advisor who is usually absent. Never block on them:
queue the question in QUESTIONS.md, state your assumption, proceed. The lab's CLAUDE.md
holds the non-negotiables; `bin/` holds the scripts that enforce them. Scripts win over memory.

## Session start
Run the ritual in CLAUDE.md (the SessionStart hook prints most of it). Collect finished jobs
with `bin/collect.sh` before anything else. Never re-run something already logged.

## Mode — pick one and name it in the log entry
- **OPTIMIZE** — make a known thing faster/cheaper/better. Profile first; roofline the workload;
  attack the measured bottleneck, never the assumed one.
- **UNDERSTAND** — explain why something works or fails. Output is a causal story backed by
  interventions (ablate, patch, probe), not correlations.
- **INVENT** — build a mechanism that doesn't exist. Existence proof first: the crudest hack
  that shows the phenomenon is real. Never optimize something you haven't shown exists.

## The loop (full protocol in [reference/loop.md](reference/loop.md))
0. **Calibrate** (once per topic) — reproduce one published number with `lib/`. Experiment
   000. Until the reference reproduces within its stated variance, nothing else counts.
1. **Survey** — ≤10 bullets with citations via a `scout` subagent, in parallel with any running
   job. Then the assumption audit: tag every design choice evidence-based / inherited /
   never-questioned. The last two are where discoveries live.
2. **Hunt anomalies** — ANOMALIES.md and prior plots outrank survey ideas.
3. **Generate ≥8 hypotheses** using ≥4 moves from
   [reference/hypothesis-moves.md](reference/hypothesis-moves.md). Each: mechanism, failure
   mode, cheapest killing experiment, predicted effect size. Write to IDEAS.md.
4. **Rank** — impact × P(works) / cost, then the so-what test. Pick 1–2.
5. **Pre-register** — `bin/new_experiment.sh`, fill PLAN.md (baseline, treatment, negative
   control, kill number, prediction), `bin/predict.py`, then `bin/prereg.sh`. No code before this.
6. **Run** — baseline reproduces first, then control, then treatment, same seeds, matched
   compute, smallest scale that can kill the idea. `bin/launch.sh` for anything long; update
   STATE.md; do useful work while waiting. Debug timebox: 2 h, then log and move on.
7. **Analyze** — `bin/report.py` is the only source of numbers. Every item of the silent-bug
   checklist in [reference/checklists.md](reference/checklists.md). Curves not endpoints,
   gap vs seed spread, predicted vs actual, one adversarial ablation, `bin/ladder.py` for
   survivors.
8. **Review** — dispatch the `research-reviewer` subagent with the experiment path. Resolve
   every objection or downgrade the claim. Nothing enters the log unreviewed.
9. **Write up** — append to RESEARCH_LOG.md using
   [reference/templates.md](reference/templates.md). FINDINGS bar met → add it. Killed →
   IDEAS.md Killed with the mechanistic reason.
10. **Decide** — win: scale or generalize. Kill with lesson: the lesson is the next hypothesis.
    5 kills with no learning → pivot proposal to QUESTIONS.md. Overwrite STATE.md. Report to
    the human in ≤10 lines: tested, happened, confidence, next. Then go again.

## Cost pattern
Literature search and log-file digging go to `scout`; code packets with a precise spec go to
`worker`; review goes to `research-reviewer`. Keep hypothesis generation, ranking, PLAN.md,
and interpretation at the session level — those are the judgment calls.
