#!/usr/bin/env python3
"""Append one run to an experiment's runs.jsonl.

This is the only sanctioned way a number enters the lab. It refuses to record a
run whose PLAN.md is unregistered or has changed since pre-registration, because
a plan that can be edited after seeing results is not a plan.

Importable as well as runnable:
    from log_run import log_run
    log_run("003", "treatment", seed=0, metrics={"val_loss": 2.21}, wall_s=130)
"""

from __future__ import annotations

import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from _common import (  # noqa: E402
    append_jsonl, config_hash, die, exp_path, find_lab_root, git_dirty, git_sha,
    now_iso, read_status, resolve_exp, sha256_file, warn, write_status,
)

UNREGISTERED_MSG = (
    "Kill criteria and predictions are pre-registered with bin/prereg.sh BEFORE any run.\n"
    "       No .prereg for {exp}: this run has no plan to be measured against.\n"
    "       Run: bin/prereg.sh {exp}"
)
CHANGED_MSG = (
    "PLAN.md has changed since it was pre-registered.\n"
    "       Changing the plan = a new experiment (bin/new_experiment.sh), not an edit.\n"
    "       registered sha256: {want}\n"
    "       current    sha256: {have}\n"
    "       Use --force only to record a run you already know is off-plan; it is\n"
    "       written with plan_hash_ok=false and report.py will flag it."
)


def _plan_hash_ok(root: str, exp: str) -> tuple[bool, str | None, str | None]:
    """Return (ok, registered_hash, current_hash). registered is None if unregistered."""
    current = sha256_file(exp_path(root, exp, "PLAN.md"))
    try:
        with open(exp_path(root, exp, ".prereg"), encoding="utf-8") as fh:
            registered = json.load(fh).get("plan_sha256")
    except (OSError, json.JSONDecodeError):
        return False, None, current
    return (registered == current and current is not None), registered, current


def log_run(exp, arm, seed, metrics, wall_s=None, flops=None, gpu_hours=None,
            config=None, note="", force=False, root=None):
    """Append a run and return the record that was written."""
    root = root or find_lab_root()
    exp = resolve_exp(root, str(exp))

    if wall_s is None and flops is None:
        die("a run needs wall_s or flops: comparisons are matched-compute, never matched-steps")

    ok, registered, current = _plan_hash_ok(root, exp)
    if not ok and not force:
        if registered is None:
            die(UNREGISTERED_MSG.format(exp=exp), code=2)
        die(CHANGED_MSG.format(want=registered, have=current), code=2)
    if not ok:
        warn(f"{exp}: recording with plan_hash_ok=false (--force)")

    dirty = git_dirty(root)
    if dirty:
        warn(f"{exp}: working tree is dirty — this run is not reproducible from a commit")

    record = {
        "ts": now_iso(),
        "exp": exp,
        "arm": arm,
        "seed": int(seed),
        "config_hash": config_hash(config, arm),
        "config": config or {},
        "metrics": {k: float(v) for k, v in dict(metrics).items()},
        "flops": None if flops is None else float(flops),
        "wall_s": None if wall_s is None else float(wall_s),
        "gpu_hours": None if gpu_hours is None else float(gpu_hours),
        "git_sha": git_sha(root),
        "git_dirty": dirty,
        "plan_hash_ok": ok,
        "note": note or "",
    }
    append_jsonl(exp_path(root, exp, "runs.jsonl"), record)

    # A queued experiment that is producing runs is, by definition, running.
    if read_status(root, exp) == "queued":
        write_status(root, exp, "running")

    return record


def _kv(pairs, coerce_numbers: bool):
    """Parse repeated k=v arguments into a dict."""
    out = {}
    for item in pairs or []:
        if "=" not in item:
            die(f"expected k=v, got '{item}'")
        k, v = item.split("=", 1)
        if coerce_numbers:
            out[k] = float(v)
        else:
            # JSON where it parses (numbers, true, null), plain string otherwise.
            try:
                out[k] = json.loads(v)
            except json.JSONDecodeError:
                out[k] = v
    return out


def main() -> int:
    ap = argparse.ArgumentParser(
        prog="log_run.py",
        description="Append a run to experiments/<exp>/runs.jsonl.",
        epilog="Example: log_run.py 003 --arm treatment --seed 0 "
               "--metric val_loss=2.21 --wall-s 130",
    )
    ap.add_argument("exp", help="experiment id or numeric prefix")
    ap.add_argument("--arm", required=True,
                    help="arm name; 'baseline', 'treatment' and 'control' have meaning")
    ap.add_argument("--seed", required=True, type=int)
    ap.add_argument("--metric", action="append", required=True, metavar="K=V",
                    help="metric, repeatable (--metric val_loss=2.21)")
    ap.add_argument("--wall-s", type=float, default=None, help="wall-clock seconds")
    ap.add_argument("--flops", type=float, default=None, help="FLOPs for the run")
    ap.add_argument("--gpu-hours", type=float, default=None)
    ap.add_argument("--config-file", default=None, help="JSON file with the run config")
    ap.add_argument("--config", action="append", metavar="K=V",
                    help="config entry, repeatable")
    ap.add_argument("--note", default="")
    ap.add_argument("--force", action="store_true",
                    help="record even though the plan is unregistered or changed "
                         "(records plan_hash_ok=false)")
    args = ap.parse_args()

    if args.wall_s is None and args.flops is None:
        ap.error("one of --wall-s or --flops is required "
                 "(comparisons are matched-compute, never matched-steps)")

    config = None
    if args.config_file:
        try:
            with open(args.config_file, encoding="utf-8") as fh:
                config = json.load(fh)
        except (OSError, json.JSONDecodeError) as exc:
            die(f"cannot read --config-file {args.config_file}: {exc}")
    if args.config:
        config = {**(config or {}), **_kv(args.config, coerce_numbers=False)}

    rec = log_run(
        args.exp, args.arm, args.seed, _kv(args.metric, coerce_numbers=True),
        wall_s=args.wall_s, flops=args.flops, gpu_hours=args.gpu_hours,
        config=config, note=args.note, force=args.force,
    )
    metrics = " ".join(f"{k}={v}" for k, v in rec["metrics"].items())
    print(f"logged {rec['exp']} {rec['arm']} seed={rec['seed']} {metrics}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
