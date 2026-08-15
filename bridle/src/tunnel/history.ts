/**
 * Thinning `session.history` pages before they cross the tunnel.
 *
 * A history page is bounded by *messages* — dsh defaults to the last 50 — but
 * it carries the whole raw event range those messages span, and that range is
 * dominated by `assistant/chunk`. One real session measured here: 50 messages,
 * 120,397 events, 22 MB, of which 120,092 were chunks. A browser on the same
 * machine absorbs that. A phone on Wi-Fi decoding it into a tree of enum values
 * does not, and the screen stays blank while it tries.
 *
 * Chunks are not lost information for a *committed* message: `assistant/message`
 * carries the assembled content, and the fold replaces the streaming bubble with
 * it. The chunks only matter for a message that has not been committed yet — the
 * in-progress one at the tail — which is what lets an app opening mid-turn see
 * the same partial text the web UI does.
 *
 * So the rule is exactly one line long: drop a chunk when a message for the same
 * `turn.step` exists on the page. On that 22 MB page it leaves 305 events.
 */

/** One entry of a history page: the session event plus its optional tool view. */
interface HistoryEntry {
  event?: { type?: unknown; data?: { turn?: unknown; step?: unknown } }
}

/** What `session.history` answers with. */
interface HistoryValue {
  events?: unknown
  [key: string]: unknown
}

/** How much a page shrank, for the debug log. */
export interface Thinning {
  before: number
  after: number
}

/**
 * Identify a message's slot within the session.
 * @param data - the event's `data` object.
 * @returns `turn.step`, or undefined when either is missing.
 */
function slotOf(data: { turn?: unknown; step?: unknown } | undefined): string | undefined {
  if (data === undefined) return undefined
  const { turn, step } = data
  if (typeof turn !== 'number' || typeof step !== 'number') return undefined
  return `${String(turn)}.${String(step)}`
}

/**
 * Drop the chunks of every message the same page already carries in full.
 *
 * Anything that is not a history page — a different method's value, a malformed
 * one — passes through untouched rather than throwing. The Bridle forwards for a
 * client it cannot see the code of, and a transform that can reject is a
 * transform that can take the tunnel down.
 * @param value - the `session.history` result value.
 * @returns the value with superseded chunks removed, and what that saved.
 */
export function thinHistory(value: unknown): { value: unknown; thinning: Thinning | undefined } {
  if (typeof value !== 'object' || value === null) return { value, thinning: undefined }
  const page = value as HistoryValue
  if (!Array.isArray(page.events)) return { value, thinning: undefined }
  const entries = page.events as HistoryEntry[]

  const committed = new Set<string>()
  for (const entry of entries) {
    if (entry.event?.type !== 'assistant/message') continue
    const slot = slotOf(entry.event.data)
    if (slot !== undefined) committed.add(slot)
  }
  if (committed.size === 0) return { value, thinning: undefined }

  const kept = entries.filter((entry) => {
    if (entry.event?.type !== 'assistant/chunk') return true
    const slot = slotOf(entry.event.data)
    return slot === undefined || !committed.has(slot)
  })
  if (kept.length === entries.length) return { value, thinning: undefined }

  return {
    value: { ...page, events: kept },
    thinning: { before: entries.length, after: kept.length },
  }
}
