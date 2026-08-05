#!/usr/bin/env bash
# setup.sh — one-command setup for the OpenRouter/DeepSeek execution tier.
#
# Usage:
#   ./setup.sh                     # interactive (prompts for key if missing)
#   ./setup.sh sk-or-v1-...        # non-interactive, stores the key
#   ./setup.sh --no-desktop        # skip Claude Desktop MCP registration
#
# Idempotent — safe to re-run any time. Verifies every step it performs.
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$SKILL_DIR/scripts"
DESKTOP=true
KEY_ARG=""

for arg in "$@"; do
  case "$arg" in
    --no-desktop) DESKTOP=false ;;
    sk-or-*) KEY_ARG="$arg" ;;
    *) echo "unknown argument: $arg (expected an sk-or-... key or --no-desktop)" >&2; exit 2 ;;
  esac
done

step() { printf '\n\033[1m== %s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
fail() { printf '  \033[31m✗\033[0m %s\n' "$1" >&2; exit 1; }

step "Dependencies"
for bin in claude jq curl uvx security; do
  command -v "$bin" >/dev/null 2>&1 || fail "$bin not found on PATH$( [ "$bin" = uvx ] && echo ' — install uv: https://docs.astral.sh/uv/' )"
done
ok "claude $(claude --version 2>/dev/null | head -1)"
ok "uvx, jq, curl, security present"

step "Scripts executable"
chmod +x "$SCRIPTS"/*.sh
ok "chmod +x scripts/*.sh"

step "OpenRouter API key"
if [ -n "$KEY_ARG" ]; then
  security add-generic-password -U -s openrouter-api-key -a openrouter -w "$KEY_ARG"
  ok "stored in macOS Keychain (item: openrouter-api-key)"
elif ! "$SCRIPTS/or-chat.sh" key-check >/dev/null 2>&1; then
  if [ -t 0 ]; then
    printf '  enter your OpenRouter API key (input hidden): '
    read -rs key; echo
    [ -n "$key" ] || fail "no key provided"
    security add-generic-password -U -s openrouter-api-key -a openrouter -w "$key"
    ok "stored in macOS Keychain"
  else
    fail "no key found — re-run with the key as an argument: ./setup.sh sk-or-v1-<key>"
  fi
fi
"$SCRIPTS/or-chat.sh" key-check | sed 's/^/  /'

step "LiteLLM gateway"
"$SCRIPTS/or-proxy.sh" start | sed 's/^/  /'

step "Claude Desktop MCP registration"
CFG="$HOME/Library/Application Support/Claude/claude_desktop_config.json"
if ! $DESKTOP; then
  echo "  - skipped (--no-desktop)"
elif [ ! -f "$CFG" ]; then
  echo "  - Claude Desktop config not found; skipping (install the app, then re-run)"
else
  # Prefer the real uv binary over a pyenv shim: Desktop's spawn environment
  # may lack the PATH the shim needs.
  UV_BIN="$(pyenv which uv 2>/dev/null || command -v uv 2>/dev/null || true)"
  [ -n "$UV_BIN" ] || fail "uv not found (uvx exists but uv doesn't?)"
  cp "$CFG" "$CFG.bak-$(date +%Y%m%d-%H%M%S)"
  jq --arg uv "$UV_BIN" --arg srv "$SKILL_DIR/mcp/server.py" \
    '.mcpServers["deepseek-openrouter"] = {command: $uv, args: ["run", "--with", "mcp", "python", $srv]}' \
    "$CFG" > "$CFG.tmp" && mv "$CFG.tmp" "$CFG"
  ok "registered deepseek-openrouter (fully restart Claude Desktop to load it)"
fi

step "Ready — cheatsheet"
cat <<EOF
  Oracle (one-shot):  $SCRIPTS/or-chat.sh chat -m '~deepseek/deepseek-v4-flash-latest' prompt.md
  Agentic worker:     $SCRIPTS/or-worker.sh -d /path/to/repo packet.md
  Monitor runs:       $SCRIPTS/or-monitor.sh list | watch | show
  Gateway:            $SCRIPTS/or-proxy.sh start | stop | status
  In Claude Code:     /orchestrate-deepseek <task>
  In Claude Desktop:  ask for the deepseek_* tools (after app restart)
EOF
