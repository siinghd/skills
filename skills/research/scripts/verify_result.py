#!/usr/bin/env python3
"""Check that every number in RESULT.md came from a logged run.

CLAUDE.md: no number appears in any .md unless a logged run produced it. This
finds typed-in numbers by building the set of everything report.py would print
-- by actually running report.py's renderers, so the two cannot drift -- and
listing anything in RESULT.md that is not in it.

A warning list for the reviewer: over-matching is deliberate, so a flagged
number is worth a look rather than proof of a fabrication.
"""

from __future__ import annotations

import argparse
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from _common import find_lab_root, resolve_exp  # noqa: E402
from report import build_model, render_md, render_text  # noqa: E402

# U+2212 MINUS SIGN as well as ASCII, because report output may be re-typeset.
NUM_RE = re.compile(r"[-−]?\d+(?:\.\d+)?")
DECIMAL_RE = re.compile(r"[-−]?\d+\.\d+")

# Lines whose numbers are structure, not results.
SKIP_PREFIXES = ("#", "Status:", "Date:", "Pre-registered plan hash matched:")
CHECKLIST_RE = re.compile(r"^\s*[-*]\s*\[[ xX]\]")
TABLE_RULE_RE = re.compile(r"^\s*\|?[\s:|-]+\|?\s*$")


def _to_float(token: str):
    try:
        return float(token.replace("−", "-"))
    except ValueError:
        return None


def _walk_numbers(obj, out: list[float]) -> None:
    """Collect every number anywhere in the report model."""
    if isinstance(obj, bool):
        return
    if isinstance(obj, (int, float)):
        out.append(float(obj))
    elif isinstance(obj, dict):
        for k, v in obj.items():
            _walk_numbers(k, out)
            _walk_numbers(v, out)
    elif isinstance(obj, (list, tuple, set)):
        for v in obj:
            _walk_numbers(v, out)


def collect_sources(model) -> list[float]:
    """Every number report.py could put on screen for this experiment."""
    sources: list[float] = []
    # 1. Whatever the renderers actually print, verbatim. Zero drift.
    for line in render_text(model) + render_md(model):
        for tok in NUM_RE.findall(line):
            val = _to_float(tok)
            if val is not None:
                sources.append(val)
    # 2. Every number in the model, including ones a renderer rounds or omits.
    _walk_numbers({k: v for k, v in model.items() if k != "runs"}, sources)
    # 3. Raw per-run values, so quoting a single seed's number is legitimate.
    for run in model["runs"]:
        for v in (run.get("metrics") or {}).values():
            sources.append(float(v))
        for key in ("wall_s", "flops", "gpu_hours", "seed"):
            if isinstance(run.get(key), (int, float)) and not isinstance(run.get(key), bool):
                sources.append(float(run[key]))
    return sources


def collect_ladder_sources(root, exp, model) -> list[float]:
    """Numbers ladder.py would print, for every (metric, numeric config key) pair.

    A pasted ladder table and its verdict line must count as sourced, or every
    survivor's RESULT.md fails review on the ladder threshold constant alone.
    """
    from ladder import build_ladder, render  # local import: ladder is optional here
    sources: list[float] = []
    metrics, size_keys = set(), set()
    for run in model["runs"]:
        metrics.update((run.get("metrics") or {}).keys())
        for k, v in (run.get("config") or {}).items():
            if _to_float(str(v)) is not None:
                size_keys.add(k)
    for metric in metrics:
        for key in size_keys:
            try:
                ladder = build_ladder(root, exp, metric, key)
            except Exception:  # a key that isn't a size axis; skip it
                continue
            for line in render(ladder):
                for tok in NUM_RE.findall(line):
                    val = _to_float(tok)
                    if val is not None:
                        sources.append(val)
            _walk_numbers(ladder, sources)
    return sources


def is_sourced(value: float, decimals: int, sources) -> bool:
    """Compare at the precision the number was written to.

    Someone who writes 2.2 means "2.2 to one decimal", so a source of 2.21
    sources it. Comparing at a coarser precision than written would let 9.99
    be sourced by a 10, which is exactly the fabrication this catches.
    """
    d = min(max(decimals, 1), 4)
    target, target_abs = round(value, d), round(abs(value), d)
    for v in sources:
        if round(v, d) == target or round(abs(v), d) == target_abs:
            return True
    return False


def main() -> int:
    ap = argparse.ArgumentParser(
        prog="verify_result.py",
        description="Flag numbers in RESULT.md that no logged run produced.")
    ap.add_argument("exp", help="experiment id or numeric prefix")
    ap.add_argument("--include-ints", action="store_true",
                    help="also check whole numbers (noisier: dates, counts, seeds)")
    ap.add_argument("--primary", default=None, help="primary metric passed to report.py")
    args = ap.parse_args()

    root = find_lab_root()
    exp = resolve_exp(root, args.exp)
    result_path = os.path.join(root, "experiments", exp, "RESULT.md")
    if not os.path.isfile(result_path):
        print(f"error: {result_path} does not exist", file=sys.stderr)
        return 1

    model = build_model(root, exp, primary=args.primary)
    if not model["runs"]:
        print(f"error: {exp} has no logged runs — every number in RESULT.md is unsourced",
              file=sys.stderr)
        return 1
    sources = collect_sources(model) + collect_ladder_sources(root, exp, model)
    pattern = NUM_RE if args.include_ints else DECIMAL_RE

    sourced, unsourced = 0, []
    with open(result_path, encoding="utf-8") as fh:
        for lineno, raw in enumerate(fh, 1):
            line = raw.rstrip("\n")
            stripped = line.strip()
            if (not stripped or stripped.startswith(SKIP_PREFIXES)
                    or CHECKLIST_RE.match(line) or TABLE_RULE_RE.match(line)):
                continue
            for tok in pattern.findall(line):
                val = _to_float(tok)
                if val is None:
                    continue
                decimals = len(tok.split(".")[1]) if "." in tok else 0
                if is_sourced(val, decimals, sources):
                    sourced += 1
                else:
                    unsourced.append((lineno, tok, stripped))

    print(f"SOURCED ({sourced})")
    if not unsourced:
        print("UNSOURCED: none")
        return 0
    print("UNSOURCED:")
    for lineno, tok, context in unsourced:
        if len(context) > 110:
            context = context[:107] + "..."
        print(f"  {result_path}:{lineno}: {tok}")
        print(f"      {context}")
    print(f"\n{len(unsourced)} number(s) in RESULT.md that no logged run produced.")
    print("Paste tables from `bin/report.py <exp> --md`; write \"untested\" rather than a guess.")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
