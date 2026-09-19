# The research loop — full protocol

Every step names the script that enforces it. If a step and a script disagree, the script is
right and the step text is stale; fix the text.

## Phase 0 — Calibrate (once per topic, experiment 000)
Pick one published result in the area with a concrete number (a loss at a token count, an
accuracy on a benchmark, a throughput). Reproduce it. Build `lib/` as needed: a minimal
train/eval/log harness that calls `bin/log_run.py` for every run and can express a negative
control. Log it as `000-reproduce-<paper>`, with the reference number and its stated variance
in PLAN.md as the prediction. Until you match within that variance, nothing else counts: a
harness that can't reproduce known results can't discover new ones. Write `lib/` tests for the
pieces that silently break (masking, loss reduction, eval mode, shuffling) and run them before
every experiment.

If calibration fails for >2 h of debugging, log the state to ANOMALIES.md and STATE.md, pick a
simpler reference number, and queue the question.

## 1. Survey
Dispatch `scout` with the topic; ask for ≤10 bullets with citations and the concrete numbers
papers report. Run it in parallel with anything training. Then do the assumption audit
yourself: list every design choice in the standard approach (norm, init, schedule, loss,
tokenizer, attention form, positional encoding, data mix, batch size, eval protocol, ...) and
tag each `evidence-based` / `inherited` / `never-questioned`. Write the audit to IDEAS.md.

## 2. Hunt anomalies
Read ANOMALIES.md and the plots from prior experiments. A bump, a plateau, a run that
shouldn't have worked, a metric that moved the wrong way, a control that did too well — each
is a hypothesis generator and evidence the current model of the problem is wrong. Anomalies
outrank ideas from the survey.

## 3. Generate ≥8 hypotheses
Use at least four moves from hypothesis-moves.md. Each hypothesis is one line plus:
mechanism (why it works), failure mode (why it wouldn't), the cheapest experiment that
kills it, and a predicted effect size as a number. Build on FINDINGS.md wherever possible —
compounding beats novelty. Write all of them to IDEAS.md `## Open`, scored.

## 4. Rank
Score = impact × P(works) / cost. Then two filters:
- So-what: "if this held at 10× scale, who changes what they do?" No answer → deprioritize.
- Information value: "what do I learn if it fails?" Nothing → deprioritize.
Pick 1–2. Prefer the one whose killing experiment is cheapest.

## 5. Pre-register — before any code
1. `bin/new_experiment.sh <slug>` → `experiments/NNN-slug/PLAN.md` from the template.
2. Fill PLAN.md: baseline config, treatment config, exact diff, a **negative control** arm
   (a treatment that must NOT work: applied to a random component, with its key term zeroed,
   shuffled labels), primary/secondary metrics, held-out final eval, seeds (≥3), matched
   compute budget, scale, time box, kill criterion as a number, prediction as a number.
3. `bin/predict.py NNN --arm treatment --metric <primary> --predicted X --baseline-expected Y
   --rationale "..."`. Wrong predictions are the most informative outcome; log them honestly.
4. `bin/prereg.sh NNN` — commits PLAN.md and records its hash. `bin/log_run.py` refuses runs
   against an edited plan. Need to change the plan? New experiment.

## 6. Run
- Baseline first. It must reproduce the number in PLAN.md. Then control. Then treatment, same
  seeds. Log every run with `bin/log_run.py` (or `from log_run import log_run` inside `lib/`).
- Smallest scale that can kill the idea. Compute is matched per arm in FLOPs or wall-clock;
  `bin/report.py` flags a mismatch above the tolerance in lab.json.
- Long jobs: `bin/launch.sh NNN -- <cmd>`. It survives session death. Overwrite STATE.md
  immediately with how to collect. Then do useful work: survey, next PLAN.md, lib tests. Never
  sit polling; if nothing is useful to do, end the session with STATE.md current.
- Debug timebox: 2 h on a harness bug, then log it and move to the next-best action.
- Budget: check `bin/budget.py` before launching. Over budget → QUESTIONS.md, not the GPU.

## 7. Analyze
- `bin/report.py NNN --md` — paste its table into RESULT.md. Never type a number.
- Silent-bug checklist (checklists.md), every item, every time, before believing a win.
- Curves, not endpoints. First 5% and last 5% of training separately. Save plots to
  `experiments/NNN/plots/` and reference them by path.
- Gap vs spread: is the treatment−baseline gap larger than the seed-to-seed std? report.py
  prints this. If not, the result is "no detectable effect at this n", not "small win".
- Control: if the control arm beats baseline, the harness is broken. Stop, fix, re-run all arms.
- Prediction vs actual: report.py joins predictions.jsonl. A gap > 2 std either way means
  the model of the problem is wrong — write down how, in RESULT.md.
- Confounds: did treatment get more tuning, warmup, data, a better init, a different eval?
- One adversarial ablation designed to make the win disappear. Log it into the SAME
  experiment's runs.jsonl as `--arm ablation-<what>` so report.py and verify_result.py see it.
  Record it even when it doesn't.
- Survivor → scaling ladder: 3 sizes, `bin/ladder.py NNN --metric <primary> --plot`.
  Shrinking effect is probably dead. Growing is the prize. Log the trend either way.
- Anything weird → ANOMALIES.md with exp id, plot path, expected vs observed.

## 8. Review
Fill RESULT.md (template). Dispatch `research-reviewer` with the experiment path. It runs
`bin/verify_result.py` and `bin/report.py`, recomputes a number from raw logs, reads the diff,
and returns ACCEPT / REVISE / REJECT with numbered objections. Resolve each in RESULT.md or
downgrade the claim and confidence. REJECT → the result does not enter RESEARCH_LOG.md as a
finding; it enters as a kill or an anomaly.

## 9. Write up
Append the log entry (templates.md) to RESEARCH_LOG.md. `bin/finish.sh NNN` if the runs were
foreground (launch.sh sets status itself). Commit. Meets the FINDINGS bar
(≥3 seeds, ≥2 settings, matched compute, control passed, ACCEPT) → add a FINDINGS entry.
Killed → IDEAS.md `## Killed` with the mechanistic reason, never "didn't work". Budget-limited
or blocked → `## Parked` with what would unpark it.

## 10. Decide
- Win → scale up (ladder) or generalize to a second setting. Both before FINDINGS.
- Kill with a lesson → the lesson is the next hypothesis.
- Kill without a lesson → next from IDEAS.md by score.
- 5 consecutive kills with no learning → the direction is wrong. Pivot proposal to
  QUESTIONS.md with 3 alternatives; take the next-best direction meanwhile.
- Calibration check every 5 experiments: are prediction errors shrinking? If not, the
  mechanism stories are decorative. Say so in the log.
Overwrite STATE.md. Report to the human in ≤10 lines: tested, happened, confidence, next.
Then go again.
