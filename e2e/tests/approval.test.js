/**
 * Human-in-the-loop, end to end.
 *
 * The architecture document claimed the end-to-end suite proved approvals. It
 * did not — there was no approval test anywhere, and "the code exists" had been
 * standing in for "the chain works". This closes that.
 *
 * A fake harness rather than a real one, deliberately. An approval only happens
 * when a model decides to run something that needs one, and waiting for that is
 * a hope, not a test. The fake implements the same five-method seam the Bridle
 * talks to, so everything above it — the tunnel, the frames, the rpcId
 * correlation, the response path — is the real thing.
 */

import assert from 'node:assert/strict'
import test from 'node:test'
import { FakeAgent, ReinsPhone, startStack } from '../lib/index.js'

/**
 * @param {Function} predicate - polled until it returns truthy.
 * @param {string} what - named in the timeout message.
 * @returns {Promise<void>} resolves once the predicate holds.
 */
async function waitFor(predicate, what, timeoutMs = 5_000) {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    if (predicate()) return
    await new Promise(resolve => setTimeout(resolve, 20))
  }
  throw new Error(`timed out waiting for ${what}`)
}

/**
 * @param {object} t - the node:test context.
 * @returns {Promise<object>} a connected phone and the fake it talks through.
 */
async function connected(t) {
  const agent = new FakeAgent()
  const stack = await startStack({ agent, dshUrl: 'http://127.0.0.1:3080' })
  t.after(() => stack.stop())

  const phone = new ReinsPhone({ bundle: stack.invite().bundle, prefer: 'direct' })
  t.after(() => { phone.close() })

  const events = []
  phone.onEvent(event => events.push(event))
  const ready = await phone.connect()
  phone.resume(ready.seq)
  await waitFor(() => agent.isPumping('mux'), 'the Bridle to subscribe to the harness')
  return { agent, phone, events }
}

test('an approval reaches the phone with everything it needs to answer', async (t) => {
  const { agent, events } = await connected(t)

  agent.requestApproval({ sessionId: 's1', toolName: 'bash', reason: 'rm -rf /tmp/x' })

  await waitFor(() => events.length > 0, 'the approval to arrive on the phone')
  const frame = events[events.length - 1].frame
  assert.equal(frame.payload.type, 'approval/requested')
  assert.equal(frame.payload.sessionId, 's1')
  assert.equal(frame.payload.toolName, 'bash')
  assert.equal(frame.payload.reason, 'rm -rf /tmp/x', 'the reason survives; it is what the person decides on')
  assert.ok(typeof frame.rpcId === 'string' && frame.rpcId.length > 0,
    'without the rpcId the answer has nothing to address')
})

test('the answer gets back to the harness, addressed to the right request', async (t) => {
  const { agent, phone, events } = await connected(t)

  const rpcId = agent.requestApproval({ sessionId: 's1', toolName: 'bash' })
  await waitFor(() => events.length > 0, 'the approval')

  await phone.answer(rpcId, { decision: "allow-once" })

  await waitFor(() => agent.responses.length > 0, 'the answer to reach the harness')
  const answer = agent.responses[0]
  assert.equal(answer.type, 'client-response')
  assert.equal(answer.rpcId, rpcId, 'the harness routes by rpcId; a wrong one answers someone else')
  assert.deepEqual(answer.result, { ok: true, value: { decision: 'allow-once' } })
})

test('a question reaches the phone with its options intact', async (t) => {
  const { agent, events } = await connected(t)

  agent.askQuestion({ sessionId: 's1', question: 'Which branch?', options: ['main', 'develop'] })

  await waitFor(() => events.length > 0, 'the question')
  const payload = events[events.length - 1].frame.payload
  assert.equal(payload.type, 'question/requested')
  assert.equal(payload.questions[0].question, 'Which branch?')
  assert.deepEqual(payload.questions[0].options.map(o => o.label), ['main', 'develop'],
    'options that do not survive leave the person unable to answer')
})

test('an approval raised while the phone is away is replayed on reconnect', async (t) => {
  // The case that matters most: approvals arrive while the phone is asleep, and
  // the whole product is worthless if they are lost. This is the replay buffer
  // doing its job on the one frame type where losing it is unrecoverable.
  const { agent, phone, events } = await connected(t)
  const seen = phone.seq

  phone.close()
  agent.requestApproval({ sessionId: 's1', toolName: 'write' })

  const ready = await phone.connect()
  phone.resume(seen)

  await waitFor(
    () => events.some(e => e.frame?.payload?.type === 'approval/requested'),
    'the missed approval to be replayed',
  )
  assert.ok(ready.seq >= seen)
})
