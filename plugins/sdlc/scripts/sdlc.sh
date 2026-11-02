#!/usr/bin/env bash
# Finds node, then runs sdlc.mjs. Hooks don't always get your shell's PATH, so a node from nvm can be
# missing there, and a hook that can't start counts as an error, not a block: the edit would go through.
# Set SDLC_NODE_SEARCH to replace the list of places to look.
set -uo pipefail

DEFAULT_SEARCH="$HOME/.nvm/versions/node/*/bin/node $HOME/.volta/bin/node $HOME/.local/share/fnm/aliases/default/bin/node /opt/homebrew/bin/node /usr/local/bin/node /usr/bin/node"

find_node() {
  command -v node && return 0
  local found="" candidate
  # shellcheck disable=SC2086 # the list holds globs and is meant to split
  for candidate in ${SDLC_NODE_SEARCH-$DEFAULT_SEARCH}; do
    [ -x "$candidate" ] || continue
    case "$candidate" in
      # nvm's glob sorts oldest first, so keep going for the newest.
      */.nvm/*) found="$candidate" ;;
      *) [ -n "$found" ] || found="$candidate"; break ;;
    esac
  done
  [ -n "$found" ] && printf '%s\n' "$found"
}

NODE="$(find_node)"
if [ -n "$NODE" ]; then
  exec "$NODE" "$(dirname "${BASH_SOURCE[0]}")/sdlc.mjs" "$@"
fi

case "${1:-}" in
  check-edit|check-ship)
    # With no node we can't read the hook payload. Only block in a repo that uses runs, so a machine
    # without node isn't locked out of every project.
    top="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    if [ -n "$top" ] && [ -d "$top/docs/sdlc" ]; then
      echo "BLOCKED by sdlc: couldn't find node, so the gate can't check this. Install Node 18+ or set SDLC_NODE_SEARCH." >&2
      exit 2
    fi
    exit 0
    ;;
esac
echo "sdlc: couldn't find node. Install Node 18+ or set SDLC_NODE_SEARCH." >&2
exit 1
