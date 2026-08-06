#!/bin/bash
# Path: ~/.claude/hooks/git-safety-check.sh
input=$(cat)
command=$(echo $input | jq -r '.tool_input.command')

# Block any git reset --hard that isn't from our safe '/revert' command
if [[ "$command" == *"git reset --hard"* && "$command" != "git reset --hard HEAD~1" ]]; then
  echo "DANGER: A 'git reset --hard' command was attempted outside of the '/revert' workflow. This is blocked for safety. Use '/revert' to undo checkpoints." >&2
  exit 2 # Exit 2 blocks the tool and feeds the error to Claude
fi

exit 0
