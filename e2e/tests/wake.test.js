/**
 * Being reached when the app is not running.
 *
 * The local notification only fires while the app holds a tunnel, and it
 * usually does not: iOS suspends a backgrounded app within minutes and the
 * socket dies with it. Every question the agent asks after that point lands in
 * a machine that is waiting for someone who was never told — which is the
 * failure this whole product is supposed to prevent, since being elsewhere is
 * the premise.
 *
 * So the machine reaches out. The token crosses the Noise channel like
 * everything else, the Relay is handed it only at the moment a push is sent,
 * and the push itself carries no words — the phone wakes, opens its own tunnel,
 * asks what happened, and writes the notification locally.
 *
 * What is tested here is the decision and the address: that a Bridle rings when
 * and only when nobody is listening, that it rings the right token, and that it
 * stops when told to. Whether Apple then delivers it is Apple's, and is not
 * pretended to be covered.
 */

import assert from 'node:assert/strict'
import test from 'node:test'
import { FakeAgent, ReinsPhone, startStack, waitFor } from '../lib/index.js'

/** A dsh mux request, shaped as the wire carries it. */
function request(type, sessionId, extra = {}) {
  return { type: 'server-request', rpcId: `rpc-${sessionId}`, method: type, payload: { type, sessionId, ...extra } }
}

/** An approval, the kind of thing worth waking someone for. */
function approval(sessionId, approvalId) {
  return request('approval/requested', sessionId, { approvalId, toolName: 'Bash' })
}

const TOKEN = 'a'.repeat(64)

test('a machine with nobody attached rings the phone it was given', { timeout: 60_000 }, async (t) => {
  const agent = new FakeAgent()
  const stack = await startStack({ agent, machineName: 'Pocket Mac', noDirect: true })
  t.after(() => stack.stop())
  await stack.waitForRelay(20_000)
  await waitFor(() => agent.isPumping('mux'), 10_000, 'the Bridle to subscribe')

  // The phone attaches once, says where it can be rung, and leaves — which is
  // what a phone does: it is in a pocket a minute later.
  const phone = new ReinsPhone(stack.invite())
  await phone.connect()
  phone.wake(TOKEN)
  await waitFor(() => stack.state.peers[0]?.push !== undefined, 5_000, 'the token to be stored')
  assert.deepEqual(stack.state.peers[0].push, { token: TOKEN, environment: 'sandbox' })
  phone.close()
  await waitFor(() => stack.core.attached === 0, 5_000, 'the tunnel to be released')

  agent.emit(approval('s1', 'a1'))

  await waitFor(() => stack.relay.wakes.length > 0, 5_000, 'the machine to ring the phone')
  assert.deepEqual(stack.relay.wakes[0], {
    token: TOKEN,
    environment: 'sandbox',
    machine: 'Pocket Mac',
  }, 'the ring named the wrong phone, or said more than it should')
})

test('a machine somebody is watching does not ring anyone', { timeout: 60_000 }, async (t) => {
  const agent = new FakeAgent()
  const stack = await startStack({ agent, machineName: 'Watched Mac', noDirect: true })
  t.after(() => stack.stop())
  await stack.waitForRelay(20_000)
  await waitFor(() => agent.isPumping('mux'), 10_000, 'the Bridle to subscribe')

  const phone = new ReinsPhone(stack.invite())
  await phone.connect()
  phone.wake(TOKEN)
  await waitFor(() => stack.state.peers[0]?.push !== undefined, 5_000, 'the token to be stored')

  // Still attached. The app will post its own notification, with the actual
  // words in it, and a push on top would be the same interruption twice.
  agent.emit(approval('s1', 'a1'))
  const seen = await new Promise((resolve) => {
    setTimeout(() => { resolve(stack.relay.wakes.length) }, 600)
  })
  assert.equal(seen, 0, 'rang a phone that was already holding the tunnel')
  phone.close()
})

test('a phone that turns notifications off stops being rung', { timeout: 60_000 }, async (t) => {
  const agent = new FakeAgent()
  const stack = await startStack({ agent, machineName: 'Quiet Mac', noDirect: true })
  t.after(() => stack.stop())
  await stack.waitForRelay(20_000)
  await waitFor(() => agent.isPumping('mux'), 10_000, 'the Bridle to subscribe')

  const phone = new ReinsPhone(stack.invite())
  await phone.connect()
  phone.wake(TOKEN)
  await waitFor(() => stack.state.peers[0]?.push !== undefined, 5_000, 'the token to be stored')
  phone.wake(null)
  await waitFor(() => stack.state.peers[0]?.push === undefined, 5_000, 'the token to be withdrawn')
  phone.close()
  await waitFor(() => stack.core.attached === 0, 5_000, 'the tunnel to be released')

  agent.emit(approval('s1', 'a1'))
  const seen = await new Promise((resolve) => {
    setTimeout(() => { resolve(stack.relay.wakes.length) }, 600)
  })
  assert.equal(seen, 0, 'kept ringing a phone that asked to be left alone')
})

test('the token survives the phone reconnecting, and is not asked for again', { timeout: 60_000 }, async (t) => {
  const agent = new FakeAgent()
  const stack = await startStack({ agent, machineName: 'Returning Mac', noDirect: true })
  t.after(() => stack.stop())
  await stack.waitForRelay(20_000)
  await waitFor(() => agent.isPumping('mux'), 10_000, 'the Bridle to subscribe')

  const invitation = stack.invite()
  const first = new ReinsPhone(invitation)
  await first.connect()
  first.wake(TOKEN)
  await waitFor(() => stack.state.peers[0]?.push !== undefined, 5_000, 'the token to be stored')
  first.close()

  // Same device, new tunnel — the ordinary case every time a phone comes back
  // onto Wi-Fi. Same keys and no pairing token, because the pairing already
  // happened; a token that did not survive this would mean the machine could
  // only ring a phone that had connected since the last restart.
  const again = new ReinsPhone({ bundle: invitation.bundle, keys: first.keys, pairing: false, prefer: 'relay' })
  await again.connect()
  assert.deepEqual(stack.state.peers[0].push, { token: TOKEN, environment: 'sandbox' })
  again.close()
  await waitFor(() => stack.core.attached === 0, 5_000, 'the tunnel to be released')

  agent.emit(approval('s1', 'a1'))
  await waitFor(() => stack.relay.wakes.length > 0, 5_000, 'the machine to ring the phone')
})
