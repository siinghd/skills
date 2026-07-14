---
description: "Refactors a file for clarity, performance, and correctness."
allowed-tools: Edit, Bash(npm run test*), Bash(npm run lint*)
---
Refactor the file `@$ARGUMENTS`.

Your goals are to improve readability, reduce complexity, and ensure adherence to our project's `CLAUDE.md` ethos.

After you have a plan for the refactor, propose the `Edit` tool call. **Simultaneously**, in the same turn, propose two `Bash` tool calls to verify your changes:
1.  Run the relevant unit tests: `npm run test:watch $ARGUMENTS`
2.  Run the linter on the file: `npm run lint $ARGUMENTS`

This parallel verification is crucial for efficiency. I want to see the code change and the verification results all at once.
