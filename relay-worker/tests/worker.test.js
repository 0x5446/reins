/**
 * The Worker Relay, against a Worker that is actually running.
 *
 * `e2e/tests/deployed.test.js` is the acceptance bar and this does not replace
 * it — point that at this Worker too. What that file does not cover is the
 * short-code path, and that is exactly the part this substrate had to re-answer:
 * the Node Relay keeps codes in one process's memory, this one gives each code
 * its own Durable Object because a claim arrives knowing the code and nothing
 * else. Untested, "the object is addressed by the code" is a sentence in a
 * README.
 *
 * Skipped unless REINS_WORKER_URL is set, because it needs a Worker somewhere:
 *
 *   npx wrangler dev --config relay-worker/wrangler.jsonc --var REINS_SWEEP_INTERVAL_MS:2000
 *   REINS_WORKER_URL=ws://127.0.0.1:8787 node --test relay-worker/tests/worker.test.js
 *
 * The sweep interval is not optional. Two tests need a sweep to happen inside
 * their lifetime rather than ten minutes later, and one of them needs it only
 * sometimes — a Bridle's close usually reaches the Relay in milliseconds, and
 * when it does not, the sweep is the only thing that retracts the row. Running
 * without the override passes four times and fails the fifth, which is worse
 * than failing every time.
 */

import assert from 'node:assert/strict'
import test from 'node:test'
import { RelayClient, createInvitation, publishInvitation } from '@reins/bridle'
import { FakeAgent, ReinsPhone, startStack, waitFor } from '@reins/e2e'

const RELAY_URL = process.env.REINS_WORKER_URL

const skip = RELAY_URL === undefined
  ? 'no worker running; set REINS_WORKER_URL to one'
  : false

/** Local, but still an upgrade and several Durable Object round trips. */
const TIMEOUT_MS = 30_000

const HTTP_BASE = RELAY_URL === undefined ? undefined : RELAY_URL.replace(/^ws/u, 'http')

/**
 * Stand up a Bridle against the Worker under test.
 * @param {import('node:test').TestContext} t - the test, for teardown.
 * @param {string} name - machine name the app will see.
 * @param {FakeAgent} [agent] - the harness to answer with.
 * @returns {Promise<any>} the running stack.
 */
async function bridle(t, name, agent = new FakeAgent()) {
  const stack = await startStack({
    relayUrl: RELAY_URL,
    dshUrl: 'http://127.0.0.1:0',
    agent,
    noDirect: true,
    machineName: name,
  })
  t.after(() => stack.stop())
  await stack.waitForRelay(TIMEOUT_MS)
  return stack
}

/**
 * The Relay's census.
 * @returns {Promise<any>} the parsed `/healthz` body.
 */
async function health() {
  const response = await fetch(new URL('/healthz', HTTP_BASE))
  assert.equal(response.status, 200)
  return response.json()
}

test('a machine that never registered is not online', { skip, timeout: TIMEOUT_MS }, async () => {
  const response = await fetch(new URL('/v1/machine/not-a-real-device', HTTP_BASE))
  assert.equal(response.status, 200)
  assert.deepEqual(await response.json(), { online: false })
})

test('a registered machine says who it is', { skip, timeout: TIMEOUT_MS }, async (t) => {
  const stack = await bridle(t, 'Worker Census')
  const response = await fetch(new URL(`/v1/machine/${encodeURIComponent(stack.state.deviceId)}`, HTTP_BASE))
  const body = await response.json()
  assert.equal(body.online, true)
  assert.equal(body.name, 'Worker Census', 'the display name survives registration')
  assert.equal(typeof body.version, 'string')
})

test('a short code buys the bundle exactly once', { skip, timeout: TIMEOUT_MS }, async (t) => {
  const stack = await bridle(t, 'Worker Short Code')
  const invitation = createInvitation(stack.state, [])
  await publishInvitation(stack.state, invitation)

  const claim = await fetch(new URL(`/v1/pair/claim?code=${encodeURIComponent(invitation.code)}`, HTTP_BASE))
  assert.equal(claim.status, 200)
  const { bundle } = await claim.json()
  assert.deepEqual(bundle, invitation.bundle, 'the bundle comes back as it was parked')

  const again = await fetch(new URL(`/v1/pair/claim?code=${encodeURIComponent(invitation.code)}`, HTTP_BASE))
  assert.equal(again.status, 404, 'a spent code is spent')

  // The claimed bundle has to be usable, not merely equal: that is the whole
  // point of the short-code path, and a Relay handing back a plausible-looking
  // bundle nobody can pair with would pass every check above.
  const phone = new ReinsPhone({ bundle, prefer: 'relay', name: 'Typed Code' })
  t.after(() => { phone.close() })
  const ready = await phone.connect()
  assert.equal(ready.machine, 'Worker Short Code')
})

test('one machine cannot fill the code space', { skip, timeout: TIMEOUT_MS }, async (t) => {
  const stack = await bridle(t, 'Worker Offer Cap')
  const codes = []
  for (let index = 0; index < 3; index += 1) {
    const invitation = createInvitation(stack.state, [])
    await publishInvitation(stack.state, invitation)
    codes.push(invitation.code)
  }
  await assert.rejects(
    publishInvitation(stack.state, createInvitation(stack.state, [])),
    /HTTP 429/u,
    'the fourth outstanding offer is refused',
  )

  // Spending one gives the slot back, so nobody ends up permanently at their
  // ceiling because of codes that were never typed.
  const spent = await fetch(new URL(`/v1/pair/claim?code=${encodeURIComponent(codes[0])}`, HTTP_BASE))
  assert.equal(spent.status, 200)
  await assert.doesNotReject(publishInvitation(stack.state, createInvitation(stack.state, [])))
})

test('an offer that does not hash to the machine it names is refused', { skip, timeout: TIMEOUT_MS }, async (t) => {
  const stack = await bridle(t, 'Worker Offer Forgery')
  const invitation = createInvitation(stack.state, [])

  // The device id check and the signature check are separate, and this trips
  // the first: a key that does not hash to the device id claimed. That binding
  // is the one docs/protocol.md §6.1 calls mandatory.
  const response = await fetch(new URL('/v1/pair/offer', HTTP_BASE), {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      code: invitation.code,
      device: 'aaaaaaaaaaaaaaaaaaaaaa',
      key: invitation.bundle.key,
      signature: 'not-a-signature',
      bundle: invitation.bundle,
      expiresAt: invitation.expiresAt,
    }),
  })
  assert.equal(response.status, 403)
})

test('a multi-megabyte frame crosses intact in both directions', { skip, timeout: TIMEOUT_MS }, async (t) => {
  // 4 MiB each way. Well under the 32 MiB the runtime allows, and chosen for
  // that reason: the failure worth catching is a substrate that mishandles a
  // message spread over many reads, which shows up here rather than at the
  // ceiling. The ceiling is the runtime's to enforce, with a 1009 close.
  const payload = 'x'.repeat(4 * 1024 * 1024)
  const agent = new FakeAgent()
  agent.answers.set('echo', { ok: true, value: { payload } })
  const stack = await bridle(t, 'Worker Big Frame', agent)

  const phone = new ReinsPhone({ bundle: stack.invite().bundle, prefer: 'relay', name: 'Big Frame' })
  t.after(() => { phone.close() })
  await phone.connect()

  const echoed = await phone.call('echo', { payload })
  assert.equal(echoed.ok, true, JSON.stringify(echoed).slice(0, 200))
  assert.equal(echoed.value.payload.length, payload.length, 'every byte came back down')
  assert.equal(agent.calls.at(-1).payload.payload.length, payload.length, 'and every byte went up')
})

test('a circuit still routes after a long idle', { skip, timeout: 90_000 }, async (t) => {
  const stack = await bridle(t, 'Worker Hibernation')
  const phone = new ReinsPhone({ bundle: stack.invite().bundle, prefer: 'relay', name: 'Sleeper' })
  t.after(() => { phone.close() })
  await phone.connect()
  assert.equal((await phone.call('host.describe', {})).ok, true)

  // Nothing here can observe hibernation directly; that is the runtime's
  // business, and the tunnel's own 25-second ping may keep this object awake
  // anyway. What it can observe is the consequence of getting hibernation
  // wrong: in-memory state is reset, so a Switchboard that kept its circuit
  // table in a field instead of in socket attachments answers with silence.
  await new Promise(resolve => setTimeout(resolve, 40_000))
  const after = await phone.call('host.describe', {})
  assert.equal(after.ok, true, 'the circuit survived')
})

test('a second socket for the same machine displaces the first', { skip, timeout: TIMEOUT_MS }, async (t) => {
  const stack = await bridle(t, 'Worker Displacement')
  const before = await health()

  // A laptop that suspends leaves a socket the Relay still believes in. Here
  // the two sockets are in two different Durable Objects, so displacement is
  // the Exchange's job rather than a map overwrite — and if it does not happen,
  // the census counts one machine twice and phones are routed to whichever
  // object the directory happened to keep.
  const second = new RelayClient(stack.core, { version: '0.1.0-test' })
  second.start()
  t.after(() => second.stop())
  await waitFor(() => second.connectionState === 'online', TIMEOUT_MS, 'the second socket to register')
  stack.relayClient.stop()

  const after = await health()
  assert.equal(after.machines, before.machines, 'one machine, not two')

  const phone = new ReinsPhone({ bundle: stack.invite().bundle, prefer: 'relay', name: 'After' })
  t.after(() => { phone.close() })
  const ready = await phone.connect()
  assert.equal(ready.machine, 'Worker Displacement', 'phones reach the surviving socket')
})

test('the census counts what is stored, not what it remembered', { skip, timeout: 120_000 }, async (t) => {
  // The bug this exists for: the census used to be a tally kept beside the
  // rows and updated by read-modify-write. A Durable Object lets other events
  // run at every await, and registering displaces the previous Switchboard,
  // which calls back in to unregister — so two paths would each read the same
  // number, each apply their delta, and the second write would erase the
  // first. A lost decrement never returns, so the error only accumulated:
  // observed climbing by one per restart until /healthz claimed three machines
  // where there was one. Left alone it would eventually refuse machines at a
  // ceiling it had not reached.
  const before = (await health()).machines

  // Reconnect the same machine repeatedly. Every cycle races a registration
  // against the displacement of its predecessor, which is precisely the
  // interleaving that used to lose an update.
  for (let round = 0; round < 4; round += 1) {
    const stack = await bridle(t, `Churn ${String(round)}`)
    await stack.stop()
  }

  // Polled here rather than with `waitFor`, which takes a synchronous
  // predicate: an async one returns a promise, every promise is truthy, and
  // the wait would pass without ever checking anything.
  //
  // Polled for thirty seconds rather than checked once because `stop()` does
  // not wait for its own close to be delivered, and it usually arrives in
  // milliseconds but is not guaranteed to arrive at all. When it does not, the
  // sweep is what retracts the row — which is why this file's header insists on
  // an interval short enough for one to happen here.
  const deadline = Date.now() + 30_000
  let after = await health()
  while (after.machines !== before && Date.now() < deadline) {
    await new Promise(resolve => setTimeout(resolve, 250))
    after = await health()
  }
  assert.equal(after.machines, before, `census drifted to ${String(after.machines)} from ${String(before)}`)
  assert.equal(after.circuits, 0, 'circuits outlived every socket that could hold one')
})

test('the sweep does not evict a machine that is still there', { skip, timeout: 120_000 }, async (t) => {
  // The sweep exists because a row is retracted only when the Bridle's socket
  // closes, and that close is not guaranteed to arrive — an evicted Worker, a
  // laptop that vanished. Rows left behind were counted forever, and the count
  // is what the ceiling is checked against.
  //
  // The orphan itself cannot honestly be staged from out here: every
  // disconnection a test can cause *does* deliver its close, and the row heals
  // through the path that already worked. What can be tested is the failure
  // that would actually hurt — a sweep that mistakes a live machine for a dead
  // one and cuts off someone who is using it. Run this against a Worker with
  // REINS_SWEEP_INTERVAL_MS set low enough for several sweeps to pass.
  const before = (await health()).machines
  const stack = await bridle(t, 'Still Here')
  assert.equal((await health()).machines, before + 1)

  // Long enough for the sweep to have run more than once at the test interval.
  await new Promise(resolve => setTimeout(resolve, 6_000))

  assert.equal((await health()).machines, before + 1, 'the sweep evicted a machine that was still connected')
  assert.equal(stack.relayClient.connectionState, 'online', 'the Bridle was cut off by its own Relay')

  // And it is still usable, not merely counted.
  const phone = new ReinsPhone({ bundle: stack.invite().bundle, name: 'After the sweep' })
  t.after(() => { phone.close() })
  const ready = await phone.connect()
  assert.equal(ready.machine, 'Still Here')
})

test('a Relay with no push key survives being asked to ring a phone', { skip, timeout: TIMEOUT_MS }, async (t) => {
  // Push is optional and this Worker has no APNs key, which is the state every
  // Relay is in until someone configures one — including this one, right now.
  // What must not happen is the machine paying for it: a control message the
  // Relay cannot act on has to be a no-op, not a disconnect. The Bridle sends
  // the wake as part of ordinary operation, so getting this wrong would take
  // down every machine whose agent asked a question.
  const agent = new FakeAgent()
  const stack = await bridle(t, 'Worker Wake', agent)
  await waitFor(() => agent.isPumping('mux'), TIMEOUT_MS, 'the Bridle to subscribe')

  const invitation = stack.invite()
  const phone = new ReinsPhone({ bundle: invitation.bundle, prefer: 'relay', name: 'Sleeper' })
  await phone.connect()
  phone.wake('b'.repeat(64), 'sandbox')
  await waitFor(() => stack.state.peers[0]?.push !== undefined, 5_000, 'the token to be stored')
  phone.close()
  await waitFor(() => stack.core.attached === 0, 5_000, 'the tunnel to be released')

  // Nobody attached, so this rings — into a Relay that cannot ring anything.
  agent.emit({
    type: 'server-request',
    rpcId: 'rpc-wake',
    method: 'approval/requested',
    payload: { type: 'approval/requested', sessionId: 's1', approvalId: 'a1', toolName: 'Bash' },
  })

  // Still there afterwards, and still usable — checked by actually using it,
  // because a socket can stay open on a Relay that has stopped switching.
  await new Promise((resolve) => { setTimeout(resolve, 1_000) })
  const machine = await health()
  assert.equal(machine.machines >= 1, true, 'the machine left the directory')

  agent.answers.set('host.describe', { ok: true, value: { alive: true } })
  const again = new ReinsPhone({ bundle: invitation.bundle, keys: phone.keys, pairing: false, prefer: 'relay' })
  t.after(() => { again.close() })
  await again.connect()
  const described = await again.call('host.describe', {})
  assert.equal(described.ok, true, 'the circuit stopped working after an unanswerable wake')
})
