#!/usr/bin/env python3
"""Report compute spend against the budget in lab.json.

Budget is a research constraint, not an accounting one: knowing the spend is
what turns "run a bigger sweep" into a question for the human (QUESTIONS.md)
instead of a reflex.
"""

from __future__ import annotations

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from _common import (  # noqa: E402
    experiments_dir, find_lab_root, fmt, lab_config, read_jsonl, resolve_exp,
)

UNSET = "budget: unset — fill lab.json"


def hours(run: dict) -> float:
    """gpu_hours when recorded; otherwise wall-clock, which is the honest floor."""
    gh = run.get("gpu_hours")
    if isinstance(gh, (int, float)) and not isinstance(gh, bool):
        return float(gh)
    ws = run.get("wall_s")
    if isinstance(ws, (int, float)) and not isinstance(ws, bool):
        return float(ws) / 3600.0
    return 0.0


def usage_by_exp(root: str) -> list[tuple[str, int, float]]:
    expdir = experiments_dir(root)
    out = []
    if not os.path.isdir(expdir):
        return out
    for name in sorted(os.listdir(expdir)):
        path = os.path.join(expdir, name, "runs.jsonl")
        if not os.path.isfile(path):
            continue
        runs = read_jsonl(path)
        out.append((name, len(runs), sum(hours(r) for r in runs)))
    return out


def main() -> int:
    ap = argparse.ArgumentParser(
        prog="budget.py",
        description="Sum compute hours per experiment and in total against lab.json.")
    ap.add_argument("--brief", action="store_true",
                    help="two lines, for the session-start hook")
    ap.add_argument("--exp", default=None, help="restrict to one experiment")
    args = ap.parse_args()

    root = find_lab_root()
    cfg = lab_config(root)
    per_exp_budget = cfg.get("budget_hours_per_experiment")
    total_budget = cfg.get("budget_hours_total")

    rows = usage_by_exp(root)
    if args.exp:
        wanted = resolve_exp(root, args.exp)
        rows = [r for r in rows if r[0] == wanted]

    total_used = sum(used for _, _, used in rows)
    over = [name for name, _, used in rows
            if per_exp_budget is not None and used > per_exp_budget]

    if args.brief:
        cap = fmt(total_budget) if total_budget is not None else "unset"
        flag = "  OVER BUDGET" if total_budget is not None and total_used > total_budget else ""
        print(f"compute: {fmt(total_used)} h used / {cap} h budget{flag}")
        if per_exp_budget is None:
            print(f"per-experiment {UNSET}")
        else:
            print(f"{len(over)} experiment(s) over the per-experiment budget "
                  f"of {fmt(per_exp_budget)} h")
        return 0

    print(f"== compute budget — {cfg.get('name', os.path.basename(root))} ==")
    if not rows:
        print("no runs logged yet")
    else:
        head = ("experiment", "runs", "hours", "of budget")
        table = [head]
        for name, n, used in rows:
            if per_exp_budget is None:
                share = "—"
            else:
                share = f"{fmt(used / per_exp_budget * 100)}%"
                if used > per_exp_budget:
                    share += "  OVER BUDGET"
            table.append((name, str(n), fmt(used), share))
        widths = [max(len(r[i]) for r in table) for i in range(len(head))]
        for idx, row in enumerate(table):
            print("  ".join(c.ljust(w) for c, w in zip(row, widths)).rstrip())
            if idx == 0:
                print("  ".join("-" * w for w in widths))

    print()
    if per_exp_budget is None:
        print(f"per-experiment {UNSET}")
    else:
        print(f"per-experiment budget: {fmt(per_exp_budget)} h")
    if total_budget is None:
        print(f"total {UNSET}")
        print(f"total used: {fmt(total_used)} h")
    else:
        line = f"total used: {fmt(total_used)} h / {fmt(total_budget)} h"
        if total_used > total_budget:
            line += "  OVER BUDGET"
        print(line)

    if over:
        print()
        print("OVER BUDGET (per experiment):")
        for name in over:
            print(f"  - {name}")
        print("A larger run goes to QUESTIONS.md, not to the GPU.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
