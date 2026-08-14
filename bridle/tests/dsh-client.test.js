/**
 * The one rule this client must never bend: it talks to a harness on this
 * machine, over loopback, and nowhere else. dsh ships with no authentication of
 * its own, so a Bridle pointed at a remote address would be handing a shell to
 * whoever answers.
 */

import assert from 'node:assert/strict'
import test from 'node:test'
import { DshClient, assertLoopback } from '../lib/index.js'

test('loopback addresses in every spelling are accepted', () => {
  for (const url of ['http://127.0.0.1:3080', 'http://localhost:8791', 'http://127.7.7.7:1234', 'http://[::1]:3080']) {
    assert.doesNotThrow(() => assertLoopback(url), url)
  }
})

test('anything off this machine is refused', () => {
  for (const url of ['http://192.168.1.10:3080', 'https://dsh.example.com', 'http://0.0.0.0:3080', 'http://10.0.0.1:3080']) {
    assert.throws(() => assertLoopback(url), /must be loopback/u, url)
  }
})

test('the client refuses to be constructed against a remote harness', () => {
  assert.throws(() => new DshClient({ baseUrl: 'http://example.com' }), /must be loopback/u)
})

test('an unreachable harness reports unreachable instead of throwing', async () => {
  // Port 1 is reserved and never listening, which is exactly the "harness is
  // not running" case a first-time user hits.
  const client = new DshClient({ baseUrl: 'http://127.0.0.1:1', requestTimeoutMs: 1_000 })
  const health = await client.health()
  assert.equal(health.reachable, false)
  assert.ok(typeof health.detail === 'string' && health.detail.length > 0)
})

test('a failed call folds into the error branch rather than rejecting', async () => {
  const client = new DshClient({ baseUrl: 'http://127.0.0.1:1', requestTimeoutMs: 1_000 })
  const result = await client.call('session.list', {})
  assert.equal(result.ok, false)
  assert.equal(typeof result.error.message, 'string')
})
