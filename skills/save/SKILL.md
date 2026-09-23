---
name: save
description: Creates a temporary 'checkpoint' commit with all current changes.
argument-hint: "[checkpoint message]"
disable-model-invocation: true
allowed-tools: Bash(git add*), Bash(git commit*)
---

Creating a save point. The commit message will be: "CHECKPOINT: $ARGUMENTS".

1.  If no message is provided, use an appropriate message based on the current changes.
2.  `git add .`
3.  `git commit -m "CHECKPOINT: $ARGUMENTS"`

Propose the `Bash` tool calls to perform these actions.
