---
name: git-commit
description: Generates a Conventional Commit message based on staged changes.
argument-hint: ""
disable-model-invocation: true
allowed-tools: Bash(git commit*)
---

Here is the current git diff for staged changes:
!`git diff --staged`

Based on the diff above, please generate a perfect commit message following the Conventional Commits specification (`type(scope): subject`). The commit message should be concise yet descriptive.

After you provide the commit message, propose the `Bash` tool call to execute it: `git commit -m "your generated message"`

Do not ever include:
Co-Authored-By: Claude <noreply@anthropic.com>
