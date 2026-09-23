---
name: refactor
description: Refactors a file for clarity, performance, and correctness.
argument-hint: "[file path]"
disable-model-invocation: true
allowed-tools: Edit, Bash(npm run test*), Bash(npm run lint*)
---

Refactor the file `@$ARGUMENTS`.

Your goals are to improve readability, reduce complexity, and ensure adherence to our project's `CLAUDE.md` ethos.

Make the edits, then verify them with the project's test and lint commands for this file (for npm projects, `npm run test -- $ARGUMENTS` and `npm run lint $ARGUMENTS`; never a watch-mode script, which does not exit). Report the change and the verification results together.
