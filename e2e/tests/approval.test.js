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
import { FakeAgent, RowelPhone, startStack } from '../lib/index.js'

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

  const phone = new RowelPhone({ bundle: stack.invite().bundle, prefer: 'direct' })
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

test('an answer too big for the tunnel fails the call instead of the connection', { timeout: 120_000 }, async (t) => {
  // The failure this prevents was observed, not imagined: a `session.history`
  // page came back as 22 MB of streaming chunks. `thinHistory` keeps that one
  // under the ceiling now, but `session.export` has no such guard and a long
  // session's archive has no upper bound at all.
  //
  // Every WebSocket on the path enforces a size limit by closing the
  // *connection* with a 1009, so writing an oversized frame produces a tunnel
  // that drops, reconnects, resumes, answers with the same frame and drops
  // again — with no error anywhere naming the cause.
  const agent = new FakeAgent()
  const stack = await startStack({ agent })
  t.after(() => stack.stop())
  await stack.waitForRelay()

  const phone = new RowelPhone({ bundle: stack.invite().bundle, prefer: 'relay' })
  t.after(() => { phone.close() })
  await phone.connect()

  agent.answers.set('host.describe', { ok: true, value: { fat: 'x'.repeat(33 * 1024 * 1024) } })
  const answer = await phone.call('host.describe', {})

  assert.equal(answer.ok, false, 'the call should fail')
  assert.equal(answer.error.code, 'too-large')
  assert.match(answer.error.message, /MB/u, 'the message should say how big it was')

  // The point of the whole exercise: the tunnel is still usable afterwards.
  agent.answers.set('host.describe', { ok: true, value: { cwd: '/tmp' } })
  const after = await phone.call('host.describe', {})
  assert.equal(after.ok, true, 'the connection survived')
  assert.equal(after.value.cwd, '/tmp')
})

test('a history page too big to send comes back shorter instead of failing', { timeout: 120_000 }, async (t) => {
  // The observed shape: a 25-message page arrived as 22 MB of streaming
  // chunks. Thinning handles the usual version of that, but a page still
  // streaming has nothing superseded to drop — so the remaining answer is to
  // ask for fewer messages, which is what `maxMessages` is for.
  const agent = new FakeAgent()

  // Stand in for a harness whose pages are proportional to what was asked for.
  // Four megabytes a message puts 25 and 12 over the 32 MiB ceiling and 6 under.
  const perMessage = 4 * 1024 * 1024
  const asks = []
  agent.handle('session.history', (payload) => {
    const messages = payload.maxMessages
    asks.push(messages)
    return {
      ok: true,
      value: {
        events: [{ event: { type: 'user/message', seq: 1, time: 0, data: { pad: 'x'.repeat(messages * perMessage) } } }],
        hasMore: true,
      },
    }
  })

  const stack = await startStack({ agent })
  t.after(() => stack.stop())
  await stack.waitForRelay()

  const phone = new RowelPhone({ bundle: stack.invite().bundle, prefer: 'relay' })
  t.after(() => { phone.close() })
  await phone.connect()

  const page = await phone.call('session.history', { sessionId: 's1', maxMessages: 25 })

  assert.equal(page.ok, true, 'the caller gets a page, not an error')
  assert.deepEqual(asks, [25, 12, 6], 'the ask halves until it fits')
  assert.equal(page.value.hasMore, true, 'and can still page back for the rest')
})
