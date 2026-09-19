#!/usr/bin/env bash
# Scaffold a research lab: the files, the budget config, and the bin/ symlink
# back to these scripts. Everything after this point assumes this layout.
set -euo pipefail

SKILL_DIR="$HOME/.claude/skills/research"
TEMPLATES="$SKILL_DIR/templates"

usage() {
  cat <<'USAGE'
usage: init_lab.sh <dir> [name] [--force]

Scaffold a research lab in <dir>. Creates the lab files, an empty
predictions.jsonl, lab.json, lib/, experiments/, a bin -> research-skill
symlink, .claude/settings.json (SessionStart hook) and .gitignore, then makes
the initial commit.

  <dir>     directory to scaffold (created if missing)
  [name]    lab name recorded in lab.json (default: basename of <dir>)
  --force   overwrite an existing lab.json

Refuses to run if <dir>/lab.json already exists, unless --force.
USAGE
}

FORCE=0
DIR=""
NAME=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --force) FORCE=1; shift ;;
    -*) echo "error: unknown option $1" >&2; usage >&2; exit 1 ;;
    *)
      if [ -z "$DIR" ]; then DIR="$1"; elif [ -z "$NAME" ]; then NAME="$1";
      else echo "error: unexpected argument $1" >&2; exit 1; fi
      shift ;;
  esac
done

[ -n "$DIR" ] || { usage >&2; exit 1; }
[ -f "$TEMPLATES/CLAUDE.md" ] || { echo "error: templates not found at $TEMPLATES" >&2; exit 1; }

mkdir -p "$DIR"
# Absolute path without readlink -f, which BSD/macOS does not have.
DIR="$(cd "$DIR" && pwd)"
[ -n "$NAME" ] || NAME="$(basename "$DIR")"

if [ -f "$DIR/lab.json" ] && [ "$FORCE" -ne 1 ]; then
  echo "error: $DIR/lab.json already exists (a lab is already here). Use --force to overwrite." >&2
  exit 1
fi

# Test for .git directly: `git rev-parse` would report true inside any parent
# repo and we would skip creating a repo for this lab.
if [ ! -d "$DIR/.git" ]; then
  git -C "$DIR" init -q
fi

mkdir -p "$DIR/experiments" "$DIR/lib" "$DIR/.claude"
touch "$DIR/experiments/.gitkeep"

cp "$TEMPLATES/CLAUDE.md" "$DIR/CLAUDE.md"
cp "$TEMPLATES/settings.json" "$DIR/.claude/settings.json"

# The eight lab files. Written only when absent so --force never eats notes.
write_if_absent() {  # write_if_absent <path> ; body on stdin
  if [ -e "$1" ]; then echo "  kept    $(basename "$1")"; cat >/dev/null; return 0; fi
  cat > "$1"
  echo "  created $(basename "$1")"
}

write_if_absent "$DIR/STATE.md" <<'MD'
# STATE — what is running, what is blocked, the exact next action

Nothing running. Next action: write the first PLAN.md (`bin/new_experiment.sh <slug>`).
MD

write_if_absent "$DIR/RESEARCH_LOG.md" <<'MD'
# Research log — append-only, one `### ` entry per iteration
MD

write_if_absent "$DIR/FINDINGS.md" <<'MD'
# Findings — confirmed results only

Entry bar: >=3 seeds, >=2 settings, matched compute, negative control passed,
reviewer ACCEPT. Each entry states the claim, the evidence (experiment ids), the
conditions it holds under, a confidence level, and what would falsify it.
Demote entries that later fail, and keep the demotion visible.
MD

write_if_absent "$DIR/IDEAS.md" <<'MD'
# Ideas — scored hypothesis backlog

## Open

## Parked
(blocked, or waiting on budget — say which)

## Killed
(a mechanistic reason is required; "didn't work" is not a reason)
MD

write_if_absent "$DIR/ANOMALIES.md" <<'MD'
# Anomalies — anything unexplained (exp id, plot path, expected vs observed)
MD

write_if_absent "$DIR/QUESTIONS.md" <<'MD'
# Questions for the human — queue them, state your assumption, and proceed
MD

write_if_absent "$DIR/INBOX.md" <<'MD'
# Inbox — the human writes here; the researcher reads it at every session start

Drop direction, corrections and new priorities below. Each note is acted on and
then moved to INBOX_DONE.md with a line saying what was done about it.
MD

write_if_absent "$DIR/INBOX_DONE.md" <<'MD'
# Inbox, handled — each note with what was done about it
MD

[ -e "$DIR/predictions.jsonl" ] || : > "$DIR/predictions.jsonl"

cat > "$DIR/lab.json" <<JSON
{
  "name": "$NAME",
  "budget_hours_per_experiment": 2,
  "budget_hours_total": 20,
  "compute_tolerance": 0.10
}
JSON

[ -e "$DIR/lib/__init__.py" ] || cat > "$DIR/lib/__init__.py" <<'PY'
"""Shared train/eval/log harness for this lab.

One implementation, used by every experiment. Never fork this into an
experiment directory: a forked harness makes two experiments incomparable
without anyone noticing.
"""
PY

[ -e "$DIR/lib/README.md" ] || cat > "$DIR/lib/README.md" <<'MD'
# lib — the shared harness

Every experiment imports its training, evaluation and logging from here rather
than carrying its own copy, because the whole lab's results are only comparable
if they came off the same code path. A change here affects every future run and
invalidates comparisons against past ones, so changes are small, reviewed
against the experiments that depend on them, and land with their tests passing.
Tests must pass before any run is logged against a modified harness.
MD

cat > "$DIR/.gitignore" <<'IGNORE'
__pycache__/
*.pt
*.ckpt
data/
checkpoints/
wandb/
.DS_Store
IGNORE

# bin -> the scripts in this skill. Expanded from $HOME rather than a hardcoded
# user, so the same command scaffolds a lab on any machine.
rm -f "$DIR/bin"
ln -s "$HOME/.claude/skills/research/scripts" "$DIR/bin"

git -C "$DIR" add -A
if git -C "$DIR" diff --cached --quiet; then
  echo "nothing new to commit"
else
  git -C "$DIR" commit -q -m "chore: init research lab" || echo "warning: commit failed (set git user.name/user.email?)" >&2
fi

cat <<NEXT

Lab ready: $DIR

Budget defaults: 2 GPU-hours per experiment, 20 total (edit lab.json to change).
Run /research <topic> here, or from anywhere: the skill finds this lab by path.
NEXT
