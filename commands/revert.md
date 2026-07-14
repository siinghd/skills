# Create this file at my-project/.claude/commands/revert.md
---
description: "Reverts the last CHECKPOINT commit and analyzes the reverted changes."
allowed-tools: Bash(git diff:*), Bash(git reset:*)
---
We are reverting the last checkpoint. I need you to understand what went wrong.

First, show me the changes from the last commit by running: `git diff HEAD~1 HEAD`

After you display the diff, I will confirm, and then you should propose the command to revert the commit: `git reset --hard HEAD~1`

Once reverted, wait for my feedback on why the change was incorrect.
