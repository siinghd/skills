"""Shared helpers for the research-lab scripts.

Everything here exists so that report.py and verify_result.py cannot drift apart:
they must agree on where the lab is, how an experiment id resolves, and — above
all — how a number is rounded for printing. If the rounding differed by one digit,
verify_result.py would flag every honestly-sourced number in RESULT.md.

Python 3.12 stdlib only.
"""

from __future__ import annotations

import hashlib
import json
import os
import subprocess
import sys
from datetime import datetime, timezone

LAB_MARKER = "lab.json"

# Metric names containing these substrings are lower-is-better. Used by report.py
# (control-beats-baseline flag) and ladder.py (sign of the effect).
LOWER_IS_BETTER_HINTS = (
    "loss", "ppl", "perplexity", "error", "err", "time", "latency",
)


# --------------------------------------------------------------------------
# formatting
# --------------------------------------------------------------------------

def fmt(x, placeholder: str = "n/a") -> str:
    """The one number->string function for the whole toolchain.

    Four decimal places, trailing zeros stripped, so 2.21 prints as "2.21" and
    100.0 prints as "100". verify_result.py re-parses these strings and matches
    them back at 1-4 decimal roundings, so any change here must be made once.
    """
    if x is None:
        return placeholder
    try:
        r = round(float(x), 4)
    except (TypeError, ValueError):
        return placeholder
    if r == 0:  # collapse -0.0, which would otherwise print as "-0"
        return "0"
    s = f"{r:.4f}".rstrip("0").rstrip(".")
    return s if s else "0"


# --------------------------------------------------------------------------
# lab layout
# --------------------------------------------------------------------------

def find_lab_root(start: str | None = None) -> str:
    """Walk up from `start` (default cwd) to the directory holding lab.json."""
    cur = os.path.abspath(start or os.getcwd())
    while True:
        if os.path.isfile(os.path.join(cur, LAB_MARKER)):
            return cur
        parent = os.path.dirname(cur)
        if parent == cur:
            die(f"not inside a research lab: no {LAB_MARKER} in {os.getcwd()} or any parent")
        cur = parent


def lab_config(root: str) -> dict:
    try:
        with open(os.path.join(root, LAB_MARKER), encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, json.JSONDecodeError) as exc:
        die(f"cannot read {LAB_MARKER}: {exc}")


def experiments_dir(root: str) -> str:
    return os.path.join(root, "experiments")


def resolve_exp(root: str, ident: str) -> str:
    """Accept a full id ('003-slug') or the bare numeric prefix ('3', '003')."""
    expdir = experiments_dir(root)
    if not os.path.isdir(expdir):
        die(f"no experiments/ directory in {root}")
    names = sorted(n for n in os.listdir(expdir) if os.path.isdir(os.path.join(expdir, n)))
    if ident in names:
        return ident
    key = ident.strip().lstrip("/").rstrip("/")
    # bare prefix: zero-pad so `3`, `03` and `003` all find 003-slug
    if key.isdigit():
        key = key.zfill(3)
    matches = [n for n in names if n == key or n.startswith(key + "-")]
    if len(matches) == 1:
        return matches[0]
    if not matches:
        die(f"no experiment matching '{ident}' in {expdir} (have: {', '.join(names) or 'none'})")
    die(f"'{ident}' is ambiguous: {', '.join(matches)}")


def exp_path(root: str, exp_id: str, *parts: str) -> str:
    return os.path.join(experiments_dir(root), exp_id, *parts)


def read_status(root: str, exp_id: str) -> str:
    try:
        with open(exp_path(root, exp_id, "status"), encoding="utf-8") as fh:
            return fh.read().strip()
    except OSError:
        return "unknown"


def write_status(root: str, exp_id: str, status: str) -> None:
    with open(exp_path(root, exp_id, "status"), "w", encoding="utf-8") as fh:
        fh.write(status + "\n")


# --------------------------------------------------------------------------
# jsonl
# --------------------------------------------------------------------------

def read_jsonl(path: str) -> list[dict]:
    """Read a .jsonl file, skipping blank lines. Missing file -> []."""
    rows: list[dict] = []
    if not os.path.isfile(path):
        return rows
    with open(path, encoding="utf-8") as fh:
        for lineno, line in enumerate(fh, 1):
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError as exc:
                warn(f"{path}:{lineno}: skipping unparseable line ({exc})")
    return rows


def append_jsonl(path: str, obj: dict) -> None:
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(obj, sort_keys=False) + "\n")


def runs_for(root: str, exp_id: str) -> list[dict]:
    return read_jsonl(exp_path(root, exp_id, "runs.jsonl"))


def predictions_for(root: str, exp_id: str) -> list[dict]:
    rows = read_jsonl(os.path.join(root, "predictions.jsonl"))
    return [r for r in rows if r.get("exp") in (exp_id, exp_id.split("-", 1)[0])]


# --------------------------------------------------------------------------
# hashing, git, time
# --------------------------------------------------------------------------

def sha256_file(path: str) -> str | None:
    try:
        with open(path, "rb") as fh:
            return hashlib.sha256(fh.read()).hexdigest()
    except OSError:
        return None


def config_hash(config: dict | None, fallback: str) -> str:
    """Hash the canonical form of the config; fall back to hashing the arm name."""
    payload = json.dumps(config, sort_keys=True, separators=(",", ":")) if config else fallback
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def _git(root: str, *args: str) -> str:
    try:
        out = subprocess.run(
            ["git", "-C", root, *args],
            capture_output=True, text=True, check=False, timeout=15,
        )
        return out.stdout.strip() if out.returncode == 0 else ""
    except (OSError, subprocess.SubprocessError):
        return ""


def git_sha(root: str) -> str:
    return _git(root, "rev-parse", "HEAD") or "unknown"


def git_dirty(root: str) -> bool:
    # Untracked files are ignored on purpose: runs.jsonl, status and .prereg are
    # written by every run and would make the flag permanently true. The flag
    # means "tracked code differs from the recorded commit".
    return bool(_git(root, "status", "--porcelain", "--untracked-files=no"))


def now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# --------------------------------------------------------------------------
# metric direction
# --------------------------------------------------------------------------

def lower_is_better(metric: str) -> bool:
    name = metric.lower()
    return any(h in name for h in LOWER_IS_BETTER_HINTS)


# --------------------------------------------------------------------------
# stats (stdlib statistics is fine, but n<2 must not raise)
# --------------------------------------------------------------------------

def mean(values) -> float | None:
    vals = [v for v in values if v is not None]
    return sum(vals) / len(vals) if vals else None


def stdev(values) -> float | None:
    """Sample standard deviation (n-1). None when n<2."""
    vals = [v for v in values if v is not None]
    if len(vals) < 2:
        return None
    m = sum(vals) / len(vals)
    return (sum((v - m) ** 2 for v in vals) / (len(vals) - 1)) ** 0.5


# --------------------------------------------------------------------------
# messaging
# --------------------------------------------------------------------------

def warn(msg: str) -> None:
    print(f"warning: {msg}", file=sys.stderr)


def die(msg: str, code: int = 1):
    print(f"error: {msg}", file=sys.stderr)
    raise SystemExit(code)
