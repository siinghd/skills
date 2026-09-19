#!/usr/bin/env bash
# Allocate the next experiment id and lay down its directory from the template.
set -euo pipefail

usage() {
  cat <<'USAGE'
usage: new_experiment.sh <slug>

Create experiments/<NNN>-<slug>/ with PLAN.md (from the skill template, with the
id and today's date filled in), an empty plots/ directory and status=queued.
The id is one past the highest existing experiment number, zero-padded to 3.

  <slug>   short lowercase name, [a-z0-9-] only
USAGE
}

[ $# -ge 1 ] || { usage >&2; exit 1; }
case "$1" in -h|--help) usage; exit 0 ;; esac

SLUG="$1"
# Validated because the slug is interpolated into a sed expression below.
case "$SLUG" in
  *[!a-z0-9-]*|"") echo "error: slug must be lowercase [a-z0-9-], got '$SLUG'" >&2; exit 1 ;;
esac

find_lab_root() {
  local d; d="$(pwd -P)"
  while [ "$d" != "/" ]; do
    if [ -f "$d/lab.json" ]; then echo "$d"; return 0; fi
    d="$(dirname "$d")"
  done
  return 1
}
ROOT="$(find_lab_root)" || { echo "error: not inside a research lab (no lab.json here or above)" >&2; exit 1; }
TEMPLATE="$HOME/.claude/skills/research/templates/PLAN.md"
[ -f "$TEMPLATE" ] || { echo "error: PLAN.md template not found at $TEMPLATE" >&2; exit 1; }

mkdir -p "$ROOT/experiments"

# Highest existing NNN. 10# forces base 10: $((009 + 1)) is an octal error.
MAX=-1
for d in "$ROOT"/experiments/*/; do
  [ -d "$d" ] || continue
  n="$(basename "$d")"
  n="${n%%-*}"
  case "$n" in
    ''|*[!0-9]*) continue ;;
  esac
  n=$((10#$n))
  [ "$n" -gt "$MAX" ] && MAX="$n"
done
ID="$(printf '%03d' "$((MAX + 1))")"
EXP="$ID-$SLUG"
DEST="$ROOT/experiments/$EXP"

[ ! -e "$DEST" ] || { echo "error: $DEST already exists" >&2; exit 1; }
mkdir -p "$DEST/plots"

# Fill the template's id placeholder and the empty Date: line.
sed -e "s/<NNN>-<slug>/$EXP/g" -e "s/^Date:[[:space:]]*$/Date: $(date +%Y-%m-%d)/" \
  "$TEMPLATE" > "$DEST/PLAN.md"
echo "queued" > "$DEST/status"

echo "$DEST"
echo "next: edit PLAN.md, then bin/predict.py, then bin/prereg.sh $ID"
