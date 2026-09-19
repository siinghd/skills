#!/usr/bin/env python3
"""Log a prediction before its run exists.

A prediction recorded after the measurement is not a prediction. This script
refuses to append one for an arm+metric that has already been measured, which
is the only mechanical way to keep predictions.jsonl honest enough to compute
calibration from.
"""

from __future__ import annotations

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from _common import (  # noqa: E402
    append_jsonl, die, find_lab_root, git_sha, now_iso, resolve_exp, runs_for,
)


def main() -> int:
    ap = argparse.ArgumentParser(
        prog="predict.py",
        description="Append a pre-run prediction to predictions.jsonl.",
        epilog="Example: predict.py 003 --arm treatment --metric val_loss "
               '--predicted 2.2 --baseline-expected 2.3 --rationale "residual path is the bottleneck"',
    )
    ap.add_argument("exp", help="experiment id or numeric prefix (003 or 003-slug)")
    ap.add_argument("--arm", required=True, help="arm the prediction is about")
    ap.add_argument("--metric", required=True, help="metric name")
    ap.add_argument("--predicted", required=True, type=float, help="predicted value")
    ap.add_argument("--baseline-expected", type=float, default=None,
                    help="what the baseline is expected to score on the same metric")
    ap.add_argument("--rationale", required=True,
                    help="why — the mechanism, not a restatement of the number")
    args = ap.parse_args()

    root = find_lab_root()
    exp = resolve_exp(root, args.exp)

    for run in runs_for(root, exp):
        if run.get("arm") == args.arm and args.metric in (run.get("metrics") or {}):
            die(
                f"{exp} already has a logged run for arm '{args.arm}' with metric "
                f"'{args.metric}'.\n"
                "       A prediction must precede its measurement — "
                "predictions.jsonl is the calibration record.\n"
                "       If this is a genuinely new prediction, it belongs to a new experiment.",
                code=2,
            )

    append_jsonl(os.path.join(root, "predictions.jsonl"), {
        "ts": now_iso(),
        "exp": exp,
        "arm": args.arm,
        "metric": args.metric,
        "predicted": args.predicted,
        "baseline_expected": args.baseline_expected,
        "rationale": args.rationale,
        "git_sha": git_sha(root),
    })

    base = "" if args.baseline_expected is None else f" (baseline expected {args.baseline_expected})"
    print(f"predicted {exp} {args.arm} {args.metric} = {args.predicted}{base}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
