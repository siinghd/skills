#!/usr/bin/env bash
# or-worker.sh — dispatch a fully agentic headless Claude Code worker that runs
# on an OpenRouter model (via the local LiteLLM gateway from or-proxy.sh).
#
# Usage:
#   or-worker.sh [-m <model>] [-d <workdir>] [-n <max-turns>] [-e <effort>] [-l <label>] [-y] [-r <session-id>] [packet-file|-]
#
#   -m  OpenRouter model id (default: $OR_WORKER_MODEL or ~deepseek/deepseek-v4-flash-latest;
#       the ~ is part of the id — quote it)
#   -d  working directory for the worker (default: current directory)
#   -n  max agent turns (default: 50)
#   -e  effort level: low|medium|high|xhigh|max (default: $OR_WORKER_EFFORT or max)
#   -l  run label used in the live-log filename (default: worker)
#   -y  bypass permissions entirely (default: acceptEdits — file edits allowed,
#       Bash blocked; keep the default unless the packet needs to run commands)
#   -r  resume a previous worker session for follow-up fixes
#
# Live progress streams as NDJSON to runs/<timestamp>-<label>.jsonl (path
# announced on stderr) — watch it with or-monitor.sh. Stdout stays the final
# result JSON: .result (report), .session_id (for -r), .total_cost_usd,
# .num_turns.
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUNS_DIR="$SKILL_DIR/runs"
PORT="${OR_PROXY_PORT:-4141}"
# The leading ~ is literal (OpenRouter's rolling-alias namespace, always the
# newest flash snapshot) — keep it quoted anywhere it appears in shell.
MODEL="${OR_WORKER_MODEL:-~deepseek/deepseek-v4-flash-latest}"
SMALL_MODEL="${OR_SMALL_MODEL:-~deepseek/deepseek-v4-flash-latest}"
WORKDIR="$PWD"
MAX_TURNS="50"
PERMISSION_MODE="acceptEdits"
RESUME=""
EFFORT="${OR_WORKER_EFFORT:-max}"
LABEL="worker"

while getopts "m:d:n:r:e:l:y" opt; do
  case "$opt" in
    m) MODEL="$OPTARG" ;;
    d) WORKDIR="$OPTARG" ;;
    n) MAX_TURNS="$OPTARG" ;;
    r) RESUME="$OPTARG" ;;
    e) EFFORT="$OPTARG" ;;
    l) LABEL="$OPTARG" ;;
    y) PERMISSION_MODE="bypassPermissions" ;;
    *) exit 2 ;;
  esac
done
shift $((OPTIND - 1))

packet_src="${1:--}"
if [ "$packet_src" = "-" ]; then
  PACKET="$(cat)"
else
  PACKET="$(cat "$packet_src")"
fi
[ -n "$PACKET" ] || { echo "ERROR: empty work packet" >&2; exit 2; }

if ! curl -sf --max-time 2 "http://127.0.0.1:${PORT}/health/liveliness" >/dev/null 2>&1; then
  echo "ERROR: gateway not running on port $PORT — start it first:" >&2
  echo "  $(dirname "$0")/or-proxy.sh start" >&2
  exit 2
fi

mkdir -p "$RUNS_DIR"
LABEL="$(printf '%s' "$LABEL" | tr -c 'A-Za-z0-9._-' '-')"
# $$ suffix keeps parallel workers launched in the same second from sharing a log.
LOG="$RUNS_DIR/$(date +%Y%m%d-%H%M%S)-${LABEL}-$$.jsonl"
echo "worker log: $LOG" >&2

extra_args=()
[ -n "$RESUME" ] && extra_args+=(--resume "$RESUME")

cd "$WORKDIR"
# env -u strips this session's Anthropic auth and nesting markers so the child
# claude process authenticates only against the local gateway.
worker_status=0
env -u ANTHROPIC_API_KEY -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT \
  ANTHROPIC_BASE_URL="http://127.0.0.1:${PORT}" \
  ANTHROPIC_AUTH_TOKEN="or-gateway" \
  ANTHROPIC_MODEL="$MODEL" \
  ANTHROPIC_SMALL_FAST_MODEL="$SMALL_MODEL" \
  CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
  claude -p "$PACKET" \
    --model "$MODEL" \
    --effort "$EFFORT" \
    --permission-mode "$PERMISSION_MODE" \
    --max-turns "$MAX_TURNS" \
    --output-format stream-json \
    --verbose \
    ${extra_args[@]+"${extra_args[@]}"} \
    > "$LOG" 2>&1 || worker_status=$?

# Contract with callers: final result JSON on stdout. -R + objects skips any
# non-JSON or scalar-JSON stderr lines that landed in the log.
result_line="$(jq -cR 'fromjson? | objects | select(.type == "result")' "$LOG" | tail -1 || true)"
if [ -n "$result_line" ]; then
  printf '%s\n' "$result_line"
fi
if [ "$worker_status" -ne 0 ] || [ -z "$result_line" ]; then
  echo "WORKER ERROR (exit $worker_status) — last log lines:" >&2
  tail -5 "$LOG" >&2
  exit 1
fi
