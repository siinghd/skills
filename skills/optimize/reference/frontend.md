# Frontend checklists

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

- [ ] **Bundle & runtime** – heavy modules imported eagerly that belong behind `lazy` / dynamic import, missing debounce/throttle on high-frequency events (scroll, input, resize, mousemove), synchronous CPU work on the main thread that belongs in `requestIdleCallback` or a worker, large images/assets without optimization.
