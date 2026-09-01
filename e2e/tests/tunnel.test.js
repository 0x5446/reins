/**
 * The path a real user takes, end to end, with nothing stubbed: a phone pairs,
 * dials a Relay, and drives a DeepSeek Harness that is actually running on this
 * machine — including a real model turn.
 *
 * Requires a harness. Point ROWEL_E2E_DSH_URL at one, or let the port probe find
 * it. Without one these tests skip rather than pass silently.
 */

import assert from 'node:assert/strict'
import test from 'node:test'
import { probeDsh } from '@rowel/bridle'
import { RowelPhone, startStack, waitFor } from '../lib/index.js'

const DSH_URL = process.env.ROWEL_E2E_DSH_URL ?? await probeDsh()
const skip = DSH_URL === undefined ? 'no DeepSeek Harness is running; set ROWEL_E2E_DSH_URL' : false

/** How long a real model turn may take before the test gives up. */
const MODEL_TIMEOUT_MS = 180_000

/**
 * Unwrap one tunnel event into the dsh mux frame it carries.
 * @param {{frame: unknown}} event - the phone-side event.
 * @returns {any} the mux frame, or undefined when the event is not one.
 */
function muxFrame(event) {
  const outer = event.frame
  if (typeof outer !== 'object' || outer === null) return undefined
  return 'payload' in outer ? outer.payload : outer
}

/**
 * Pull the session events for one session out of a phone's event list.
 * @param {Array<{frame: unknown}>} events - everything the phone has seen.
 * @param {string} sessionId - the session of interest.
 * @returns {any[]} the dsh session events, in arrival order.
 */
function sessionEvents(events, sessionId) {
  const found = []
  for (const event of events) {
    const frame = muxFrame(event)
    if (frame?.type === 'session/event' && frame.sessionId === sessionId) found.push(frame.event)
  }
  return found
}

/**
 * Whether the model has finished a turn in this session.
 * @param {Array<{frame: unknown}>} events - everything the phone has seen.
 * @param {string} sessionId - the session of interest.
 * @returns {boolean} true once a `turn/end` has arrived.
 */
function finished(events, sessionId) {
  return sessionEvents(events, sessionId).some(event => event.type === 'turn/end')
}

/**
 * What the harness said when it could not reach its model.
 *
 * On the host stream rather than the session's, because it is a fact about the
 * machine rather than about the conversation.
 * @param {Array<{frame: unknown}>} events - everything the phone has seen.
 * @returns {string | undefined} the message, or undefined when nothing failed.
 */
function agentError(events) {
  for (const event of events) {
    const payload = event.frame?.payload
    if (payload?.type === 'host/agent-error') return String(payload.message ?? 'no detail')
  }
  return undefined
}

/**
 * The assistant's visible text for a session, assembled the way the app does.
 * @param {Array<{frame: unknown}>} events - everything the phone has seen.
 * @param {string} sessionId - the session of interest.
 * @returns {string} the concatenated text, preferring completed messages.
 */
function assistantText(events, sessionId) {
  const all = sessionEvents(events, sessionId)
  const complete = all
    .filter(event => event.type === 'assistant/message')
    .flatMap(event => event.data.message.content ?? [])
    .filter(block => block.type === 'text')
    .map(block => block.text)
    .join('')
  if (complete.length > 0) return complete
  // Streaming deltas are what the app renders while the turn is live; falling
  // back to them keeps this honest if a provider skips the assembled message.
  return all
    .filter(event => event.type === 'assistant/chunk' && event.data.chunk?.type === 'text-delta')
    .map(event => event.data.chunk.text)
    .join('')
}

test('a phone pairs, reaches the harness through the relay, and gets a real model reply', { skip, timeout: MODEL_TIMEOUT_MS + 60_000 }, async (t) => {
  const stack = await startStack({ dshUrl: DSH_URL, machineName: 'E2E Machine' })
  t.after(() => stack.stop())
  await stack.waitForRelay()

  const phone = new RowelPhone({ bundle: stack.invite().bundle, prefer: 'relay', name: 'E2E iPhone' })
  t.after(() => { phone.close() })

  const ready = await phone.connect()
  assert.equal(ready.machine, 'E2E Machine', 'the app learns which machine it reached')
  assert.equal(ready.dshReachable, true, 'the bridle reports its harness as up')
  assert.equal(stack.state.peers.length, 1, 'pairing recorded the device')
  assert.equal(stack.state.peers[0].name, 'E2E iPhone')

  const describe = await phone.call('host.describe', {})
  assert.equal(describe.ok, true, JSON.stringify(describe))
  assert.equal(typeof describe.value.cwd, 'string')

  // Subscribing before prompting is what a real client does.
  const events = []
  phone.onEvent(event => events.push(event))
  phone.resume(ready.seq)

  const created = await phone.call('session.create', { cwd: describe.value.cwd })
  assert.equal(created.ok, true, JSON.stringify(created))
  const sessionId = created.value.sessionId
  assert.equal(typeof sessionId, 'string')

  const prompted = await phone.call('session.prompt', {
    sessionId,
    mode: 'queue',
    content: [{ type: 'text', text: 'Reply with exactly one word and nothing else: PONG' }],
  })
  assert.equal(prompted.ok, true, JSON.stringify(prompted))

  await waitFor(() => finished(events, sessionId), MODEL_TIMEOUT_MS, 'the model to finish its turn')

  // Said before the assertion below, because an empty reply is what a provider
  // outage, an expired key and a spent quota all look like from here — and
  // "expected PONG, got \"\"" sends whoever sees it looking for a parsing bug
  // in this file. Cost an hour once, against a plan that had run out of tokens.
  const failure = agentError(events)
  assert.equal(failure, undefined, `the harness could not reach its model: ${String(failure)}`)

  const reply = assistantText(events, sessionId)
  assert.match(reply.toUpperCase(), /PONG/u, `expected the model to answer PONG, got ${JSON.stringify(reply)}`)

  const history = await phone.call('session.history', { sessionId })
  assert.equal(history.ok, true, JSON.stringify(history))
  assert.ok(Array.isArray(history.value.events), 'history comes back through the tunnel too')
})

test('the same phone reconnects without the pairing token', { skip, timeout: 120_000 }, async (t) => {
  const stack = await startStack({ dshUrl: DSH_URL })
  t.after(() => stack.stop())
  await stack.waitForRelay()
  const bundle = stack.invite().bundle

  const first = new RowelPhone({ bundle, prefer: 'relay', name: 'Persistent iPhone' })
  await first.connect()
  const identity = first.keys
  first.close()

  // A second launch of the same app: same key, no token, and the machine already
  // knows it. This is every launch after the first one.
  const second = new RowelPhone({ bundle, keys: identity, pairing: false, prefer: 'relay' })
  t.after(() => { second.close() })
  const ready = await second.connect()
  assert.equal(ready.dshReachable, true)
  assert.equal(stack.state.peers.length, 1, 'reconnecting did not create a second device')

  const result = await second.call('session.list', {})
  assert.equal(result.ok, true, JSON.stringify(result))
})

test('replay is gapless across a reconnect, and honest when it cannot be', { skip, timeout: 120_000 }, async (t) => {
  const capacity = 16
  const stack = await startStack({ dshUrl: DSH_URL, eventCapacity: capacity })
  t.after(() => stack.stop())
  await stack.waitForRelay()
  const bundle = stack.invite().bundle

  const phone = new RowelPhone({ bundle, prefer: 'relay', name: 'Flaky iPhone' })
  t.after(() => { phone.close() })
  const ready = await phone.connect()

  const seen = []
  phone.onEvent(event => seen.push(event.seq))
  phone.resume(ready.seq)

  // Frames sourced through the bridle's own log, so the test does not depend on
  // the model choosing to say anything.
  stack.core.events.append('mux', { type: 'session/subscribed', sessionId: 'a', lastSeq: 1 })
  stack.core.events.append('mux', { type: 'session/subscribed', sessionId: 'b', lastSeq: 1 })
  await waitFor(() => seen.length >= 2, 5_000, 'live frames to arrive')

  const caughtUpTo = phone.seq
  phone.close()

  // Two more while nobody is listening: well inside the buffer.
  stack.core.events.append('mux', { type: 'session/subscribed', sessionId: 'c', lastSeq: 1 })
  stack.core.events.append('mux', { type: 'session/subscribed', sessionId: 'd', lastSeq: 1 })

  const back = new RowelPhone({ bundle, keys: phone.keys, pairing: false, prefer: 'relay' })
  t.after(() => { back.close() })
  await back.connect()
  const replayed = []
  back.onEvent(event => replayed.push(event.seq))
  back.resume(caughtUpTo)
  await waitFor(() => replayed.length >= 2, 5_000, 'the gap to be replayed')
  assert.equal(replayed[0], caughtUpTo + 1, 'replay resumes at the first frame the phone missed')
  assert.deepEqual(replayed, replayed.map((_, index) => caughtUpTo + 1 + index), 'no gaps and no repeats')

  // Now overflow the buffer while nothing is attached, and confirm the bridle
  // admits the gap instead of pretending it can reach back.
  back.close()
  for (let index = 0; index < capacity + 4; index += 1) {
    stack.core.events.append('mux', { type: 'session/subscribed', sessionId: `overflow-${String(index)}`, lastSeq: 1 })
  }
  const late = new RowelPhone({ bundle, keys: phone.keys, pairing: false, prefer: 'relay' })
  t.after(() => { late.close() })
  await late.connect()
  const resyncs = []
  late.onResync(from => resyncs.push(from))
  late.resume(caughtUpTo)
  await waitFor(() => resyncs.length === 1, 5_000, 'a resync instruction')
  assert.equal(resyncs[0], stack.core.events.head, 'the app is told exactly where the bridle now is')
})
