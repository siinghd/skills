---
description: "Creates a temporary 'checkpoint' commit with all current changes."
allowed-tools: Bash(git add:*), Bash(git commit:*)
---
Creating a save point. The commit message will be: "CHECKPOINT: $ARGUMENTS".

I will now execute the following commands:
1.  Ignore is running, it is not part of the commit message.
2.  If not message is provide, use appropriate message with, tools you can use is git!
3. `git add .`
4. `git commit -m "CHECKPOINT: $ARGUMENTS"`

Propose the `Bash` tool calls to perform these actions.

Do not ever include:
🤖 Generated with [Claude Code](https://claude.ai/code)

Co-Authored-By: Claude <noreply@anthropic.com>
