# Hypothesis moves

Use at least four per iteration. Each move yields one-line hypotheses; each hypothesis gets a
mechanism, a failure mode, a cheapest killing experiment, and a predicted effect size.

- **First principles** — what must this computation do, minimally? Where is the slack between
  that and what the baseline actually does? (Bits that must flow, decisions that must be made,
  information that must be stored — and where the baseline spends more than that.)
- **Fermi** — FLOPs, bytes moved, tokens seen, memory traffic, parameter count per decision.
  Where is the real bottleneck? Is anyone attacking it? Roofline before opinion.
- **Invert an assumption** — take one `inherited` or `never-questioned` tag from the assumption
  audit and do the opposite.
- **Remove a component** — delete it entirely. If nothing changes, it was decorative and the
  compute is free to spend elsewhere.
- **Push a knob 100×** — not 2×. Extreme settings expose the mechanism; mild ones expose noise.
- **Combine two things never combined** — two known techniques whose mechanisms are
  orthogonal. Predict whether they add, saturate, or interfere.
- **Transfer from an adjacent field** — compression, control theory, signal processing,
  systems/caching, biology, economics, statistics. Name the analogy and where it breaks.
- **Oracle** — if you had a perfect X for free, what would you do with it? Now approximate X
  cheaply. (Perfect data ordering, perfect routing, perfect stopping, perfect init.)
- **Redundancy** — what is computed repeatedly that could be cached, shared, predicted, or
  skipped? Across layers, tokens, steps, seeds, epochs.
- **Failure localization** — where exactly does the baseline fail? Which examples, layers,
  positions, token types, training phases? Fix only that.
- **Unexploited signal** — what does the model already compute internally that the training
  signal ignores? Attention entropy, gradient agreement, loss variance, hidden-state norms.
- **Anomaly as mechanism** — take an entry from ANOMALIES.md and write the simplest mechanism
  that would produce it. Test the mechanism, not the anomaly.
- **Scale extrapolation** — what breaks first if you scale 10×? Data? Optimizer? Memory
  bandwidth? Attack that now at small scale.

Scoring each hypothesis in IDEAS.md:
```
- [score 6.0] <one line>. Mechanism: ... Fails if: ... Kill test: <what, cost>. Predicted: <metric delta>.
```
score = impact (1–5) × P(works) (0–1) / cost (GPU-hours, min 0.5).
