/**
 * What a phone is told when it attaches to a machine that has already stopped
 * to ask something.
 *
 * An approval or a question crosses dsh's mux stream once, live. A phone that
 * is not attached at that instant never hears it — and being elsewhere is the
 * entire premise of this app, so "not attached at that instant" is the normal
 * case, not the edge one. Found by triggering an `ask_user_question` and
 * watching the phone show a spinner while the browser two feet away showed a
 * card with three options on it.
 *
 * dsh avoids this by re-sending pending requests to every new mux subscriber,
 * which is what makes a browser reload work. Bridle's subscription is
 * long-lived and collects that re-send only when Bridle itself restarts, so
 * the same guarantee has to exist one layer out, where the phones come and go.
 */

import assert from 'node:assert/strict'
import test from 'node:test'
import { BridleCore } from '@rowel/bridle'

/** A dsh mux frame, shaped as the wire carries it. */
function frame(type, sessionId, extra = {}) {
  return {
    type: 'server-request',
    rpcId: `rpc-${type}-${sessionId}`,
    method: type,
    payload: { type, sessionId, ...extra },
  }
}

/** A core whose dsh never answers; only the mux bookkeeping is under test. */
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
    feedHost: (f) => { for (const p of pumps) if (p.stream === 'host') p.onFrame(f) },
  }
}

test('a question the machine is waiting on is held for whoever attaches next', async () => {
  const { machine, feed } = core()
  await machine.start()
  assert.deepEqual(machine.pendingRequests, [], 'nothing is waiting yet')

  const asked = frame('question/requested', 's1', { questions: [{ id: 'q', question: 'which?' }] })
  feed(asked)
  assert.deepEqual(machine.pendingRequests, [asked], 'a phone attaching now would never hear about it')
  machine.stop()
})

test('an approval is held the same way', async () => {
  const { machine, feed } = core()
  await machine.start()
  const asked = frame('approval/requested', 's1', { approvalId: 'a1', toolName: 'Edit' })
  feed(asked)
  assert.deepEqual(machine.pendingRequests, [asked])
  machine.stop()
})

test('answering it anywhere stops it being held', async () => {
  const { machine, feed } = core()
  await machine.start()
  feed(frame('question/requested', 's1', { questions: [{ id: 'q', question: 'which?' }] }))
  // The browser on the Mac answered, or another phone did. Either way nobody
  // should be asked again — and the resolved event names the session, not the
  // request, which is why the map is keyed that way.
  feed(frame('question/resolved', 's1'))
  assert.deepEqual(machine.pendingRequests, [])
  machine.stop()
})

test('two sessions can each be waiting on their own thing', async () => {
  const { machine, feed } = core()
  await machine.start()
  const one = frame('question/requested', 's1', { questions: [{ id: 'q', question: 'a?' }] })
  const two = frame('approval/requested', 's2', { approvalId: 'a1', toolName: 'Edit' })
  feed(one)
  feed(two)
  assert.deepEqual(machine.pendingRequests, [one, two])

  feed(frame('question/resolved', 's1'))
  assert.deepEqual(machine.pendingRequests, [two], 'answering one session cleared the other')
  machine.stop()
})

test('ordinary traffic is not mistaken for a request', async () => {
  const { machine, feed } = core()
  await machine.start()
  feed(frame('session/event', 's1', { event: { type: 'tool/call' } }))
  feed({ nonsense: true })
  feed({ payload: { type: 'question/requested' } })       // no session
  feed({ payload: { sessionId: 's1' } })                   // no type
  assert.deepEqual(machine.pendingRequests, [])
  machine.stop()
})

test('deleting a session that was waiting stops it being held', async () => {
  const { machine, feed, feedHost } = core()
  await machine.start()
  feed(frame('question/requested', 's1', { questions: [{ id: 'q', question: 'which?' }] }))
  assert.equal(machine.pendingRequests.length, 1)

  // A session deleted mid-question resolves nothing, so nothing would ever
  // clear it — the one way this bookkeeping could grow without bound.
  feedHost(frame('host/session-removed', 's1'))
  assert.deepEqual(machine.pendingRequests, [])
  machine.stop()
})
