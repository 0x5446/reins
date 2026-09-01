/**
 * A phone that arrives after the machine has stopped to ask.
 *
 * This is the app's whole premise in one test. The agent hits an approval
 * while you are somewhere else; you open Rowel; the card has to be there. It
 * was not — the request crosses dsh's mux stream once, live, and a phone not
 * attached at that instant never heard it. Found by triggering an
 * `ask_user_question` and watching the phone show a spinner while the browser
 * two feet away showed a card with three options.
 *
 * The unit tests cover the bookkeeping. This one covers the thing that matters:
 * the frame reaches a phone that connects afterwards, over a real tunnel.
 */

import assert from 'node:assert/strict'
import test from 'node:test'
import { FakeAgent, RowelPhone, startStack, waitFor } from '../lib/index.js'

/** Unwrap a tunnel event into the dsh frame it carries. */
function payloadOf(event) {
  const outer = event.frame
  if (typeof outer !== 'object' || outer === null) return undefined
  return 'payload' in outer ? outer.payload : outer
}

/** A dsh mux request, shaped as the wire carries it. */
function request(type, sessionId, extra = {}) {
  return { type: 'server-request', rpcId: `rpc-${sessionId}`, method: type, payload: { type, sessionId, ...extra } }
}

test('a phone attaching after the question still gets it', { timeout: 60_000 }, async (t) => {
  const agent = new FakeAgent()
  const stack = await startStack({ agent, machineName: 'Waiting Mac' })
  t.after(() => stack.stop())
  await waitFor(() => agent.isPumping('mux'), 10_000, 'the Bridle to subscribe')

  // The machine stops and asks, with nobody attached at all.
  agent.emit(request('question/requested', 's1', {
    questions: [{ id: 'q1', question: 'Keep Exa as the only provider?', options: [{ label: 'Keep' }, { label: 'Switch' }] }],
  }))

  const phone = new RowelPhone({ bundle: stack.invite().bundle, name: 'Late iPhone' })
  t.after(() => { phone.close() })
  const asked = []
  phone.onEvent(event => {
    const payload = payloadOf(event)
    if (payload?.type === 'question/requested') asked.push(payload)
  })
  await phone.connect()

  await waitFor(() => asked.length > 0, 10_000, 'the pending question to be replayed on attach')
  assert.equal(asked[0].sessionId, 's1')
  assert.equal(asked[0].questions[0].question, 'Keep Exa as the only provider?')
})

test('a question answered before the phone arrives is not offered again', { timeout: 60_000 }, async (t) => {
  const agent = new FakeAgent()
  const stack = await startStack({ agent, machineName: 'Answered Mac' })
  t.after(() => stack.stop())
  await waitFor(() => agent.isPumping('mux'), 10_000, 'the Bridle to subscribe')

  agent.emit(request('question/requested', 's1', { questions: [{ id: 'q1', question: 'which?' }] }))
  // Answered in the browser on the Mac, before this phone ever connects.
  agent.emit(request('question/resolved', 's1'))

  const phone = new RowelPhone({ bundle: stack.invite().bundle, name: 'Late iPhone' })
  t.after(() => { phone.close() })
  const asked = []
  phone.onEvent(event => {
    if (payloadOf(event)?.type === 'question/requested') asked.push(event)
  })
  // Deliberately no `resume`: without it the only frames a phone receives are
  // the ones the Bridle volunteers on attach, which is exactly the set under
  // test. Asking for the replay too would drag in the historical pair and say
  // nothing about whether the machine still believes it is waiting.
  await phone.connect()
  await new Promise(resolve => setTimeout(resolve, 500))

  assert.deepEqual(asked, [], 'a settled question was offered to a phone as though it were still open')
})
