---
name: optimize
description: Comprehensive optimization audit for any codebase (frontend, backend, libraries, scripts) — finds bad logic, missing abstractions, security smells, type-safety gaps, concurrency issues, observability gaps, test smells, performance hot spots, re-renders, unnecessary Effects, memory leaks, dead code, scalability issues, and bundle bloat, then fixes what you approve. **By default, scopes to the current working set** (uncommitted changes + files changed on the current branch vs. the base branch) — not the entire repo. Pass `repo` as the path arg to scan the full codebase, or a path/glob to scope explicitly (e.g. `/optimize performance src/api/**`).
argument-hint: "[all | logic | abstractions | security | types | concurrency | observability | tests | performance | rerenders | effects | memory | scalability | deadcode | bundle] [path-or-glob | repo]"
disable-model-invocation: true
---

Perform a comprehensive optimization audit on this codebase. Work in two phases.

## Phase 0 – Detect stack and scope (one short pass)

**Stack detection** — identify what applies so you can skip inapplicable categories:
- Look for `package.json`, `tsconfig.json`, `go.mod`, `pyproject.toml`/`requirements.txt`, `Cargo.toml`, `Gemfile`, `pom.xml`/`build.gradle`, `composer.json`, etc.
- Note: language(s), whether React/Vue/Svelte is present, whether there's a bundler (Vite/Webpack/Next/etc.), whether there's a server framework, whether there's a typed superset (TypeScript, mypy, etc.), whether there's a test runner.

**Scope resolution — default to the current working set, not the whole repo.** Resolve in this order:

1. If the path arg is `repo` (or `--all-files`) → scope = entire repository.
2. Else if a path/glob was provided → scope = that path/glob, expanded to a concrete file list.
3. Else (default) → scope = the **current working set**:
   - Uncommitted changes: `git status --porcelain` → files with any status (staged, unstaged, untracked).
   - Plus branch changes vs. base: `git diff --name-only $(git merge-base HEAD origin/main 2>/dev/null || git merge-base HEAD main 2>/dev/null || git merge-base HEAD master 2>/dev/null)...HEAD`.
   - Filter out deleted files and binary/lock files (`*.lock`, `package-lock.json`, `pnpm-lock.yaml`, images, etc.).
   - If the resulting set is empty (clean working tree on base branch), fall back to the last commit's changed files (`git diff --name-only HEAD~1 HEAD`). If still empty, tell the user "no working changes detected — pass `repo` to scan the whole codebase or a path to scope explicitly" and stop.
   - Important caveat: cross-file findings (abstraction opportunities across many sites, scalability patterns, dead-code unused-export detection) are weaker on a partial scope — note this in the output: `Scope: working set (N files) — cross-file categories may miss findings outside scope.`

Output a one-line summary up front: `Stack: <lang(s)> · <frameworks> · <bundler|none> · <test runner|none>` and `Scope: <working set | repo | <glob>> (N files)`. Use the stack info to skip clearly-inapplicable categories outright (don't list them).

## Phase 1 – Audit (read-only, parallelized via sub-agents)

**The goal: in one pass, check each file in full context — no double work, no false positives from pattern-matching in isolation.** Two failure modes to avoid: (a) reading the same file N times for N categories, (b) flagging an "anti-pattern" that's actually the canonical solution because the auditor didn't see the surrounding context.

### Dispatch strategy depends on scope size

- **≤ 30 files (working-set scope, typical case)** → fan out **by file bucket**, not by category. Group the file list into ~5 roughly-balanced buckets. Spawn one `Explore` sub-agent per bucket; each reads its files **once** and runs **all applicable categories** on them in a single pass. This is the "in one go" mode — patterns are evaluated against surrounding code, each file is read once, false positives drop sharply.

- **> 30 files (repo scope, large globs)** → fan out **by category**. Spawn one `Explore` sub-agent per applicable category; each scans the full file list looking for its specific patterns. Trades context for search throughput at scale.

Both modes dispatch in a **single message with multiple `Agent` tool calls** so they run concurrently. Wall-clock is bounded by the slowest bucket/category, not the sum.

### Anti-false-positive rules (every sub-agent applies these)

1. **Read enough context.** Before flagging, read at least 10 lines around the candidate site. If the surrounding code legitimizes the pattern (a guarding condition, an explanatory comment, a recognised idiom), do not flag.

2. **Articulate harm concretely.** Every finding must include a one-line `harm:` describing the bad outcome **in this specific code**. "Pattern X is sometimes problematic" is not enough; "here, X causes Y under Z" is required. If you can't write that line, drop the finding.

3. **Confidence tagging.** Every finding carries `confidence: high | medium | low`:
   - `high` — the bad outcome is clearly visible from the evidence alone.
   - `medium` — the pattern is suspicious but the harm depends on context not fully visible.
   - `low` — the pattern matches but you're unsure if it's harmful here.

4. **Respect known-good patterns — do NOT flag these:**
   - **React `setState` during render** when it's the canonical pattern for deriving state from props/previous-state (see https://react.dev/reference/react/useState#storing-information-from-previous-renders). The shape: a `setState` call inside the render body, guarded by an `if` comparing a tracked previous value to the current prop.
   - **React Effects that synchronize with external (non-React) systems** — DOM imperative APIs, third-party widgets, subscriptions to browser APIs, focus management. Effects are *intended* for these.
   - **`useSyncExternalStore`** subscriptions — they look like manual subscription code but are the correct primitive.
   - **Serial `await`s in a loop where each iteration depends on the previous result** — sequential ordering is the requirement, not a perf bug.
   - **Fire-and-forget promises with an explicit `void` operator or a comment justifying it** — intentional, not a bug.
   - **`SELECT *`** in scripts/migrations/admin tools where the schema is narrow or the row is small by design.
   - **Magic numbers that are universal** — HTTP status codes, well-known ports, `0`/`1`/`-1` sentinels, `200`/`404`/`500`, `Math.PI`.
   - **"Unused" exports in library/public-API files** — they're the API surface, not dead code.
   - **Boolean parameters where the function is single-purpose and the boolean is its primary axis** (e.g. `parseFloat(s, strict)`).

### Category ownership (no double-flagging)

Every issue belongs to exactly one category. When a pattern fits two, the leftmost wins:

| Concern | Owner |
|---|---|
| Race conditions, cancellation, locks across `await`, deadlocks, backpressure | **concurrency** (not logic) |
| Caching strategy (read-through, single-flight, TTLs, stampede) | **performance** (not scalability) |
| N+1 queries, missing indexes, O(n²) over user data, pagination | **scalability** (not performance) |
| Wrong data structures (`.includes` in loop, regex re-compile, `JSON.parse` per call) | **performance** (not logic) |
| Unbounded caches, listeners not removed, leaked goroutines | **memory** (not performance) |
| SQL injection, unsafe deserialization, weak crypto, hardcoded secrets | **security** (not logic) |
| Logged-but-not-propagated errors, missing trace IDs, structured logging | **observability** (not logic) |
| Unstable JSX props, missing memo on hot components | **rerenders** (not performance) |
| Effect that should be an event handler / derived state | **effects** (not rerenders) |
| Heavy module imported eagerly that should be `lazy` / dynamic import | **bundle** (not performance) |

In file-bucket mode, the sub-agent applies this table itself. In category mode, each agent only owns its slice and ignores cross-category territory.

### Sub-agent prompt contents (both modes)

Each sub-agent receives a self-contained prompt with:
- The categories it owns + full bullets (file-bucket: all applicable categories with the ownership table; category mode: one category).
- The resolved file list from Phase 0. Must not scan outside this list.
- The stack summary from Phase 0.
- The four anti-false-positive rules above (verbatim).
- The finding format (below).
- A cap: top 15 findings per category, sorted by impact desc then confidence desc.
- Instruction to return *only* structured findings, nothing else.

### Finding format

```
[ ] <file>:<line> – <issue> – impact:<low|medium|high> – confidence:<high|medium|low>
    > <1–3 lines of the offending code, quoted verbatim>
    harm: <concrete bad outcome in this code>
    fix: <one-line concrete change>
```

Evidence quote, `harm:`, and `fix:` are all required. A finding missing any of them is invalid and gets dropped during validation.

### Parent-side validation pass (single pass before printing)

After sub-agents return, run **one validation pass** to clean the aggregated list:

1. **De-dup** by `file:line` — drop duplicates across categories (e.g. concurrency and logic both flagged the same race). Keep the one whose category owns it per the ownership table; tie-break on higher confidence.
2. **Drop low-confidence** by default — `confidence: low` findings are hidden. At the end, print one line: `Suppressed N low-confidence findings — pass --show-low to see them.` (no implementation needed for the flag, just signal the count exists).
3. **Sanity-check harm** — for each finding, does the `harm:` line concretely follow from the evidence? Drop generic harms ("could cause bugs", "may not scale", "potential issue") that don't tie to the code.
4. **Sort within category** by impact desc, then confidence desc.
5. Apply per-category cap (top 15) and the >50-total summary mode.
6. Print: stack line, scope line, then each category in stable order (logic → abstractions → security → types → concurrency → observability → tests → performance → rerenders → effects → memory → scalability → deadcode → bundle). Skip categories that produced no findings or are stack-inapplicable.

The audit applies to any code — frontend, backend, CLIs, libraries, scripts. Skip categories that don't apply to the detected stack (e.g. no React → skip rerenders/effects; no bundler → skip bundle). Apply the general categories (logic, abstractions, security, performance, memory, scalability, deadcode) to every codebase.

### Categories

- [ ] **Bad logic & code smells** (general) – correctness and clarity issues that aren't bugs yet but will become bugs or maintenance traps. Flag each with a one-line fix:
  - Incorrect or sloppy control flow: misplaced `await`, missing `await` on a promise, swallowed exceptions (`catch {}`, `catch (e) { /* ignore */ }`), `try` blocks that hide the real error, returning inside `finally`, mutating a variable while iterating it.
  - Wrong data structures: O(n) `.includes` / `.indexOf` inside a loop where a `Set`/`Map` would be O(1); arrays used as queues with `shift()`; repeated `.find` over the same list; rebuilding the same lookup map on every call.
  - Off-by-one and boundary bugs: inclusive/exclusive range mistakes, empty-input cases not handled, last-element edge cases, integer overflow, unchecked division by zero.
  - Boolean and null handling: truthy checks that conflate `0`/`""`/`false` with "missing", `==` vs `===`, `!= null` vs explicit checks, optional chaining masking real bugs, default values that hide upstream nulls.
  - Time and concurrency: race conditions between async calls, fire-and-forget promises, shared mutable state across requests, non-idempotent retries, lock held across an `await`, comparing wall-clock times across timezones, parsing dates without an explicit format.
  - I/O and resources: file/socket/DB handles not closed on error paths, missing `using`/`with`/`defer`, reading entire files into memory when streaming would do, unbounded buffering.
  - Error handling: errors logged but not propagated (or vice versa), generic `Error` thrown where a typed error matters, error messages that don't include the offending value, retries with no backoff or no cap.
  - Validation and trust boundaries: input validated in one path but not another, server trusting client-supplied IDs, missing authorization on a "obviously internal" endpoint, SQL/shell/HTML interpolation instead of parameterization.
  - API contract drift: function signature says one thing, callers assume another; nullable fields treated as non-null; enum widened in one place but not exhaustively handled elsewhere.
  - Naming and clarity: misleading names (`getUser` that mutates, `isReady` that fetches), boolean parameters that flip behaviour, deeply nested conditionals that invert easily with early returns, functions doing two unrelated things.
  - Comments lying about the code, TODO/FIXME older than 6 months without a tracking link, dead `console.log` / `print` / debug code shipped to prod.

- [ ] **Security smells** (general) – issues that aren't a full security audit but are clear smells:
  - Hardcoded secrets, API keys, tokens, or credentials in source/config; `.env` committed; secrets in test fixtures.
  - SQL/shell/HTML/template injection: string-concatenation into queries or commands instead of parameterized APIs.
  - Path traversal: user input fed into `fs`/`open` without normalizing or anchoring under a base dir.
  - SSRF: server-side fetches whose URL/host comes from user input without an allowlist.
  - Weak crypto: MD5/SHA1 for security purposes, ECB mode, hardcoded IVs, `Math.random()` for tokens, custom crypto.
  - AuthZ gaps: routes/handlers missing authentication or ownership checks; "internal" endpoints exposed publicly; mass-assignment of incoming objects into DB models.
  - Unsafe deserialization: `pickle.loads`, `yaml.load` (unsafe), `eval`, `Function(...)`, `child_process.exec` with interpolation.
  - CORS `*` on credentialed endpoints, missing CSRF on state-changing routes, cookies without `Secure`/`HttpOnly`/`SameSite`.
  - Logging or error responses that leak PII, tokens, or stack traces to clients.
  - Missing rate limits / brute-force protection on auth, password reset, OTP, or expensive endpoints.

- [ ] **Type safety** (typed languages — TS/Python-with-types/etc.; skip if untyped) –
  - `any` / `unknown` / `interface{}` leaks across module boundaries; values cast with `as` / `# type: ignore` to silence errors instead of fixing them.
  - `JSON.parse` / external input typed as the expected shape without a runtime validator (zod, valibot, pydantic, etc.).
  - Discriminated unions handled non-exhaustively (`switch` without a `default: never` / `assertNever`).
  - Nullable fields treated as non-null via `!` / `as NonNullable<...>` without a check.
  - Function signatures that lie (return type wider than reality, parameters typed `string` but used as `string | undefined`).
  - `// @ts-expect-error` / `# type: ignore` without an explanatory comment or a tracking link.

- [ ] **Concurrency** (general) – flag separately from logic when concurrent execution is in play:
  - Shared mutable state across async tasks/goroutines/threads without a lock or message passing.
  - Promises/futures fired in parallel where order matters, or awaited serially in a loop where they could be batched (`Promise.all` / `gather` / errgroup).
  - Missing cancellation: long operations with no `AbortController` / `context.Context` / `CancellationToken` plumbed through.
  - Goroutines/tasks leaked: spawned but never awaited or cancelled; channels/queues without a clear closer.
  - Backpressure ignored: producers outrun consumers with no bounded buffer; unbounded `Promise.all` over a huge list.
  - Locks held across `await` / I/O; nested locks taken in inconsistent order (deadlock risk); double-checked locking that isn't safe in this language.
  - Non-atomic read-modify-write on shared counters/maps; using `Map`/dict as a cache from multiple workers without sync.
  - Time-based logic without a clock abstraction (untestable; flaky under clock skew).

- [ ] **Observability** (server / long-running code) –
  - Errors caught and logged but not propagated, or propagated without context (no wrapping, no offending value).
  - Logs without correlation/request/trace IDs across service boundaries; logs at the wrong level (errors at `info`, debug spam at `warn`).
  - Missing structured logging (`console.log("user " + id)` instead of structured fields); PII logged in plaintext.
  - No metrics/spans on slow paths (DB calls, external HTTP, queue handlers); SLO-relevant code paths invisible.
  - Health checks that don't actually check dependencies; readiness vs liveness conflated.
  - `try/catch` swallowing errors with no telemetry signal at all.

- [ ] **Test smells** (when tests exist) –
  - Tests asserting on implementation details (private fns, internal state, exact log strings) instead of behaviour.
  - Shared mutable state across tests (module-level vars, DB rows, files) causing order-dependence.
  - Time and randomness used directly (`Date.now()`, `Math.random()`) instead of injected — sources of flakiness.
  - Snapshot tests with no semantic assertions; snapshots so large no one reviews diffs.
  - Tests that always pass (assertion never reachable, mocked fn never called but no `expect(...).toHaveBeenCalled`).
  - `it.skip` / `xit` / `@pytest.mark.skip` left in without a tracking link.
  - Mocks deeper than one layer (mocking what you mock); integration tests that mock the database under test.
  - Slow setup repeated per test where a shared fixture would do; missing isolation between parallel tests.

- [ ] **Re-renders** (React) – missing/incorrect `memo`/`useMemo`/`useCallback`, unstable object/array/function props, inline `{}` / `[]` / `() => {}` passed as props, context providers whose `value` is a new reference every render, bad `useEffect` dependency arrays (missing, stale, or over-broad).

- [ ] **Unnecessary Effects** (React) – code that violates https://react.dev/learn/you-might-not-need-an-effect. Flag each occurrence:
  - Derived state stored in `useState` + synced via `useEffect` → compute directly in render (wrap in `useMemo` only if measurably expensive).
  - Effect that runs only in response to a user action → move the logic into the event handler.
  - Effect that resets or adjusts state when a prop changes → use `key` to remount, or compute during render from a tracked previous value.
  - Chain of Effects where one `setState` triggers another Effect → collapse into a single event handler.
  - Effect that POSTs to an API in response to a state change → call the API directly in the handler.
  - Child Effect calling an `onChange` / `onFetched` prop → lift state to the parent, or call the callback in the handler.
  - App initialization inside an Effect with `[]` deps → move to module scope or guard with a module-level flag.
  - Manual `addEventListener` + cleanup in an Effect subscribing to an external store → use `useSyncExternalStore`.

- [ ] **Memory leaks** (general) – event listeners without cleanup, `setInterval`/`setTimeout` not cleared on unmount/shutdown, subscriptions / WebSocket / EventSource / observers / DB connections / streams not closed, async ops resolving after cancel/unmount without an `AbortController` or context cancellation, closures retaining large objects, unbounded caches/maps that grow forever, goroutines/tasks/threads spawned in a loop without lifetime management.

- [ ] **Scalability** (general) – N+1 queries, missing batching, unindexed DB lookups, transactions held across network calls, missing pagination/cursors, unbounded lists rendered or returned, O(n²) loops over user-scaled data, synchronous calls in a loop where a bulk API exists, hot loops re-allocating, missing caching at obvious boundaries, tight coupling / circular imports / cross-module reach-ins.

- [ ] **Performance hot spots** (general) – issues that cost real wall-clock time, distinct from algorithmic scalability. Bullets are tagged by where they apply; skip ones that don't fit the stack:
  - **Compute** – regex re-compiled inside a loop instead of hoisted, JSON re-parsed/re-stringified on every read, repeated work that should be hoisted out of a loop or memoized, missing memoization on pure expensive functions, redundant deep clones, recomputing the same selector/derived value per call.
  - **Allocation / GC** – object/array literals created in tight loops, string concatenation in a loop where `join`/`StringBuilder`/`bytes.Buffer` would do, boxing primitives unnecessarily, large temporary arrays from chained `map`/`filter` over big inputs (use a single pass or a transducer), holding references that block GC.
  - **Network** (any code making HTTP calls) – serial `await`s for independent requests that could run in parallel (`Promise.all` / `gather` / errgroup), no request deduping for identical concurrent calls, no single-flight / coalescing under load, missing retries with backoff *and* a cap, missing timeouts (default-infinite is the bug), payloads larger than they need to be (no field selection, no compression).
  - **HTTP server** – missing `Cache-Control` / `ETag` on cacheable responses, no gzip/brotli on text responses, no HTTP/2 or keep-alive where the platform supports it, redirect chains, blocking middleware on the hot path.
  - **Database** (beyond N+1 in scalability) – `SELECT *` returning fat rows when only a few columns are used, missing covering indexes for hot queries, queries without `LIMIT` on user-driven lists, ORM lazy-loading footguns crossing request boundaries, row-by-row inserts/updates where a bulk statement exists, transaction scope wider than it needs to be (lock contention), missing connection pool or pool sized wrong, prepared statements re-prepared per call.
  - **Caching strategy** – read-through cache missing in front of expensive lookups, no negative caching (every miss hits the origin), cache stampede risk (no single-flight / lock around fill), TTLs that are wrong (forever, or so short the cache is useless), cache key not including all variance (per-user data served cross-user).
  - **Startup / cold start** – heavy work at module import time (DB connects, large file reads, regex/AST builds), eager initialization of subsystems used by 1% of requests, sync filesystem reads at boot, large bundles loaded before first paint.
  - **Frontend rendering** (browser) – layout thrash (read–write–read–write cycles forcing sync layout), expensive CSS selectors, massive initial DOM, large inline base64 assets blocking first paint, render-blocking CSS/JS, non-passive scroll/touch listeners.
  - **Asset delivery** (frontend) – unoptimized images (no `srcset`, no modern format like AVIF/WebP, no width/height attributes causing CLS), no CDN, no preconnect/preload for critical resources, fonts blocking render without `font-display: swap`.
  - **Batching & coalescing** – missing debounce on writes (e.g. autosave fires per keystroke), missing throttle on high-frequency reads (resize/scroll observers), per-event work that could be coalesced into a microtask/`requestAnimationFrame`, write fan-out that could be batched into a single transaction.
  - **Measurement discipline** – call out where a fix needs profiling first ("flag, don't fix") rather than guessing. Performance work without a measurement is how regressions get added.

- [ ] **Dead code** – unused imports, variables, exports, functions, types; unreachable branches; obsolete feature flags; long-commented-out blocks.

- [ ] **Abstraction opportunities** – code that isn't a literal copy but *should* be lifted into a reusable abstraction. Flag each occurrence with the call sites involved and a concrete target shape (function signature, hook name, component API):
  - Similar-shaped logic across call sites that varies only in a value, type, or one step → parameterize into a single function/hook (don't force a premature abstraction if the variation is genuinely diverging — note that explicitly).
  - Multi-step procedures (fetch → validate → transform → persist) repeated with minor differences → extract a pipeline/orchestrator and inject the differing step.
  - Cross-cutting concerns inlined per call site (auth checks, logging, retries, error mapping, telemetry, feature-flag gates) → lift into a wrapper, decorator, middleware, or hook.
  - Conditional logic keyed on a "kind"/"type" field reimplemented in several files → consolidate behind a strategy map, registry, or discriminated-union handler.
  - Imperative loops doing filter/map/reduce by hand → use the appropriate higher-order operation, or extract a named domain operation if the intent is non-obvious.
  - Repeated React patterns (data fetching + loading/error UI, controlled-form boilerplate, debounced input + effect, subscription lifecycle) → extract a custom hook with a clear API.
  - Repeated UI composition (same wrapper + className stack + prop plumbing) → extract a styled primitive or compound component.
  - Domain concepts represented as raw primitives in many places (IDs, money, durations) → introduce a typed wrapper / branded type / value object.
  - Magic values used to coordinate behaviour across files → centralize as named constants, an enum, or config.
  - Test setup that re-creates the same world per file → extract a factory/builder or shared fixture.
  - Be honest about cost: only flag when the abstraction reduces real complexity. Note "rule of three" — two similar sites is usually fine; three+ with the same shape is the signal. Avoid abstracting things that look alike but evolve independently.

- [ ] **Bundle & runtime** – heavy modules imported eagerly that belong behind `lazy` / dynamic import, missing debounce/throttle on high-frequency events (scroll, input, resize, mousemove), synchronous CPU work on the main thread that belongs in `requestIdleCallback` or a worker, large images/assets without optimization.

## Phase 2 – Apply fixes (parallelized by file, not by category)

- Argument = `all` → fix everything **except `high`-impact items**. Before touching any `high` item, list the planned changes in 1–2 lines each and pause once for confirmation. This prevents sweeping changes you didn't intend.
- Argument = a category name (`logic`, `abstractions`, `security`, `types`, `concurrency`, `observability`, `tests`, `performance`, `rerenders`, `effects`, `memory`, `scalability`, `deadcode`, `bundle`) → fix only that category. Same `high`-impact gate applies.
- No argument → pause and ask: *"Which items should I fix? Reply with 'all', specific numbers, or a category name."*

**Sub-agent dispatch for fixes:**
1. Group all approved findings by **file path** (not by category) — multiple edits to the same file must be serialized to avoid write conflicts.
2. Group files into independent buckets (no shared file). Spawn one sub-agent per bucket in a single message with multiple `Agent` calls. Use `subagent_type: "general-purpose"` for fixes.
3. Each sub-agent gets the list of findings for its files, the fix rules below, and is told to return a one-line summary per fix applied (`<file>:<line> – <what changed> – <why>`).
4. After sub-agents complete, the parent runs verification (typecheck/lint/tests) once across the whole change set and reports pass/fail.

If only one or two findings are approved, skip sub-agents and apply directly — orchestration overhead isn't worth it below that threshold.

Fix rules (apply in every sub-agent and in the parent if fixing directly):
- Only proceed with fixes after a response when no argument was given.
- For each fix applied, state in one line what changed and why.
- Make one logical fix per edit — do not bundle unrelated fixes into a single edit.
- After fixes in a given category, run the obvious verification step if available (typecheck, lint, the relevant test file) and report pass/fail. Don't claim done without verification when verification is cheap.
- If an issue requires broader architectural change, flag it as a note rather than patching unsafely.
- Never silently expand scope: don't refactor neighbouring code "while you're there." If you find a new issue mid-fix, add it to the audit list, don't fix it inline.

**Argument received:** $ARGUMENTS
