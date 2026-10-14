import type { Register } from 'claude-code'

// The cache TTL is 5 min by default, 1 h on the extended tier. Set it to match
// your session; the compact trigger only makes sense when TTL > COMPACT_AT.
const TTL_MS = 60 * 60 * 1000
const COMPACT_AT_MS = 5 * 60 * 1000
// Compacting spends tokens (reads the history, writes a summary), so it only
// pays off when rebuilding the cache after expiry would cost more. Below this
// context fill, let the cache expire and skip the compact.
const MIN_CONTEXT_PERCENT = 30

const fmt = (ms: number) => {
  const s = Math.max(0, Math.ceil(ms / 1000))
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`
}

export const register: Register = on => {
  // The API times the TTL from the START of a request that writes or reads the
  // cache. We touch at prompt/tool-call time, which is at or before that start,
  // so the countdown errs short (compacts early), never late.
  let lastTouch: number | null = null
  let isCompacting = false
  let hasCompactedThisWindow = false

  on('session.start', async ($, e, next) => {
    lastTouch = await $.clock.now()
    hasCompactedThisWindow = false

    $.clock.every(1000, async () => {
      if (lastTouch === null) {
        $.ui.status('cache: cold')
        return
      }
      const left = TTL_MS - ((await $.clock.now()) - lastTouch)
      if (left <= 0) {
        $.ui.status('cache: expired')
        return
      }
      $.ui.status(`cache ${fmt(left)}`)

      // Compact while idle so the rebuild after expiry is the small summary,
      // not the full conversation. compact() rejects mid-turn; retry next tick.
      if (left <= COMPACT_AT_MS && !hasCompactedThisWindow && !isCompacting) {
        isCompacting = true
        try {
          const { context } = await $.session.usage()
          if ((context.percent ?? 0) < MIN_CONTEXT_PERCENT) {
            hasCompactedThisWindow = true // small context: not worth the tokens
            return
          }
          await $.session.compact()
          hasCompactedThisWindow = true
          lastTouch = null // new prefix is not cached until the next request
          $.ui.toast('cache-clock: auto-compacted before cache expiry')
        } catch {
          // a turn is running; try again on the next tick
        } finally {
          isCompacting = false
        }
      }
    })

    return next(e)
  })

  on('prompt.submit', async ($, e, next) => {
    lastTouch = await $.clock.now()
    hasCompactedThisWindow = false
    return next(e)
  })

  on('tool.call', async ($, e, next) => {
    lastTouch = await $.clock.now()
    hasCompactedThisWindow = false
    return next(e)
  })
}
