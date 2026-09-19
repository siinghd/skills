# Checklists

## Silent-bug checklist — every item, every time, before believing a win
- [ ] Loss at init ≈ expected (e.g. ln(vocab) for LM cross-entropy). Off → init or masking bug.
- [ ] Overfits a single batch to ~0 loss. Can't → gradient/optimizer/data-pipeline bug.
- [ ] Gradient reaches every parameter (assert no param has grad None or all-zero after a step).
- [ ] Shapes asserted at module boundaries; broadcasting can't silently reshape.
- [ ] Eval mode toggled (dropout, norm statistics); eval is deterministic across two calls.
- [ ] Loader shuffles train; zero overlap between train and eval shards (hash-check a sample).
- [ ] Treatment diff reviewed line by line against baseline. Only the intended change differs.
- [ ] Compute actually matched: report.py shows no compute flag.
- [ ] Negative control did not win. If it did, stop; the harness is broken.
- [ ] Seeds differ across seed runs (config_hash same, seed different, metrics not identical).
- [ ] dtype unchanged between arms (a silent fp32→bf16 change is a "speedup").
- [ ] Same tokenizer, same data, same eval script for every arm.

## Confound checklist
- Did treatment get more hyperparameter search, warmup, data, or a better init than baseline?
- Was the baseline tuned as hard as the treatment? By whom, and is it logged?
- Does the improvement survive when the primary metric is swapped for a secondary one?
- Does it survive a different seed set entirely?
- Does it survive on the held-out final eval (touched once)?

## Adversarial ablation — pick at least one (log as `--arm ablation-<what>` in the same experiment)
- Randomize the treatment's key component (random routing, random mask, shuffled gate).
- Apply the treatment to the wrong place (wrong layer, wrong tensor). It should not help.
- Halve the treatment's compute and give it to the baseline instead.
- Remove the part of the treatment the mechanism story says matters. Effect should vanish.

## Scaling ladder
- 3 model (or data) sizes spanning ≥10×. Same arms, ≥3 seeds per cell.
- `bin/ladder.py NNN --metric <primary> --plot`. Verdict: growing / flat / shrinking.
- Shrinking → probably an artifact of small scale; Parked unless the mechanism predicts it.
- Flat → real but bounded; report the bound.
- Growing → the prize. Generalize to a second setting before FINDINGS.

## STATE.md checklist (overwrite before any long job and at session end)
- Running jobs: exp id, pid, how to collect, expected finish.
- Current hypothesis and experiment id.
- Exact next action (a command or a file to edit).
- What you were in the middle of, if interrupted.
- Anything blocked and on what.
