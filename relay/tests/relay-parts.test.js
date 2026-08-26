/** The Relay's two pieces of state: held pairing offers, and per-caller rate limits. */

import assert from 'node:assert/strict'
import test from 'node:test'
import { CapacityError, OfferStore, RateLimiter, Registry, RelayServer, limits } from '../lib/index.js'

/**
 * @param {string} device - device id the bundle names.
 * @returns {object} a bundle good enough for the store.
 */
function bundle(device) {
  return { v: 1, relay: 'wss://relay.test', device, key: 'k', token: 't', name: 'A Mac' }
}

test('an offer can be claimed exactly once', () => {
  const store = new OfferStore()
  assert.equal(store.put('KTPQ-3WRM', 'dev1', bundle('dev1'), Date.now() + 60_000), true)
  assert.deepEqual(store.claim('KTPQ-3WRM')?.device, 'dev1')
  assert.equal(store.claim('KTPQ-3WRM'), undefined)
})

test('an expired offer cannot be claimed', () => {
  const store = new OfferStore()
  const now = 1_000_000
  store.put('AAAA-BBBB', 'dev1', bundle('dev1'), now + 1_000, now)
  assert.equal(store.claim('AAAA-BBBB', now + 2_000), undefined)
})

test('the relay clamps a machine that asks to be remembered forever', () => {
  const store = new OfferStore()
  const now = 1_000_000
  store.put('AAAA-BBBB', 'dev1', bundle('dev1'), now + 999 * 60 * 60 * 1000, now)
  assert.equal(store.claim('AAAA-BBBB', now + 16 * 60 * 1000), undefined)
})

test('one machine cannot fill the store with offers', () => {
  const store = new OfferStore()
  const expiry = Date.now() + 60_000
  assert.equal(store.put('C1', 'dev1', bundle('dev1'), expiry), true)
  assert.equal(store.put('C2', 'dev1', bundle('dev1'), expiry), true)
  assert.equal(store.put('C3', 'dev1', bundle('dev1'), expiry), true)
  assert.equal(store.put('C4', 'dev1', bundle('dev1'), expiry), false)
  assert.equal(store.put('C5', 'dev2', bundle('dev2'), expiry), true)
})

test('a burst is allowed, then the caller has to wait', () => {
  const limiter = new RateLimiter(3, 1)
  const now = 1_000_000
  assert.equal(limiter.take('1.2.3.4', now), true)
  assert.equal(limiter.take('1.2.3.4', now), true)
  assert.equal(limiter.take('1.2.3.4', now), true)
  assert.equal(limiter.take('1.2.3.4', now), false)
  assert.equal(limiter.take('1.2.3.4', now + 1_100), true)
})

test('rate limits are per caller', () => {
  const limiter = new RateLimiter(1, 1)
  const now = 1_000_000
  assert.equal(limiter.take('a', now), true)
  assert.equal(limiter.take('a', now), false)
  assert.equal(limiter.take('b', now), true)
})

test('registering a machine twice displaces the older socket', () => {
  const registry = new Registry()
  const closes = []
  const socket = label => ({ close: (code, reason) => closes.push([label, code, reason]) })
  const first = socket('first')
  registry.register('dev1', 'Mac', '0.1.0', first)
  registry.register('dev1', 'Mac', '0.1.0', socket('second'))
  assert.equal(registry.size, 1)
  assert.deepEqual(closes, [['first', 4000, 'replaced by a newer connection']])
})

test('a stale socket closing does not evict the live machine', () => {
  const registry = new Registry()
  const stale = { close: () => {} }
  registry.register('dev1', 'Mac', '0.1.0', stale)
  const live = { close: () => {} }
  registry.register('dev1', 'Mac', '0.1.0', live)
  registry.unregister('dev1', stale)
  assert.equal(registry.find('dev1')?.socket, live)
})

test('a machine refuses more circuits than it can serve', () => {
  const registry = new Registry()
  const machine = registry.register('dev1', 'Mac', '0.1.0', { close: () => {} })
  for (let index = 0; index < 8; index += 1) {
    assert.ok(registry.attach(machine, { close: () => {} }), `circuit ${index}`)
  }
  assert.equal(registry.attach(machine, { close: () => {} }), undefined)
  assert.equal(registry.circuitCount, 8)
})

test('the relay serves the installer only when an operator asks for it', async (t) => {
  const here = new URL('../../install.sh', import.meta.url)
  const server = new RelayServer({ port: 0, host: '127.0.0.1', installScript: here.pathname })
  const port = await server.listen()
  t.after(() => server.close())

  const response = await fetch(`http://127.0.0.1:${String(port)}/install`)
  assert.equal(response.status, 200)
  assert.match(response.headers.get('content-type') ?? '', /text\/plain/u)

  const script = await response.text()
  assert.match(script, /^#!\/usr\/bin\/env sh/u, 'what comes back has to be runnable by sh')
  assert.match(script, /bridle pair/u, 'and it has to end by telling them what to run next')
})

test('the installer route is off by default', async (t) => {
  // Piping an empty body into `sh` succeeds silently and installs nothing,
  // which is worse than an error. And the official deployment does not serve
  // an installer at all: one compromise should not become a supply-chain event.
  const server = new RelayServer({ port: 0, host: '127.0.0.1' })
  const port = await server.listen()
  t.after(() => server.close())

  const response = await fetch(`http://127.0.0.1:${String(port)}/install`)
  assert.equal(response.status, 404)
})

test('the relay refuses machines past its global ceiling', () => {
  // Per-machine limits bound nothing an attacker cares about: a machine identity
  // is a keypair, so anyone can mint as many as they like. Without a global
  // ceiling the free relay is a general-purpose encrypted forwarder with someone
  // else paying, and the first symptom is the host out of file descriptors.
  const registry = new Registry()
  const sockets = []
  // Driven off the exported limit rather than a literal, so tuning capacity for
  // a smaller box does not silently turn this into a no-op test.
  for (let i = 0; i < limits.maxMachines; i += 1) {
    const socket = { close() {} }
    sockets.push(socket)
    registry.register(`dev-${String(i)}`, 'A Mac', '0.1.0', socket)
  }
  assert.equal(registry.size, limits.maxMachines)
  assert.throws(() => registry.register('one-too-many', 'A Mac', '0.1.0', { close() {} }), CapacityError)
})

test('a machine already known can always reconnect, even at the ceiling', () => {
  // Checked after displacement on purpose. Shedding the people already using it
  // is the wrong half of the population to shed, and a laptop that suspends
  // reconnects constantly.
  const registry = new Registry()
  for (let i = 0; i < limits.maxMachines; i += 1) {
    registry.register(`dev-${String(i)}`, 'A Mac', '0.1.0', { close() {} })
  }
  assert.doesNotThrow(() => registry.register('dev-0', 'A Mac', '0.1.0', { close() {} }))
  assert.equal(registry.size, limits.maxMachines, 'reconnecting displaces rather than adds')
})

test('the bridle door is metered like every other entrance', async (t) => {
  // This was the one unmetered path: every other endpoint charged a bucket,
  // while the door that allocates registration state per connection took
  // callers at line rate. A healthy Bridle connects once, so a caller burning
  // through the whole allowance inside a second is not a Bridle.
  const { default: WebSocket } = await import('ws')
  const server = new RelayServer({ port: 0, host: '127.0.0.1' })
  const port = await server.listen()
  t.after(() => server.close())

  const outcomes = await Promise.all(Array.from({ length: 35 }, () =>
    new Promise((resolve) => {
      const socket = new WebSocket(`ws://127.0.0.1:${String(port)}/v1/bridle`)
      const done = (result) => { socket.terminate(); resolve(result) }
      socket.on('message', () => { done('challenged') })
      socket.on('close', (code) => { done(code === 4029 ? 'refused' : 'closed') })
      socket.on('error', () => { done('errored') })
    })))

  const refused = outcomes.filter((outcome) => outcome === 'refused').length
  const challenged = outcomes.filter((outcome) => outcome === 'challenged').length
  assert.ok(refused >= 5, `${String(refused)} of the over-budget connections were refused; the bridle door is still unmetered`)
  assert.ok(challenged <= 30, 'more connections were challenged than the allowance permits')
  assert.ok(challenged >= 1, 'a legitimate first connection was refused outright')
})
