#!/usr/bin/env bash
# Harvest background jobs. Run this before starting anything new, so finished
# work is noticed rather than silently re-run.
set -euo pipefail

usage() {
  cat <<'USAGE'
usage: collect.sh [--help]

Print the status of every experiment: state, pid liveness, exit code, and the
tail of train.log for running or dead jobs. Jobs whose process vanished without
an exit code are marked orphaned. Finished experiments are listed once under
FINISHED SINCE LAST COLLECT, then marked collected.
USAGE
}

case "${1:-}" in -h|--help) usage; exit 0 ;; esac

find_lab_root() {
  local d; d="$(pwd -P)"
  while [ "$d" != "/" ]; do
    if [ -f "$d/lab.json" ]; then echo "$d"; return 0; fi
    d="$(dirname "$d")"
  done
  return 1
}
ROOT="$(find_lab_root)" || { echo "error: not inside a research lab (no lab.json here or above)" >&2; exit 1; }

FINISHED=""
ANY=0

for d in "$ROOT"/experiments/*/; do
  [ -d "$d" ] || continue
  ANY=1
  EXP="$(basename "$d")"
  STATUS="$(cat "$d/status" 2>/dev/null || echo unknown)"
  PID="$(cat "$d/run.pid" 2>/dev/null || echo "")"
  CODE="$(cat "$d/exit_code" 2>/dev/null || echo "")"

  ALIVE="-"
  if [ -n "$PID" ]; then
    if kill -0 "$PID" 2>/dev/null; then ALIVE="alive"; else ALIVE="gone"; fi
  fi

  NOTE=""
  # A process that disappeared without writing an exit code was killed (OOM,
  # reboot, a lost session). Recording it as dead stops it looking like progress.
  if [ "$STATUS" = "running" ] && [ "$ALIVE" = "gone" ] && [ -z "$CODE" ]; then
    echo "dead" > "$d/status"
    STATUS="dead"
    NOTE="  orphaned (process gone, no exit code)"
  fi

  LINE="$EXP  status=$STATUS"
  if [ "$STATUS" = "running" ] && [ -z "$PID" ]; then
    NOTE="  foreground runs, no pid — bin/finish.sh $EXP at writeup"
  fi
  [ -n "$PID" ] && LINE="$LINE  pid=$PID($ALIVE)"
  [ -n "$CODE" ] && LINE="$LINE  exit=$CODE"
  echo "$LINE$NOTE"

  if [ "$STATUS" = "running" ] || [ "$STATUS" = "dead" ]; then
    if [ -s "$d/train.log" ]; then
      tail -n 3 "$d/train.log" | sed 's/^/    /'
    fi
  fi

  if [ "$STATUS" = "done" ] || [ "$STATUS" = "dead" ]; then
    if [ ! -f "$d/.collected" ]; then
      FINISHED="$FINISHED$EXP  status=$STATUS${CODE:+  exit=$CODE}
"
      touch "$d/.collected"
    fi
  fi
done

[ "$ANY" -eq 1 ] || echo "no experiments yet"

echo
echo "FINISHED SINCE LAST COLLECT:"
if [ -n "$FINISHED" ]; then
  printf '%s' "$FINISHED" | sed 's/^/  /'
else
  echo "  (none)"
fi

echo
if command -v nvidia-smi >/dev/null 2>&1; then
  nvidia-smi --query-gpu=index,utilization.gpu,memory.used,memory.total \
    --format=csv,noheader,nounits 2>/dev/null \
  | awk -F', *' '{printf "GPU %s: util %s%%  mem %s/%s MiB\n", $1, $2, $3, $4}' \
  || echo "GPU: nvidia-smi present but query failed"
else
  echo "GPU: none detected"
fi
