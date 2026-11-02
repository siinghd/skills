# Correctness and safety checklists

- [ ] **Bad logic & code smells** (general) – correctness and clarity issues that aren't bugs yet but will become bugs or maintenance traps. Flag each with a one-line fix:
  - Incorrect or sloppy control flow: misplaced `await`, missing `await` on a promise, swallowed exceptions (`catch {}`, `catch (e) { /* ignore */ }`), `try` blocks that hide the real error, returning inside `finally`, mutating a variable while iterating it.
  - Wrong data structures: O(n) `.includes` / `.indexOf` inside a loop where a keyed lookup would be O(1) (a `Set`/`Map`, or a flat array when keys are dense; see [layout.md](layout.md) for hot paths); arrays used as queues with `shift()`; repeated `.find` over the same list; rebuilding the same lookup map on every call.
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
