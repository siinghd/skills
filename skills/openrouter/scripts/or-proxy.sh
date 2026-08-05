#!/usr/bin/env bash
# or-proxy.sh — manage the local LiteLLM gateway that translates Claude Code's
# Anthropic-format API calls into OpenRouter (OpenAI-format) calls.
#
# Usage: or-proxy.sh {start|stop|status|logs}
#
# Listens on 127.0.0.1:${OR_PROXY_PORT:-4141}. Runs via uvx, so nothing is
# installed globally. Key resolution matches or-chat.sh (env var, then Keychain).
#
# litellm is pinned to 1.91.4: the last release with a universal (pure-python)
# wheel. 1.92+ publish only Linux/Windows binary wheels, so macOS falls back to
# a Rust source build that fails on stock cargo. Bump only after checking PyPI
# for a py3-none-any or macosx wheel. Override via OR_LITELLM_VERSION.
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${OR_PROXY_PORT:-4141}"
PID_FILE="$SKILL_DIR/.proxy.pid"
LOG_FILE="$SKILL_DIR/.proxy.log"
CONFIG="$SKILL_DIR/litellm-config.yaml"
HEALTH_URL="http://127.0.0.1:${PORT}/health/liveliness"
LITELLM_SPEC="litellm[proxy]==${OR_LITELLM_VERSION:-1.91.4}"

resolve_key() {
  if [ -n "${OPENROUTER_API_KEY:-}" ]; then
    printf '%s' "$OPENROUTER_API_KEY"
  else
    security find-generic-password -s openrouter-api-key -w 2>/dev/null || {
      echo "ERROR: no OpenRouter key. Set OPENROUTER_API_KEY or run:" >&2
      echo "  security add-generic-password -s openrouter-api-key -a openrouter -w '<key>'" >&2
      exit 3
    }
  fi
}

healthy() {
  curl -sf --max-time 2 "$HEALTH_URL" >/dev/null 2>&1
}

is_running() {
  [ -f "$PID_FILE" ] || return 1
  local pid
  pid="$(cat "$PID_FILE")"
  kill -0 "$pid" 2>/dev/null || return 1
  # Guard against PID recycling: only trust the file if it's really our gateway.
  ps -p "$pid" -o command= 2>/dev/null | grep -q litellm
}

kill_gateway() {
  if [ -f "$PID_FILE" ]; then
    kill "$(cat "$PID_FILE")" 2>/dev/null || true
  fi
  # uvx may leave a child process holding the port; the config path is unique.
  pkill -f "litellm --config $CONFIG" 2>/dev/null || true
  rm -f "$PID_FILE"
}

case "${1:-}" in
  start)
    if healthy; then
      if is_running; then
        echo "already running (pid $(cat "$PID_FILE"), port $PORT)"
      else
        echo "already running on port $PORT (unmanaged process — no PID file)"
      fi
      exit 0
    fi
    rm -f "$PID_FILE"
    OPENROUTER_API_KEY="$(resolve_key)" \
      nohup uvx --from "$LITELLM_SPEC" litellm \
        --config "$CONFIG" --host 127.0.0.1 --port "$PORT" \
        >"$LOG_FILE" 2>&1 &
    echo $! > "$PID_FILE"
    # First run downloads litellm via uvx, so allow a generous startup window.
    deadline=$((SECONDS + 240))
    while [ "$SECONDS" -lt "$deadline" ]; do
      if healthy; then
        echo "proxy up on 127.0.0.1:$PORT (pid $(cat "$PID_FILE"))"
        exit 0
      fi
      kill -0 "$(cat "$PID_FILE")" 2>/dev/null || {
        echo "ERROR: proxy process died during startup; last log lines:" >&2
        tail -20 "$LOG_FILE" >&2
        rm -f "$PID_FILE"
        exit 1
      }
      sleep 2
    done
    echo "ERROR: proxy did not become healthy within 240s; killing it. See $LOG_FILE" >&2
    kill_gateway
    exit 1
    ;;

  stop)
    if [ -f "$PID_FILE" ] || healthy; then
      kill_gateway
      echo "stopped"
    else
      echo "not running"
    fi
    ;;

  status)
    if healthy; then
      if is_running; then
        echo "running and healthy (pid $(cat "$PID_FILE"), port $PORT)"
      else
        echo "running and healthy on port $PORT (unmanaged — no PID file)"
      fi
    elif is_running; then
      echo "process alive (pid $(cat "$PID_FILE")) but health check failing"
      exit 1
    else
      echo "not running"
      exit 1
    fi
    ;;

  logs)
    tail -50 "$LOG_FILE"
    ;;

  *)
    echo "usage: or-proxy.sh {start|stop|status|logs}" >&2
    exit 2
    ;;
esac
