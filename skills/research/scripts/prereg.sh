#!/usr/bin/env bash
# Pre-register a plan: freeze PLAN.md's hash before any run exists, so that
# log_run.py can tell a measured plan from an edited one.
set -euo pipefail

usage() {
  cat <<'USAGE'
usage: prereg.sh <exp> [--force]

Pre-register experiments/<exp>/PLAN.md. Checks the plan has a kill criterion, a
prediction and arms including a negative control, commits the plan, and writes
.prereg with its sha256. log_run.py refuses to log runs against a plan that is
unregistered or has changed since.

  <exp>     experiment id or its numeric prefix (e.g. 003 or 003-slug)
  --force   re-register even though runs are already logged (changing a plan
            mid-experiment is normally a new experiment, not an edit)
USAGE
}

FORCE=0
IDENT=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --force) FORCE=1; shift ;;
    -*) echo "error: unknown option $1" >&2; exit 1 ;;
    *) IDENT="$1"; shift ;;
  esac
done
[ -n "$IDENT" ] || { usage >&2; exit 1; }

find_lab_root() {
  local d; d="$(pwd -P)"
  while [ "$d" != "/" ]; do
    if [ -f "$d/lab.json" ]; then echo "$d"; return 0; fi
    d="$(dirname "$d")"
  done
  return 1
}
ROOT="$(find_lab_root)" || { echo "error: not inside a research lab (no lab.json here or above)" >&2; exit 1; }

resolve_exp() {  # <root> <ident> -> experiment directory name
  local root="$1" ident="$2" d base n=0 hit=""
  if [ -d "$root/experiments/$ident" ]; then echo "$ident"; return 0; fi
  case "$ident" in
    ''|*[!0-9]*) ;;
    *) ident="$(printf '%03d' "$((10#$ident))")" ;;
  esac
  for d in "$root"/experiments/"$ident"-*/; do
    [ -d "$d" ] || continue
    base="$(basename "$d")"; hit="$base"; n=$((n + 1))
  done
  [ "$n" -eq 1 ] || return 1
  echo "$hit"
}
EXP="$(resolve_exp "$ROOT" "$IDENT")" || { echo "error: no single experiment matching '$IDENT'" >&2; exit 1; }
DIR="$ROOT/experiments/$EXP"
PLAN="$DIR/PLAN.md"

[ -f "$PLAN" ] || { echo "error: $PLAN does not exist — nothing to pre-register" >&2; exit 1; }

# Re-registering after measurement would let the plan follow the data.
if [ -f "$DIR/.prereg" ] && [ -s "$DIR/runs.jsonl" ] && [ "$FORCE" -ne 1 ]; then
  echo "error: $EXP is already pre-registered and has logged runs." >&2
  echo "       Changing the plan now = a new experiment. Use bin/new_experiment.sh," >&2
  echo "       or --force if you are deliberately amending a plan with no results yet." >&2
  exit 1
fi

fail=0
require() {  # require <grep-pattern> <human description>
  if ! grep -q "$1" "$PLAN"; then
    echo "error: PLAN.md is missing $2" >&2
    fail=1
  fi
}
require '^## Kill criterion' "a '## Kill criterion' section (decide the number now, not after)"
require '^## Prediction'     "a '## Prediction' section"
require '^## Arms'           "an '## Arms' section"

# The control arm must be described under Arms, not merely mentioned somewhere.
arms_block="$(awk '/^## Arms/{f=1;next} /^## /{f=0} f' "$PLAN")"
if ! printf '%s' "$arms_block" | grep -qi 'control'; then
  echo "error: PLAN.md's Arms section names no negative control." >&2
  echo "       Every experiment needs an arm that must NOT work; if it wins, the harness is broken." >&2
  fail=1
fi
[ "$fail" -eq 0 ] || exit 1

# A missing prediction is a warning: predict.py can still be run before the
# first log_run, and blocking here would be more annoying than useful.
if ! grep -q "\"exp\": \"$EXP\"" "$ROOT/predictions.jsonl" 2>/dev/null; then
  echo "warning: no entry for $EXP in predictions.jsonl — run bin/predict.py before the first run" >&2
fi

# The prediction is part of the pre-registration, so it is committed with the plan;
# otherwise predictions.jsonl leaves the tree dirty for every run that follows.
PRED="$ROOT/predictions.jsonl"
git -C "$ROOT" add "$PLAN" "$PRED" 2>/dev/null || true
if git -C "$ROOT" diff --cached --quiet -- "$PLAN" "$PRED" 2>/dev/null; then
  echo "(plan already committed; nothing to commit)"
else
  git -C "$ROOT" commit -q -m "prereg $EXP" -- "$PLAN" "$PRED" 2>/dev/null \
    || echo "warning: commit failed; continuing (set git user.name/user.email?)" >&2
fi

HASH="$(shasum -a 256 "$PLAN" | cut -d' ' -f1)"
GITSHA="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat > "$DIR/.prereg" <<JSON
{"plan_sha256": "$HASH", "git_sha": "$GITSHA", "ts": "$TS"}
JSON

echo "pre-registered $EXP"
echo "plan_sha256: $HASH"
