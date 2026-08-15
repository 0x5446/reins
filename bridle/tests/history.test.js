/**
 * Thinning history pages. The bug this exists for: a real 50-message page came
 * back as 120,397 events and 22 MB because every streaming chunk rode along, and
 * the phone showed a blank conversation while it tried to decode it.
 */

import assert from 'node:assert/strict'
import test from 'node:test'
import { thinHistory } from '../lib/tunnel/history.js'

/**
 * @param {string} type - event type.
 * @param {number} turn - turn number.
 * @param {number} step - step within the turn.
 * @returns {object} a page entry.
 */
function entry(type, turn, step) {
  return { event: { type, seq: 1, data: { turn, step } } }
}

test('chunks of a committed message are dropped', () => {
  const page = {
    events: [
      entry('assistant/chunk', 1, 0),
      entry('assistant/chunk', 1, 0),
      entry('assistant/message', 1, 0),
    ],
    hasMore: false,
  }
  const { value, thinning } = thinHistory(page)
  assert.deepEqual(thinning, { before: 3, after: 1 })
  assert.equal(value.events.length, 1)
  assert.equal(value.events[0].event.type, 'assistant/message')
  assert.equal(value.hasMore, false, 'the rest of the page survives')
})

test('chunks of the in-progress message are kept', () => {
  // The tail message has no `assistant/message` yet. Its chunks are the only
  // copy of that text, and dropping them is what would make an app that opens
  // mid-turn show nothing while the web UI shows the partial answer.
  const page = {
    events: [
      entry('assistant/chunk', 1, 0),
      entry('assistant/message', 1, 0),
      entry('assistant/chunk', 1, 1),
      entry('assistant/chunk', 1, 1),
    ],
  }
  const { value } = thinHistory(page)
  assert.equal(value.events.length, 3)
  assert.deepEqual(
    value.events.map(e => `${e.event.type}@${String(e.event.data.step)}`),
    ['assistant/message@0', 'assistant/chunk@1', 'assistant/chunk@1'],
  )
})

test('everything that is not a chunk survives untouched', () => {
  const page = {
    events: [
      entry('user/message', 1, 0),
      entry('tool/call', 1, 0),
      entry('assistant/chunk', 1, 0),
      entry('assistant/message', 1, 0),
      entry('tool/result', 1, 0),
      entry('turn/end', 1, 0),
    ],
  }
  const { value } = thinHistory(page)
  assert.deepEqual(
    value.events.map(e => e.event.type),
    ['user/message', 'tool/call', 'assistant/message', 'tool/result', 'turn/end'],
  )
})

test('a page with nothing to drop is returned as-is', () => {
  const page = { events: [entry('assistant/chunk', 1, 0)] }
  const { value, thinning } = thinHistory(page)
  assert.equal(thinning, undefined)
  assert.equal(value, page, 'the same object, so no needless copy crosses the tunnel')
})

test('malformed input passes through instead of throwing', () => {
  // The Bridle forwards for a client whose build it cannot see. A transform that
  // can reject is a transform that can take the tunnel down.
  for (const input of [undefined, null, 42, 'text', {}, { events: 'not an array' }]) {
    const { value, thinning } = thinHistory(input)
    assert.equal(value, input)
    assert.equal(thinning, undefined)
  }
})

test('an event missing turn or step is never dropped', () => {
  const page = {
    events: [
      { event: { type: 'assistant/chunk', data: {} } },
      entry('assistant/message', 1, 0),
    ],
  }
  const { value } = thinHistory(page)
  assert.equal(value.events.length, 2, 'a chunk that cannot be matched is kept, not guessed at')
})
