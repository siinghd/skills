#!/usr/bin/env bash
# agent-guard.sh — PreToolUse guard for implementation subagents.
#
# Wired into an agent definition's `hooks:` frontmatter, NOT into global
# settings, so it constrains only the agents that opt in — the orchestrator
# (main session) keeps full access. Verified enforced even under
# --permission-mode bypassPermissions.
#
# Blocks two classes of action, both of which have caused real damage:
#   1. Destructive git — a worker seeing a peer's concurrent edits mistakes them
#      for its own overreach and reverts them. `git checkout` leaves NO trace in
#      `git status`, so this is both destructive and invisible after the fact.
#   2. Secret access — reading .env/key/credential files, which must reach a
#      worker only as a sanitized value pasted by the orchestrator.
#
# Contract: reads the PreToolUse hook JSON on stdin. exit 0 = allow,
# exit 2 = block (stderr is shown to the agent as the reason).
set -uo pipefail

input="$(cat)"

# Fail CLOSED. If the payload can't be parsed we cannot know what is being run,
# and silently allowing is how a guard becomes decorative. jq is already a hard
# dependency of this rig, so this should never fire in practice.
if ! command -v jq >/dev/null 2>&1; then
  echo "agent-guard: jq not found — blocking to fail closed." >&2
  exit 2
fi
if ! printf '%s' "$input" | jq -e . >/dev/null 2>&1; then
  echo "agent-guard: unparseable hook payload — blocking to fail closed." >&2
  exit 2
fi

tool="$(printf '%s' "$input" | jq -r '.tool_name // ""')"
agent="$(printf '%s' "$input" | jq -r '.agent_type // ""')"

# Main-session calls carry no agent_type. The orchestrator is trusted; it is the
# one that has to be able to repair whatever a worker gets wrong.
[ -n "$agent" ] || exit 0

# Secret-bearing paths. Kept in sync with worker-settings.json's deny list, which
# covers the headless DeepSeek workers that never see these hooks.
#
# Two variants deliberately: a tool's file_path is a bare path, but a shell
# command embeds the path among spaces, quotes and redirections — anchoring on
# `/` or start-of-string (correct for a path) silently misses `cat .env`.
secret_path_re='(^|/)\.env($|\.)|(^|/)\.netrc$|(^|/)\.npmrc$|\.(pem|key|p12|pfx)$|(^|/)id_(rsa|ed25519|ecdsa)|(^|/)\.ssh/|(^|/)\.aws/|credentials'
secret_cmd_re='(^|[^[:alnum:]_.-])\.env([^[:alnum:]_-]|$)|\.env\.[A-Za-z]|\.(pem|key|p12|pfx)([^[:alnum:]]|$)|id_(rsa|ed25519|ecdsa)|\.ssh/|\.aws/|\.netrc|\.npmrc|credentials'

case "$tool" in
  Bash)
    cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // ""')"

    # Any git subcommand that can discard working-tree state. Deliberately broad:
    # over-blocking costs a reported blocker, under-blocking costs the user's work.
    if printf '%s' "$cmd" | grep -qE '\bgit\b[^;&|]*\b(checkout|restore|reset|clean|stash)\b'; then
      cat >&2 <<EOF
BLOCKED by agent-guard (agent_type=$agent): destructive git is not permitted.

Changes in this tree that you did not make belong to the orchestrator or to a
peer worker — they are NOT your overreach, and reverting them destroys work that
\`git status\` will not show as missing. If the tree state looks wrong, STOP and
report it as a blocker instead.
EOF
      exit 2
    fi

    # Reading a secret through a shell command rather than the Read tool.
    if printf '%s' "$cmd" | grep -qE '\b(cat|less|more|head|tail|bat|strings|xxd|od|grep|rg|ag|awk|sed|cp|scp|curl|source|\.)\b' \
       && printf '%s' "$cmd" | grep -qE "$secret_cmd_re"; then
      echo "BLOCKED by agent-guard (agent_type=$agent): that path holds credentials. Ask the orchestrator for a sanitized value and report a blocker." >&2
      exit 2
    fi
    ;;

  Read|Edit|Write|NotebookEdit)
    path="$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // ""')"
    if [ -n "$path" ] && printf '%s' "$path" | grep -qE "$secret_path_re"; then
      echo "BLOCKED by agent-guard (agent_type=$agent): $path holds credentials. Ask the orchestrator for a sanitized value and report a blocker." >&2
      exit 2
    fi
    ;;
esac

exit 0
