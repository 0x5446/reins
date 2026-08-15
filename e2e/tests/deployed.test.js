/**
 * The same tunnel the app will use, against the Relay that is actually
 * deployed — not one this process started.
 *
 * Everything else in `e2e/` runs a Relay in-process on loopback. That proves
 * the protocol and proves nothing about the deployment: a tunnel that refuses
 * WebSocket upgrades, a proxy that buffers a stream into uselessness, a
 * capacity ceiling set to a number smaller than intended, TLS that only works
 * from the machine that configured it. Each of those passes every other test
 * in this directory and breaks the product.
 *
 * Skipped unless REINS_E2E_RELAY_URL is set, because it needs the network and
 * a Relay someone is paying for:
 *
 *   REINS_E2E_RELAY_URL=wss://reins.novabox.ai node --test e2e/tests/deployed.test.js
 */

import assert from 'node:assert/strict'
import test from 'node:test'
import { probeDsh } from '@reins/bridle'
import { FakeAgent, ReinsPhone, startStack, waitFor } from '../lib/index.js'

const RELAY_URL = process.env.REINS_E2E_RELAY_URL
const DSH_URL = process.env.REINS_E2E_DSH_URL ?? await probeDsh()

const skip = RELAY_URL === undefined
  ? 'no deployed relay; set REINS_E2E_RELAY_URL to test one'
  : false

/**
 * The one hostname that carries the static site and the installer redirect.
 *
 * A relay is reachable at several addresses — the public one, the standby the
 * Node relay keeps so it stays testable, a local port under `wrangler dev` —
 * and only this one has pages behind it. Written as the address that *does*
 * rather than a list of ones that do not: the first version excluded
 * `workers.dev` and then failed the moment a standby name appeared, because a
 * blocklist has to be updated every time and a match does not.
 */
const SITE_HOST = 'reins.novabox.ai'
const SHARES_THE_SITE = RELAY_URL !== undefined && new URL(RELAY_URL).hostname === SITE_HOST
const skipSite = skip !== false ? skip : (SHARES_THE_SITE ? false : 'this relay is not behind the public hostname')
const skipLive = skip !== false
  ? skip
  : DSH_URL === undefined ? 'no DeepSeek Harness is running; set REINS_E2E_DSH_URL' : false

/** A public Relay is a round trip to another continent, not a loopback hop. */
const NET_TIMEOUT_MS = 60_000

/** The same host over plain HTTPS, for the routes that are not WebSockets. */
const HTTP_BASE = RELAY_URL === undefined ? undefined : RELAY_URL.replace(/^ws/u, 'http')

/**
 * The Relay's health endpoint over plain HTTPS.
 * @returns {Promise<any>} the parsed body.
 */
async function health() {
  const url = new URL('/healthz', HTTP_BASE)
  const response = await fetch(url, { signal: AbortSignal.timeout(15_000) })
  assert.equal(response.status, 200, `GET ${url.href} should be 200`)
  return response.json()
}

/**
 * Poll an asynchronous condition. `waitFor` takes a synchronous one, and an
 * async predicate handed to it returns a always-truthy Promise — passing
 * instantly and proving nothing.
 * @param {() => Promise<boolean>} condition - checked every 500ms.
 * @param {number} timeoutMs - how long to keep trying.
 * @param {string} what - named in the timeout message.
 */
async function waitForAsync(condition, timeoutMs, what) {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    if (await condition()) return
    await new Promise(resolve => setTimeout(resolve, 500))
  }
  throw new Error(`timed out after ${timeoutMs}ms waiting for ${what}`)
}

test('the deployed relay answers', { skip, timeout: NET_TIMEOUT_MS }, async () => {
  const body = await health()
  for (const key of ['machines', 'circuits', 'offers', 'uptimeSeconds']) {
    assert.equal(typeof body[key], 'number', `/healthz reports ${key}`)
  }
})

test('the installer comes from the repository, not from the relay', { skip: skipSite, timeout: NET_TIMEOUT_MS }, async () => {
  // A Relay that also hands out the installer turns one compromise into a
  // supply-chain event, so the edge redirects /install to the repository and
  // REINS_INSTALL_SCRIPT stays empty. `redirect: 'manual'` matters: following
  // the hop would land on GitHub and pass even if the Relay had started
  // serving the script itself.
  const response = await fetch(new URL('/install', HTTP_BASE), {
    redirect: 'manual',
    signal: AbortSignal.timeout(15_000),
  })
  assert.equal(response.status, 302, '/install should be an edge redirect')
  assert.match(
    response.headers.get('location') ?? '',
    /^https:\/\/raw\.githubusercontent\.com\//u,
    'the redirect must point at the repository',
  )
})

test('the pages the app links to exist, and have not eaten the relay', { skip: skipSite, timeout: NET_TIMEOUT_MS }, async () => {
  // `Links.swift` sends people to these. A 404 behind the app's Privacy button
  // is also a rejected App Store submission.
  for (const path of ['/', '/get', '/help', '/privacy', '/_/style.css']) {
    const response = await fetch(new URL(path, HTTP_BASE), { signal: AbortSignal.timeout(15_000) })
    assert.equal(response.status, 200, `${path} should be served`)
  }

  // The site and the Relay share a hostname, split by path. Widening a Worker
  // route to `/*` would take the whole product offline while every page above
  // kept returning 200 — so the check that matters is that the Relay's own
  // routes still reach the Relay.
  const relayRoutes = await fetch(new URL('/healthz', HTTP_BASE), { signal: AbortSignal.timeout(15_000) })
  assert.match(
    relayRoutes.headers.get('content-type') ?? '',
    /application\/json/u,
    '/healthz must still be answered by the relay, not by the site',
  )
})

test('a phone pairs and drives a machine through the deployed relay', { skip, timeout: NET_TIMEOUT_MS * 3 }, async (t) => {
  // A fake agent, deliberately. This test is about the wire between here and
  // the Relay; a live model would make it slow, flaky, and about something else.
  const agent = new FakeAgent()
  const stack = await startStack({
    relayUrl: RELAY_URL,
    dshUrl: 'http://127.0.0.1:0',
    agent,
    noDirect: true,
    machineName: 'Deployed Relay Probe',
  })
  t.after(() => stack.stop())
  await stack.waitForRelay(NET_TIMEOUT_MS)

  const before = await health()
  assert.ok(before.machines >= 1, 'the bridle shows up in the relay census')

  const phone = new ReinsPhone({ bundle: stack.invite().bundle, prefer: 'relay', name: 'Deploy Probe' })
  t.after(() => { phone.close() })

  const ready = await phone.connect()
  assert.equal(ready.machine, 'Deployed Relay Probe', 'the handshake completed across the public path')

  const events = []
  phone.onEvent(event => events.push(event))
  phone.resume(ready.seq)

  const described = await phone.call('host.describe', {})
  assert.equal(described.ok, true, JSON.stringify(described))

  // Streaming, not just request/response: a proxy that buffers would pass the
  // call above and fail here.
  agent.emit({ type: 'session/subscribed', sessionId: 'probe', lastSeq: 1 })
  await waitFor(() => events.length >= 1, NET_TIMEOUT_MS, 'a pushed frame to cross the tunnel')

  const during = await health()
  assert.ok(during.circuits >= 1, 'the relay is switching a circuit for this phone')
})

test('the relay forgets a phone that hangs up', { skip, timeout: NET_TIMEOUT_MS * 3 }, async (t) => {
  const stack = await startStack({
    relayUrl: RELAY_URL,
    dshUrl: 'http://127.0.0.1:0',
    agent: new FakeAgent(),
    noDirect: true,
    machineName: 'Deployed Relay Teardown',
  })
  t.after(() => stack.stop())
  await stack.waitForRelay(NET_TIMEOUT_MS)

  const phone = new ReinsPhone({ bundle: stack.invite().bundle, prefer: 'relay', name: 'Hang Up' })
  await phone.connect()
  const busy = await health()
  phone.close()

  // Circuits that survive their phone are how a long-lived Relay runs out of
  // memory a month after anyone was looking at it.
  await waitForAsync(
    async () => (await health()).circuits < busy.circuits,
    NET_TIMEOUT_MS,
    'the relay to drop the circuit',
  )
})

test('a real harness is reachable through the deployed relay', { skip: skipLive, timeout: NET_TIMEOUT_MS * 4 }, async (t) => {
  const stack = await startStack({
    relayUrl: RELAY_URL,
    dshUrl: DSH_URL,
    noDirect: true,
    machineName: 'Deployed Relay Live',
  })
  t.after(() => stack.stop())
  await stack.waitForRelay(NET_TIMEOUT_MS)

  const phone = new ReinsPhone({ bundle: stack.invite().bundle, prefer: 'relay', name: 'Live Probe' })
  t.after(() => { phone.close() })
  const ready = await phone.connect()
  assert.equal(ready.dshReachable, true, 'the bridle found its harness')

  const sessions = await phone.call('session.list', {})
  assert.equal(sessions.ok, true, JSON.stringify(sessions))
  assert.ok(Array.isArray(sessions.value.items), 'the session list came back over the public path')

  // A response big enough to be split across WebSocket frames. The session list
  // carries every session's projections; a tunnel that mangles fragmentation
  // survives a `host.describe` and dies here.
  const described = await phone.call('host.describe', {})
  assert.equal(described.ok, true, JSON.stringify(described))
  assert.equal(typeof described.value.cwd, 'string')
})
