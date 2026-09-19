#!/usr/bin/env python3
"""The only sanctioned source of numbers for RESULT.md.

Result tables are pasted from this script, never typed, and verify_result.py
checks that every number in RESULT.md came from here. To make that check
airtight, the numbers are computed once in build_model() and rendered by
render_text()/render_md(); verify_result.py imports all three rather than
re-deriving anything, so the two can never disagree.
"""

from __future__ import annotations

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from _common import (  # noqa: E402
    find_lab_root, fmt, lab_config, lower_is_better, mean, predictions_for,
    resolve_exp, runs_for, stdev,
)

MIN_SEEDS = 3  # CLAUDE.md: anything entering FINDINGS needs >=3 seeds, mean +- std


def build_model(root, exp, primary=None, direction=None):
    """Compute every number this report will show. Pure: no printing."""
    runs = runs_for(root, exp)
    tolerance = lab_config(root).get("compute_tolerance", 0.10) or 0.10

    # Preserve first-seen order so the report reads in the order work happened.
    arms, metrics = [], []
    for r in runs:
        if r.get("arm") not in arms:
            arms.append(r.get("arm"))
        for m in (r.get("metrics") or {}):
            if m not in metrics:
                metrics.append(m)

    if primary is None:
        primary = metrics[0] if metrics else None
    if direction is None:
        lower = lower_is_better(primary) if primary else True
    else:
        lower = direction

    cells = {}
    for arm in arms:
        for metric in metrics:
            vals = [r["metrics"][metric] for r in runs
                    if r.get("arm") == arm and metric in (r.get("metrics") or {})]
            if not vals:
                continue
            cells[(arm, metric)] = {
                "n": len(vals), "values": vals,
                "mean": mean(vals), "std": stdev(vals),
                "reportable": len(vals) >= MIN_SEEDS,
            }

    compute = {}
    for arm in arms:
        arm_runs = [r for r in runs if r.get("arm") == arm]
        compute[arm] = {
            "n": len(arm_runs),
            "wall_s": mean([r.get("wall_s") for r in arm_runs]),
            "flops": mean([r.get("flops") for r in arm_runs]),
            "gpu_hours": mean([r.get("gpu_hours") for r in arm_runs]),
        }

    flags = []
    has_baseline = "baseline" in arms
    if runs and not has_baseline:
        flags.append("no 'baseline' arm: nothing to compare against, and the baseline "
                     "must reproduce a reference number before any treatment runs")

    # Matched compute. A step-matched comparison looks fair and is not.
    if has_baseline:
        for arm in arms:
            if arm == "baseline":
                continue
            for key in ("wall_s", "flops"):
                base, got = compute["baseline"][key], compute[arm][key]
                if base in (None, 0) or got is None:
                    continue
                rel = abs(got - base) / abs(base)
                if rel > tolerance:
                    flags.append(
                        f"compute mismatch: {arm} mean {key} {fmt(got)} vs baseline "
                        f"{fmt(base)} = {fmt(rel * 100)}% apart (tolerance "
                        f"{fmt(tolerance * 100)}%); this comparison is not matched-compute"
                    )

    dirty = [r for r in runs if r.get("git_dirty")]
    if dirty:
        flags.append(f"{len(dirty)} run(s) logged from a dirty working tree: "
                     "not reproducible from a commit")
    offplan = [r for r in runs if not r.get("plan_hash_ok", True)]
    if offplan:
        flags.append(f"{len(offplan)} run(s) logged with plan_hash_ok=false: "
                     "PLAN.md changed after pre-registration")

    # The negative control exists to catch a broken harness. If it wins, the
    # result is about the harness, not the idea.
    control_check = None
    if has_baseline and "control" in arms and primary:
        cb, cc = cells.get(("baseline", primary)), cells.get(("control", primary))
        if cb and cc and cb["mean"] is not None and cc["mean"] is not None:
            margin = (cb["mean"] - cc["mean"]) if lower else (cc["mean"] - cb["mean"])
            spread = max(cb["std"] or 0.0, cc["std"] or 0.0)
            beats = margin > spread
            control_check = {"margin": margin, "spread": spread, "beats": beats}
            if beats:
                flags.append(
                    f"negative control beats baseline on {primary} by {fmt(margin)} "
                    f"(> spread {fmt(spread)}): the harness is broken, not the idea"
                )

    gaps = []
    if has_baseline and primary:
        base_cell = cells.get(("baseline", primary))
        for arm in arms:
            if arm == "baseline":
                continue
            cell = cells.get((arm, primary))
            if not (base_cell and cell) or None in (base_cell["mean"], cell["mean"]):
                continue
            delta = cell["mean"] - base_cell["mean"]
            improvement = -delta if lower else delta
            spread = max(base_cell["std"] or 0.0, cell["std"] or 0.0)
            gaps.append({
                "arm": arm, "delta": delta, "improvement": improvement,
                "spread": spread, "separated": abs(delta) > spread,
            })

    predictions = []
    for p in predictions_for(root, exp):
        cell = cells.get((p.get("arm"), p.get("metric")))
        actual = cell["mean"] if cell else None
        std = (cell or {}).get("std")
        abs_err = None if actual is None or p.get("predicted") is None else abs(actual - p["predicted"])
        predictions.append({
            "arm": p.get("arm"), "metric": p.get("metric"),
            "predicted": p.get("predicted"),
            "baseline_expected": p.get("baseline_expected"),
            "actual": actual, "abs_err": abs_err,
            "err_in_std": (abs_err / std) if (abs_err is not None and std) else None,
            "rationale": p.get("rationale", ""),
        })

    return {
        "exp": exp, "runs": runs, "n_runs": len(runs),
        "arms": arms, "metrics": metrics, "cells": cells, "compute": compute,
        "primary": primary, "lower_is_better": lower, "tolerance": tolerance,
        "flags": flags, "gaps": gaps, "predictions": predictions,
        "control_check": control_check,
    }


def _cell_str(cell):
    """mean +- std, or the refusal to report a mean below the seed floor."""
    if cell is None:
        return "-"
    if not cell["reportable"]:
        return f"n={cell['n']}: not reportable"
    return f"{fmt(cell['mean'])} ± {fmt(cell['std'])}"


def _direction_words(model):
    return "lower is better" if model["lower_is_better"] else "higher is better"


def render_text(model) -> list[str]:
    m = model
    out = [f"== {m['exp']} — report ==",
           f"runs: {m['n_runs']}   primary metric: {m['primary']} ({_direction_words(m)})", ""]
    if not m["runs"]:
        out.append("no runs logged yet.")
        return out

    rows = [("arm", "metric", "n", "mean ± std")]
    for arm in m["arms"]:
        for metric in m["metrics"]:
            cell = m["cells"].get((arm, metric))
            if cell:
                rows.append((arm, metric, str(cell["n"]), _cell_str(cell)))
    out += _aligned(rows) + [""]

    out.append("compute per arm (means):")
    crows = [("arm", "runs", "wall_s", "flops", "gpu_hours")]
    for arm in m["arms"]:
        c = m["compute"][arm]
        crows.append((arm, str(c["n"]), fmt(c["wall_s"]), fmt(c["flops"]), fmt(c["gpu_hours"])))
    out += _aligned(crows) + [""]

    if m["gaps"]:
        out.append(f"gap vs spread on {m['primary']} (vs baseline):")
        for g in m["gaps"]:
            verdict = "separated" if g["separated"] else "WITHIN NOISE"
            out.append(f"  {g['arm']}: delta {fmt(g['delta'])}  spread {fmt(g['spread'])}  -> {verdict}")
        out.append("")

    if m["predictions"]:
        out.append("predicted vs actual:")
        prows = [("arm", "metric", "predicted", "actual", "abs err", "err/std")]
        for p in m["predictions"]:
            prows.append((p["arm"], p["metric"], fmt(p["predicted"]), fmt(p["actual"]),
                          fmt(p["abs_err"]), fmt(p["err_in_std"])))
        out += _aligned(prows) + [""]

    out.append("FLAGS: none" if not m["flags"] else "FLAGS:")
    for f in m["flags"]:
        out.append(f"  - {f}")
    return out


def render_md(model) -> list[str]:
    m = model
    out = [f"### {m['exp']} — report",
           "",
           f"`{m['n_runs']}` runs · primary metric **{m['primary']}** ({_direction_words(m)})",
           ""]
    if not m["runs"]:
        out.append("No runs logged yet.")
        return out

    out += ["| arm | metric | n | mean ± std |", "| --- | --- | --- | --- |"]
    for arm in m["arms"]:
        for metric in m["metrics"]:
            cell = m["cells"].get((arm, metric))
            if cell:
                out.append(f"| {arm} | {metric} | {cell['n']} | {_cell_str(cell)} |")
    out += ["", "| arm | runs | mean wall_s | mean flops | mean gpu_hours |",
            "| --- | --- | --- | --- | --- |"]
    for arm in m["arms"]:
        c = m["compute"][arm]
        out.append(f"| {arm} | {c['n']} | {fmt(c['wall_s'])} | {fmt(c['flops'])} | "
                   f"{fmt(c['gpu_hours'])} |")

    if m["gaps"]:
        out += ["", f"**Gap vs spread on {m['primary']}**", "",
                "| arm | delta vs baseline | spread | separated? |",
                "| --- | --- | --- | --- |"]
        for g in m["gaps"]:
            out.append(f"| {g['arm']} | {fmt(g['delta'])} | {fmt(g['spread'])} | "
                       f"{'yes' if g['separated'] else 'no — within noise'} |")

    if m["predictions"]:
        out += ["", "**Predicted vs actual**", "",
                "| arm | metric | predicted | actual | abs err | err/std |",
                "| --- | --- | --- | --- | --- | --- |"]
        for p in m["predictions"]:
            out.append(f"| {p['arm']} | {p['metric']} | {fmt(p['predicted'])} | "
                       f"{fmt(p['actual'])} | {fmt(p['abs_err'])} | {fmt(p['err_in_std'])} |")

    out += [""]
    if not m["flags"]:
        out.append("**FLAGS:** none")
    else:
        out.append("**FLAGS:**")
        out += [f"- {f}" for f in m["flags"]]
    return out


def _aligned(rows):
    widths = [max(len(str(r[i])) for r in rows) for i in range(len(rows[0]))]
    out = []
    for idx, row in enumerate(rows):
        out.append("  ".join(str(c).ljust(w) for c, w in zip(row, widths)).rstrip())
        if idx == 0:
            out.append("  ".join("-" * w for w in widths))
    return out


def main() -> int:
    ap = argparse.ArgumentParser(
        prog="report.py",
        description="Report an experiment's runs. The only sanctioned source of "
                    "numbers for RESULT.md — paste, never retype.")
    ap.add_argument("exp", help="experiment id or numeric prefix")
    ap.add_argument("--md", action="store_true",
                    help="emit GitHub Markdown tables (what gets pasted into RESULT.md)")
    ap.add_argument("--primary", default=None,
                    help="primary metric (default: first metric seen in runs.jsonl)")
    direction = ap.add_mutually_exclusive_group()
    direction.add_argument("--lower-is-better", dest="lower", action="store_true", default=None)
    direction.add_argument("--higher-is-better", dest="lower", action="store_false", default=None)
    args = ap.parse_args()

    root = find_lab_root()
    exp = resolve_exp(root, args.exp)
    model = build_model(root, exp, primary=args.primary, direction=args.lower)
    print("\n".join(render_md(model) if args.md else render_text(model)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
