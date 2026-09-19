#!/usr/bin/env bash
# finish.sh — mark an experiment done (or dead) when its runs were logged in the
# foreground, i.e. not through launch.sh, which writes the status itself.
# Called at writeup (loop step 9) so collect.sh and session_start.sh stop
# reporting the experiment as running.
set -euo pipefail

usage() { echo "usage: finish.sh <exp|NNN> [done|dead]"; exit "${1:-0}"; }
[ $# -ge 1 ] || usage 1
case "$1" in -h|--help) usage 0;; esac

ROOT="$PWD"
while [ ! -f "$ROOT/lab.json" ]; do
  [ "$ROOT" = "/" ] && { echo "finish.sh: not inside a lab (no lab.json)" >&2; exit 1; }
  ROOT="$(dirname "$ROOT")"
done

# Accept the bare NNN prefix or the full NNN-slug.
MATCH="$(ls -d "$ROOT"/experiments/"$1"* 2>/dev/null | head -n 1 || true)"
[ -n "$MATCH" ] || { echo "finish.sh: no experiment matching '$1'" >&2; exit 1; }
EXP="$(basename "$MATCH")"
STATE="${2:-done}"
case "$STATE" in done|dead) ;; *) echo "finish.sh: state must be done or dead" >&2; exit 1;; esac

if [ -f "$MATCH/run.pid" ] && kill -0 "$(cat "$MATCH/run.pid")" 2>/dev/null; then
  echo "finish.sh: $EXP still has a live process (pid $(cat "$MATCH/run.pid")); collect it first" >&2
  exit 1
fi
echo "$STATE" > "$MATCH/status"
echo "$EXP: status=$STATE"
