# <NNN>-<slug> — PLAN

Mode: OPTIMIZE | UNDERSTAND | INVENT
Date:
Hypothesis (one line):
Mechanism (why it should work):
Failure mode (why it wouldn't):
Builds on: <FINDINGS ids or "none">

## Arms
- baseline: <config; reference number it must reproduce and its source>
- treatment: <config>
- control: <a variant that must NOT work, e.g. treatment applied to a random component,
  shuffled labels, treatment with its key term zeroed. Say why it must fail.>
Exact diff baseline → treatment (file/function level):

## Measurement
Primary metric:
Secondary metrics:
Held-out final eval (touched once, at writeup):
Seeds: <list, ≥3>
Matched compute per arm: <FLOPs or wall-clock and how it is enforced>
Scale: <model size / data size; the smallest that can kill the idea>
Time box: <hours>

## Kill criterion (a number, decided now)
Abandon if <metric> < baseline + <delta> at <checkpoint>.

## Prediction (log it with bin/predict.py before running)
<metric> for treatment: <number> (baseline expected: <number>). Rationale:
What result would surprise me most:

## Sanity checks before trusting anything
See checklists.md: loss at init, single-batch overfit, grad reach, eval mode, overlap, diff review.
