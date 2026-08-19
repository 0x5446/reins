/**
 * Reaching a phone that is not there.
 *
 * The app posts its own notification when the agent stops to ask something, and
 * that works exactly as long as the app is running. It is usually not: iOS
 * suspends it within minutes of the screen going dark, the tunnel dies with it,
 * and the machine sits waiting on someone who was never told. Being elsewhere
 * is what this product is for, so this is the common case rather than the edge
 * one.
 *
 * These are the parts that decide *whether* to ring and *where* — the parts a
 * test can hold. Whether Apple then delivers it cannot be tested from here and
 * is not pretended to be.
 */

import assert from 'node:assert/strict'
import test from 'node:test'
import { BridleCore } from '@reins/bridle'

/** A dsh mux frame, shaped as the wire carries it. */
function frame(type, sessionId, extra = {}) {
  return {
    type: 'server-request',
    rpcId: `rpc-${type}-${sessionId}`,
    method: type,
    payload: { type, sessionId, ...extra },
  }
}

/** A core whose dsh never answers; only the bookkeeping is under test. */
function core() {
  const pumps = []
  const machine = new BridleCore(
    {
      version: 1,
      deviceId: 'd',
      privateKey: Buffer.alloc(32).toString('base64url'),
      signingKey: Buffer.alloc(64).toString('base64url'),
      machineName: 'a-mac',
      relayUrl: '',
      dshUrl: 'http://127.0.0.1:9',
      peers: [],
    },
    {
      dsh: {
        baseUrl: 'http://127.0.0.1:9',
        call: async () => ({ ok: true, value: {} }),
        health: async () => ({ reachable: false }),
        pump: async (stream, onFrame) => { pumps.push({ stream, onFrame }) },
      },
    },
  )
  return {
    machine,
    feed: (f) => { for (const p of pumps) if (p.stream === 'mux') p.onFrame(f) },
  }
}

test('a request that stops the agent says so, once', async () => {
  const { machine, feed } = core()
  await machine.start()
  let rings = 0
  machine.onWaiting(() => { rings += 1 })

  feed(frame('approval/requested', 's1', { approvalId: 'a1', toolName: 'Bash' }))
  assert.equal(rings, 1)

  // dsh re-sends every pending request to each new mux subscriber, and this
  // Bridle resubscribes whenever dsh restarts. Ringing again would wake someone
  // for a question they were already woken for — possibly hours earlier.
  feed(frame('approval/requested', 's1', { approvalId: 'a1', toolName: 'Bash' }))
  assert.equal(rings, 1, 'a re-sent request rang the phone a second time')
  machine.stop()
})

test('answering does not ring anyone', async () => {
  const { machine, feed } = core()
  await machine.start()
  feed(frame('question/requested', 's1', { questions: [{ id: 'q', question: 'which?' }] }))
  let rings = 0
  machine.onWaiting(() => { rings += 1 })
  feed(frame('question/resolved', 's1'))
  assert.equal(rings, 0)
  machine.stop()
})

test('a question asked after one was answered rings again', async () => {
  const { machine, feed } = core()
  await machine.start()
  let rings = 0
  machine.onWaiting(() => { rings += 1 })
  feed(frame('question/requested', 's1', { questions: [{ id: 'q', question: 'which?' }] }))
  feed(frame('question/resolved', 's1'))
  // Same session, new question. The dedupe is against a request still
  // outstanding, not against the session ever having asked one — otherwise a
  // conversation would be silent after its first question.
  feed(frame('question/requested', 's1', { questions: [{ id: 'q2', question: 'and now?' }] }))
  assert.equal(rings, 2)
  machine.stop()
})

test('attachments are counted, and released once however often they are dropped', async () => {
  const { machine } = core()
  await machine.start()
  assert.equal(machine.attached, 0)

  const first = machine.attach()
  const second = machine.attach()
  assert.equal(machine.attached, 2, 'two phones, one machine')

  first()
  first()
  assert.equal(machine.attached, 1, 'a session disposed twice decremented twice')

  second()
  assert.equal(machine.attached, 0)
  machine.stop()
})

test('a listener that throws does not stop the fold', async () => {
  const { machine, feed } = core()
  await machine.start()
  machine.onWaiting(() => { throw new Error('the relay socket had just closed') })
  let reached = false
  machine.onWaiting(() => { reached = true })

  feed(frame('approval/requested', 's1', { approvalId: 'a1', toolName: 'Edit' }))
  assert.equal(reached, true, 'one bad listener silenced the next')
  assert.equal(machine.pendingRequests.length, 1, 'the request was lost with the exception')
  machine.stop()
})
