#!/usr/bin/env python3
"""Scaling ladder: does the effect grow, hold or wash out with scale?

An effect measured at one size says almost nothing about whether it matters.
CLAUDE.md makes a non-shrinking ladder a precondition for 'high' confidence,
so this reports the trend rather than a single-size win.

matplotlib is optional: --plot degrades to the table plus a note.
"""

from __future__ import annotations

import argparse
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from _common import (  # noqa: E402
    exp_path, find_lab_root, fmt, lower_is_better, mean, resolve_exp, runs_for,
    stdev,
)

MIN_SEEDS = 3
FLAT_FRACTION = 0.05  # |slope| below this share of the mean |effect| reads as flat


def _slope(xs, ys):
    """Least-squares slope of y on x. None when x has no spread."""
    n = len(xs)
    if n < 2:
        return None
    mx, my = sum(xs) / n, sum(ys) / n
    denom = sum((x - mx) ** 2 for x in xs)
    if denom == 0:
        return None
    return sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / denom


def build_ladder(root, exp, metric, size_key, baseline="baseline", treatment="treatment",
                 direction=None):
    runs = runs_for(root, exp)
    lower = lower_is_better(metric) if direction is None else direction

    # cells[(arm, size)] = [values]
    cells: dict[tuple[str, float], list[float]] = {}
    for r in runs:
        metrics = r.get("metrics") or {}
        if metric not in metrics:
            continue
        raw = (r.get("config") or {}).get(size_key)
        if raw is None:
            continue
        try:
            size = float(raw)  # config values may arrive as strings
        except (TypeError, ValueError):
            continue
        cells.setdefault((r.get("arm"), size), []).append(float(metrics[metric]))

    sizes = sorted({size for _, size in cells})
    rows = []
    for size in sizes:
        b, t = cells.get((baseline, size), []), cells.get((treatment, size), [])
        bm, tm = mean(b), mean(t)
        # Positive effect always means "treatment is better", whichever way the
        # metric runs, so the trend reads the same for loss and accuracy.
        if bm is None or tm is None:
            effect = None
        else:
            effect = (bm - tm) if lower else (tm - bm)
        rows.append({
            "size": size, "n_baseline": len(b), "n_treatment": len(t),
            "baseline_mean": bm, "treatment_mean": tm,
            "baseline_std": stdev(b), "treatment_std": stdev(t),
            "effect": effect,
        })

    usable = [r for r in rows
              if r["effect"] is not None
              and r["n_baseline"] >= MIN_SEEDS and r["n_treatment"] >= MIN_SEEDS
              and r["size"] > 0]

    verdict, slope, threshold = "insufficient", None, None
    if len(usable) >= 2 and len(usable) == len(rows):
        xs = [math.log(r["size"]) for r in usable]
        ys = [r["effect"] for r in usable]
        slope = _slope(xs, ys)
        if slope is not None:
            mean_abs = mean([abs(y) for y in ys]) or 0.0
            threshold = FLAT_FRACTION * mean_abs
            if abs(slope) <= threshold:
                verdict = "flat"
            elif slope > 0:
                verdict = "growing"
            else:
                verdict = "shrinking"

    reason = None
    if verdict == "insufficient":
        if len(sizes) < 2:
            reason = f"needs >=2 sizes with both arms, have {len(sizes)}"
        else:
            thin = [fmt(r["size"]) for r in rows
                    if r["n_baseline"] < MIN_SEEDS or r["n_treatment"] < MIN_SEEDS
                    or r["effect"] is None]
            reason = (f"cells with n<{MIN_SEEDS} or a missing arm at size(s): "
                      f"{', '.join(thin)}") if thin else "slope undefined"

    return {
        "exp": exp, "metric": metric, "size_key": size_key, "lower_is_better": lower,
        "baseline": baseline, "treatment": treatment,
        "rows": rows, "slope": slope, "threshold": threshold,
        "verdict": verdict, "reason": reason,
    }


def render(model) -> list[str]:
    m = model
    direction = "lower is better" if m["lower_is_better"] else "higher is better"
    out = [f"== {m['exp']} — scaling ladder on {m['metric']} ({direction}) ==",
           f"size key: config['{m['size_key']}']   "
           f"effect = {m['treatment']} better than {m['baseline']} by", ""]
    if not m["rows"]:
        out.append(f"no runs with both a '{m['metric']}' metric and config['{m['size_key']}'].")
        return out

    head = ("size", f"n({m['baseline']})", f"n({m['treatment']})",
            f"{m['baseline']} mean", f"{m['treatment']} mean", "effect")
    table = [head]
    for r in m["rows"]:
        table.append((fmt(r["size"]), str(r["n_baseline"]), str(r["n_treatment"]),
                      fmt(r["baseline_mean"]), fmt(r["treatment_mean"]), fmt(r["effect"])))
    widths = [max(len(row[i]) for row in table) for i in range(len(head))]
    for idx, row in enumerate(table):
        out.append("  ".join(c.ljust(w) for c, w in zip(row, widths)).rstrip())
        if idx == 0:
            out.append("  ".join("-" * w for w in widths))

    out.append("")
    if m["slope"] is not None:
        out.append(f"slope of effect vs log({m['size_key']}): {fmt(m['slope'])} "
                   f"(flat if |slope| <= {fmt(m['threshold'])})")
    out.append(f"VERDICT: {m['verdict']}" + (f" — {m['reason']}" if m["reason"] else ""))
    if m["verdict"] == "shrinking":
        out.append("A shrinking effect caps confidence below 'high' no matter how "
                   "clean the single-size win looks.")
    return out


def write_plot(model, root) -> tuple[str | None, str]:
    """Return (path, reason). A None path always comes with why, because
    'no plot' from a missing library and from missing data need different fixes."""
    rows = [r for r in model["rows"] if r["effect"] is not None]
    if not rows:
        return None, "no size has both arms measured, so there is nothing to plot"
    try:
        import matplotlib
        matplotlib.use("Agg")  # no display in a background agent session
        import matplotlib.pyplot as plt
    except ImportError:
        return None, "matplotlib is not importable; the table above is the result"

    outdir = exp_path(root, model["exp"], "plots")
    os.makedirs(outdir, exist_ok=True)
    path = os.path.join(outdir, f"ladder_{model['metric']}.png")

    fig, ax = plt.subplots(figsize=(6, 4))
    ax.plot([r["size"] for r in rows], [r["effect"] for r in rows], marker="o")
    ax.axhline(0, linewidth=0.8, color="grey")
    ax.set_xscale("log")
    ax.set_xlabel(model["size_key"])
    ax.set_ylabel(f"effect on {model['metric']} (positive = {model['treatment']} better)")
    ax.set_title(f"{model['exp']}: {model['verdict']}")
    fig.tight_layout()
    fig.savefig(path, dpi=120)
    plt.close(fig)
    return path, "written"


def main() -> int:
    ap = argparse.ArgumentParser(
        prog="ladder.py",
        description="Report whether an effect grows, holds or shrinks with scale.")
    ap.add_argument("exp", help="experiment id or numeric prefix")
    ap.add_argument("--metric", required=True)
    ap.add_argument("--size-key", default="params",
                    help="config key holding the scale (default: params)")
    ap.add_argument("--baseline", default="baseline")
    ap.add_argument("--treatment", default="treatment")
    ap.add_argument("--plot", action="store_true",
                    help="write plots/ladder_<metric>.png (needs matplotlib)")
    direction = ap.add_mutually_exclusive_group()
    direction.add_argument("--lower-is-better", dest="lower", action="store_true", default=None)
    direction.add_argument("--higher-is-better", dest="lower", action="store_false", default=None)
    args = ap.parse_args()

    root = find_lab_root()
    exp = resolve_exp(root, args.exp)
    model = build_ladder(root, exp, args.metric, args.size_key,
                         baseline=args.baseline, treatment=args.treatment,
                         direction=args.lower)
    print("\n".join(render(model)))

    if args.plot:
        path, reason = write_plot(model, root)
        print(f"plot: {path}" if path else f"plot: skipped — {reason}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
