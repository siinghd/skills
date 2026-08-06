#!/usr/bin/env bash
# setup.sh — one-command setup for the OpenRouter execution tier.
#
# Supports macOS, Linux (including WSL, the recommended Windows route) and
# Windows under Git Bash/MSYS2. These are all bash scripts, so native
# cmd.exe/PowerShell is NOT supported.
#
# Usage:
#   ./setup.sh                     # interactive (prompts for key if missing)
#   ./setup.sh sk-or-v1-...        # non-interactive, stores the key
#   ./setup.sh --no-desktop        # skip Claude Desktop MCP registration
#   ./setup.sh --help              # show this usage block
#
# Idempotent — safe to re-run any time. Verifies every step it performs.
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$SKILL_DIR/scripts"
# Shared, OS-aware helpers (os detection, key storage). Written by its own
# packet — we only consume its contract, never create or edit it.
. "$SCRIPTS/or-common.sh"
DESKTOP=true
KEY_ARG=""

MODEL_ARG=""
prev=""
for arg in "$@"; do
  if [ "$prev" = "--model" ]; then MODEL_ARG="$arg"; prev=""; continue; fi
  case "$arg" in
    --model) prev="--model" ;;
    --model=*) MODEL_ARG="${arg#--model=}" ;;
    --no-desktop) DESKTOP=false ;;
    --help|-h)
      sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    sk-or-*) KEY_ARG="$arg" ;;
    *) echo "unknown argument: $arg (expected an sk-or-... key or --no-desktop)" >&2; exit 2 ;;
  esac
done

step() { printf '\n\033[1m== %s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
fail() { printf '  \033[31m✗\033[0m %s\n' "$1" >&2; exit 1; }

# Detect the platform once and report it; everything below branches on it.
OS="$(or_os)"
step "Platform"
ok "detected: $OS"

step "Dependencies"
# Required on every platform. We build the list dynamically because the
# set differs per OS rather than writing three near-identical loops.
bins=( claude jq curl uvx )
[ "$OS" = macos ] && bins+=( security )
for bin in "${bins[@]}"; do
  command -v "$bin" >/dev/null 2>&1 || fail "$bin not found on PATH$( [ "$bin" = uvx ] && echo ' — install uv: https://docs.astral.sh/uv/' )"
done
ok "claude $(claude --version 2>/dev/null | head -1)"
ok "${bins[*]} present on $OS"
# Linux: secret-tool is optional. Its absence is not fatal — the key simply
# falls back to a 0600 file, so warn rather than die so setup still succeeds.
if [ "$OS" = linux ] && ! command -v secret-tool >/dev/null 2>&1; then
  echo "  - secret-tool not found; the key will be stored in $(or_key_file) (0600) instead of the secret service"
fi

step "Scripts executable"
chmod +x "$SCRIPTS"/*.sh
ok "chmod +x scripts/*.sh"

step "OpenRouter API key"
if [ -n "$KEY_ARG" ]; then
  or_store_key "$KEY_ARG"
elif ! "$SCRIPTS/or-chat.sh" key-check >/dev/null 2>&1; then
  if [ -t 0 ]; then
    printf '  enter your OpenRouter API key (input hidden): '
    read -rs key; echo
    [ -n "$key" ] || fail "no key provided"
    or_store_key "$key"
  else
    fail "no key found — re-run with the key as an argument: ./setup.sh sk-or-v1-<key>"
  fi
fi
"$SCRIPTS/or-chat.sh" key-check | sed 's/^/  /'

step "Model selection"
. "$SCRIPTS/or-config.sh"
if [ -n "$MODEL_ARG" ]; then
  or_set_model "$MODEL_ARG" && ok "default model set to $MODEL_ARG"
elif [ -f "$(or_config_file)" ]; then
  or_load_config; ok "using stored default: ${OR_WORKER_MODEL:-?}"
else
  or_set_model '~deepseek/deepseek-v4-flash-latest'
  ok "no model chosen — defaulted to ~deepseek/deepseek-v4-flash-latest"
fi
echo "  change any time:  ./setup.sh --model '<id>'      list ids: $SCRIPTS/or-chat.sh models <filter>"

step "LiteLLM gateway"
"$SCRIPTS/or-proxy.sh" start | sed 's/^/  /'

step "Agent ledger"
if [ -f "$SKILL_DIR/ledger/led.py" ]; then
  python3 "$SKILL_DIR/ledger/led.py" init >/dev/null 2>&1 \
    && ok "ledger ready at ${LEDGER_DB:-$HOME/.claude/ledger/ledger.db}" \
    || echo "  - ledger init failed (non-fatal; run led.py init manually)"
else
  echo "  - ledger/led.py not found; skipping"
fi

step "Subagent guard hook"
# Registered globally rather than per-agent: a global PreToolUse hook reaches
# every subagent including ones added later, and agent-guard.sh scopes itself to
# subagents by checking `agent_type`, so the orchestrator stays unrestricted.
GUARD="$HOME/.claude/hooks/agent-guard.sh"
SETTINGS_FILE="$HOME/.claude/settings.json"
if [ ! -f "$GUARD" ]; then
  echo "  - $GUARD not found; run ./sync.sh install first, then re-run"
else
  chmod +x "$GUARD"
  [ -f "$SETTINGS_FILE" ] || echo '{}' > "$SETTINGS_FILE"
  if jq -e '(.hooks.PreToolUse // [])[]?.hooks[]?.command | select(test("agent-guard"))' "$SETTINGS_FILE" >/dev/null 2>&1; then
    ok "already registered in settings.json"
  else
    cp "$SETTINGS_FILE" "$SETTINGS_FILE.bak-$(date +%Y%m%d-%H%M%S)"
    jq '.hooks.PreToolUse = ((.hooks.PreToolUse // []) + [{"matcher":"Bash|Read|Edit|Write|NotebookEdit","hooks":[{"type":"command","command":"~/.claude/hooks/agent-guard.sh"}]}])' \
      "$SETTINGS_FILE" > "$SETTINGS_FILE.tmp" && mv "$SETTINGS_FILE.tmp" "$SETTINGS_FILE"
    ok "registered in settings.json (restart Claude Code — hooks load at session start)"
  fi
fi

step "Claude Desktop MCP registration"
# Desktop ships an app-specific config path per OS.
case "$OS" in
  macos)   CFG="$HOME/Library/Application Support/Claude/claude_desktop_config.json" ;;
  windows) CFG="${APPDATA:-$HOME/AppData/Roaming}/Claude/claude_desktop_config.json" ;;
  linux)   CFG="${XDG_CONFIG_HOME:-$HOME/.config}/Claude/claude_desktop_config.json" ;;
esac
if ! $DESKTOP; then
  echo "  - skipped (--no-desktop)"
elif [ ! -f "$CFG" ]; then
  echo "  - Claude Desktop config not found; skipping (install the app, then re-run)"
else
    # Prefer the real uv binary over a pyenv shim: Desktop's spawn environment
    # may lack the PATH the shim needs.
    UV_BIN="$(pyenv which uv 2>/dev/null || command -v uv 2>/dev/null || true)"
    SRV="$SKILL_DIR/mcp/server.py"
    # Check before any path translation: cygpath on an empty string would emit a
    # raw error instead of this explanatory failure.
    [ -n "$UV_BIN" ] || fail "uv not found (uvx exists but uv doesn't?)"
    # Windows Desktop is a native app and cannot read MSYS-style paths like
    # /c/Users/..., so convert both paths to native form. Without cygpath there
    # is no way to translate, so skip registration rather than write broken paths.
    if [ "$OS" = windows ]; then
      if command -v cygpath >/dev/null 2>&1; then
        UV_BIN="$(cygpath -w "$UV_BIN")"
        SRV="$(cygpath -w "$SRV")"
      else
        # No translation = the native app would get MSYS paths it can't read,
        # so skip straight past registration but still finish the script.
        SKIP_DESKTOP=true
      fi
    fi
    if [ -z "${SKIP_DESKTOP:-}" ]; then
      cp "$CFG" "$CFG.bak-$(date +%Y%m%d-%H%M%S)"
      # Also drop the pre-rename key so a machine set up earlier doesn't end up
      # with two servers exposing the same tools under different names.
      jq --arg uv "$UV_BIN" --arg srv "$SRV" \
        '.mcpServers["openrouter"] = {command: $uv, args: ["run", "--with", "mcp", "python", $srv]}
         | del(.mcpServers["deepseek-openrouter"])' \
        "$CFG" > "$CFG.tmp" && mv "$CFG.tmp" "$CFG"
      ok "registered openrouter (fully restart Claude Desktop to load it)"
    else
      echo "  - cygpath not found; cannot translate paths for native Claude Desktop — skipping registration"
      echo "    (use WSL for full parity, or install MSYS2 with cygpath)"
    fi
fi

step "Ready — cheatsheet"
cat <<EOF
  Pick a model:       ./setup.sh --model '<id>'   (list: $SCRIPTS/or-chat.sh models deepseek)
  Oracle (one-shot):  $SCRIPTS/or-chat.sh chat prompt.md          # uses your chosen model
  One-off other model:$SCRIPTS/or-chat.sh chat -m 'qwen/qwen3-coder' prompt.md
  Agentic worker:     $SCRIPTS/or-worker.sh -d /path/to/repo packet.md
  Monitor runs:       $SCRIPTS/or-monitor.sh list | watch | show
  Gateway:            $SCRIPTS/or-proxy.sh start | stop | status
  In Claude Code:     /orchestrate <task> use deepseek-v4-flash-latest
  In Claude Desktop:  ask for the openrouter_* tools (after app restart)
EOF
