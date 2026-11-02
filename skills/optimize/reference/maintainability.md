# Maintainability checklists

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
