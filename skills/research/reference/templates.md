# Templates

PLAN.md and RESULT.md templates live in `templates/` and are copied by `bin/new_experiment.sh`.

## RESEARCH_LOG.md entry (append-only)
```
### NNN-slug — MODE — YYYY-MM-DD
Hypothesis: <one line>
Setup: <arms, scale, seeds, compute per arm, exp path>
Result (from report.py):
| arm | metric | n | mean ± std | compute |
|---|---|---|---|---|
Predicted vs actual: <predicted> vs <actual> (<error in std units>)
Control: passed | FAILED
Reviewer: ACCEPT | REVISE | REJECT — objections resolved: <n>/<m>
Interpretation: <2–4 lines; the mechanism story and what the evidence does to it>
Confidence: low | medium | high — would change it: <what>
Outcome: WIN → <next scale/setting> | KILL → <mechanistic reason> | INCONCLUSIVE → <why>
Next: <exact next action>
```

## FINDINGS.md entry (confirmed only)
```
### F<n>: <claim in one sentence>
Evidence: <exp ids>, n=<seeds> × <settings>, compute-matched, control passed, reviewer ACCEPT.
Conditions: <scale, data, architecture where it was shown; where it was NOT tested>
Effect: <mean ± std per setting; ladder verdict>
Confidence: medium | high
Falsified by: <a concrete observation that would demote this>
Status: active | DEMOTED <date> by <exp id> — <why>
```

## IDEAS.md entry
```
- [score 6.0] <one line>. Mechanism: ... Fails if: ... Kill test: <what, cost>. Predicted: <delta>.
```
Killed entries move to `## Killed` as:
```
- <one line> — killed by NNN-slug: <mechanistic reason>. Lesson: <what it taught>.
```
Parked entries move to `## Parked` with `— unpark when: <condition>`.

## ANOMALIES.md entry
```
- <date> NNN-slug: <what happened> | expected: <what> | plot: experiments/NNN/plots/<file>
  | status: open | explained by <exp id>
```

## QUESTIONS.md entry
```
- [ ] <date> <question>. Assumed: <what you did instead>. Impact if wrong: <what>.
```

## STATE.md
```
# STATE — <date time>
Running: <exp id> pid <n>, log experiments/NNN/train.log, collect with bin/collect.sh, ETA <t>
Hypothesis: <one line> (NNN-slug)
Next action: <one command or file>
Mid-task: <what was interrupted, if anything>
Blocked: <what, on what> | none
```

## INBOX.md (the human writes here; you move handled notes to INBOX_DONE.md)
```
- <date> <note from the human>
```
INBOX_DONE.md line: `- <date> <note> → <what you did / where it is logged>`
