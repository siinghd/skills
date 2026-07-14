---
description: "Scaffolds failing tests and a shell implementation for TDD."
allowed-tools: Write
---
We are using Test-Driven Development for the feature: "$ARGUMENTS".

1.  Create a test file at `src/features/$ARGUMENTS.test.ts`. Write comprehensive, FAILING tests that cover the primary success case, edge cases, and error conditions for this feature.
2.  Create a shell implementation file at `src/features/$ARGUMENTS.ts` with placeholder functions that throw `new Error('Not implemented')`.
3.  Use the `Write` tool to create these two files.

You are explicitly forbidden from writing any implementation logic in this step. The tests MUST fail.
