---
name: tdd-scaffold
description: Scaffolds failing tests and a shell implementation for TDD.
argument-hint: "[feature name]"
disable-model-invocation: true
allowed-tools: Write
---

We are using Test-Driven Development for the feature: "$ARGUMENTS".

1.  Create a test file at `src/features/$ARGUMENTS.test.ts`. Write comprehensive, FAILING tests that cover the primary success case, edge cases, and error conditions for this feature.
2.  Create a shell implementation file at `src/features/$ARGUMENTS.ts` with placeholder functions that throw `new Error('Not implemented')`.
3.  Use the `Write` tool to create these two files.

Write no implementation logic in this step: the tests should fail against the stub, which is how TDD confirms they test real behavior.
