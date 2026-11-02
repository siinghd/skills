# Audit protocol

Every audit subagent applies these rules. The goal is to check each file in full context, without reading it repeatedly or flagging a pattern that is correct where it stands.

## Rules

1. **Read enough context.** Before flagging, read at least 10 lines around the site. If a guard, comment, or recognised idiom legitimizes the pattern, don't flag it.
2. **State the harm concretely.** `harm:` describes the bad outcome in this code: "here, X causes Y under Z". If you can't write that line, drop the finding.
3. **Weigh the context.** `context:` names the facts that make this finding apply here: how often the code runs, the data size, the goal, or the evidence. The same pattern can be a real problem on a hot path and fine on a cold one. If the relevant fact is unknown, lower the confidence and say what is unknown. A profile of a file or caller doesn't prove every function in it is hot.
4. **Tag confidence.**
   - `high`: the bad outcome is clearly visible from the evidence.
   - `medium`: suspicious, but the harm depends on context not fully visible.
   - `low`: the pattern matches, but you're unsure it's harmful here.
5. **Tag impact** by how much of the stated workload or risk it affects.
   - `high`: a large share of the goal metric, or data loss, a security breach, or an outage.
   - `medium`: a noticeable cost on a path that runs often, or a bug under plausible conditions.
   - `low`: a small or rare cost.

## Do not flag these known-good patterns

- React `setState` during render, guarded by an `if` comparing a tracked previous value to the current prop. This is the canonical way to derive state from previous renders (https://react.dev/reference/react/useState#storing-information-from-previous-renders).
- React Effects that synchronize with external systems: imperative DOM APIs, third-party widgets, browser subscriptions, focus management.
- `useSyncExternalStore` subscriptions.
- Serial `await`s in a loop where each iteration depends on the previous result.
- Fire-and-forget promises with an explicit `void` or a justifying comment.
- `SELECT *` in scripts, migrations, or admin tools where the row is small by design.
- Universal magic numbers: HTTP status codes, well-known ports, `0`/`1`/`-1` sentinels, `Math.PI`.
- "Unused" exports in library or public-API files.
- Boolean parameters where the function is single-purpose and the boolean is its primary axis (e.g. `parseFloat(s, strict)`).
- Hash maps, pointers, and heap allocation on cold paths or small data, where a layout change would add complexity with no measurable gain.
- The existence of a cache that passes the cache test in [layout.md](layout.md). Its fill path, keys, and bounds can still be findings.

## Category ownership

Every issue belongs to exactly one category.

| Concern | Owner |
|---|---|
| Race conditions, cancellation, locks across `await`, deadlocks, backpressure | **concurrency** |
| SQL injection, unsafe deserialization, weak crypto, hardcoded secrets | **security** |
| Logged-but-not-propagated errors, missing trace IDs, structured logging | **observability** |
| Memory layout, hash map vs. array, pointers vs. indices, AoS vs. SoA, bitsets, arenas, inline-capacity lists | **layout** |
| A cache that fails the cache test, even if it is also unbounded | **layout** |
| A cache that passes the test: fill, TTL, stampede, invalidation, keys | **performance** |
| Hot-path work that can be avoided: regex re-compile, `JSON.parse` per call, `.includes` in a loop over small-to-medium data | **performance** |
| N+1 queries, missing indexes, O(n²) over user data, pagination | **scalability** |
| Unbounded growth (including a cache that passes the test but has no bound), listeners not removed, leaked goroutines | **memory** |
| Unstable JSX props, missing memo on hot components | **rerenders** |
| Effect that should be an event handler or derived state | **effects** |
| Heavy module imported eagerly that should be lazy | **bundle** |

## Finding format

Evidence quote, `context:`, `harm:`, and `fix:` are all required. A finding missing any of them is invalid.

```
[ ] <category> – <file>:<line> – <issue> – impact:<low|medium|high> – confidence:<high|medium|low>
    > <1–3 lines of the offending code, quoted verbatim>
    context: <facts that make this apply here>
    harm: <concrete bad outcome in this code>
    fix: <one-line concrete change>
```

For `layout` and `performance` findings, add `measure: <how to confirm the gain>`. If it can't be measured yet, write `measure: flag, don't fix – <what is missing>`, and keep `fix:` as the candidate change.
