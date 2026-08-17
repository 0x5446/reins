/**
 * Thinning `session.list` before it crosses the tunnel.
 *
 * The list is the one screen that cannot be paged. dsh answers `session.list`
 * with every session it has and ignores `limit`, `offset` and `cursor` alike —
 * measured, all three — so the payload grows with the person's history and the
 * client has no say in it.
 *
 * What it grows *with* is the surprise. Each row carries the session's whole
 * projection set: permissions and their options, image limits, token usage,
 * context breakdown, plan state. On one real machine — 67 sessions, 77 KB —
 * that came to nine tenths of the bytes, and the app reads exactly one of those
 * projections, `title`. The rest it folds per conversation from the event
 * stream when a conversation is opened, so the copies in the list are answers
 * to a question nobody asks.
 *
 * Dropping them is the same trade `thinHistory` makes: the Bridle knows what
 * crosses a phone's radio and dsh does not. It is safe in both directions of
 * version skew — an older app already read only the title, and a newer app
 * against an older Bridle simply receives the fat rows it can still parse.
 *
 * Deliberately a keep-list rather than a drop-list. A projection dsh adds next
 * year should be absent by default rather than shipped to every phone because
 * nobody remembered to name it here.
 */

/** Projections the app actually reads from a list row. */
const KEPT_PROJECTIONS = new Set(['title'])

/** One row of `session.list`. */
interface Row {
  projections?: { values?: Record<string, unknown>; [key: string]: unknown }
  [key: string]: unknown
}

/** What `session.list` answers with. */
interface Roster {
  items?: unknown
  [key: string]: unknown
}

/** How much the list shrank, for the debug log. */
export interface Trimming {
  before: number
  after: number
}

/**
 * Strip every list-row projection the app does not read.
 *
 * Anything that is not a session list — another method's value, a malformed
 * one — passes through untouched rather than throwing, for the reason
 * `thinHistory` gives: a transform that can reject is a transform that can
 * take the tunnel down.
 * @param value - the `session.list` result value.
 * @returns the value with unread projections removed, and what that saved.
 */
export function thinRoster(value: unknown): { value: unknown; trimming: Trimming | undefined } {
  if (typeof value !== 'object' || value === null) return { value, trimming: undefined }
  const roster = value as Roster
  if (!Array.isArray(roster.items)) return { value, trimming: undefined }

  const before = JSON.stringify(roster.items).length
  const items = (roster.items as Row[]).map((row) => {
    const values = row.projections?.values
    if (typeof values !== 'object' || values === null) return row
    const kept: Record<string, unknown> = {}
    for (const [name, projection] of Object.entries(values)) {
      if (KEPT_PROJECTIONS.has(name)) kept[name] = projection
    }
    return { ...row, projections: { ...row.projections, values: kept } }
  })

  const after = JSON.stringify(items).length
  if (after >= before) return { value, trimming: undefined }
  return { value: { ...roster, items }, trimming: { before, after } }
}
