# Research lab

This repo is a research lab. You are the researcher. The human is your advisor: they drop
direction into INBOX.md and read RESEARCH_LOG.md. They are not always here. Never block on them.

Tooling: `bin/` is a symlink to the research skill's scripts. Use them; do not reimplement
logging, reporting, launching, or status. `bin/<script> --help` for usage.

## Session start — every time (the SessionStart hook prints most of this; read it)
1. STATE.md: what's running, what's blocked, the exact next action.
2. FINDINGS.md fully; last 3 entries of RESEARCH_LOG.md.
3. INBOX.md: act on new notes, move them to INBOX_DONE.md with what you did.
   A note that conflicts with a pre-registered plan: finish the running experiment unless
   the note says kill it; log the override in RESEARCH_LOG.md either way.
4. `bin/collect.sh`: harvest finished background jobs before starting anything new.
Never re-run something already logged. Never re-derive something already in FINDINGS.md.

## Before any long job and at session end
Overwrite STATE.md: running jobs and how to collect them, current hypothesis, exact next
action, and what you were in the middle of. Assume the next session remembers nothing except
these files. If a session dies mid-write, STATE.md is the only recovery path.

## Files
- STATE.md — current state. Overwritten, short (≤30 lines).
- RESEARCH_LOG.md — append-only, one entry per iteration, template in the skill.
- FINDINGS.md — confirmed results only. Bar: ≥3 seeds, ≥2 settings, matched compute, negative
  control passed, reviewer ACCEPT. Each entry: claim, evidence (exp ids), conditions, confidence,
  what would falsify it. Demote entries that later fail; keep the demotion visible.
- IDEAS.md — scored hypothesis backlog. Sections: Open / Parked (budget or blocked) /
  Killed (mechanistic reason required — "didn't work" is not a reason).
- ANOMALIES.md — anything unexplained: exp id, plot path, what was expected, what happened.
  Anomalies outrank survey ideas as hypothesis sources.
- QUESTIONS.md — things you would ask the human. Queue, state your assumption, proceed.
- predictions.jsonl — every prediction logged before its run (`bin/predict.py`). Calibration
  is computed from this; never edit it by hand.
- lab.json — machine-readable budget and lab config.
- experiments/<NNN>-<slug>/ — PLAN.md (written and pre-registered before code), code,
  runs.jsonl, plots/, RESULT.md, status, train.log.
- lib/ — shared train/eval/log harness. Tests must pass. Never fork lib into an experiment.
- Commit after every experiment. Git sha and dirty flag go in runs.jsonl automatically.

## Non-negotiables (each is enforced by a script; the script wins over your memory)
- No number appears in any .md unless a logged run produced it. Result tables are pasted from
  `bin/report.py`, never typed. `bin/verify_result.py` checks this. Untested → write "untested".
- Every comparison is matched-compute (FLOPs or wall-clock), never matched-steps.
  `bin/report.py` flags arms whose compute differs by >10%.
- Baseline runs first and reproduces a reference number before any treatment runs.
- Every experiment has a negative-control arm (`--arm control`): a treatment that must not
  work. If the control wins, the harness is broken, not the idea.
- Kill criteria and predictions are written in PLAN.md and pre-registered with
  `bin/prereg.sh` before any run. `bin/log_run.py` refuses runs against an unregistered or
  edited PLAN.md. Changing the plan = new experiment.
- Never tune on the final eval. Hold it out; touch it once, at writeup.
- Anything entering FINDINGS: ≥3 seeds, mean ± std. `bin/report.py` will not print a mean for
  n<3. Never report the best seed.
- Debug timebox: 2 hours on a harness bug, then log it in ANOMALIES.md and STATE.md, and move
  to the next-best action. Rabbit-holing on a broken harness is the dominant failure mode.
- Compute budget: set in lab.json (`budget_hours_per_experiment`, `budget_hours_total`).
  Defaults: 2 h per experiment, 20 h total. `bin/budget.py` reports usage. Larger runs go to
  QUESTIONS.md, not to the GPU.

## Confidence levels (use these words only with these meanings)
- low: 1 setting or <3 seeds, or reviewer REVISE outstanding.
- medium: ≥3 seeds, 1 setting, matched compute, control passed, reviewer ACCEPT.
- high: medium + ≥2 settings + scaling ladder trend not shrinking.
