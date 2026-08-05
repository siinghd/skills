#!/usr/bin/env bash
# or-monitor.sh — human-readable monitoring for or-worker.sh runs.
#
# Usage:
#   or-monitor.sh list                 # all runs: status, cost, turns
#   or-monitor.sh watch [log.jsonl]    # live-tail a run (default: newest)
#   or-monitor.sh show  [log.jsonl]    # render a run's full transcript (default: newest)
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUNS_DIR="$SKILL_DIR/runs"

latest() {
  # || true: under pipefail, no-match (exit 1) or SIGPIPE from head (141) would
  # otherwise kill the caller's command substitution before its guard runs.
  ls -t "$RUNS_DIR"/*.jsonl 2>/dev/null | head -1 || true
}

# Accept bare filenames (as printed by `list`) as well as full paths.
resolve() {
  if [ -f "$1" ]; then printf '%s' "$1"; else printf '%s' "$RUNS_DIR/$1"; fi
}

# Renders claude stream-json events; fromjson? + objects silently skips
# non-JSON lines and bare JSON scalars mixed in from stderr.
FILTER='
  fromjson? | objects |
  if .type == "system" and .subtype == "init" then
    "▶ start — session \(.session_id) — model \(.model)"
  elif .type == "assistant" then
    (.message.content[]? |
      if .type == "text" and ((.text // "") | length) > 0 then
        "💬 " + (.text | if length > 500 then .[0:500] + " …" else . end)
      elif .type == "tool_use" then
        "🔧 \(.name) " + ((.input | tojson) | if length > 200 then .[0:200] + " …" else . end)
      else empty end)
  elif .type == "result" then
    "■ \(.subtype // "done") — $\(.total_cost_usd // 0) — \(.num_turns // "?") turns — session \(.session_id // "?")\n"
    + ((.result // "") | if length > 2000 then .[0:2000] + " …" else . end)
  else empty end
'

case "${1:-}" in
  list)
    files="$(ls -t "$RUNS_DIR"/*.jsonl 2>/dev/null || true)"
    [ -n "$files" ] || { echo "no runs yet"; exit 0; }
    while IFS= read -r f; do
      line="$(jq -cR 'fromjson? | objects | select(.type == "result")' "$f" | tail -1 || true)"
      if [ -n "$line" ]; then
        status="$(jq -r '"\(.subtype // "done")  $\(.total_cost_usd // 0)  \(.num_turns // "?") turns"' <<<"$line")"
      else
        status="RUNNING (or exited without a result)"
      fi
      printf '%-55s %s\n' "$(basename "$f")" "$status"
    done <<<"$files"
    ;;

  watch)
    f="${2:-$(latest)}"
    [ -n "$f" ] || { echo "no runs found in $RUNS_DIR" >&2; exit 1; }
    f="$(resolve "$f")"
    echo "watching $f (ctrl-c to stop)" >&2
    tail -n +1 -f "$f" | jq --unbuffered -rR "$FILTER"
    ;;

  show)
    f="${2:-$(latest)}"
    [ -n "$f" ] || { echo "no runs found in $RUNS_DIR" >&2; exit 1; }
    f="$(resolve "$f")"
    jq -rR "$FILTER" "$f"
    ;;

  *)
    echo "usage: or-monitor.sh {list|watch [log]|show [log]}" >&2
    exit 2
    ;;
esac
